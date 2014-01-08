
{-# LANGUAGE OverloadedStrings #-}

module MOO.Builtins ( builtinFunctions, callBuiltin, verifyBuiltins ) where

import Control.Monad (when, foldM, liftM, join)
import Control.Monad.State (gets)
import Data.List (transpose, inits)
import Data.Map (Map)
import Data.Maybe (fromMaybe)
import Data.Time (formatTime, utcToLocalZonedTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds, posixSecondsToUTCTime)
import System.IO.Unsafe (unsafePerformIO)
import System.Locale (defaultTimeLocale)

import qualified Data.Map as M
import qualified Data.Text as T
import qualified Data.Vector as V

import MOO.Builtins.Common
import MOO.Types
import MOO.Task
import MOO.Database
import MOO.Object
import MOO.Version

import MOO.Builtins.Values  as Values
import MOO.Builtins.Objects as Objects
import MOO.Builtins.Network as Network
import MOO.Builtins.Tasks   as Tasks

{-# ANN module ("HLint: ignore Use camelCase" :: String) #-}

-- | A 'Map' of all built-in functions, keyed by name
builtinFunctions :: Map Id (Builtin, Info)
builtinFunctions =
  M.fromList $ miscBuiltins ++
  Values.builtins ++ Objects.builtins ++ Network.builtins ++ Tasks.builtins

-- | Call the named built-in function with the given arguments, checking first
-- for the appropriate number and types of arguments. Raise 'E_INVARG' if the
-- built-in function is unknown.
callBuiltin :: Id -> [Value] -> MOO Value
callBuiltin func args = case M.lookup func builtinFunctions of
  Just (bf, info) -> checkArgs info args >> bf args
  Nothing -> raiseException $
             Exception (Err E_INVARG) "Unknown built-in function" (Str func)

  where checkArgs (Info min max types _) args = do
          let nargs = length args
            in when (nargs < min || nargs > fromMaybe nargs max) $ raise E_ARGS
          checkTypes types args

        checkTypes (t:ts) (a:as) = do
          when (typeMismatch t $ typeOf a) $ raise E_TYPE
          checkTypes ts as
        checkTypes _ _ = return ()

        typeMismatch x    y    | x == y = False
        typeMismatch TAny _             = False
        typeMismatch TNum TInt          = False
        typeMismatch TNum TFlt          = False
        typeMismatch _    _             = True

-- | Perform internal consistency verification of all the built-in functions,
-- checking that each implementation actually accepts the claimed argument
-- types. Note that an inconsistency may cause the program to abort.
--
-- Assuming the program doesn't abort, this generates either a string
-- describing an inconsistency, or an integer giving the total number of
-- (verified) built-in functions.
verifyBuiltins :: Either String Int
verifyBuiltins = foldM accum 0 $ M.assocs builtinFunctions
  where accum a b = valid b >>= Right . (+ a)
        valid (name, (func, Info min max types _))
          | name /= T.toCaseFold name         = invalid "name not case-folded"
          | min < 0                           = invalid "arg min < 0"
          | maybe False (< min) max           = invalid "arg max < min"
          | length types /= fromMaybe min max = invalid "incorrect # types"
          | testArgs func min max types       = ok
          where invalid msg = Left $ T.unpack name ++ ": " ++ msg
                ok = Right 1

        testArgs func min max types = all test argSpecs
          where argSpecs = drop min $ inits $ map mkArgs augmentedTypes
                augmentedTypes = maybe (types ++ [TAny]) (const types) max
                test argSpec = all (\args -> func args `seq` True) $
                               enumerateArgs argSpec

        enumerateArgs :: [[Value]] -> [[Value]]
        enumerateArgs (a:[]) = transpose [a]
        enumerateArgs (a:as) = concatMap (combine a) (enumerateArgs as)
          where combine ps rs = map (: rs) ps
        enumerateArgs []     = [[]]

        mkArgs :: Type -> [Value]
        mkArgs TAny = mkArgs TNum ++ mkArgs TStr ++ mkArgs TObj ++
                      mkArgs TErr ++ mkArgs TLst
        mkArgs TNum = mkArgs TInt ++ mkArgs TFlt
        mkArgs TInt = [Int 0]
        mkArgs TFlt = [Flt 0]
        mkArgs TStr = [Str T.empty]
        mkArgs TObj = [Obj 0]
        mkArgs TErr = [Err E_NONE]
        mkArgs TLst = [Lst V.empty]

-- 4.4 Built-in Functions

miscBuiltins :: [BuiltinSpec]
miscBuiltins = [
    -- 4.4.1 Object-Oriented Programming
    ("pass"          , (bf_pass          , Info 0 Nothing  []           TAny))

    -- 4.4.5 Operations Involving Times and Dates
  , ("time"          , (bf_time          , Info 0 (Just 0) []           TInt))
  , ("ctime"         , (bf_ctime         , Info 0 (Just 1) [TInt]       TStr))

    -- 4.4.7 Administrative Operations
  , ("dump_database" , (bf_dump_database , Info 0 (Just 0) []           TAny))
  , ("shutdown"      , (bf_shutdown      , Info 0 (Just 1) [TStr]       TAny))
  , ("load_server_options",
                  (bf_load_server_options, Info 0 (Just 0) []           TAny))
  , ("server_log"    , (bf_server_log    , Info 1 (Just 2) [TStr, TAny] TAny))
  , ("renumber"      , (bf_renumber      , Info 1 (Just 1) [TObj]       TObj))
  , ("reset_max_object",
                     (bf_reset_max_object, Info 0 (Just 0) []           TAny))

    -- 4.4.8 Server Statistics and Miscellaneous Information
  , ("server_version", (bf_server_version, Info 0 (Just 0) []           TStr))
  , ("memory_usage"  , (bf_memory_usage  , Info 0 (Just 0) []           TLst))
  , ("db_disk_size"  , (bf_db_disk_size  , Info 0 (Just 0) []           TInt))
  , ("verb_cache_stats",
                     (bf_verb_cache_stats, Info 0 (Just 0) []           TLst))
  , ("log_cache_stats",
                     (bf_log_cache_stats , Info 0 (Just 0) []           TAny))
  ]

-- 4.4.1 Object-Oriented Programming

bf_pass args = do
  (name, verbLoc, this) <- frame $ \frame ->
    (verbName frame, verbLocation frame, initialThis frame)
  maybeMaybeParent <- fmap objectParent `liftM` getObject verbLoc
  case join maybeMaybeParent of
    Just parent -> callVerb parent this name args
    Nothing     -> raise E_VERBNF

-- 4.4.5 Operations Involving Times and Dates

currentTime :: MOO IntT
currentTime = (floor . utcTimeToPOSIXSeconds) `liftM` gets startTime

bf_time [] = Int `liftM` currentTime

bf_ctime []         = ctime =<< currentTime
bf_ctime [Int time] = ctime time

ctime :: IntT -> MOO Value
ctime time =
  return $ Str $ T.pack $ formatTime defaultTimeLocale format zonedTime
  where format    = "%a %b %_d %T %Y %Z"
        zonedTime = unsafePerformIO $ utcToLocalZonedTime utcTime
        utcTime   = posixSecondsToUTCTime (fromIntegral time)

-- 4.4.7 Administrative Operations

bf_dump_database [] = notyet "dump_database"

bf_shutdown optional = notyet "shutdown"
  where (message : _) = maybeDefaults optional

bf_load_server_options [] = checkWizard >> loadServerOptions >> return nothing

bf_server_log (Str message : optional) = notyet "server_log"
  where [is_error] = booleanDefaults optional [False]

bf_renumber [Obj object] = notyet "renumber"

bf_reset_max_object [] = do
  checkWizard
  getDatabase >>= liftSTM . resetMaxObject >>= putDatabase
  return nothing

-- 4.4.8 Server Statistics and Miscellaneous Information

bf_server_version [] = return (Str serverVersionText)

bf_memory_usage [] = return $ Lst V.empty  -- ... nothing to see here

bf_db_disk_size [] = raise E_QUOTA  -- not yet?

bf_verb_cache_stats [] = notyet "verb_cache_stats"
bf_log_cache_stats [] = notyet "log_cache_stats"