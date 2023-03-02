{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

module Keelung.Compiler.Optimize.MinimizeConstraints.BooleanRelations where

import Control.DeepSeq (NFData)
import Data.Field.Galois (GaloisField)
import Data.List qualified as List
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import GHC.Generics (Generic)
import Keelung.Compiler.Constraint (RefB (..), RefU)
import Keelung.Syntax (Width)
import Prelude hiding (lookup)

data BooleanRelations n = BooleanRelations
  { links :: Map RefB (Maybe (n, RefB), n),
    sizes :: Map RefB Int,
    -- | Here stores bit tests on pinned UInt variables, so that we can export them as constraints later.
    pinnedBitTests :: Set (Width, RefU, Int)
  }
  deriving (Eq, Generic, NFData)

instance (Show n, Eq n, Num n) => Show (BooleanRelations n) where
  show xs =
    "BooleanRelations {\n"
      ++ "  sizes = "
      ++ showList' (map (\(var, n) -> show var <> ": " <> show n) (Map.toList $ sizes xs))
      ++ "\n\n"
      ++ "  pinnedBitTests = " <> show (Set.toList (exportPinnedBitTests xs)) <> "\n\n"
      ++ mconcat (map showLink (Map.toList $ links xs))
      ++ "\n}"
    where
      showList' ys = "[" <> List.intercalate ", " ys <> "]"

      showLink (var, (Just (slope, root), intercept)) = "  " <> show var <> " = " <> (if slope == 1 then "" else show slope) <> show root <> (if intercept == 0 then "" else " + " <> show intercept) <> "\n"
      showLink (var, (Nothing, intercept)) = "  " <> show var <> " = " <> show intercept <> "\n"

new :: BooleanRelations n
new = BooleanRelations mempty mempty mempty

-- | Find the root of a variable, returns:
--      1. if the variable is already a root
--      2. the slope
--      3. the root
--      4. the intercept
lookup :: Num n => RefB -> BooleanRelations n -> (Bool, (Maybe (n, RefB), n))
lookup var xs = case parentOf xs var of
  Nothing -> (True, (Just (1, var), 0)) -- returns self as root
  Just (parent, intercept) -> (False, (parent, intercept))

-- | Returns 'Nothing' if the variable is already a root.
--   else returns 'Just (slope, root)'  where 'var = slope * root + intercept'
parentOf :: Num n => BooleanRelations n -> RefB -> Maybe (Maybe (n, RefB), n)
parentOf xs var = case Map.lookup var (links xs) of
  Nothing -> Nothing -- var is a root
  Just (Nothing, intercept) -> Just (Nothing, intercept) -- var is a root
  Just (Just (slope, parent), intercept) -> case parentOf xs parent of
    Nothing ->
      -- parent is a root
      Just (Just (slope, parent), intercept)
    Just (Nothing, intercept') ->
      -- parent is a value
      -- var = slope * parent + intercept
      -- parent = intercept'
      --  =>
      -- var = slope * intercept' + intercept
      Just (Nothing, slope * intercept' + intercept)
    Just (Just (slope', grandparent), intercept') ->
      -- var = slope * parent + intercept
      -- parent = slope' * grandparent + intercept'
      --  =>
      -- var = slope * (slope' * grandparent + intercept') + intercept
      --  =>
      -- var = slope * slope' * grandparent + slope * intercept' + intercept
      Just (Just (slope * slope', grandparent), slope * intercept' + intercept)

-- | Calculates the relation between two variables `var1` and `var2`
--   Returns `Nothing` if the two variables are not related.
--   Returns `Just (slope, intercept)` where `var1 = slope * var2 + intercept` if the two variables are related.
relationBetween :: GaloisField n => RefB -> RefB -> BooleanRelations n -> Maybe (n, n)
relationBetween var1 var2 xs = case (lookup var1 xs, lookup var2 xs) of
  ((True, _), (True, _)) ->
    if var1 == var2
      then Just (1, 0)
      else Nothing -- var1 and var2 are roots, but not the same one
  ((True, _), (False, (Just (slope2, root2), intercept2))) ->
    -- var2 = slope2 * root2 + intercept2
    --  =>
    -- root2 = (var2 - intercept2) / slope2
    if var1 == root2
      then -- var1 = root2
      --  =>
      -- var1 = (var2 - intercept2) / slope2
        Just (recip slope2, -intercept2 / slope2)
      else Nothing
  ((True, _), (False, (Nothing, _))) -> Nothing -- var1 is a root, var2 is a value
  ((False, (Just (slope1, root1), intercept1)), (True, _)) ->
    -- var1 = slope1 * root1 + intercept1
    if var2 == root1
      then -- var2 = root1
      --  =>
      -- var1 = slope1 * var2 + intercept1
        Just (slope1, intercept1)
      else Nothing
  ((False, (Nothing, _)), (True, _)) -> Nothing -- var1 is a value, var2 is a root
  ((False, (Just (slope1, root1), intercept1)), (False, (Just (slope2, root2), intercept2))) ->
    -- var1 = slope1 * root1 + intercept1
    -- var2 = slope2 * root2 + intercept2
    if root1 == root2
      then -- var2 = slope2 * root2 + intercept2
      --  =>
      -- root2 = (var2 - intercept2) / slope2 = root1
      --  =>
      -- var1 = slope1 * root1 + intercept1
      --  =>
      -- var1 = slope1 * ((var2 - intercept2) / slope2) + intercept1
      --  =>
      -- var1 = slope1 * var2 / slope2 - slope1 * intercept2 / slope2 + intercept1
        Just (slope1 / slope2, -slope1 * intercept2 / slope2 + intercept1)
      else Nothing
  ((False, (Just _, _)), (False, (Nothing, _))) -> Nothing -- var2 is a value
  ((False, (Nothing, _)), (False, (Just _, _))) -> Nothing -- var1 is a value
  ((False, (Nothing, _)), (False, (Nothing, _))) -> Nothing -- both are values

-- | If the RefB is of RefUBit, remember it
rememberPinnedBitTest :: RefB -> BooleanRelations n -> BooleanRelations n
rememberPinnedBitTest (RefUBit width ref index) xs = xs {pinnedBitTests = Set.insert (width, ref, index) (pinnedBitTests xs)}
rememberPinnedBitTest _ xs = xs

-- | Bind a variable to a value
bindToValue :: GaloisField n => RefB -> n -> BooleanRelations n -> BooleanRelations n
bindToValue x value xs =
  case parentOf xs x of
    Nothing ->
      -- x does not have a parent, so it is its own root
      rememberPinnedBitTest x $
        xs
          { links = Map.insert x (Nothing, value) (links xs),
            sizes = Map.insert x 1 (sizes xs)
          }
    Just (Nothing, _oldValue) ->
      -- x is already a root with `_oldValue` as its value
      -- TODO: handle this kind of conflict in the future
      -- FOR NOW: overwrite the value of x with the new value
      rememberPinnedBitTest x $
        xs
          { links = Map.insert x (Nothing, value) (links xs)
          }
    Just (Just (slopeP, parent), interceptP) ->
      -- x is a child of `parent` with slope `slopeP` and intercept `interceptP`
      --  x = slopeP * parent + interceptP
      -- now since that x = value, we have
      --  value = slopeP * parent + interceptP
      -- =>
      --  value - interceptP = slopeP * parent
      -- =>
      --  parent = (value - interceptP) / slopeP
      rememberPinnedBitTest x $
        xs
          { links =
              Map.insert parent (Nothing, (value - interceptP) / slopeP) $
                Map.insert x (Nothing, value) $
                  links xs,
            sizes = Map.insert x 1 (sizes xs)
          }

relate :: GaloisField n => RefB -> (n, RefB, n) -> BooleanRelations n -> Maybe (BooleanRelations n)
relate x (0, _, intercept) xs = Just $ bindToValue x intercept xs
relate x (slope, y, intercept) xs
  | x > y = relate' x (slope, y, intercept) xs -- x = slope * y + intercept
  | x < y = relate' y (recip slope, x, -intercept / slope) xs -- y = x / slope - intercept / slope
  | otherwise = Nothing

-- | Establish the relation of 'x = slope * y + intercept'
--   Returns Nothing if the relation has already been established
relate' :: GaloisField n => RefB -> (n, RefB, n) -> BooleanRelations n -> Maybe (BooleanRelations n)
relate' x (slope, y, intercept) xs =
  case parentOf xs x of
    Just (Nothing, interceptX) ->
      -- x is already a root with `interceptX` as its value
      --  x = slope * y + intercept
      --  x = interceptX
      -- =>
      --  slope * y + intercept = interceptX
      -- =>
      --  y = (interceptX - intercept) / slope
      Just $ bindToValue y (interceptX - intercept / slope) xs
    Just (Just (slopeX, rootOfX), interceptX) ->
      -- x is a child of `rootOfX` with slope `slopeX` and intercept `interceptX`
      --  x = slopeX * rootOfX + interceptX
      --  x = slope * y + intercept
      -- =>
      --  slopeX * rootOfX + interceptX = slope * y + intercept
      -- =>
      --  slopeX * rootOfX = slope * y + intercept - interceptX
      -- =>
      --  rootOfX = (slope * y + intercept - interceptX) / slopeX
      relate rootOfX (slope / slopeX, y, intercept - interceptX / slopeX) xs
    Nothing ->
      -- x does not have a parent, so it is its own root
      case parentOf xs y of
        Just (Nothing, interceptY) ->
          -- y is already a root with `interceptY` as its value
          --  x = slope * y + intercept
          --  y = interceptY
          -- =>
          --  x = slope * interceptY + intercept
          Just $ bindToValue x (slope * interceptY + intercept) xs
        Just (Just (slopeY, rootOfY), interceptY) ->
          -- y is a child of `rootOfY` with slope `slopeY` and intercept `interceptY`
          --  y = slopeY * rootOfY + interceptY
          --  x = slope * y + intercept
          -- =>
          --  x = slope * (slopeY * rootOfY + interceptY) + intercept
          -- =>
          --  x = slope * slopeY * rootOfY + slope * interceptY + intercept
          Just $
            rememberPinnedBitTest x $
              xs
                { links = Map.insert x (Just (slope * slopeY, rootOfY), slope * interceptY + intercept) (links xs),
                  sizes = Map.insertWith (+) y 1 (sizes xs)
                }
        Nothing ->
          -- y does not have a parent, so it is its own root
          Just $
            rememberPinnedBitTest x $
              xs
                { links = Map.insert x (Just (slope, y), intercept) (links xs),
                  sizes = Map.insertWith (+) y 1 (sizes xs)
                }

toMap :: BooleanRelations n -> Map RefB (Maybe (n, RefB), n)
toMap = links

size :: BooleanRelations n -> Int
size = Map.size . links

exportPinnedBitTests :: BooleanRelations n -> Set RefB
exportPinnedBitTests = Set.map (\(w, ref, i) -> RefUBit w ref i) . pinnedBitTests