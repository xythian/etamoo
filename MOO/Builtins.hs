
{-# LANGUAGE OverloadedStrings #-}

module MOO.Builtins ( callBuiltin ) where

import           Control.Monad (when, mplus)
import           Control.Monad.IO.Class (liftIO)
import           Control.Concurrent.MVar
import           Control.Exception (bracket)
import           Foreign.Storable (sizeOf)
import           Data.Maybe (fromMaybe)
import           Data.Map (Map)
import qualified Data.Map as Map
import qualified Data.Text as T
import qualified Data.Vector as V
import qualified Data.Vector.Mutable as VM
import           System.Random
import           System.IO.Unsafe (unsafePerformIO)
import           Text.Printf (printf)
import           Foreign hiding (unsafePerformIO)
import           Foreign.C

import MOO.Types
import MOO.Execution
import MOO.Parser (parseNum, parseObj)

-- 4.4 Built-in Functions

type Builtin = [Value] -> MOO Value

data Info = Info Int (Maybe Int) [Type] Type

builtins :: Map Id (Builtin, Info)
builtins = patch $ Map.fromList [
    ("pass"         , (bf_pass         , Info 0 Nothing  []           TAny))

  , ("typeof"       , (bf_typeof       , Info 1 (Just 1) [TAny]       TInt))
  , ("tostr"        , (bf_tostr        , Info 0 Nothing  []           TStr))
  , ("toliteral"    , (bf_toliteral    , Info 1 (Just 1) [TAny]       TStr))
  , ("toint"        , (bf_toint        , Info 1 (Just 1) [TAny]       TInt))
  , ("toobj"        , (bf_toobj        , Info 1 (Just 1) [TAny]       TObj))
  , ("tofloat"      , (bf_tofloat      , Info 1 (Just 1) [TAny]       TFlt))
  , ("equal"        , (bf_equal        , Info 2 (Just 2) [TAny, TAny] TInt))
  , ("value_bytes"  , (bf_value_bytes  , Info 1 (Just 1) [TAny]       TInt))
  , ("value_hash"   , (bf_value_hash   , Info 1 (Just 1) [TAny]       TStr))

  , ("random"       , (bf_random       , Info 0 (Just 1) [TInt]       TInt))
  , ("min"          , (bf_min          , Info 1 Nothing  [TNum]       TNum))
  , ("max"          , (bf_max          , Info 1 Nothing  [TNum]       TNum))
  , ("abs"          , (bf_abs          , Info 1 (Just 1) [TNum]       TNum))
  , ("floatstr"     , (bf_floatstr     , Info 2 (Just 3) [TFlt, TInt,
                                                          TAny]       TStr))
  , ("sqrt"         , (bf_sqrt         , Info 1 (Just 1) [TFlt]       TFlt))
  , ("sin"          , (bf_sin          , Info 1 (Just 1) [TFlt]       TFlt))
  , ("cos"          , (bf_cos          , Info 1 (Just 1) [TFlt]       TFlt))
  , ("tan"          , (bf_tan          , Info 1 (Just 1) [TFlt]       TFlt))
  , ("asin"         , (bf_asin         , Info 1 (Just 1) [TFlt]       TFlt))
  , ("acos"         , (bf_acos         , Info 1 (Just 1) [TFlt]       TFlt))
  , ("atan"         , (bf_atan         , Info 1 (Just 2) [TFlt, TFlt] TFlt))
  , ("sinh"         , (bf_sinh         , Info 1 (Just 1) [TFlt]       TFlt))
  , ("cosh"         , (bf_cosh         , Info 1 (Just 1) [TFlt]       TFlt))
  , ("tanh"         , (bf_tanh         , Info 1 (Just 1) [TFlt]       TFlt))
  , ("exp"          , (bf_exp          , Info 1 (Just 1) [TFlt]       TFlt))
  , ("log"          , (bf_log          , Info 1 (Just 1) [TFlt]       TFlt))
  , ("log10"        , (bf_log10        , Info 1 (Just 1) [TFlt]       TFlt))
  , ("ceil"         , (bf_ceil         , Info 1 (Just 1) [TFlt]       TFlt))
  , ("floor"        , (bf_floor        , Info 1 (Just 1) [TFlt]       TFlt))
  , ("trunc"        , (bf_trunc        , Info 1 (Just 1) [TFlt]       TFlt))

  , ("length"       , (bf_length       , Info 1 (Just 1) [TAny]       TInt))
  , ("strsub"       , (bf_strsub       , Info 3 (Just 4) [TStr, TStr,
                                                          TStr, TAny] TStr))
  , ("index"        , (bf_index        , Info 2 (Just 3) [TStr, TStr,
                                                          TAny]       TInt))
  , ("rindex"       , (bf_rindex       , Info 2 (Just 3) [TStr, TStr,
                                                          TAny]       TInt))
  , ("strcmp"       , (bf_strcmp       , Info 2 (Just 2) [TStr, TStr] TInt))
  , ("decode_binary", (bf_decode_binary, Info 1 (Just 2) [TStr, TAny] TLst))
  , ("encode_binary", (bf_encode_binary, Info 0 Nothing  []           TStr))
  , ("match"        , (bf_match        , Info 2 (Just 3) [TStr, TStr,
                                                          TAny]       TLst))
  , ("rmatch"       , (bf_rmatch       , Info 2 (Just 3) [TStr, TStr,
                                                          TAny]       TLst))
  , ("substitute"   , (bf_substitute   , Info 2 (Just 2) [TStr, TLst] TStr))
  , ("crypt"        , (bf_crypt        , Info 1 (Just 2) [TStr, TStr] TStr))
  , ("string_hash"  , (bf_string_hash  , Info 1 (Just 1) [TStr]       TStr))
  , ("binary_hash"  , (bf_binary_hash  , Info 1 (Just 1) [TStr]       TStr))

  , ("is_member"    , (bf_is_member    , Info 2 (Just 2) [TAny, TLst] TInt))
  , ("listinsert"   , (bf_listinsert   , Info 2 (Just 3) [TLst, TAny,
                                                          TInt]       TLst))
  , ("listappend"   , (bf_listappend   , Info 2 (Just 3) [TLst, TAny,
                                                          TInt]       TLst))
  , ("listdelete"   , (bf_listdelete   , Info 2 (Just 2) [TLst, TInt] TLst))
  , ("listset"      , (bf_listset      , Info 3 (Just 3) [TLst, TAny,
                                                          TInt]       TLst))
  , ("setadd"       , (bf_setadd       , Info 2 (Just 2) [TLst, TAny] TLst))
  , ("setremove"    , (bf_setremove    , Info 2 (Just 2) [TLst, TAny] TLst))
  ]
  where patch funcs = Map.insert "tonum" (funcs Map.! "toint") funcs

callBuiltin :: Id -> [Value] -> MOO Value
callBuiltin func args = case Map.lookup func builtins of
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

boolean (v:_) = truthOf v
boolean []    = False

-- 4.4.1 Object-Oriented Programming

bf_pass args = notyet

-- 4.4.2 Manipulating MOO Values

-- 4.4.2.1 General Operations Applicable to all Values

bf_typeof = return . Int . typeCode . typeOf . head

bf_tostr = return . Str . T.concat . map toText

bf_toliteral = return . Str . toliteral . head
  where toliteral (Lst vs) = T.concat
                             ["{"
                             , T.intercalate ", " $ map toliteral (V.toList vs)
                             , "}"]
        toliteral (Str x) = T.concat ["\"", T.concatMap escape x, "\""]
          where escape '"'  = "\\\""
                escape '\\' = "\\\\"
                escape c    = T.singleton c
        toliteral (Err x) = T.pack $ show x
        toliteral v = toText v

-- XXX toint(" - 34  ") does not parse as -34
bf_toint [v] = toint v
  where toint v = case v of
          Int _ -> return v
          Flt x | x >= 0    -> if x > fromIntegral (maxBound :: IntT)
                               then raise E_FLOAT else return (Int $ floor   x)
                | otherwise -> if x < fromIntegral (minBound :: IntT)
                               then raise E_FLOAT else return (Int $ ceiling x)
          Obj x -> return (Int $ fromIntegral x)
          Str x -> maybe (return $ Int 0) toint (parseNum x)
          Err x -> return (Int $ fromIntegral $ fromEnum x)
          Lst _ -> raise E_TYPE

bf_toobj [v] = toobj v
  where toobj v = case v of
          Int x -> return (Obj $ fromIntegral x)
          Flt x | x >= 0    -> if x > fromIntegral (maxBound :: ObjT)
                               then raise E_FLOAT else return (Obj $ floor   x)
                | otherwise -> if x < fromIntegral (minBound :: ObjT)
                               then raise E_FLOAT else return (Obj $ ceiling x)
          Obj _ -> return v
          Str x -> maybe (return $ Obj 0) toobj $ parseNum x `mplus` parseObj x
          Err x -> return (Obj $ fromIntegral $ fromEnum x)
          Lst _ -> raise E_TYPE

bf_tofloat [v] = tofloat v
  where tofloat v = case v of
          Int x -> return (Flt $ fromIntegral x)
          Flt _ -> return v
          Obj x -> return (Flt $ fromIntegral x)
          Str x -> maybe (return $ Flt 0) tofloat (parseNum x)
          Err x -> return (Flt $ fromIntegral $ fromEnum x)
          Lst _ -> raise E_TYPE

bf_equal [v1, v2] = return $ truthValue (v1 `equal` v2)

bf_value_bytes [v] = guessSize $ value_bytes v
  where value_bytes v = case v of
          -- Make stuff up ...
          Int x -> sizeOf x
          Flt x -> sizeOf x
          Obj x -> sizeOf x
          Str x -> sizeOf 'x' * (T.length x + 1)
          Err x -> sizeOf (undefined :: Int)
          Lst x -> box + V.sum (V.map value_bytes x)
        guessSize base = return (Int $ fromIntegral $ box + base)
        box = 8

bf_value_hash [v] = do
  lit <- bf_toliteral [v]
  bf_string_hash [lit]

-- 4.4.2.2 Operations on Numbers

bf_random []                    = bf_random [Int maxBound]
bf_random [Int mod] | mod <= 0  = raise E_INVARG
                    | otherwise = liftIO $ randomRIO (1, mod) >>= return . Int

bf_min ((Int v):xs) = minMaxInt min v xs
bf_min ((Flt v):xs) = minMaxFlt min v xs

bf_max ((Int v):xs) = minMaxInt max v xs
bf_max ((Flt v):xs) = minMaxFlt max v xs

minMaxInt :: (IntT -> IntT -> IntT) -> IntT -> [Value] -> MOO Value
minMaxInt f = go
  where go x (Int y:rs) = go (f x y) rs
        go v []         = return $ Int v
        go _ _          = raise E_TYPE

minMaxFlt :: (FltT -> FltT -> FltT) -> FltT -> [Value] -> MOO Value
minMaxFlt f = go
  where go x (Flt y:rs) = go (f x y) rs
        go v []         = return $ Flt v
        go _ _          = raise E_TYPE

bf_abs [Int x] = return $ Int $ abs x
bf_abs [Flt x] = return $ Flt $ abs x

bf_floatstr (Flt x : Int precision : scientific)
  | precision < 0 = raise E_INVARG
  | otherwise = return $ Str $ T.pack $ printf format x
  where prec   = min precision 19
        useSci = boolean scientific
        format = printf "%%.%d%c" prec $ if useSci then 'e' else 'f'

bf_sqrt  [Flt x] = checkFloat $ sqrt x

bf_sin   [Flt x] = checkFloat $ sin x
bf_cos   [Flt x] = checkFloat $ cos x
bf_tan   [Flt x] = checkFloat $ tan x

bf_asin  [Flt x] = checkFloat $ asin x
bf_acos  [Flt x] = checkFloat $ acos x
bf_atan  [Flt y] = checkFloat $ atan y
bf_atan  [Flt y,
          Flt x] = checkFloat $ atan2 y x

bf_sinh  [Flt x] = checkFloat $ sinh x
bf_cosh  [Flt x] = checkFloat $ cosh x
bf_tanh  [Flt x] = checkFloat $ tanh x

bf_exp   [Flt x] = checkFloat $ exp x
bf_log   [Flt x] = checkFloat $ log x
bf_log10 [Flt x] = checkFloat $ logBase 10 x

bf_ceil  [Flt x] = checkFloat $ fromIntegral $ ceiling x
bf_floor [Flt x] = checkFloat $ fromIntegral $ floor   x
bf_trunc [Flt x] | x < 0     = checkFloat $ fromIntegral $ ceiling x
                 | otherwise = checkFloat $ fromIntegral $ floor   x

-- 4.4.2.3 Operations on Strings

bf_length [Str string] = return (Int $ fromIntegral $ T.length string)
bf_length [Lst list]   = return (Int $ fromIntegral $ V.length list)
bf_length _            = raise E_TYPE

bf_strsub (Str subject : Str what : Str with : case_matters) = notyet

bf_index  (Str str1 : Str str2 : case_matters) = notyet
bf_rindex (Str str1 : Str str2 : case_matters) = notyet

bf_strcmp [Str str1, Str str2] =
  return $ Int $ case compare str1 str2 of
    LT -> -1
    EQ ->  0
    GT ->  1

bf_decode_binary (Str bin_string : fully) = notyet
bf_encode_binary args = notyet

bf_match  (Str subject : Str pattern : case_matters) = notyet
bf_rmatch (Str subject : Str pattern : case_matters) = notyet

bf_substitute [Str template, Lst subs] = notyet

-- [Use OS crypt]

foreign import ccall "crypt" c_crypt :: CString -> CString -> IO CString

crypt :: String -> String -> String
crypt key salt =
  unsafePerformIO $ bracket (takeMVar lock) (putMVar lock) $ \_ ->
    withCString key $ \c_key -> withCString salt $ \c_salt ->
      c_crypt c_key c_salt >>= peekCString
  where lock = unsafePerformIO $ newMVar ()

bf_crypt [Str text, Str salt] | T.length salt < 2 = bf_crypt [Str text]
                              | otherwise =
  return $ Str $ T.pack $ crypt (T.unpack text) (T.unpack salt)

bf_crypt [Str text] = do
  i <- liftIO $ randomRIO (0, length saltstuff)
  j <- liftIO $ randomRIO (0, length saltstuff)
  let salt = [saltstuff !! i, saltstuff !! j]
  bf_crypt [Str text, Str (T.pack salt)]
  where saltstuff = ['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9'] ++ "./"

-- [End crypt]

bf_string_hash [Str text] = notyet
bf_binary_hash [Str bin_string] = notyet

-- 4.4.2.4 Operations on Lists

-- bf_length already defined above

bf_is_member [value, Lst list] =
  return $ Int $ maybe 0 (fromIntegral . succ) $
  V.findIndex (`equal` value) list

bf_listinsert [Lst list, value, Int index] = notyet
bf_listinsert [Lst list, value] = return $ Lst $ V.cons value list

bf_listappend [Lst list, value, Int index] = notyet
bf_listappend [Lst list, value] = return $ Lst $ V.snoc list value

bf_listdelete [Lst list, Int index]
  | index' < 1 || index' > V.length list = raise E_RANGE
  | otherwise = return $ Lst $ s V.++ V.tail r
  where index' = fromIntegral index
        (s, r) = V.splitAt (index' - 1) list

bf_listset [Lst list, value, Int index]
  | index' < 1 || index' > V.length list = raise E_RANGE
  | otherwise = return $ Lst $
                V.modify (\v -> VM.write v (index' - 1) value) list
  where index' = fromIntegral index

bf_setadd [Lst list, value] =
  return $ Lst $ if V.elem value list then list else V.snoc list value

bf_setremove [Lst list, value] =
  return $ Lst $ case V.elemIndex value list of
    Nothing    -> list
    Just index -> s V.++ V.tail r
      where (s, r) = V.splitAt index list

-- 4.4.3 Manipulating Objects

-- 4.4.3.1 Fundamental Operations on Objects

