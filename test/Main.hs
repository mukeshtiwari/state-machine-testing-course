{-# LANGUAGE KindSignatures    #-}
{-# LANGUAGE OverloadedStrings #-}
module Main where

import           Turtle

import           Control.Monad.IO.Class     (MonadIO, liftIO)
import           Debug.Trace                (traceShowId)

import           Hedgehog
import qualified Hedgehog.Gen               as Gen
import qualified Hedgehog.Range             as Range

import Data.Text                  (Text)
import qualified Data.Text                  as T
import qualified Data.Text.IO               as T

import           System.Exit                (exitFailure, exitSuccess)
import           System.IO                  (BufferMode (..), Handle, hClose,
                                             hFlush, hGetBuffering, hGetLine,
                                             hPutStrLn, hSetBuffering)
import qualified System.Process.Typed       as TP

import qualified System.Process             as P

import           Data.ByteString.Lazy.Char8 (ByteString)
import qualified Data.ByteString.Lazy.Char8 as BS

newtype Buffer (v :: * -> *) =
  Buffer Text
  deriving (Show, Eq)

data Cmd_PrintAll (v :: * -> *) =
  Cmd_PrintAll
  deriving (Show, Eq)

instance HTraversable Cmd_PrintAll where
  htraverse _ _ = pure Cmd_PrintAll

newtype Cmd_Append (v :: * -> *) =
  Cmd_Append Text
  deriving (Show, Eq)

instance HTraversable Cmd_Append where
  htraverse _ (Cmd_Append t) = pure (Cmd_Append t)

cAppendText
  :: ( MonadGen n
     , MonadIO m
     , MonadTest m
     )
  => EdProc
  -> Command n m Buffer
cAppendText edProc =
  let
    gen _ = Just $ Cmd_Append <$> Gen.text (Range.linear 1 100) Gen.alphaNum

    execute (Cmd_Append t) = evalIO $ do
      -- sendToEd ["a",t,".","w"] edfp
      -- readEdFile edfp
      let ec = edCmd edProc
      ec "a"
      ec t
      ec "."
      ec ",p"
      T.pack <$> hGetLine (_edOut edProc)
  in
    Command gen execute
    [ Update $ \(Buffer b) (Cmd_Append i) _out ->
        Buffer (b <> i)

    , Ensure $ \(Buffer _old) (Buffer new) (Cmd_Append _i) out ->
        new === out
    ]

cPrintAll
  :: ( MonadIO m
     , MonadTest m
     , MonadGen n
     )
  => EdProc
  -> Command n m Buffer
cPrintAll edProc =
  let
    gen _ = Just $ Gen.constant Cmd_PrintAll

    execute _ = evalIO $ do
      -- readEdFile edfp
      edCmd edProc ",p"
      BS.pack <$> hGetLine (_edOut edProc)
  in
    Command gen execute
    [ Ensure $ \(Buffer old) (Buffer new) _ _ -> old === new
    ]

edProcConfig =
  TP.setStdin TP.createPipe
  $ TP.setStdout TP.createPipe
  $ TP.setStderr TP.closed "ed"

edCmd p c = T.hPutStrLn (_edIn p) c >> hFlush (_edIn p)

sendToEd :: [Text] -> Turtle.FilePath -> IO ()
sendToEd cmds f =
  let
    cmdsWithQ = textToLines $ format (s%"q\n") (T.unlines cmds)
  in
    procs "ed" ["-s", format fp f] (select cmdsWithQ)

readEdFile :: Turtle.FilePath -> IO Text
readEdFile f = T.readFile (T.unpack $ format fp f)

prop_ap :: EdProc -> Property
prop_ap edProc = property $ do
  let
    cmds = ($ edProc) <$> [cAppendText, cPrintAll]
    initialState = Buffer mempty

  actions <- forAll $ Gen.sequential (Range.linear 1 10) initialState cmds

  -- Reset the ed buffer
  evalIO $ edCmd edProc ",d"

  executeSequential initialState actions

data EdProc = EdProc
  { _edIn  :: Handle
  , _edOut :: Handle
  , _edPh  :: P.ProcessHandle
  }

main :: IO ()
main = do
  let p = (P.shell "ed") { P.std_in = P.CreatePipe, P.std_out = P.CreatePipe }
  b <- P.withCreateProcess p $ \(Just stdin) (Just stdout) _ ph -> do

    hSetBuffering stdout LineBuffering

    let edProc = EdProc stdin stdout ph

    b <- checkSequential $ Group "ed (real deal)"
       [ ("property_a_p", prop_ap edProc)
       ]

    edCmd edProc "Q"

    pure b

  if b then exitSuccess else exitFailure