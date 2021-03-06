
{-# LANGUAGE CPP, OverloadedStrings, FlexibleInstances #-}

-- | Basic data types used throughout the MOO server code
module MOO.Types (

  -- * Haskell Types Representing MOO Values
    IntT
  , FltT
  , StrT
  , ObjT
  , ErrT
  , LstT

  , ObjId
  , Id

  , LineNo

  -- * MOO Type and Value Reification
  , Type(..)
  , Value(..)
  , Error(..)

  , zero
  , emptyString
  , emptyList

  -- * Type and Value Functions
  , fromId
  , toId
  , string2builder

  , fromInt
  , fromFlt
  , fromStr
  , fromObj
  , fromErr
  , fromLst

  , equal
  , comparable
  , truthOf
  , truthValue
  , typeOf

  , typeCode

  , toText
  , toLiteral
  , toMicroseconds
  , error2text

  -- * List Convenience Functions
  , fromList
  , fromListBy
  , stringList
  , objectList

  -- * Miscellaneous
  , endOfTime

  -- * Estimating Haskell Storage Sizes
  , Sizeable(..)

  ) where

import Control.Concurrent (ThreadId)
import Control.Concurrent.STM (TVar)
import Data.CaseInsensitive (CI)
import Data.HashMap.Strict (HashMap)
import Data.Int (Int32, Int64)
import Data.IntSet (IntSet)
import Data.Map (Map)
import Data.Text (Text)
import Data.Text.Lazy.Builder (Builder)
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Foreign.Storable (sizeOf)
import System.Random (StdGen)

import qualified Data.CaseInsensitive as CI
import qualified Data.HashMap.Strict as HM
import qualified Data.IntSet as IS
import qualified Data.Map as M
import qualified Data.Text as T
import qualified Data.Text.Lazy.Builder as TLB

import {-# SOURCE #-} MOO.List (MOOList)
import MOO.String (MOOString)

import {-# SOURCE #-} qualified MOO.List as Lst
import qualified MOO.String as Str

-- | The 'Sizeable' class is used to estimate the storage requirements of
-- various values, for use by several built-in functions which are supposed to
-- return the byte sizes of certain internal structures.
--
-- The sizes calculated by instances of this class are necessarily
-- approximate, since it may be difficult or impossible to measure them
-- precisely in the Haskell runtime environment.
class Sizeable t where
  -- | Return the estimated storage size of the given value, in bytes.
  storageBytes :: t -> Int

instance Sizeable () where
  storageBytes _ = sizeOf (undefined :: Int)

instance Sizeable Bool where
  storageBytes = sizeOf

instance Sizeable Int where
  storageBytes = sizeOf

instance Sizeable Int32 where
  storageBytes = sizeOf

instance Sizeable Int64 where
  storageBytes = sizeOf

instance Sizeable Double where
  storageBytes = sizeOf

instance Sizeable Text where
  storageBytes t = sizeOf 'x' * (T.length t + 1)

instance Sizeable MOOString where
  storageBytes = Str.storageBytes

instance Sizeable s => Sizeable (CI s) where
  storageBytes = (* 2) . storageBytes . CI.original

instance Sizeable MOOList where
  storageBytes = Lst.storageBytes

instance Sizeable a => Sizeable [a] where
  storageBytes = foldr bytes (storageBytes ())
    where bytes x s = s + storageBytes () + storageBytes x

instance Sizeable a => Sizeable (Maybe a) where
  storageBytes Nothing  = storageBytes ()
  storageBytes (Just x) = storageBytes () + storageBytes x

instance (Sizeable a, Sizeable b) => Sizeable (a, b) where
  storageBytes (x, y) = storageBytes () + storageBytes x + storageBytes y

instance (Sizeable k, Sizeable v) => Sizeable (Map k v) where
  storageBytes =
    M.foldrWithKey' (\k v s -> s + storageBytes k + storageBytes v) 0

instance Sizeable StdGen where
  storageBytes _ = storageBytes () + 2 * storageBytes (undefined :: Int32)

instance Sizeable UTCTime where
  storageBytes _ = 4 * storageBytes ()

instance Sizeable ThreadId where
  storageBytes _ = storageBytes ()

instance Sizeable IntSet where
  storageBytes x = storageBytes () + storageBytes (0 :: Int) * IS.size x

instance (Sizeable k, Sizeable v) => Sizeable (HashMap k v) where
  storageBytes = HM.foldrWithKey bytes (storageBytes ())
    where bytes k v s = s + storageBytes k + storageBytes v

instance Sizeable (TVar a) where
  storageBytes _ = storageBytes ()

# ifdef MOO_64BIT_INTEGER
type IntT = Int64
# else
type IntT = Int32
# endif
                          -- ^ MOO integer
type FltT = Double        -- ^ MOO floating-point number
type StrT = MOOString     -- ^ MOO string
type ObjT = ObjId         -- ^ MOO object number
type ErrT = Error         -- ^ MOO error
type LstT = MOOList       -- ^ MOO list

type ObjId = Int          -- ^ MOO object number
type Id    = CI Text      -- ^ MOO identifier (string lite)

type LineNo = Int         -- ^ MOO code line number

-- | Convert an identifier to and from another type.
class Ident a where
  fromId :: Id -> a
  toId   :: a -> Id

instance Ident [Char] where
  fromId = T.unpack . CI.original
  toId   = CI.mk . T.pack

instance Ident Text where
  fromId = CI.original
  toId   = CI.mk

instance Ident MOOString where
  fromId = Str.fromText . CI.original
  toId   = CI.mk . Str.toText

instance Ident Builder where
  fromId = TLB.fromText . CI.original
  toId   = error "Unsupported conversion from Builder to Id"

string2builder :: StrT -> Builder
string2builder = TLB.fromText . Str.toText

-- | A 'Value' represents any MOO value.
data Value = Int IntT  -- ^ integer
           | Flt FltT  -- ^ floating-point number
           | Str StrT  -- ^ string
           | Obj ObjT  -- ^ object number
           | Err ErrT  -- ^ error
           | Lst LstT  -- ^ list
           deriving (Eq, Show)

instance Sizeable Value where
  storageBytes value = case value of
    Int x -> box + storageBytes x
    Flt x -> box + storageBytes x
    Str x -> box + storageBytes x
    Obj x -> box + storageBytes x
    Err x -> box + storageBytes x
    Lst x -> box + storageBytes x
    where box = storageBytes ()

-- | A default (false) MOO value
zero :: Value
zero = truthValue False

-- | An empty MOO string
emptyString :: Value
emptyString = Str Str.empty

-- | An empty MOO list
emptyList :: Value
emptyList = Lst Lst.empty

fromInt :: Value -> IntT
fromInt (Int x) = x

fromFlt :: Value -> FltT
fromFlt (Flt x) = x

fromStr :: Value -> StrT
fromStr (Str x) = x

fromObj :: Value -> ObjT
fromObj (Obj x) = x

fromErr :: Value -> ErrT
fromErr (Err x) = x

fromLst :: Value -> LstT
fromLst (Lst x) = x

-- | Test two MOO values for indistinguishable (case-sensitive) equality.
equal :: Value -> Value -> Bool
(Str x) `equal` (Str y) = x `Str.equal` y
(Lst x) `equal` (Lst y) = x `Lst.equal` y
x       `equal` y       = x == y

-- Case-insensitive ordering
instance Ord Value where
  (Int x) `compare` (Int y) = x `compare` y
  (Flt x) `compare` (Flt y) = x `compare` y
  (Str x) `compare` (Str y) = x `compare` y
  (Obj x) `compare` (Obj y) = x `compare` y
  (Err x) `compare` (Err y) = x `compare` y
  _       `compare` _       = error "Illegal comparison"

-- | Can the provided values be compared for relative ordering?
comparable :: Value -> Value -> Bool
comparable x y = case (typeOf x, typeOf y) of
  (TLst, _ ) -> False
  (tx  , ty) -> tx == ty

-- | A 'Type' represents one or more MOO value types.
data Type = TAny  -- ^ any type
          | TNum  -- ^ integer or floating-point number
          | TInt  -- ^ integer
          | TFlt  -- ^ floating-point number
          | TStr  -- ^ string
          | TObj  -- ^ object number
          | TErr  -- ^ error
          | TLst  -- ^ list
          deriving (Eq, Show)

-- | A MOO error
data Error = E_NONE     -- ^ No error
           | E_TYPE     -- ^ Type mismatch
           | E_DIV      -- ^ Division by zero
           | E_PERM     -- ^ Permission denied
           | E_PROPNF   -- ^ Property not found
           | E_VERBNF   -- ^ Verb not found
           | E_VARNF    -- ^ Variable not found
           | E_INVIND   -- ^ Invalid indirection
           | E_RECMOVE  -- ^ Recursive move
           | E_MAXREC   -- ^ Too many verb calls
           | E_RANGE    -- ^ Range error
           | E_ARGS     -- ^ Incorrect number of arguments
           | E_NACC     -- ^ Move refused by destination
           | E_INVARG   -- ^ Invalid argument
           | E_QUOTA    -- ^ Resource limit exceeded
           | E_FLOAT    -- ^ Floating-point arithmetic error
           deriving (Eq, Ord, Enum, Bounded, Show)

instance Sizeable Error where
  storageBytes _ = storageBytes ()

-- | Is the given MOO value considered to be /true/ or /false/?
truthOf :: Value -> Bool
truthOf (Int x) = x /= 0
truthOf (Flt x) = x /= 0.0
truthOf (Str t) = not (Str.null t)
truthOf (Lst v) = not (Lst.null v)
truthOf _       = False

-- | Return a default MOO value (integer) having the given boolean value.
truthValue :: Bool -> Value
truthValue False = Int 0
truthValue True  = Int 1

-- | Return a 'Type' indicating the type of the given value.
typeOf :: Value -> Type
typeOf Int{} = TInt
typeOf Flt{} = TFlt
typeOf Str{} = TStr
typeOf Obj{} = TObj
typeOf Err{} = TErr
typeOf Lst{} = TLst

-- | Return an integer code corresponding to the given type. These codes are
-- visible to MOO code via the @typeof()@ built-in function and various
-- predefined variables.
typeCode :: Type -> IntT
typeCode TNum = -2
typeCode TAny = -1
typeCode TInt =  0
typeCode TObj =  1
typeCode TStr =  2
typeCode TErr =  3
typeCode TLst =  4
typeCode TFlt =  9

-- | Return a string representation of the given MOO value, using the same
-- rules as the @tostr()@ built-in function.
toText :: Value -> Text
toText (Int x) = T.pack (show x)
toText (Flt x) = T.pack (show x)
toText (Str x) = Str.toText x
toText (Obj x) = T.pack ('#' : show x)
toText (Err x) = error2text x
toText (Lst _) = "{list}"

-- | Return a literal representation of the given MOO value, using the same
-- rules as the @toliteral()@ built-in function.
toLiteral :: Value -> Text
toLiteral (Lst x) = T.concat ["{", T.intercalate ", " $
                                   map toLiteral (Lst.toList x), "}"]
toLiteral (Str x) = T.concat ["\"", T.concatMap escape $ Str.toText x, "\""]
  where escape :: Char -> Text
        escape '"'  = "\\\""
        escape '\\' = "\\\\"
        escape c    = T.singleton c
toLiteral (Err x) = T.pack (show x)
toLiteral v = toText v

-- | Interpret a MOO value as a number of microseconds.
toMicroseconds :: Value -> Maybe Integer
toMicroseconds (Int secs) = Just $ fromIntegral secs * 1000000
toMicroseconds (Flt secs) = Just $ ceiling    $ secs * 1000000
toMicroseconds  _         = Nothing

-- | Return a string description of the given error value.
error2text :: Error -> Text
error2text E_NONE    = "No error"
error2text E_TYPE    = "Type mismatch"
error2text E_DIV     = "Division by zero"
error2text E_PERM    = "Permission denied"
error2text E_PROPNF  = "Property not found"
error2text E_VERBNF  = "Verb not found"
error2text E_VARNF   = "Variable not found"
error2text E_INVIND  = "Invalid indirection"
error2text E_RECMOVE = "Recursive move"
error2text E_MAXREC  = "Too many verb calls"
error2text E_RANGE   = "Range error"
error2text E_ARGS    = "Incorrect number of arguments"
error2text E_NACC    = "Move refused by destination"
error2text E_INVARG  = "Invalid argument"
error2text E_QUOTA   = "Resource limit exceeded"
error2text E_FLOAT   = "Floating-point arithmetic error"

-- | Turn a Haskell list into a MOO list.
fromList :: [Value] -> Value
fromList = Lst . Lst.fromList

-- | Turn a Haskell list into a MOO list, using a function to map Haskell
-- values to MOO values.
fromListBy :: (a -> Value) -> [a] -> Value
fromListBy f = fromList . map f

-- | Turn a list of strings into a MOO list.
stringList :: [StrT] -> Value
stringList = fromListBy Str

-- | Turn a list of object numbers into a MOO list.
objectList :: [ObjT] -> Value
objectList = fromListBy Obj

-- | This is the last UTC time value representable as a signed 32-bit
-- seconds-since-1970 value. Unfortunately it is used as a sentinel value in
-- LambdaMOO to represent the starting time of indefinitely suspended tasks,
-- so we really can't support time values beyond this point... yet.
endOfTime :: UTCTime
endOfTime = posixSecondsToUTCTime $ fromIntegral (maxBound :: Int32)
