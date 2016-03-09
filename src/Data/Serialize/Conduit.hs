-- Taken from <https://www.stackage.org/lts-5.2/package/cereal-conduit-0.7.2.5> (BSD3 license),
-- see URL for additional license and copyright info.

{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE RankNTypes #-}
-- | Turn a 'Get' into a 'Sink' and a 'Put' into a 'Source'
-- These functions are built upno the Data.Conduit.Cereal.Internal functions with default
-- implementations of 'ErrorHandler' and 'TerminationHandler'
--
-- The default 'ErrorHandler' and 'TerminationHandler' both throw a 'GetException'.

module Data.Serialize.Conduit ( GetException
                           , sinkGet
                           , conduitGet
                           , conduitGet2
                           , sourcePut
                           , conduitPut
                           ) where

import           Control.Exception.Base
import           Control.Monad.Trans.Class (MonadTrans, lift)
import           Control.Monad.Trans.Resource (MonadThrow, monadThrow)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Conduit as C
import qualified Data.Conduit.List as CL
import           Data.Serialize hiding (get, put)
import           Data.Typeable
import           Control.Monad (forever, when)

-- | What should we do if the Get fails?
type ConduitErrorHandler m o = String -> C.Conduit BS.ByteString m o
type SinkErrorHandler m r = String -> C.Consumer BS.ByteString m r

-- | What should we do if the stream is done before the Get is done?
type SinkTerminationHandler m r = (BS.ByteString -> Result r) -> C.Consumer BS.ByteString m r

-- | Construct a conduitGet with the specified 'ErrorHandler'
mkConduitGet :: Monad m
             => ConduitErrorHandler m o
             -> Get o
             -> C.Conduit BS.ByteString m o
mkConduitGet errorHandler get = consume True (runGetPartial get) [] BS.empty
  where pull f b s
          | BS.null s = C.await >>= maybe (when (not $ null b) (C.leftover $ BS.concat $ reverse b)) (pull f b)
          | otherwise = consume False f b s
        consume initial f b s = case f s of
          Fail msg _ -> do
            when (not $ null b) (C.leftover $ BS.concat $ reverse consumed)
            errorHandler msg
          Partial p -> pull p consumed BS.empty
          Done a s' -> case initial of
                         -- this only works because the Get will either _always_ consume no input, or _never_ consume no input.
                         True  -> forever $ C.yield a
                         False -> C.yield a >> pull (runGetPartial get) [] s'
--                         False -> C.yield a >> C.leftover s' >> mkConduitGet errorHandler get
          where consumed = s : b

-- | Construct a sinkGet with the specified 'ErrorHandler' and 'TerminationHandler'
mkSinkGet :: Monad m
          => SinkErrorHandler m r
          -> SinkTerminationHandler m r
          -> Get r
          -> C.Consumer BS.ByteString m r
mkSinkGet errorHandler terminationHandler get = consume (runGetPartial get) [] BS.empty
  where pull f b s
          | BS.null s = C.await >>= \ x -> case x of
                          Nothing -> when (not $ null b) (C.leftover $ BS.concat $ reverse b) >> terminationHandler f
                          Just a -> pull f b a
          | otherwise = consume f b s
        consume f b s = case f s of
          Fail msg _ -> do
            when (not $ null b) (C.leftover $ BS.concat $ reverse consumed)
            errorHandler msg
          Partial p -> pull p consumed BS.empty
          Done r s' -> when (not $ BS.null s') (C.leftover s') >> return r
          where consumed = s : b



data GetException = GetException String
  deriving (Show, Typeable)

instance Exception GetException

-- | Run a 'Get' repeatedly on the input stream, producing an output stream of whatever the 'Get' outputs.
conduitGet :: MonadThrow m => Get o -> C.Conduit BS.ByteString m o
conduitGet = mkConduitGet errorHandler
  where errorHandler msg = pipeError $ GetException msg
{-# DEPRECATED conduitGet "Please switch to conduitGet2, see comment on that function" #-}

-- | Convert a 'Get' into a 'Sink'. The 'Get' will be streamed bytes until it returns 'Done' or 'Fail'.
--
-- If 'Get' succeed it will return the data read and unconsumed part of the input stream.
-- If the 'Get' fails due to deserialization error or early termination of the input stream it raise an error.
sinkGet :: MonadThrow m => Get r -> C.Consumer BS.ByteString m r
sinkGet = mkSinkGet errorHandler terminationHandler
  where errorHandler msg = pipeError $ GetException msg
        terminationHandler f = case f BS.empty of
          Fail msg _ -> pipeError $ GetException msg
          Done r lo -> C.leftover lo >> return r
          Partial _ -> pipeError $ GetException "Failed reading: Internal error: unexpected Partial."

pipeError :: (MonadThrow m, MonadTrans t, Exception e) => e -> t m a
pipeError e = lift $ monadThrow e

-- | Convert a 'Put' into a 'Source'. Runs in constant memory.
sourcePut :: Monad m => Put -> C.Producer m BS.ByteString
sourcePut put = CL.sourceList $ LBS.toChunks $ runPutLazy put

-- | Run a 'Putter' repeatedly on the input stream, producing a concatenated 'ByteString' stream.
conduitPut :: Monad m => Putter a -> C.Conduit a m BS.ByteString
conduitPut p = CL.map $ runPut . p

-- | Reapply @Get o@ to a stream of bytes as long as more data is available,
-- and yielding each new value downstream. This has a few differences from
-- @conduitGet@:
--
-- * If there is a parse failure, the bytes consumed so far by this will not be
-- returned as leftovers. The reason for this is that the only way to guarantee
-- the leftovers will be returned correctly is to hold onto all consumed
-- @ByteString@s, which leads to non-constant memory usage.
--
-- * This function will properly terminate a @Get@ function at end of stream,
-- see https://github.com/snoyberg/conduit/issues/246.
--
-- * @conduitGet@ will pass empty @ByteString@s from the stream directly to
-- cereal, which will trigger cereal to think that the stream has been closed.
-- This breaks the normal abstraction in conduit of ignoring how data is
-- chunked. In @conduitGet2@, all empty @ByteString@s are filtered out and not
-- passed to cereal.
--
-- * After @conduitGet2@ successfully returns, we are guaranteed that there is
-- no data left to be consumed in the stream.
--
-- @since 0.7.3
conduitGet2 :: MonadThrow m => Get o -> C.Conduit BS.ByteString m o
conduitGet2 get =
    awaitNE >>= start
  where
    -- Get the next chunk of data, only returning an empty ByteString at the
    -- end of the stream.
    awaitNE =
        loop
      where
        loop = C.await >>= maybe (return BS.empty) check
        check bs
            | BS.null bs = loop
            | otherwise = return bs

    start bs
        | BS.null bs = return ()
        | otherwise = result (runGetPartial get bs)

    result (Fail msg _) = monadThrow (GetException msg)
    -- This will feed an empty ByteString into f at end of stream, which is how
    -- we indicate to cereal that there is no data left. If we wanted to be
    -- more pedantic, we could ensure that cereal only ever consumes a single
    -- ByteString to avoid a loop, but that is the contract that cereal is
    -- giving us anyway.
    result (Partial f) = awaitNE >>= result . f
    result (Done x rest) = do
        C.yield x
        if BS.null rest
            then awaitNE >>= start
            else start rest
