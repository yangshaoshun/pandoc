{-# LANGUAGE DeriveFunctor, DeriveDataTypeable, TypeSynonymInstances,
FlexibleInstances, GeneralizedNewtypeDeriving, FlexibleContexts #-}

{-
Copyright (C) 2016 Jesse Rosenthal <jrosenthal@jhu.edu>

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
-}

{- |
   Module      : Text.Pandoc.Class
   Copyright   : Copyright (C) 2016 Jesse Rosenthal
   License     : GNU GPL, version 2 or above

   Maintainer  : Jesse Rosenthal <jrosenthal@jhu.edu>
   Stability   : alpha
   Portability : portable

Typeclass for pandoc readers and writers, allowing both IO and pure instances.
-}

module Text.Pandoc.Class ( PandocMonad(..)
                         , TestState(..)
                         , TestEnv(..)
                         , getPOSIXTime
                         , PandocIO(..)
                         , PandocPure(..)
                         , PandocExecutionError(..)
                         , runIO
                         , runIOorExplode
                         , runPure
                         ) where

import Prelude hiding (readFile, fail)
import qualified Control.Monad as M (fail)
import System.Random (StdGen, next, mkStdGen)
import qualified System.Random as IO (newStdGen)
import Codec.Archive.Zip (Archive, fromArchive, emptyArchive)
import Data.Unique (hashUnique)
import qualified Data.Unique as IO (newUnique)
import qualified Text.Pandoc.Shared as IO ( fetchItem
                                          , fetchItem'
                                          , getDefaultReferenceDocx
                                          , getDefaultReferenceODT
                                          , warn
                                          , readDataFile)
import Text.Pandoc.MediaBag (MediaBag, lookupMedia)
import Text.Pandoc.Compat.Time (UTCTime)
import qualified Text.Pandoc.Compat.Time as IO (getCurrentTime)
import Data.Time.Clock.POSIX ( utcTimeToPOSIXSeconds
                             , posixSecondsToUTCTime
                             , POSIXTime )
import Text.Pandoc.MIME (MimeType, getMimeType)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import qualified Control.Exception as E
import qualified System.Environment as IO (lookupEnv)
import System.FilePath.Glob (match, compile)
import System.FilePath ((</>))
import qualified System.FilePath.Glob as IO (glob)
import Control.Monad.State hiding (fail)
import Control.Monad.Reader hiding (fail)
import Control.Monad.Except hiding (fail)
import Data.Word (Word8)
import Data.Typeable
import Data.Default
import System.IO.Error

class (Functor m, Applicative m, Monad m, MonadError PandocExecutionError m) => PandocMonad m where
  lookupEnv :: String -> m (Maybe String)
  getCurrentTime :: m UTCTime
  getDefaultReferenceDocx :: Maybe FilePath -> m Archive
  getDefaultReferenceODT :: Maybe FilePath -> m Archive
  newStdGen :: m StdGen
  newUniqueHash :: m Int
  readFileLazy :: FilePath -> m BL.ByteString
  readDataFile :: Maybe FilePath
               -> FilePath
               -> m B.ByteString
  fetchItem :: Maybe String
            -> String
            -> m (Either E.SomeException (B.ByteString, Maybe MimeType))
  fetchItem' :: MediaBag
             -> Maybe String
             -> String
             -> m (Either E.SomeException (B.ByteString, Maybe MimeType))
  warn :: String -> m ()
  fail :: String -> m b
  glob :: String -> m [FilePath]

--Some functions derived from Primitives:

getPOSIXTime :: (PandocMonad m) => m POSIXTime
getPOSIXTime = utcTimeToPOSIXSeconds <$> getCurrentTime


-- We can add to this as we go
data PandocExecutionError = PandocFileReadError FilePath
                          | PandocShouldNeverHappenError String
                          | PandocSomeError String
                          deriving (Show, Typeable)

-- Nothing in this for now, but let's put it there anyway.
data PandocStateIO = PandocStateIO
  deriving Show

instance Default PandocStateIO where
  def = PandocStateIO

runIO :: PandocIO a -> IO (Either PandocExecutionError a)
runIO ma = flip evalStateT def $ runExceptT $ unPandocIO ma

runIOorExplode :: PandocIO a -> IO a
runIOorExplode ma = do
  eitherVal <- runIO ma
  case eitherVal of
    Right x -> return x
    Left (PandocFileReadError fp) -> error $ "promple reading " ++ fp
    Left (PandocShouldNeverHappenError s) -> error s
    Left (PandocSomeError s) -> error s

newtype PandocIO a = PandocIO {
  unPandocIO :: ExceptT PandocExecutionError (StateT PandocStateIO IO) a
  } deriving (MonadIO, Functor, Applicative, Monad, MonadError PandocExecutionError)

instance PandocMonad PandocIO where  
  lookupEnv = liftIO . IO.lookupEnv
  getCurrentTime = liftIO IO.getCurrentTime
  getDefaultReferenceDocx = liftIO . IO.getDefaultReferenceDocx
  getDefaultReferenceODT = liftIO . IO.getDefaultReferenceODT
  newStdGen = liftIO IO.newStdGen
  newUniqueHash = hashUnique <$> (liftIO IO.newUnique)
  readFileLazy s = do
    eitherBS <- liftIO (tryIOError $ BL.readFile s)
    case eitherBS of
      Right bs -> return bs
      Left _ -> throwError $ PandocFileReadError s
  -- TODO: Make this more sensitive to the different sorts of failure
  readDataFile mfp fname = do
    eitherBS <- liftIO (tryIOError $ IO.readDataFile mfp fname)
    case eitherBS of
      Right bs -> return bs
      Left _ -> throwError $ PandocFileReadError fname
  fail = M.fail
  fetchItem ms s = liftIO $ IO.fetchItem ms s
  fetchItem' mb ms s = liftIO $ IO.fetchItem' mb ms s
  warn = liftIO . IO.warn
  glob = liftIO . IO.glob

data TestState = TestState { stStdGen     :: StdGen
                           , stWord8Store :: [Word8] -- should be
                                                     -- inifinite,
                                                     -- i.e. [1..]
                           , stWarnings   :: [String]
                           , stUniqStore  :: [Int] -- should be
                                                   -- inifinite and
                                                   -- contain every
                                                   -- element at most
                                                   -- once, e.g. [1..]
                           }

instance Default TestState where
  def = TestState { stStdGen = mkStdGen 1848
                  , stWord8Store = [1..]
                  , stWarnings = []
                  , stUniqStore = [1..]
                  }

data TestEnv = TestEnv { envEnv :: [(String, String)]
                       , envTime :: UTCTime
                       , envReferenceDocx :: Archive
                       , envReferenceODT :: Archive
                       , envFiles :: [(FilePath, B.ByteString)]
                       , envUserDataDir :: [(FilePath, B.ByteString)]
                       , envCabalDataDir :: [(FilePath, B.ByteString)]
                       , envFontFiles :: [FilePath]
                       }

-- We have to figure this out a bit more. But let's put some empty
-- values in for the time being.
instance Default TestEnv where
  def = TestEnv { envEnv = [("USER", "pandoc-user")]
                , envTime = posixSecondsToUTCTime 0
                , envReferenceDocx = emptyArchive
                , envReferenceODT = emptyArchive
                , envFiles = []
                , envUserDataDir = []
                , envCabalDataDir = []
                , envFontFiles = []
                }

instance E.Exception PandocExecutionError

newtype PandocPure a = PandocPure {
  unPandocPure :: ExceptT PandocExecutionError
                  (ReaderT TestEnv (State TestState)) a
  } deriving (Functor, Applicative, Monad, MonadReader TestEnv, MonadState TestState, MonadError PandocExecutionError)

runPure :: PandocPure a -> Either PandocExecutionError a
runPure x = flip evalState def $ flip runReaderT def $ runExceptT $ unPandocPure x

instance PandocMonad PandocPure where
  lookupEnv s = do
    env <- asks envEnv
    return (lookup s env)

  getCurrentTime = asks envTime

  getDefaultReferenceDocx _ = asks envReferenceDocx

  getDefaultReferenceODT _ = asks envReferenceODT

  newStdGen = do
    g <- gets stStdGen
    let (_, nxtGen) = next g
    modify $ \st -> st { stStdGen = nxtGen }
    return g

  newUniqueHash = do
    uniqs <- gets stUniqStore
    case uniqs of
      u : us -> do
        modify $ \st -> st { stUniqStore = us }
        return u
      _ -> M.fail "uniq store ran out of elements"
  readFileLazy fp =   do
    fps <- asks envFiles
    case lookup fp fps of
      Just bs -> return (BL.fromStrict bs)
      Nothing -> throwError $ PandocFileReadError fp
  readDataFile Nothing "reference.docx" = do
    (B.concat . BL.toChunks . fromArchive) <$> (getDefaultReferenceDocx Nothing)
  readDataFile Nothing "reference.odt" = do
    (B.concat . BL.toChunks . fromArchive) <$> (getDefaultReferenceODT Nothing)
  readDataFile Nothing fname = do
    let fname' = if fname == "MANUAL.txt" then fname else "data" </> fname
    BL.toStrict <$> (readFileLazy fname')
  readDataFile (Just userDir) fname = do
    userDirFiles <- asks envUserDataDir
    case lookup (userDir </> fname) userDirFiles of
      Just bs -> return bs
      Nothing -> readDataFile Nothing fname
  fail = M.fail
  fetchItem _ fp = do
    fps <- asks envFiles
    case lookup fp fps of
      Just bs -> return (Right (bs, getMimeType fp))
      Nothing -> return (Left $ E.toException $ PandocFileReadError fp)

  fetchItem' media sourceUrl nm = do
    case lookupMedia nm media of
      Nothing -> fetchItem sourceUrl nm
      Just (mime, bs) -> return (Right (B.concat $ BL.toChunks bs, Just mime))

  warn s =  modify $ \st -> st { stWarnings = s : stWarnings st }

  glob s = do
    fontFiles <- asks envFontFiles
    return (filter (match (compile s)) fontFiles)
