{-# LANGUAGE DuplicateRecordFields      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE NoImplicitPrelude          #-}
{-# LANGUAGE OverloadedStrings          #-}
module Etc.Spec.Types where


import           Prelude             (fail)
import           Protolude

import           Data.Aeson          ((.:), (.:?))
import           Data.HashMap.Strict (HashMap)
import           Data.Vector         (Vector)

import qualified Data.Aeson          as JSON
import qualified Data.Aeson.Types    as JSON (Parser, typeMismatch)
import qualified Data.HashMap.Strict as HashMap

--------------------------------------------------------------------------------
-- Error Types

data ConfigurationError
  = InvalidConfiguration Text
  | InvalidConfigKeyPath [Text]
  deriving (Show)

instance Exception ConfigurationError

--------------------------------------------------------------------------------

data CliOptValueType
  = StringOpt
  | NumberOpt
  | SwitchOpt
  deriving (Show, Eq)

data CliArgValueType
  = StringArg
  | NumberArg
  deriving (Show, Eq)

data CliEntryMetadata
  = Opt {
    optLong      :: Maybe Text
  , optShort     :: Maybe Text
  , optMetavar   :: Maybe Text
  , optHelp      :: Maybe Text
  , optRequired  :: Bool
  , optValueType :: CliOptValueType
  }
  | Arg {
    argMetavar   :: Maybe Text
  , argRequired  :: Bool
  , argValueType :: CliArgValueType
  }
  deriving (Show, Eq)

data CliEntrySpec cmd
  = CmdEntry {
    cliEntryCmdValue :: Vector cmd
  , cliEntryMetadata :: CliEntryMetadata
  }
  | PlainEntry {
    cliEntryMetadata :: CliEntryMetadata
  }
  deriving (Show, Eq)

data CliCmdSpec
  = CliCmdSpec {
    cliCmdDesc   :: Text
  , cliCmdHeader :: Text
  }
  deriving (Show, Eq)

data ConfigSources cmd
  = ConfigSources {
    envVar   :: Maybe Text
  , cliEntry :: Maybe (CliEntrySpec cmd)
  }
  deriving (Show, Eq)

data ConfigValue cmd
  = ConfigValue {
    defaultValue  :: Maybe JSON.Value
  , configSources :: ConfigSources cmd
  }
  | SubConfig {
    subConfig :: HashMap Text (ConfigValue cmd)
  }
  deriving (Show, Eq)

data CliProgramSpec
  = CliProgramSpec {
    cliProgramDesc   :: Text
  , cliProgramHeader :: Text
  , cliCommands      :: Maybe (HashMap Text CliCmdSpec)
  }
  deriving (Show, Eq)

data ConfigSpec cmd
  = ConfigSpec {
    specConfigFilepaths :: [Text]
  , specCliProgramSpec  :: Maybe CliProgramSpec
  , specConfigValues    :: HashMap Text (ConfigValue cmd)
  }
  deriving (Show, Eq)

--------------------------------------------------------------------------------
-- JSON Parsers

instance JSON.FromJSON CliCmdSpec where
  parseJSON json =
    case json of
      JSON.Object object ->
        CliCmdSpec
        <$> object .: "desc"
        <*> object .: "header"
      _ ->
        JSON.typeMismatch "CliCmdSpec" json

instance JSON.FromJSON CliProgramSpec where
  parseJSON json =
    case json of
      JSON.Object object ->
        CliProgramSpec
        <$> object .: "desc"
        <*> object .: "header"
        <*> object .:? "commands"
      _ ->
        JSON.typeMismatch "CliProgramSpec" json

cliArgTypeParser
  :: JSON.Object
    -> JSON.Parser CliArgValueType
cliArgTypeParser object = do
  value <- object .: "type"
  case value of
    JSON.String typeName ->
      if typeName == "string" then
        return StringArg
      else if typeName == "number" then
        return NumberArg
      else
        JSON.typeMismatch "CliArgValueType (string, number)" value
    _ ->
      JSON.typeMismatch "CliArgValueType (string, number)" value

cliArgParser
  :: JSON.Object
    -> JSON.Parser CliEntryMetadata
cliArgParser object =
  Arg
    <$> (object .:? "metavar")
    <*> (fromMaybe True <$> (object .:? "required"))
    <*> (cliArgTypeParser object)

cliOptTypeParser
  :: JSON.Object
    -> JSON.Parser CliOptValueType
cliOptTypeParser object = do
  mvalue <- object .:? "type"
  case mvalue of
    Just value@(JSON.String typeName) ->
      if typeName == "string" then
        return StringOpt
      else if typeName == "number" then
        return NumberOpt
      else if typeName == "switch" then
        return SwitchOpt
      else
        JSON.typeMismatch "CliOptValueType (string, number, switch)" value

    Just value ->
      JSON.typeMismatch "CliOptValueType" value

    Nothing ->
      fail "CLI Option type is required"

cliOptParser
  :: JSON.Object
    -> JSON.Parser CliEntryMetadata
cliOptParser object = do
  long  <- object .:? "long"
  short <- object .:? "short"
  if isNothing long && isNothing short then
    fail "'option' field input requires either 'long' or 'short' settings"
  else
    Opt
      <$> (pure long)
      <*> (pure short)
      <*> (object .:? "metavar")
      <*> (object .:? "help")
      <*> (fromMaybe True <$> (object .:? "required"))
      <*> (cliOptTypeParser object)

instance JSON.FromJSON cmd => JSON.FromJSON (CliEntrySpec cmd) where
  parseJSON json =
      case json of
        JSON.Object object -> do
          cmdValue   <- object .:? "commands"
          value <- object .: "input"

          let
            optParseEntryCtor =
              maybe PlainEntry CmdEntry cmdValue

          case value of
            JSON.String inputName ->
              if inputName == "option" then
                optParseEntryCtor <$> cliOptParser object
              else if inputName == "argument" then
                optParseEntryCtor <$> cliArgParser object
              else
                JSON.typeMismatch "CliEntryMetadata (invalid input)" value
            _ ->
              JSON.typeMismatch "CliEntryMetadata (invalid input)" value
        _ ->
          JSON.typeMismatch "CliEntryMetadata" json

instance JSON.FromJSON cmd => JSON.FromJSON (ConfigValue cmd) where
  parseJSON json  =
    case json of
      JSON.Array _ ->
        fail "Entries cannot have arrays as values"
      JSON.Object object ->
        case HashMap.lookup "etc/spec" object of
          -- normal object
          Nothing -> do
            result <- foldM
                        (\result (key, value) -> do
                            innerValue <- JSON.parseJSON value
                            return $ HashMap.insert key innerValue result)
                        HashMap.empty
                        (HashMap.toList object)
            if HashMap.null result then
              fail "Entries cannot have empty maps as values"
            else
              return (SubConfig result)

          -- etc spec value object
          Just (JSON.Object spec) ->
            ConfigValue
              <$> spec .:? "default"
              <*> (ConfigSources <$> (spec .:? "env")
                                 <*> (spec .:? "cli"))

          -- any other JSON value
          Just innerJson ->
            return $
              ConfigValue (Just innerJson) (ConfigSources Nothing Nothing)

      _ ->
        return $
          ConfigValue (Just json) (ConfigSources Nothing Nothing)

instance JSON.FromJSON cmd => JSON.FromJSON (ConfigSpec cmd) where
  parseJSON json  =
    case json of
      JSON.Object object ->
        ConfigSpec
        <$> (fromMaybe [] <$> (object .:?  "etc/filepaths"))
        <*> (object .:? "etc/cli")
        <*> (object .:  "etc/entries")
      _ ->
        JSON.typeMismatch "ConfigSpec" json
