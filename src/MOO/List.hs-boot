-- -*- Haskell -*-

module MOO.List ( MOOList, storageBytes
                , empty, equal, null, toList, fromList ) where

import {-# SOURCE #-} MOO.Types (Value)

import Prelude hiding (null)

data MOOList

instance Eq MOOList
instance Show MOOList

storageBytes :: MOOList -> Int

empty :: MOOList
equal :: MOOList -> MOOList -> Bool
null :: MOOList -> Bool
toList :: MOOList -> [Value]
fromList :: [Value] -> MOOList
