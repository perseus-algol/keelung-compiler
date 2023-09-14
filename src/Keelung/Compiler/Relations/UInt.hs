{-# LANGUAGE MultiParamTypeClasses #-}

module Keelung.Compiler.Relations.UInt
  ( UIntRelations,
    new,
    assign,
    relate,
    relationBetween,
    toMap,
    size,
    isValid,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Keelung (HasWidth (widthOf))
import Keelung.Compiler.Compile.Error
import Keelung.Compiler.Relations.EquivClass qualified as EquivClass
import Keelung.Data.Reference
import Prelude hiding (lookup)

type UIntRelations =
  EquivClass.EquivClass
    RefU -- relations on RefUs
    Integer -- constants can be represented as integers
    () -- only allowing RefU of the same width to be related (as equal) at the moment

new :: UIntRelations
new = EquivClass.new "UInt (RefU Equivalence)"

-- | Assigning a constant value to a RefU
assign :: RefU -> Integer -> UIntRelations -> EquivClass.M (Error n) UIntRelations
assign var val xs = mapError $ EquivClass.assign var val xs

-- | Relate two RefUs of the same width
relate :: RefU -> RefU -> UIntRelations -> EquivClass.M (Error n) UIntRelations
relate var1 var2 xs =
  if widthOf var1 /= widthOf var2
    then pure xs
    else mapError $ EquivClass.relate var1 () var2 xs

-- | Examine the relation between two RefUs
relationBetween :: RefU -> RefU -> UIntRelations -> Bool
relationBetween var1 var2 xs = case EquivClass.relationBetween var1 var2 xs of
  Nothing -> False
  Just () -> True

-- | Given a predicate, convert the relations to a mapping of RefUs to either some other RefU or a constant value
toMap :: (RefU -> Bool) -> UIntRelations -> Map RefU (Either RefU Integer)
toMap shouldBeKept xs = Map.mapMaybeWithKey convert $ EquivClass.toMap xs
  where
    convert var status = do
      if shouldBeKept var
        then case status of
          EquivClass.IsConstant val -> Just (Right val)
          EquivClass.IsRoot _ -> Nothing
          EquivClass.IsChildOf parent () ->
            if shouldBeKept parent
              then Just $ Left parent
              else Nothing
        else Nothing

-- | Helper function for lifting errors
mapError :: EquivClass.M (Integer, Integer) a -> EquivClass.M (Error n) a
mapError = EquivClass.mapError (uncurry ConflictingValuesU)

size :: UIntRelations -> Int
size = Map.size . EquivClass.toMap

isValid :: UIntRelations -> Bool
isValid = EquivClass.isValid
