{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Snap.Util.GZip
( withCompression
, withCompression' ) where

import qualified Codec.Compression.GZip as GZip
import qualified Codec.Compression.Zlib as Zlib
import           Control.Concurrent
import           Control.Applicative hiding (many)
import           Control.Exception
import           Control.Monad
import           Control.Monad.Trans
import           Data.Attoparsec.Char8 hiding (Done)
import qualified Data.Attoparsec.Char8 as Atto
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as L
import           Data.ByteString.Char8 (ByteString)
import           Data.Iteratee.WrappedByteString
import qualified Data.Set as Set
import           Data.Set (Set)
import           Data.Typeable
import           Prelude hiding (catch, takeWhile)

------------------------------------------------------------------------------
import           Snap.Internal.Debug
import           Snap.Iteratee hiding (Enumerator)
import           Snap.Types


------------------------------------------------------------------------------
-- | Runs a 'Snap' web handler with compression if available.
--
-- If the client has indicated support for @gzip@ or @compress@ in its
-- @Accept-Encoding@ header, and the @Content-Type@ in the response is one of
-- the following types:
--
--   * @application/x-javascript@
--
--   * @text/css@
--
--   * @text/html@
--
--   * @text/javascript@
--
--   * @text/plain@
--
--   * @text/xml@
--
-- Then the given handler's output stream will be compressed,
-- @Content-Encoding@ will be set in the output headers, and the
-- @Content-Length@ will be cleared if it was set. (We can't process the stream
-- in O(1) space if the length is known beforehand.)

withCompression :: Snap a   -- ^ the web handler to run
                -> Snap ()
withCompression = withCompression' compressibleMimeTypes


------------------------------------------------------------------------------
-- | The same as 'withCompression', with control over which MIME types to
-- compress.
withCompression' :: Set ByteString
                    -- ^ set of compressible MIME types
                 -> Snap a
                    -- ^ the web handler to run
                 -> Snap ()
withCompression' mimeTable action = do
    _    <- action
    resp <- getResponse
    let mbCt = getHeader "Content-Type" resp

    debug $ "withCompression', content-type is " ++ show mbCt

    case mbCt of
      (Just (ct:_)) -> if Set.member ct mimeTable
                         then chkAcceptEncoding
                         else return ()
      _             -> return ()

  where
    chkAcceptEncoding :: Snap ()
    chkAcceptEncoding = do
        req <- getRequest
        debug $ "checking accept-encoding"
        let mbAcc = getHeader "Accept-Encoding" req
        debug $ "accept-encoding is " ++ show mbAcc
        let s = case mbAcc of
                  Nothing -> ""
                  Just xs -> B.intercalate " " xs

        types <- liftIO $ parseAcceptEncoding s

        chooseType types


    chooseType []               = return ()
    chooseType ("gzip":_)       = gzipCompression
    chooseType ("compress":_)   = compressCompression
    chooseType ("x-gzip":_)     = gzipCompression
    chooseType ("x-compress":_) = compressCompression
    chooseType (_:xs)           = chooseType xs


------------------------------------------------------------------------------
-- private following
------------------------------------------------------------------------------


------------------------------------------------------------------------------
compressibleMimeTypes :: Set ByteString
compressibleMimeTypes = Set.fromList [ "application/x-javascript"
                                     , "text/css"
                                     , "text/html"
                                     , "text/javascript"
                                     , "text/plain"
                                     , "text/xml" ]




------------------------------------------------------------------------------
gzipCompression :: Snap ()
gzipCompression = modifyResponse f
  where
    f = setHeader "Content-Encoding" "gzip" .
        clearContentLength .
        filterResponseBody gcompress


------------------------------------------------------------------------------
compressCompression :: Snap ()
compressCompression = modifyResponse f
  where
    f = setHeader "Content-Encoding" "compress" .
        clearContentLength .
        filterResponseBody ccompress


------------------------------------------------------------------------------
gcompress :: forall a . Enumerator a -> Enumerator a
gcompress = compressEnumerator GZip.compress


------------------------------------------------------------------------------
ccompress :: forall a . Enumerator a -> Enumerator a
ccompress = compressEnumerator Zlib.compress


------------------------------------------------------------------------------
compressEnumerator :: forall a .
                      (L.ByteString -> L.ByteString)
                   -> Enumerator a
                   -> Enumerator a
compressEnumerator compFunc enum iteratee = do
    writeEnd <- newChan
    readEnd  <- newChan
    tid      <- forkIO $ threadProc readEnd writeEnd

    enum (IterateeG $ f readEnd writeEnd tid iteratee)

  where
    --------------------------------------------------------------------------
    streamFinished :: Stream -> Bool
    streamFinished (EOF _)   = True
    streamFinished (Chunk _) = False


    --------------------------------------------------------------------------
    consumeSomeOutput :: Chan Stream
                      -> Iteratee IO a
                      -> IO (Iteratee IO a)
    consumeSomeOutput writeEnd iter = do
        e <- isEmptyChan writeEnd
        if e
          then return iter
          else do
            ch <- readChan writeEnd

            iter' <- liftM liftI $ runIter iter ch
            if (streamFinished ch)
               then return iter'
               else consumeSomeOutput writeEnd iter'


    --------------------------------------------------------------------------
    consumeRest :: Chan Stream
                -> Iteratee IO a
                -> IO (IterV IO a)
    consumeRest writeEnd iter = do
        ch <- readChan writeEnd

        iv <- runIter iter ch
        if (streamFinished ch)
           then return iv
           else consumeRest writeEnd $ liftI iv


    --------------------------------------------------------------------------
    f readEnd writeEnd tid i (EOF Nothing) = do
        debug $ "f (EOF Nothing)"
        writeChan readEnd Nothing
        x <- consumeRest writeEnd i
        killThread tid
        return x

    f _ _ tid i ch@(EOF (Just _)) = do
        debug $ "f (EOF err)"
        x <- runIter i ch
        killThread tid
        return x

    f readEnd writeEnd tid i (Chunk s') = do
        let s = unWrap s'
        debug $ "f (Chunk " ++ show s ++ ")"
        writeChan readEnd $ Just s
        i' <- consumeSomeOutput writeEnd i
        return $ Cont (IterateeG $ f readEnd writeEnd tid i') Nothing


    --------------------------------------------------------------------------
    threadProc :: Chan (Maybe ByteString)
               -> Chan Stream
               -> IO ()
    threadProc readEnd writeEnd = do
        stream <- getChanContents readEnd
        let bs = L.fromChunks $ streamToChunks stream

        let output = L.toChunks $ compFunc bs
        let runIt = do
            mapM_ (writeChan writeEnd . toChunk) output
            writeChan writeEnd $ EOF Nothing

        runIt `catch` \(e::SomeException) ->
            writeChan writeEnd $ EOF (Just $ Err $ show e)


    --------------------------------------------------------------------------
    streamToChunks []            = []
    streamToChunks (Nothing:_)   = []
    streamToChunks ((Just x):xs) = x:(streamToChunks xs)


    --------------------------------------------------------------------------
    toChunk = Chunk . WrapBS


fullyParse :: ByteString -> Parser a -> Either String a
fullyParse s p =
    case r' of
      (Fail _ _ e)    -> Left e
      (Partial _)     -> Left "parse failed"
      (Atto.Done _ x) -> Right x
  where
    r  = parse p s
    r' = feed r ""


-- We're not gonna bother with quality values; we'll do gzip or compress in
-- that order
acceptParser :: Parser [ByteString]
acceptParser = do
    xs <- option [] $ (:[]) <$> encoding
    ys <- many (char ',' *> encoding)
    endOfInput
    return $ xs ++ ys
  where
    encoding = skipSpace *> c <* skipSpace

    c = do
        x <- coding
        option () qvalue
        return x

    qvalue = do
        skipSpace
        char ';'
        skipSpace
        char 'q'
        skipSpace
        char '='
        float
        return ()

    coding = string "*" <|> takeWhile isAlpha_ascii

    float = takeWhile isDigit >>
            option () (char '.' >> takeWhile isDigit >> pure ())


data BadAcceptEncodingException = BadAcceptEncodingException
   deriving (Typeable)

instance Show BadAcceptEncodingException where
    show BadAcceptEncodingException = "bad 'accept-encoding' header"

instance Exception BadAcceptEncodingException


------------------------------------------------------------------------------
parseAcceptEncoding :: ByteString -> IO [ByteString]
parseAcceptEncoding s =
    case r of
      Left _ -> throwIO BadAcceptEncodingException
      Right x -> return x
  where
    r = fullyParse s acceptParser

