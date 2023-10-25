module Keelung.Compiler.Compile.Util
  ( widthOfInteger,
    calculateBounds,
    calculateCarrySigns,
    calculateSignsOfLimbs,
    rangeToBitSigns,
    bitSignsToRange,
  )
where

import Data.Bits qualified
import Data.Sequence (Seq)
import Keelung.Data.Limb (Limb (..))
import Keelung.Data.Limb qualified as Limb
import Keelung.Data.U (widthOfInteger)

--------------------------------------------------------------------------------

-- | Calculate the lower bound and upper bound
calculateBounds :: Integer -> Seq Limb -> (Integer, Integer)
calculateBounds constant = foldl step (constant, constant)
  where
    step :: (Integer, Integer) -> Limb -> (Integer, Integer)
    step (lower, upper) limb = case Limb.lmbSigns limb of
      Left True -> (lower, upper + 2 ^ Limb.lmbWidth limb - 1)
      Left False -> (lower - 2 ^ Limb.lmbWidth limb + 1, upper)
      Right xs -> let (lower', upper') = calculateBoundsOfigns (lower, upper) xs in (lower + lower', upper + upper')

    calculateBoundsOfigns :: (Integer, Integer) -> [Bool] -> (Integer, Integer)
    calculateBoundsOfigns (_, _) [] = (0, 0)
    calculateBoundsOfigns (lower, upper) (True : xs) = let (lower', upper') = calculateBoundsOfigns (lower, upper) xs in (lower' * 2, upper' * 2 + 1)
    calculateBoundsOfigns (lower, upper) (False : xs) = let (lower', upper') = calculateBoundsOfigns (lower, upper) xs in (lower' * 2 - 1, upper' * 2)

-- | Like `calculateBounds`, but only retain the carry bits
calculateCarrySigns :: Int -> Integer -> Seq Limb -> [Bool]
calculateCarrySigns limbWidth constant limbs = drop limbWidth $ calculateSignsOfLimbs limbWidth constant limbs

-- | Calculate the signs of bits of the summation of some Limbs and a constant
calculateSignsOfLimbs :: Int -> Integer -> Seq Limb -> [Bool]
calculateSignsOfLimbs limbWidth constant limbs =
  let (lower_, upper) = calculateBounds constant limbs
      -- if the lower bound is negative, round it to the nearest multiple of `2 ^ limbWidth` smaller than it!
      lower = if lower_ < 0 then (lower_ `div` (2 ^ limbWidth)) * 2 ^ limbWidth else lower_

      signs = rangeToBitSigns (lower, upper)
      numberOfSigns = length signs
   in -- pad the signs to the width of limbs if necessary
      signs <> replicate (limbWidth - numberOfSigns) True

-- | Given a range, calculate the signs of bits such that the range can be represented by the bits
rangeToBitSigns :: (Integer, Integer) -> [Bool]
rangeToBitSigns (lower, upper) =
  let range = upper - lower
      width = widthOfInteger (fromInteger (-lower) `max` fromInteger upper `max` range)
   in if lower >= 0
        then replicate width True
        else map (not . Data.Bits.testBit (-lower)) [0 .. width - 1]

-- | Given a list of signs of bits, calculate the range represented by the bits
bitSignsToRange :: [Bool] -> (Integer, Integer)
bitSignsToRange =
  snd
    . foldl
      ( \(index, (lower, higher)) sign ->
          if sign then (index + 1, (lower, higher + 2 ^ index)) else (index + 1, (lower - 2 ^ index, higher))
      )
      (0 :: Int, (0, 0))

--  in if lower < 0
--       then
--         -- if the lower bound is still >= `-2 ^ limbWidth`, we max it to `-2 ^ limbWidth` for the ease of calculation
--         if (-lower) <= 2 ^ limbWidth
--           then
--             let range = upper + (2 ^ limbWidth)
--                 carryWidth = widthOfInteger range
--              in False : replicate (carryWidth - limbWidth - 1) True
--           else
--             let range = upper - lower -- + 2 ^ limbWidth - 1
--                 carryWidth = widthOfInteger range
--              in map (not . Data.Bits.testBit (-lower + 2 ^ limbWidth)) [limbWidth .. carryWidth - 1]
--       else
--         let carryWidth = widthOfInteger upper
--          in replicate (carryWidth - limbWidth) True