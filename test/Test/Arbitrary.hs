-- | Instances of 'Arbitrary'
module Test.Arbitrary where

import Data.Bifunctor (first)
import Data.IntMap qualified as IntMap
import Data.Map qualified as Map
import Data.Set qualified as Set
import Keelung.Data.PolyL (PolyL)
import Keelung.Data.PolyL qualified as PolyL
import Keelung.Data.Reference
import Keelung.Data.Slice (Slice)
import Keelung.Data.Slice qualified as Slice
import Keelung.Data.SliceLookup (Segment, SliceLookup)
import Keelung.Data.SliceLookup qualified as SliceLookup
import Keelung.Data.U (U)
import Keelung.Data.U qualified as U
import Keelung.Syntax (HasWidth (widthOf), Width)
import Test.QuickCheck

--------------------------------------------------------------------------------

instance Arbitrary RefU where
  arbitrary = arbitraryRefUOfWidth 1 16

arbitraryRefUOfWidth :: Width -> Width -> Gen RefU
arbitraryRefUOfWidth widthLowerBound widthUpperBound = do
  width <- chooseInt (widthLowerBound, widthUpperBound)
  var <- chooseInt (0, 99)
  constructor <- elements [RefUO, RefUI, RefUP, RefUX]
  pure $ constructor width var

instance Arbitrary RefF where
  arbitrary =
    oneof
      [ RefFO <$> chooseInt (0, 99),
        RefFI <$> chooseInt (0, 99),
        RefFP <$> chooseInt (0, 99),
        RefFX <$> chooseInt (0, 99)
      ]

instance Arbitrary RefB where
  arbitrary =
    oneof
      [ RefBO <$> chooseInt (0, 99),
        RefBI <$> chooseInt (0, 99),
        RefBP <$> chooseInt (0, 99),
        RefBX <$> chooseInt (0, 99)
      ]

instance Arbitrary Ref where
  arbitrary = oneof [F <$> arbitrary, B <$> arbitrary]

--------------------------------------------------------------------------------

instance Arbitrary U where
  arbitrary = chooseInt (1, 16) >>= arbitraryUOfWidth

arbitraryUOfWidth :: Width -> Gen U
arbitraryUOfWidth width = do
  value <- chooseInteger (0, 2 ^ width - 1)
  pure $ U.new width value

instance Arbitrary Segment where
  arbitrary = arbitrary >>= arbitrarySegmentOfSlice

arbitrarySegmentOfSlice :: Slice -> Gen Segment
arbitrarySegmentOfSlice (Slice.Slice _ start end) =
  let width = end - start
   in oneof
        [ SliceLookup.Constant <$> arbitraryUOfWidth width,
          SliceLookup.ChildOf <$> arbitrarySliceOfWidth width,
          do
            childrenCount <- chooseInt (1, 16)
            children <- vectorOf childrenCount $ arbitrarySliceOfWidth width
            pure $ SliceLookup.Parent width (Map.fromList (map (\child -> (Slice.sliceRefU child, Set.singleton child)) children))
        ]

instance Arbitrary Slice where
  arbitrary = chooseInt (1, 16) >>= arbitrarySliceOfWidth

arbitrarySliceOfWidth :: Width -> Gen Slice
arbitrarySliceOfWidth width = do
  -- choose the starting offset of the slice first
  start <- chooseInt (0, 16)
  let end = start + width
  refUWidth <- chooseInt (end, end + 16)
  ref <- arbitraryRefUOfWidth refUWidth (refUWidth + 16)
  pure $ Slice.Slice ref start end

instance Arbitrary SliceLookup where
  arbitrary = do
    start <- chooseInt (0, 16)
    segments <- removeAdjectSameKind <$> arbitrary
    let width = sum (map widthOf segments)
    var <- arbitraryRefUOfWidth width (width + 16)
    pure $
      SliceLookup.normalize $
        SliceLookup.SliceLookup
          (Slice.Slice var start (start + width))
          (snd $ foldr (\segment (index, acc) -> (index + widthOf segment, IntMap.insert index segment acc)) (start, mempty) segments)
    where
      -- prevent segments of the same kind from being adjacent
      removeAdjectSameKind :: [Segment] -> [Segment]
      removeAdjectSameKind =
        foldr
          ( \segment acc -> case acc of
              [] -> [segment]
              (segment' : acc') -> if SliceLookup.sameKindOfSegment segment segment' then acc' else segment : acc
          )
          []

--------------------------------------------------------------------------------

instance (Arbitrary n, Integral n) => Arbitrary (PolyL n) where
  arbitrary = do
    constant <- arbitrary
    slices <- arbitrary
    let limbs = map (first Slice.toLimb) slices
    refs <- arbitrary
    case PolyL.fromRefs constant refs of
      Left _ -> case PolyL.fromLimbs constant limbs of
        Left _ -> PolyL.fromLimb constant . Slice.toLimb <$> arbitrary
        Right poly -> return poly
      Right poly -> pure $ PolyL.insertLimbs 0 limbs poly
