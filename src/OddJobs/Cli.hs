{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE DataKinds #-}
module OddJobs.Cli where

import Options.Applicative as Opts
import Data.Text
import OddJobs.Job (startJobRunner, Config(..))
import System.Daemonize (DaemonOptions(..), daemonize)
import System.Posix.Process (getProcessID)
import qualified System.Directory as Dir
import qualified System.Exit as Exit
import System.Environment (getProgName)
import OddJobs.Types (Seconds(..), delaySeconds)
import qualified System.Posix.Signals as Sig
import qualified UnliftIO.Async as Async
import qualified OddJobs.Endpoints as UI
import Servant.Server as Servant
import Servant.API
import Data.Proxy
import Data.Text.Encoding (decodeUtf8)
import Network.Wai.Handler.Warp as Warp

-- * Introduction
--
-- $intro
--
-- This module has a bunch of functions (that use the 'optparse-applicative'
-- library) to help you rapidly build a standalone job-runner deamon based on
-- odd-jobs. You should probably start-off by using the pre-packaged [default
-- behaviour](#defaultBehaviour), notably the 'defaultMain' function. If the
-- default behaviour of the resultant CLI doesn't suit your needs, consider
-- reusing\/extending the [individual argument parsers](#parsers). If you find
-- you cannot reuse those, then it would be best to write your CLI from scratch
-- instead of force-fitting whatever has been provided here.
--
-- It is __highly recommended__ that you read the following links before putting
-- odd-jobs into production.
--
--   * The [getting started
--     guide](https://www.haskelltutorials.com/odd-jobs/guide.html#getting-started)
--     which will walk you through a bare-bones example of using the
--     'defaultMain' function. It should make the callback-within-callback
--     clearer.
--
--   * The [section on
--     deployment](https://www.haskelltutorials.com/odd-jobs/guide.html#deployment)
--     in the guide.

-- * Default behaviour
--
-- $defaultBehaviour
--
-- #defaultBehaviour#
--

{-|
Please do not get scared by the type-signature of the first argument.
Conceptually, it's a callback, within another callback.

The callback function that you pass to 'defaultMain' will be executed once the
job-runner has forked as a background dameon. Your callback function will be
given another callback function, i.e. the @Config -> IO ()@ part that you need
to call once you've setup @Config@ and whatever environment is required to run
your application code.

This complication is necessary because immediately after forking a new daemon
process, a bunch of resources will need to be allocated for the job-runner to
start functioning. At the minimum, a DB connection pool and logger. However,
realistically, a bunch of additional resources will also be required for
setting up the environment needed for running jobs in your application's
monad.

All of these resource allocations need to be bracketed so that when the
job-runner exits, they may be cleaned-up gracefully.

Please take a look at the [getting started
guide](https://www.haskelltutorials.com/odd-jobs/guide.html#getting-started) for
an example of how to use this function.
-}
defaultMain :: ((Config -> IO ()) -> IO ())
            -- ^ A callback function that will be executed once the dameon has
            -- forked into the background.
            -> IO ()
defaultMain startFn = do
  Args{argsCommand} <- customExecParser defaultCliParserPrefs defaultCliInfo
  case argsCommand of
    Start cmdArgs -> do
      defaultStartCommand cmdArgs startFn
    Stop cmdArgs -> do
      defaultStopCommand cmdArgs
    Status ->
      Prelude.error "not implemented yet"

{-| Used by 'defaultMain' if the 'Start' command is issued via the CLI. If
@--daemonize@ switch is also passed, it checks for 'startPidFile':

* If it doesn't exist, it forks a background daemon, writes the PID file, and
  exits.

* If it exists, it refuses to start, to prevent multiple invocations of the same
  background daemon.
-}
defaultStartCommand :: StartArgs
                    -> ((Config -> IO ()) -> IO ())
                    -- ^ the same callback-within-callback function described in
                    -- 'defaultMain'
                    -> IO ()
defaultStartCommand args@StartArgs{..} startFn = do
  progName <- getProgName
  case startDaemonize of
    False -> do
      startFn coreStartupFn
    True -> do
      (Dir.doesPathExist startPidFile) >>= \case
        True -> do
          putStrLn $
            "PID file already exists. Please check if " <> progName <> " is still running in the background." <>
            " If not, you can safely delete this file and start " <> progName <> " again: " <> startPidFile
          Exit.exitWith (Exit.ExitFailure 1)
        False -> do
          daemonize defaultDaemonOptions (pure ()) $ const $ do
            pid <- getProcessID
            writeFile startPidFile (show pid)
            putStrLn $ "Started " <> progName <> " in background with PID=" <> show pid <> ". PID written to " <> startPidFile
            startFn $ \cfg -> coreStartupFn cfg{cfgPidFile = Just startPidFile}
  where
    coreStartupFn cfg = do
      Async.withAsync (defaultWebUi args cfg) $ \_ -> do
        startJobRunner cfg


defaultWebUi :: StartArgs
             -> Config
             -> IO ()
defaultWebUi StartArgs{..} cfg@Config{..} = do
  env <- UI.mkEnv cfg ("/" <>)
  case startWebUiAuth of
    Nothing -> pure ()
    Just AuthNone ->
      let app = UI.server cfg env Prelude.id
      in Warp.run startWebUiPort $
         Servant.serve (Proxy :: Proxy UI.FinalAPI) app
    Just (AuthBasic u p) ->
      let api = Proxy :: Proxy (BasicAuth "OddJobs Admin UI" OddJobsUser :> UI.FinalAPI)
          ctx = defaultBasicAuth (u, p) :. EmptyContext
          -- Now the app will receive an extra argument for OddJobsUser,
          -- which we aren't really interested in.
          app _ = UI.server cfg env Prelude.id
      in Warp.run startWebUiPort $
         Servant.serveWithContext api ctx app

{-| Used by 'defaultMain' if 'Stop' command is issued via the CLI. Sends a
@SIGINT@ signal to the process indicated by 'shutPidFile'. Waits for a maximum
of 'shutTimeout' seconds (controller by @--timeout@) for the daemon to shutdown
gracefully, after which a @SIGKILL@ is issued
-}
defaultStopCommand :: StopArgs
                   -> IO ()
defaultStopCommand StopArgs{..} = do
  progName <- getProgName
  pid <- read <$> (readFile shutPidFile)
  if (shutTimeout == Seconds 0)
    then forceKill pid
    else do putStrLn $ "Sending SIGINT to pid=" <> show pid <>
              " and waiting " <> (show $ unSeconds shutTimeout) <> " seconds for graceful stop"
            Sig.signalProcess Sig.sigINT pid
            (Async.race (delaySeconds shutTimeout) checkProcessStatus) >>= \case
              Right _ -> do
                putStrLn $ progName <> " seems to have exited gracefully."
                Exit.exitSuccess
              Left _ -> do
                putStrLn $ progName <> " has still not exited."
                forceKill pid
  where
    forceKill pid = do
      putStrLn $ "Sending SIGKILL to pid=" <> show pid
      Sig.signalProcess Sig.sigKILL pid

    checkProcessStatus = do
      Dir.doesPathExist shutPidFile >>= \case
        True -> do
          delaySeconds (Seconds 1)
          checkProcessStatus
        False -> do
          pure ()

-- * Default CLI parsers
--
-- $parsers$
--
-- #parsers#
--
-- If the [default behaviour](#defaultBehaviour) doesn't suit your needs, you
-- can write a @main@ function yourself, and consider using\/extending the CLI
-- parsers documented in this section.


-- | The command-line is parsed into this data-structure using 'argParser'
data Args = Args
  { argsCommand :: !Command
  } deriving (Eq, Show)


-- | The top-level command-line parser
argParser :: Parser Args
argParser = Args <$> commandParser

-- ** Top-level command parser

-- | CLI commands are parsed into this data-structure by 'commandParser'
data Command
  = Start StartArgs
  | Stop StopArgs
  | Status
  deriving (Eq, Show)

-- Parser for 'argsCommand'
commandParser :: Parser Command
commandParser = hsubparser
   ( command "start" (info startParser (progDesc "start the odd-jobs runner")) <>
     command "stop" (info stopParser (progDesc "stop the odd-jobs runner")) <>
     command "status" (info statusParser (progDesc "print status of all active jobs"))
   )

-- ** Start command

-- | @start@ command is parsed into this data-structure by 'startParser'
data StartArgs = StartArgs
  {
    -- | Switch to pick the authentication mechanism for web UI. __Note:__ We
    -- don't have a separate switch to enable\/disable the web UI. Picking an
    -- authentication mechanism by specifying the relevant options,
    -- automatically enables the web UI. Ref: 'webUiAuthParser'
    startWebUiAuth :: !(Maybe WebUiAuth)
    -- | Port on which the web UI will run.
  , startWebUiPort :: !Int
    -- | You'll need to pass the @--daemonize@ switch to fork the job-runner as
    -- a background daemon, else it will keep running as a foreground process.
  , startDaemonize :: !Bool
    -- | PID file for the background dameon. Ref: 'pidFileParser'
  , startPidFile :: !FilePath
  } deriving (Eq, Show)

startParser :: Parser Command
startParser = fmap Start $ StartArgs
  <$> webUiAuthParser
  <*> option auto ( long "web-ui-port" <>
                    metavar "PORT" <>
                    value 7777 <>
                    showDefault <>
                    help "The port on which the Web UI listens. Please note, to actually enable the Web UI you need to pick one of the available auth schemes"
                  )
  <*> switch ( long "daemonize" <>
               help "Fork the job-runner as a background daemon. If omitted, the job-runner remains in the foreground."
             )
  <*> pidFileParser

data WebUiAuth
  = AuthNone
  | AuthBasic !Text !Text
  deriving (Eq, Show)

-- | Pick one of the following auth mechanisms for the web UI:
--
--   * No auth - @--web-ui-no-auth@  __NOT RECOMMENDED__
--   * Basic auth - @--web-ui-basic-auth-user <USER>@ and
--     @--web-ui-basic-auth-password <PASS>@
webUiAuthParser :: Parser (Maybe WebUiAuth)
webUiAuthParser = basicAuthParser <|> noAuthParser <|> (pure Nothing)
  where
    basicAuthParser = fmap Just $ AuthBasic
      <$> strOption ( long "web-ui-basic-auth-user" <>
                      metavar "USER" <>
                      help "Username for basic auth"
                    )
      <*> strOption ( long "web-ui-basic-auth-password" <>
                      metavar "PASS" <>
                      help "Password for basic auth"
                    )
    noAuthParser = flag' (Just AuthNone)
      ( long "web-ui-no-auth" <>
        help "Start the web UI with any authentication. NOT RECOMMENDED."
      )

-- ** Stop command

-- | @stop@ command is parsed into this data-structure by 'stopParser'. Please
-- note, that this command first sends a @SIGINT@ to the daemon and waits for
-- 'shutTimeout' seconds. If the daemon doesn't shut down cleanly within that
-- time, it sends a @SIGKILL@ to kill immediately.
data StopArgs = StopArgs
  { -- | After sending a @SIGINT@, how many seconds to wait before sending a
    -- @SIGKILL@
    shutTimeout :: !Seconds
    -- | PID file of the deamon. Ref: 'pidFileParser'
  , shutPidFile :: !FilePath
  } deriving (Eq, Show)

stopParser :: Parser Command
stopParser = fmap Stop $ StopArgs
  <$> option (Seconds <$> auto) ( long "timeout" <>
                                  metavar "TIMEOUT" <>
                                  help "Maximum seconds to wait before force-killing the background daemon."
                                  -- value defaultTimeout <>
                                  -- showDefaultWith (show . unSeconds)
                                )
  <*> pidFileParser


-- ** Status command

-- | The @status@ command has not been implemented yet. PRs welcome :-)
statusParser :: Parser Command
statusParser = pure Status

-- ** Other parsing utilities

-- | If @--pid-file@ is not given as a command-line argument, this defaults to
-- @./odd-jobs.pid@
pidFileParser :: Parser FilePath
pidFileParser =
  strOption ( long "pid-file" <>
              metavar "PIDFILE" <>
              value "./odd-jobs.pid" <>
              showDefault <>
              help "Path of the PID file for the daemon. Takes effect only during stop or only when using the --daemonize option at startup"
            )

defaultCliParserPrefs :: ParserPrefs
defaultCliParserPrefs = prefs $
  showHelpOnError <>
  showHelpOnEmpty

defaultCliInfo :: ParserInfo Args
defaultCliInfo =
  info (argParser  <**> helper) fullDesc

defaultDaemonOptions :: DaemonOptions
defaultDaemonOptions = DaemonOptions
  { daemonShouldChangeDirectory = False
  , daemonShouldCloseStandardStreams = False
  , daemonShouldIgnoreSignals = True
  , daemonUserToChangeTo = Nothing
  , daemonGroupToChangeTo = Nothing
  }


-- ** Auth implementations for the default Web UI

-- *** Basic Auth

data OddJobsUser = OddJobsUser !Text !Text deriving (Eq, Show)

defaultBasicAuth :: (Text, Text) -> BasicAuthCheck OddJobsUser
defaultBasicAuth (user, pass) = BasicAuthCheck $ \b ->
  let u = decodeUtf8 (basicAuthUsername b)
      p = decodeUtf8 (basicAuthPassword b)
  in if u==user && p==pass
     then pure (Authorized $ OddJobsUser u p)
     else pure BadPassword
