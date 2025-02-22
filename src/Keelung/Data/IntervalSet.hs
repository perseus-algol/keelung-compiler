{-# LANGUAGE DeriveFunctor #-}
-- For RefU Limb segement reference counting
{-# LANGUAGE DeriveGeneric #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Use guards" #-}

module Keelung.Data.IntervalSet
  ( -- * Construction
    IntervalSet,
    new,
    InitInsertCase (..),
    InsertCase (..),

    -- * Operations
    normalize,
    adjust,
    split,
    merge,

    -- * Conversion
    toIntervalTable,
    fromLimb,
    toSlices,
    fromSlice,

    -- * Query
    intervalsWithin,
    totalCount,
    allZero,
    lookup,
    member,
    Error (..),
    validate,
    isValid,
  )
where

import Control.DeepSeq (NFData)
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IntMap
import Data.List qualified as List
import Data.Sequence (Seq)
import Data.Sequence qualified as Seq
import GHC.Generics (Generic)
import Keelung.Compiler.Util (showList')
import Keelung.Data.IntervalTable (IntervalTable (IntervalTable))
import Keelung.Data.Limb (Limb)
import Keelung.Data.Limb qualified as Limb
import Keelung.Data.Reference (RefU)
import Keelung.Data.Slice (Slice)
import Keelung.Data.Slice qualified as Slice
import Prelude hiding (lookup)

-- | Key: start of an interval
--   Value: (end of the interval, count of the interval)
--    invariant: no two intervals overlap
newtype IntervalSet n = IntervalSet {unIntervalSet :: IntMap (Int, n)} deriving (Eq, Ord, Functor, Generic)

instance (Eq n, Num n, Show n) => Show (IntervalSet n) where
  show (IntervalSet xs) =
    showList'
      $ map
        ( \(start, (end, count)) ->
            if end - start == 1 && count /= 0
              then (if count == 1 then "" else show count) <> "$" <> show start
              else
                ( if count == 1
                    then "$" <> show start <> " ~ $" <> show (end - 1)
                    else show count <> "($" <> show start <> " ~ $" <> show (end - 1) <> ")"
                )
        )
      $ IntMap.toList xs

instance (NFData n) => NFData (IntervalSet n)

instance (Num n, Eq n) => Semigroup (IntervalSet n) where
  (<>) = merge

instance (Num n, Eq n) => Monoid (IntervalSet n) where
  mempty = new

type Interval = (Int, Int) -- (start, end)

--------------------------------------------------------------------------------

-- | O(1): Create an empty interval set
new :: IntervalSet n
new = IntervalSet mempty

-- | O(n). To an IntervalTable
toIntervalTable :: Int -> IntervalSet Int -> IntervalTable
toIntervalTable domainSize (IntervalSet intervals) =
  let FoldState table occupiedSize = IntMap.foldlWithKey' step (FoldState mempty 0) intervals
   in IntervalTable domainSize occupiedSize table
  where
    step :: FoldState -> Int -> (Int, Int) -> FoldState
    step (FoldState acc occupiedSize) start (end, _) =
      FoldState
        (IntMap.insert start (end, start - occupiedSize) acc) -- insert the total size of "holes" before this interval
        (occupiedSize + end - start)

-- | O(1): Create an interval set from a limb
fromLimb :: (Num n) => (Limb, n) -> IntervalSet n
fromLimb (limb, n) =
  if Limb.lmbWidth limb == 0
    then IntervalSet mempty
    else case Limb.lmbSigns limb of
      Left True -> IntervalSet $ IntMap.singleton (Limb.lmbOffset limb) (Limb.lmbOffset limb + Limb.lmbWidth limb, n)
      Left False -> IntervalSet $ IntMap.singleton (Limb.lmbOffset limb) (Limb.lmbOffset limb + Limb.lmbWidth limb, -n)
      Right signs ->
        let aggregateSigns = Slice.aggregateSigns signs
         in IntervalSet $ IntMap.fromList $ map (\(sign, width, offset) -> (offset, (offset + width, if sign then n else -n))) aggregateSigns

-- | O(n): Convert an interval set to a list of Slices
toSlices :: RefU -> IntervalSet n -> [(Slice, n)]
toSlices ref (IntervalSet xs) = map (\(start, (end, count)) -> (Slice.Slice ref start end, count)) $ IntMap.toList xs

-- | O(1): Create an interval set from a Slice and a multiplier
fromSlice :: (Num n, Eq n) => (Slice, n) -> Maybe (IntervalSet n)
fromSlice (Slice.Slice _ start end, n) =
  if start == end || n == 0
    then Nothing
    else Just $ IntervalSet $ IntMap.singleton start (end, n)

--------------------------------------------------------------------------------

-- | Whether to normalize after adjusting
normalizeAfterAdjust :: Bool
normalizeAfterAdjust = True

-- | O(min(n, W)): Adjust the count of an interval.
adjust :: (Num n, Eq n) => Interval -> n -> IntervalSet n -> IntervalSet n
adjust _ 0 (IntervalSet xs) = IntervalSet xs
adjust (start, end) count (IntervalSet xs) =
  if start == end
    then IntervalSet xs
    else
      let actions = calculateActionInit (start, end) count (IntervalSet xs)
       in if normalizeAfterAdjust
            then normalize $ executeActions actions (IntervalSet xs)
            else executeActions actions (IntervalSet xs)

-- | O(n): Compute the total count of all intervals (for testing purposes)
totalCount :: (Num n) => IntervalSet n -> n
totalCount (IntervalSet xs) = IntMap.foldlWithKey' (\acc start (end, count) -> acc + count * fromIntegral (end - start)) 0 xs

-- | O(n): Compute the total count of all intervals (for testing purposes)
allZero :: (Num n, Eq n) => IntervalSet n -> Bool
allZero (IntervalSet xs) = all ((== 0) . snd) xs

-- | O(min(n, W)): Look up the count of a variable in the interval set
lookup :: IntervalSet n -> Int -> Maybe n
lookup (IntervalSet xs) x = case IntMap.lookupLE x xs of
  Nothing -> Nothing
  Just (_, (end, count)) -> if x < end then Just count else Nothing

-- | O(min(n, W)): Check if a variable occurred (i.e. count /= 0) in the interval set
member :: (Eq n, Num n) => IntervalSet n -> Int -> Bool
member (IntervalSet xs) x = case IntMap.lookupLE x xs of
  Nothing -> False
  Just (_, (end, count)) -> x < end && count /= 0

-- | Given an interval, return a list of intervals that occurred (i.e. count /= 0) in this interval
intervalsWithin :: (Eq n, Num n) => IntervalSet n -> (Int, Int) -> Seq (Int, Int)
intervalsWithin (IntervalSet xs) (start, end) =
  let (_, rest) = split (IntervalSet xs) start
      (IntervalSet middle, _) = split rest end
   in Seq.fromList $ map (\(start', (end', _)) -> (start', end')) $ IntMap.toList middle

-- | Split an IntervalSet into two at a given point
split :: (Eq n, Num n) => IntervalSet n -> Int -> (IntervalSet n, IntervalSet n)
split (IntervalSet xs) pos =
  let -- split the map into three parts: before "pos", at "pos", after "pos"
      (before, middle, after) = IntMap.splitLookup pos xs
   in case middle of
        Just (moddleEnd, middleCount) ->
          -- there happens to be an interval at "pos"
          (IntervalSet before, IntervalSet $ IntMap.insert pos (moddleEnd, middleCount) after)
        Nothing ->
          -- see if there is an interval in the "before" part that overlaps with "pos"
          case IntMap.maxViewWithKey before of
            Just ((start, (end, count)), beforeBefore) ->
              if end > pos && count /= 0
                then (IntervalSet (IntMap.insert start (pos, count) beforeBefore), IntervalSet (IntMap.insert pos (end, count) after))
                else (IntervalSet before, IntervalSet after)
            Nothing ->
              (IntervalSet mempty, IntervalSet xs) -- no interval before "pos"

-- | O(n): Merge two interval maps
merge :: (Num n, Eq n) => IntervalSet n -> IntervalSet n -> IntervalSet n
merge (IntervalSet xs) (IntervalSet ys) = normalize $ IntervalSet $ IntMap.fromDistinctAscList $ mergeIntervalList (IntMap.toAscList xs) (IntMap.toAscList ys)

-- | O(n): Merge two interval lists
mergeIntervalList :: (Num n) => [(Int, (Int, n))] -> [(Int, (Int, n))] -> [(Int, (Int, n))]
mergeIntervalList [] [] = []
mergeIntervalList [] ys = ys
mergeIntervalList xs [] = xs
mergeIntervalList ((start1, (end1, count1)) : xss) ((start2, (end2, count2)) : yss) = case start1 `compare` start2 of
  LT -> case end1 `compare` end2 of
    LT ->
      if end1 <= start2
        then --
        --  xs  ├───┤
        --  ys          ├───┤
          (start1, (end1, count1)) : mergeIntervalList xss ((start2, (end2, count2)) : yss)
        else --
        --  xs  ├───┼───┤
        --  ys      ├───┼───┤
          (start1, (start2, count1)) : (start2, (end1, count1 + count2)) : mergeIntervalList xss ((end1, (end2, count2)) : yss)
    EQ ->
      --  xs  ├───┼───┤
      --  ys      ├───┤
      (start1, (start2, count1)) : (start2, (end2, count1 + count2)) : mergeIntervalList xss yss
    GT ->
      --  xs  ├───┼───┼───┤
      --  ys      ├───┤
      (start1, (start2, count1)) : (start2, (end2, count1 + count2)) : mergeIntervalList ((end2, (end1, count1)) : xss) yss
  EQ -> case end1 `compare` end2 of
    LT ->
      --  xs  ├───┤
      --  ys  ├───┼───┤
      (start1, (end1, count1 + count2)) : mergeIntervalList xss ((end1, (end2, count2)) : yss)
    EQ ->
      --  xs  ├───────┤
      --  ys  ├───────┤
      (start1, (end1, count1 + count2)) : mergeIntervalList xss yss
    GT ->
      --  xs  ├───┼───┤
      --  ys  ├───┤
      (start2, (end2, count1 + count2)) : mergeIntervalList ((end2, (end1, count1)) : xss) yss
  GT -> case end1 `compare` end2 of
    LT ->
      --  xs      ├───┤
      --  ys  ├───┼───┼───┤
      (start2, (start1, count2)) : (start1, (end1, count1 + count2)) : mergeIntervalList xss ((end1, (end2, count2)) : yss)
    EQ ->
      --  xs      ├───┤
      --  ys  ├───┼───┤
      (start2, (start1, count2)) : (start1, (end1, count1 + count2)) : mergeIntervalList xss yss
    GT ->
      if end2 <= start1
        then --
        --  xs          ├───┤
        --  ys  ├───┤
          (start2, (end2, count2)) : mergeIntervalList ((start1, (end1, count1)) : xss) yss
        else --
        --  xs      ├───┼───┤
        --  ys  ├───┼───┤
          (start2, (start1, count2)) : (start1, (end2, count1 + count2)) : mergeIntervalList ((end2, (end1, count1)) : xss) yss

-- | O(n): Normalizes an interval set by:
--      1. concatenating adjacent intervals with the same count
--      2. removing intervals with zero count
--      3. removing intervals with zero length
normalize :: (Eq n, Num n) => IntervalSet n -> IntervalSet n
normalize = IntervalSet . IntMap.fromDistinctAscList . normalizeList . IntMap.toDescList . unIntervalSet
  where
    -- input: reversed (descending) list
    -- output: ascending list
    normalizeList :: (Eq n, Num n) => [(Int, (Int, n))] -> [(Int, (Int, n))]
    normalizeList = step []

    step :: (Eq n, Num n) => [(Int, (Int, n))] -> [(Int, (Int, n))] -> [(Int, (Int, n))]
    step acc [] = acc
    step [] ((start, (end, count)) : xs) =
      if start == end || count == 0 -- see if the coming interval is empty
        then step [] xs
        else step [(start, (end, count))] xs
    step ((start2, (end2, count2)) : acc) ((start1, (end1, count1)) : xs) =
      if start1 == end1 || count1 == 0 -- see if the coming interval is empty
        then step ((start2, (end2, count2)) : acc) xs
        else
          if end1 == start2 && count1 == count2
            then step ((start1, (end2, count1)) : acc) xs
            else step ((start1, (end1, count1)) : (start2, (end2, count2)) : acc) xs

--------------------------------------------------------------------------------

data Error n
  = OverlappingIntervals Interval Interval -- two intervals overlap
  | WidthlessInterval -- length == 0
  | ZeroedInterval -- count == 0
  | UnmergedIntervals Interval Interval n -- adjacent intervals with the same count are not merged
  deriving (Eq, Show)

-- | O(n): Check if a IntervalSet is valid
validate :: (Eq n, Num n) => IntervalSet n -> Maybe (Error n)
validate (IntervalSet xs) = case IntMap.foldlWithKey' step NotStarted xs of
  NotStarted -> Nothing -- vacously true
  Invalid err -> Just err
  Valid _ _ -> Nothing
  where
    step :: (Eq n, Num n) => Validity n -> Int -> (Int, n) -> Validity n
    step _ _ (_, 0) = Invalid ZeroedInterval -- no interval has 0 count
    step NotStarted start (end, count) =
      if start < end
        then Valid (start, end) count
        else Invalid WidthlessInterval -- no interval has 0 length
    step (Invalid err) _ _ = Invalid err
    step (Valid (prevStart, prevEnd) prevCount) start (end, count) = case prevEnd `compare` start of
      LT ->
        if start < end
          then Valid (start, end) count
          else Invalid WidthlessInterval -- no interval has 0 length
      EQ ->
        if prevCount /= count
          then Valid (start, end) count
          else Invalid (UnmergedIntervals (prevStart, prevEnd) (start, end) count) -- adjacent intervals with the same count are not merged
      GT -> Invalid (OverlappingIntervals (prevStart, prevEnd) (start, end)) -- no two intervals overlap

-- | O(n): Check if these intervals are valid (for testing purposes)
--   Invariants:
--      1. no two intervals overlap
--      2. no interval has 0 length
--      3. no interval has 0 count
--      4. adjacent intervals with the same count are be merged
isValid :: (Eq n, Num n) => IntervalSet n -> Bool
isValid = (==) Nothing . validate

data Validity n
  = NotStarted
  | Invalid (Error n)
  | Valid
      Interval -- previous interval
      n -- previous count

-- -- | Relationship between two intervals
-- --   The first letter represents "inserted.start `compare` existing.start"
-- --   The second word represents the position of "inserted.end" relative to "existing"
-- data Case
--   = --  inserted      ├──┤
--     --  existing            ├───────────┤
--     LBefore
--   | --  inserted      ├─────┤
--     --  existing            ├───────────┤
--     LStart
--   | --  inserted      ├───────────┤
--     --  existing            ├───────────┤
--     LBetween
--   | --  inserted      ├─────────────────┤
--     --  existing            ├───────────┤╠════╣
--     LEnd
--   | --  inserted      ├─────────────────┤
--     --  existing            ├───────────┼─────┤
--     LEndJ
--   | --  inserted      ├───────────────────────┤
--     --  existing            ├───────────┤
--     LAfter
--   | --  inserted            ├─────┤
--     --  existing      ╠════╣├───────────┤
--     EBefore
--   | --  inserted            ├─────┤
--     --  existing      ├─────┼───────────┤
--     JEBefore
--   | --  inserted            ├───────────┤
--     --  existing            ├───────────┤
--     EEnd
--   | --  inserted            ├───────────┤
--     --  existing      ├─────┼───────────┤╠════╣
--     JEEnd
--   | --  inserted            ├───────────┤
--     --  existing      ╠════╣├───────────┼─────┤
--     EEndJ
--   | --  inserted            ├───────────┤
--     --  existing      ├─────┼───────────┼─────┤
--     JEEndJ
--   | --  inserted            ├─────────────────┤
--     --  existing      ╠════╣├───────────┤
--     EAfter
--   | --  inserted            ├─────────────────┤
--     --  existing      ├─────┼───────────┤
--     JEAfter
--   | --  inserted                  ├──┤
--     --  existing            ├───────────┤
--     GBefore
--   | --  inserted                  ├─────┤
--     --  existing            ├───────────┤╠════╣
--     GEnd
--   | --  inserted                  ├─────┤
--     --  existing            ├───────────┼─────┤
--     GEndJ
--   | --  inserted                  ├───────────┤
--     --  existing            ├───────────┤
--     GAfter

-- | Initial cases for insertion
data InitInsertCase
  = --  inserted                  ├────...
    --  existing               ├─────┤
    InitInBetween
  | --  inserted                  ├────...
    --  existing            ├─────┤ ├───┤
    InitAtEnd
  | --  inserted                  ├────...
    --  existing                    ├───┤
    InitNothingBefore

--   --  inserted                  ├────...
--   --  existing            ├─────┼─────┤
--   LInBorder

-- initInsertCase :: Interval -> IntervalSet n -> InitInsertCase
-- initInsertCase (l, r) (IntervalSet xs) = case IntMap.lookupLT l xs of
--   Nothing -> InitNothingBefore
--   Just (_, (end, _)) -> case l `compare` end of
--     LT -> InitInBetween
--     EQ -> InitAtEnd
--     GT -> InitNothingBefore

-- | Subsequent cases for insertion
data InsertCase
  = --  inserted                  ├─────┤
    --  existing                  ├─────┤
    InsertCase1
  | --  inserted                  ├─────┤
    --  existing                     ├─────┤
    InsertCase2
  | InsertCase4

-- insertCase :: Interval -> IntervalSet n -> InsertCase
-- insertCase (l, r) (IntervalSet xs) = case IntMap.lookupGE l xs of
--   Nothing -> InsertCase4
--   Just (_, (end, _)) -> case l `compare` start of
--     LT -> InsertCase2
--     EQ -> AtEnd
--     GT -> NothingAfter

-- rightCase :: Interval -> IntervalSet n -> InitCase
-- rightCase (l, r) (IntervalSet xs) = case IntMap.lookupGE l xs of
--   Nothing -> LNothing
--   Just (_, (end, _)) -> case l `compare` end of
--     LT -> LInBetween
--     EQ -> LAtEnd
--     GT -> LAtStart

--------------------------------------------------------------------------------

-- | Actions to be executed on an interval set
data Action n
  = InsertNew
      Interval -- interval to be inserted
      n -- count
  deriving (Eq, Show)

-- | Calculate the actions needed to insert an interval into an interval set
calculateActionInit :: (Num n, Eq n) => Interval -> n -> IntervalSet n -> [Action n]
calculateActionInit inserted@(start, end) count (IntervalSet xs) = case IntMap.lookupLT start xs of
  Nothing ->
    --   inserted      ├─────────────────┤
    --   existing
    calculateActionAfter
      inserted
      count
      (IntervalSet xs)
  Just (existingStart, (existingEnd, existingCount)) -> case start `compare` existingEnd of
    LT ->
      case end `compare` existingEnd of
        LT ->
          -- inserted            ╠═════╣
          -- existing      ├─────╠═════╣─────┤
          --    parts         1     2     3

          let insertPart1 = InsertNew (existingStart, start) existingCount
              insertPart2 = InsertNew (start, end) (existingCount + count)
              insertPart3 = InsertNew (end, existingEnd) existingCount
           in [insertPart1, insertPart2, insertPart3]
        EQ ->
          -- inserted            ╠═════╣
          -- existing      ├─────╠═════╣
          --    parts         1     2

          let insertPart1 = InsertNew (existingStart, start) existingCount
              insertPart2 = InsertNew (start, existingEnd) (existingCount + count)
           in case IntMap.lookup end xs of
                Nothing -> [insertPart1, insertPart2]
                Just (nextEnd, nextCount) ->
                  if existingCount + count == nextCount
                    then [insertPart1, InsertNew (start, nextEnd) (existingCount + count), InsertNew (end, nextEnd) 0]
                    else [insertPart1, insertPart2]
        GT ->
          -- inserted            ╠═════╣─────┤
          -- existing      ├─────╠═════╣
          --    parts         1     2

          let insertPart1 = InsertNew (existingStart, start) existingCount
              insertPart2 = InsertNew (start, existingEnd) (existingCount + count)
              restActions = calculateActionAfter (existingEnd, end) count (IntervalSet xs)
           in insertPart1 : insertPart2 : restActions
    EQ ->
      -- inserted                  ├─────┤
      -- existing      ├───────────┤
      if count == existingCount
        then calculateActionAfter (existingStart, end) count (IntervalSet (IntMap.delete existingStart xs))
        else calculateActionAfter inserted count (IntervalSet xs)
    GT ->
      -- inserted                  ├─────┤
      -- existing      ├─────┤
      calculateActionAfter inserted count (IntervalSet xs)

-- | Calculate the actions needed to insert an interval into an interval set with existing intervals after it
calculateActionAfter :: (Num n, Eq n) => Interval -> n -> IntervalSet n -> [Action n]
calculateActionAfter inserted@(start, end) count (IntervalSet xs) = case IntMap.lookupGE start xs of
  Nothing ->
    -- inserted          ├─────────────────┤
    -- existing
    [InsertNew inserted count]
  Just (existingStart, (existingEnd, existingCount)) -> case end `compare` existingStart of
    LT ->
      -- inserted      ├─────┤
      -- existing                  ├─────┤
      [InsertNew inserted count]
    EQ ->
      -- inserted      ├───────────┤
      -- existing                  ├─────┤
      if count == existingCount
        then [InsertNew (start, existingEnd) count, InsertNew (existingStart, existingEnd) 0]
        else [InsertNew inserted count]
    GT -> case end `compare` existingEnd of
      LT -> case start `compare` existingStart of
        LT ->
          -- inserted      ├─────╠═════╣
          -- existing            ╠═════╣─────┤
          --    parts         1     2     3
          let insertPart1 = InsertNew (start, existingStart) count
              insertPart2 = InsertNew (existingStart, end) (existingCount + count)
              insertPart3 = InsertNew (end, existingEnd) existingCount
           in [insertPart1, insertPart2, insertPart3]
        EQ ->
          -- inserted      ╠═══════════╣
          -- existing      ╠═══════════╣─────┤
          --    parts            1        2
          let insertPart1 = InsertNew (start, end) (existingCount + count)
              insertPart2 = InsertNew (end, existingEnd) existingCount
           in [insertPart1, insertPart2]
        GT ->
          -- inserted            ╠═════╣
          -- existing      ├─────╠═════╣─────┤
          --    parts         1     2     3
          let insertPart1 = InsertNew (existingStart, start) count
              insertPart2 = InsertNew (start, end) (existingCount + count)
              insertPart3 = InsertNew (end, existingEnd) existingCount
           in [insertPart1, insertPart2, insertPart3]
      EQ ->
        -- inserted      ├─────╠═════╣
        -- existing            ╠═════╣
        --    parts         1     2
        let insertPart1 = InsertNew (start, existingStart) count
            insertPart2 = InsertNew (existingStart, end) (existingCount + count)
         in -- lookahead to merge possible adjecent intervals
            case IntMap.lookup end xs of
              Nothing -> [insertPart1, insertPart2]
              Just (nextEnd, nextCount) ->
                if existingCount + count == nextCount
                  then [insertPart1, InsertNew (existingStart, nextEnd) (existingCount + count), InsertNew (end, nextEnd) 0]
                  else [insertPart1, insertPart2]
      GT ->
        --     inserted      ├─────╠═════╣─────┤
        --     existing            ╠═════╣
        --        parts         1     2     3

        let insertPart1 = InsertNew (start, existingStart) count
            insertPart2 = InsertNew (existingStart, existingEnd) (existingCount + count)
            restActions = calculateActionAfter (existingEnd, end) count (IntervalSet xs)
         in insertPart1 : insertPart2 : restActions

-- | Execute a list of actions on an interval set
executeActions :: (Eq n, Num n) => [Action n] -> IntervalSet n -> IntervalSet n
executeActions actions (IntervalSet set) = IntervalSet $ List.foldl' step set actions
  where
    step :: (Eq n, Num n) => IntMap (Int, n) -> Action n -> IntMap (Int, n)
    step xs (InsertNew (start, end) count) =
      if start == end
        then xs
        else
          if count == 0
            then IntMap.delete start xs
            else IntMap.insert start (end, count) xs

--------------------------------------------------------------------------------

-- | Temporary data structure for constructing an IntervalTable
data FoldState = FoldState
  { -- | The resulting table
    _stateTable :: IntMap (Int, Int),
    -- | The total size of intervals so far
    _stateEndOfLastInterval :: Int
  }
