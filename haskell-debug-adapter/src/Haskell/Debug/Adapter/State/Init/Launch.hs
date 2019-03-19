{-# LANGUAGE MultiParamTypeClasses #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Haskell.Debug.Adapter.State.Init.Launch where

import Control.Monad.IO.Class
import Control.Monad.Except
import Control.Monad.State
import Control.Concurrent
import Control.Lens
import System.Directory
import System.FilePath
import Text.Parsec
import qualified Text.Read as R
import qualified System.Log.Logger as L
import qualified Data.String.Utils as U
import qualified Data.ByteString.Lazy as LB
import qualified Data.List as L
import qualified Data.Version as V

import qualified Haskell.DAP as DAP
import qualified Haskell.Debug.Adapter.Utility as U
import qualified Haskell.Debug.Adapter.State.Utility as SU
import Haskell.Debug.Adapter.Type
import Haskell.Debug.Adapter.Constant
import qualified Haskell.Debug.Adapter.Logger as L
import qualified Haskell.Debug.Adapter.GHCi as P

-- |
--   Any errors should be critical. don't catch anything here.
--
instance StateRequestIF InitState DAP.LaunchRequest where
  action (Init_Launch req) = do
    liftIO $ L.debugM _LOG_APP $ "InitState LaunchRequest called. " ++ show req
    app req


-- |
--   @see https://github.com/Microsoft/vscode/issues/4902
--   @see https://microsoft.github.io/debug-adapter-protocol/overview
-- 
app :: DAP.LaunchRequest -> AppContext (Maybe StateTransit)
app req = do
  
  setUpConfig req
  setUpLogger req
  createTasksJsonFile

  U.sendStdoutEvent "Configuration read.\n"
  U.sendConsoleEvent "Starting GHCi.\n"
  U.sendErrorEvent "Wait for a moment.\n\n"

  -- must start here. can not start in the entry of GHCiRun State.
  -- because there is a transition from DebugRun to GHCiRun.
  startGHCi req
  initGHCi

  -- dont send launch response here.
  -- it must send after configuration done response.
  modify $ \s-> s{_launchReqSeqAppStores = DAP.seqLaunchRequest req}

  -- after initialized event, vscode send setBreak... and
  -- ConfigurationDone request.
  initSeq <- U.getIncreasedResponseSequence
  U.addResponse $ InitializedEvent $ DAP.defaultInitializedEvent {DAP.seqInitializedEvent = initSeq}
  
  return $ Just Init_GHCiRun


-- |
--
setUpConfig :: DAP.LaunchRequest -> AppContext ()
setUpConfig req = do
  let args = DAP.argumentsLaunchRequest req
  appStores <- get
  
  let wsMVar = appStores^.workspaceAppStores
      ws = DAP.workspaceLaunchRequestArguments args
  _ <- liftIO $ takeMVar wsMVar
  liftIO $ putMVar wsMVar ws
  liftIO $ L.debugM _LOG_APP $ "workspace is " ++ ws

  let logPRMVar = appStores^.logPriorityAppStores
  logPR <- getLogPriority $ DAP.logLevelLaunchRequestArguments args
  _ <- liftIO $ takeMVar logPRMVar
  liftIO $ putMVar logPRMVar logPR

  put appStores {
      _startupAppStores     = U.replace [_SEP_WIN] [_SEP_UNIX] (DAP.startupLaunchRequestArguments args)
    , _startupFuncAppStores = maybe "" (\s->if null (U.strip s) then "" else  (U.strip s)) (DAP.startupFuncLaunchRequestArguments args)
    , _startupArgsAppStores = maybe "" (id) (DAP.startupArgsLaunchRequestArguments args)
    , _stopOnEntryAppStores = DAP.stopOnEntryLaunchRequestArguments args
    , _mainArgsAppStores    = maybe "" (id) (DAP.mainArgsLaunchRequestArguments args)
    }

  where
    getLogPriority logPRStr = case R.readEither logPRStr of
      Right lv -> return lv
      Left err -> do
        U.sendErrorEvent $ "log priority is invalid. WARNING set. [" ++ err ++ "]\n"
        return L.WARNING

-- |
--
setUpLogger :: DAP.LaunchRequest -> AppContext ()
setUpLogger req = do
  let args = DAP.argumentsLaunchRequest req
  ctx <- get
  logPR <- liftIO $ readMVar $ ctx^.logPriorityAppStores

  liftIO $ L.setUpLogger (DAP.logFileLaunchRequestArguments args) logPR


-- |
--
createTasksJsonFile :: AppContext ()
createTasksJsonFile = do
  ctx <- get
  wsPath <- liftIO $ readMVar $ ctx^.workspaceAppStores
  let jsonDir  = wsPath </> ".vscode"
      jsonFile = jsonDir </> "tasks.json"

  catchError
    (checkDir jsonDir >> checkFile jsonFile >> createFile jsonFile)
    errHdl

  where

    -- |
    --
    errHdl msg = liftIO $ L.debugM _LOG_APP msg

    -- |
    --
    checkDir jsonDir = liftIO (doesDirectoryExist jsonDir) >>= \case
      False -> throwError $ "setting folder not found. skip saveing tasks.json. DIR:" ++ jsonDir
      True -> return () 

    -- |
    --
    checkFile jsonFile = liftIO (doesFileExist jsonFile) >>= \case
      True -> throwError $ "tasks.json file exists. " ++ jsonFile
      False -> return () 

    -- |
    --
    createFile jsonFile = do
      liftIO $ U.saveFileBSL jsonFile _TASKS_JSON_FILE_CONTENTS
      U.sendConsoleEvent $ "create tasks.json file. " ++ jsonFile ++ "\n"


-- |
--
startGHCi :: DAP.LaunchRequest -> AppContext ()
startGHCi req = do
  let args = DAP.argumentsLaunchRequest req
      initPmpt = maybe _GHCI_PROMPT id (DAP.ghciInitialPromptLaunchRequestArguments args)
      envs = DAP.ghciEnvLaunchRequestArguments args
      cmdStr = DAP.ghciCmdLaunchRequestArguments args
      cmdList = filter (not.null) $ U.split " " cmdStr
      cmd  = head cmdList
      opts = tail cmdList

  appStores <- get
  cwd <- liftIO $ readMVar $ appStores^.workspaceAppStores

  liftIO $ L.debugM _LOG_APP $ "ghci initial prompt [" ++ initPmpt ++ "]."

  U.sendStdoutEventLF $ "CWD:" ++ cwd
  U.sendStdoutEventLF $ "CMD:" ++ L.intercalate " " (cmd : opts)
  U.sendStdoutEventLF ""

  P.startGHCi cmd opts cwd envs
  P.expect initPmpt expCallBK

  where
    expCallBK _ _ ([]) = return ()
    expCallBK True  acc (x:[]) = do
      U.sendStdoutEvent x
      updateGHCiVersion acc
    expCallBK False _ (x:[]) = U.sendStdoutEventLF x
    expCallBK True  _ xs = do
      mapM_ U.sendStdoutEventLF $ init xs
      U.sendStdoutEvent $ last xs
    expCallBK False _ xs = mapM_ U.sendStdoutEventLF xs

    updateGHCiVersion acc = case parse verParser "getGHCiVersion" (unlines acc) of
      Right v -> updateGHCiVersion' v
      Left e  -> do
        U.sendConsoleEventLF $ "can not parse ghci version. [" ++ show e ++ "] assumes "  ++ V.showVersion _BASE_GHCI_VERSION ++ "."
        updateGHCiVersion' _BASE_GHCI_VERSION

    verParser = do
      _ <- manyTill anyChar (try (string "GHCi, version "))
      v1 <- manyTill digit (char '.')
      v2 <- manyTill digit (char '.')
      v3 <- manyTill digit (char ':')
      return $ V.makeVersion [read v1, read v2, read v3]

    updateGHCiVersion' v = do
      -- U.debugEV _LOG_APP $ "GHCi version is " ++ V.showVersion v
      mver <- view ghciVerAppStores <$> get
      liftIO $ putMVar mver v


-- |
--
initGHCi :: AppContext ()
initGHCi = do
  setPrompt
  setMainArgs

  file <- view startupAppStores <$> get
  SU.loadHsFile file

-- |
--
setPrompt :: AppContext ()
setPrompt = do
  p <- view ghciPmptAppStores <$> get
  let pmpt = _DAP_CMD_END2 ++ "\\n" ++ p
      cmd  = ":set prompt \""++pmpt++"\""
      cmd2 = ":set prompt-cont \""++pmpt++"\""

  P.cmdAndOut cmd
  P.expectH P.stdoutCallBk

  P.cmdAndOut cmd2
  P.expectH P.stdoutCallBk

  return ()

-- |
--
setMainArgs :: AppContext ()
setMainArgs = view mainArgsAppStores <$> get >>= \case
  [] -> return ()
  args -> do
    let cmd  = ":set args "++args

    P.cmdAndOut cmd
    P.expectH P.stdoutCallBk

    return ()


-- |
--
_TASKS_JSON_FILE_CONTENTS :: LB.ByteString
_TASKS_JSON_FILE_CONTENTS = U.str2lbs $ U.join "\n" $
  [
    "{"
  , "  // atuomatically created by phoityne-vscode"
  , "  "
  , "  \"version\": \"2.0.0\","
  , "  \"presentation\": {"
  , "    \"reveal\": \"always\","
  , "    \"panel\": \"new\""
  , "  },"
  , "  \"tasks\": ["
  , "    {"
  , "      \"group\": {"
  , "        \"kind\": \"build\","
  , "        \"isDefault\": true"
  , "      },"
  , "      \"label\": \"stack build\","
  , "      \"type\": \"shell\","
  , "      \"command\": \"echo START_STACK_BUILD && cd ${workspaceRoot} && stack build && echo END_STACK_BUILD \""
  , "    },"
  , "    { "
  , "      \"group\": \"build\","
  , "      \"type\": \"shell\","
  , "      \"label\": \"stack clean & build\","
  , "      \"command\": \"echo START_STACK_CLEAN_AND_BUILD && cd ${workspaceRoot} && stack clean && stack build && echo END_STACK_CLEAN_AND_BUILD \""
  , "    },"
  , "    { "
  , "      \"group\": {"
  , "        \"kind\": \"test\","
  , "        \"isDefault\": true"
  , "      },"
  , "      \"type\": \"shell\","
  , "      \"label\": \"stack test\","
  , "      \"command\": \"echo START_STACK_TEST && cd ${workspaceRoot} && stack test && echo END_STACK_TEST \""
  , "    },"
  , "    { "
  , "      \"isBackground\": true,"
  , "      \"type\": \"shell\","
  , "      \"label\": \"stack watch\","
  , "      \"command\": \"echo START_STACK_WATCH && cd ${workspaceRoot} && stack build --test --no-run-tests --file-watch && echo END_STACK_WATCH \""
  , "    }"
  , "  ]"
  , "}"
  ]

