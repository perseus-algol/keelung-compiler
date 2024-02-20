{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}

module Keelung.Compiler.ConstraintModule
  ( ConstraintModule (..),
    sizeOfConstraintModule,
    prettyVariables,
    UpdateOccurrences (..),
    addOccurrences,
    removeOccurrences,
    Hint (..),
  )
where

import Control.DeepSeq (NFData)
import Data.Field.Galois (GaloisField)
import Data.Foldable (toList)
import Data.IntMap.Strict qualified as IntMap
import Data.IntSet qualified as IntSet
import Data.Map qualified as Map
import Data.Sequence (Seq)
import Data.Set (Set)
import Data.Set qualified as Set
import GHC.Generics (Generic)
import Keelung.Compiler.Optimize.OccurB (OccurB)
import Keelung.Compiler.Optimize.OccurB qualified as OccurB
import Keelung.Compiler.Optimize.OccurF (OccurF)
import Keelung.Compiler.Optimize.OccurF qualified as OccurF
import Keelung.Compiler.Optimize.OccurU (OccurU)
import Keelung.Compiler.Optimize.OccurU qualified as OccurU
import Keelung.Compiler.Optimize.OccurUB (OccurUB)
import Keelung.Compiler.Optimize.OccurUB qualified as OccurUB
import Keelung.Compiler.Options
import Keelung.Compiler.Relations (Relations)
import Keelung.Compiler.Relations qualified as Relations
import Keelung.Compiler.Util
import Keelung.Data.FieldInfo
import Keelung.Data.Limb (Limb (..))
import Keelung.Data.PolyL (PolyL)
import Keelung.Data.PolyL qualified as PolyL
import Keelung.Data.Reference
import Keelung.Data.U (U)
import Keelung.Syntax.Counters hiding (getBooleanConstraintCount, getBooleanConstraintRanges, prettyBooleanConstraints, prettyVariables)

--------------------------------------------------------------------------------

-- | A constraint module is a collection of constraints with some additional information
data ConstraintModule n = ConstraintModule
  { -- options
    cmOptions :: Options,
    -- for counting the number of each category of variables
    cmCounters :: !Counters,
    -- for counting the occurrences of variables in constraints (excluding the ones that are in Relations)
    cmOccurrenceF :: !OccurF,
    cmOccurrenceB :: !OccurB,
    cmOccurrenceU :: !(Either OccurU OccurUB),
    cmRelations :: Relations n,
    -- addative constraints
    cmAddL :: Seq (PolyL n),
    -- multiplicative constraints
    cmMulL :: Seq (PolyL n, PolyL n, Either n (PolyL n)),
    -- hits for computing equality
    cmEqZeros :: Seq (PolyL n, RefF),
    -- hints for generating witnesses for DivMod constraints
    -- a = b * q + r
    cmDivMods :: Seq (Either RefU U, Either RefU U, Either RefU U, Either RefU U),
    -- hints for generating witnesses for carry-less DivMod constraints
    -- a = b .*. q .^. r
    cmCLDivMods :: Seq (Either RefU U, Either RefU U, Either RefU U, Either RefU U),
    -- hints for generating witnesses for ModInv constraints
    cmModInvs :: Seq (Either RefU U, Either RefU U, Either RefU U, U)
  }
  deriving (Eq, Generic, NFData)

instance (GaloisField n, Integral n) => Show (ConstraintModule n) where
  show cm =
    "Constraint Module {\n"
      <> showFieldInfo
      <> showRelations
      <> showAddL
      <> showMulL
      <> showEqs
      <> showDivModHints
      <> showCLDivModHints
      <> showModInvHints
      <> show (cmOccurrenceF cm)
      <> show (cmOccurrenceB cm)
      <> ( case cmOccurrenceU cm of
             Left x -> show x
             Right x -> show x
         )
      <> prettyVariables (cmCounters cm)
      <> "}"
    where
      adapt :: String -> Seq a -> (a -> String) -> String
      adapt name xs f =
        let size = length xs
         in if size == 0
              then ""
              else "  " <> name <> " (" <> show size <> "):\n\n" <> unlines (map (("    " <>) . f) (toList xs)) <> "\n"

      showFieldInfo :: String
      showFieldInfo = "  Field: " <> show (fieldTypeData (optFieldInfo (cmOptions cm))) <> "\n"

      showDivModHints =
        if null $ cmDivMods cm
          then ""
          else "  DivMod hints:\n" <> indent (indent (showList' (map (\(x, y, q, r) -> show x <> " = " <> show y <> " * " <> show q <> " + " <> show r) (toList $ cmDivMods cm))))

      showCLDivModHints =
        if null $ cmCLDivMods cm
          then ""
          else "  CLDivMod hints:\n" <> indent (indent (showList' (map (\(x, y, q, r) -> show x <> " = " <> show y <> " * " <> show q <> " + " <> show r) (toList $ cmCLDivMods cm))))

      showModInvHints =
        if null $ cmModInvs cm
          then ""
          else "  ModInv hints:\n" <> indent (indent (showList' (map (\(a, _aainv, _n, p) -> show a <> "⁻¹ = (mod " <> show p <> ")") (toList $ cmModInvs cm))))

      showRelations =
        if Relations.size (cmRelations cm) == 0
          then ""
          else "  Relations:\n" <> indent (indent (show (cmRelations cm)))

      showAddL = adapt "AddL" (cmAddL cm) $ \xs -> "0 = " <> show xs
      showMulL = adapt "MulL" (cmMulL cm) showMulL'

      showEqs = adapt "EqZeros" (cmEqZeros cm) $ \(poly, m) ->
        "EqZeros " <> show poly <> " / " <> show m

      showMulL' (aV, bV, cV) = showVecWithParen aV ++ " * " ++ showVecWithParen bV ++ " = " ++ showVec cV
        where
          showVec :: (Integral n, GaloisField n) => Either n (PolyL n) -> String
          showVec (Left c) = show c
          showVec (Right xs) = show xs

          -- wrap the string with parenthesis if it has more than 1 term
          showVecWithParen :: (Integral n, GaloisField n) => PolyL n -> String
          showVecWithParen xs =
            if PolyL.size xs < 2
              then showVec (Right xs)
              else "(" ++ showVec (Right xs) ++ ")"

prettyVariables :: Counters -> String
prettyVariables counters =
  let totalSize = getTotalCount counters
      padRight4 s = s <> replicate (4 - length s) ' '
      padLeft12 n = replicate (12 - length (show n)) ' ' <> show n
      formLine typ =
        padLeft12 (getCount counters (Output, typ))
          <> "    "
          <> padLeft12 (getCount counters (PublicInput, typ))
          <> "    "
          <> padLeft12 (getCount counters (PrivateInput, typ))
          <> "    "
          <> padLeft12 (getCount counters (Intermediate, typ))
      uint w = "\n    UInt" <> padRight4 (toSubscript w) <> formLine (ReadUInt w)
      -- Bit widths existed in the system
      uWidthEntries (Counters o i p x _ _ _) = IntMap.keysSet (uP o) <> IntMap.keysSet (uP i) <> IntMap.keysSet (uP p) <> IntMap.keysSet (uX x)
      showUInts =
        let entries = uWidthEntries counters
         in if IntSet.null entries
              then ""
              else mconcat $ fmap uint (IntSet.toList entries)
   in if totalSize == 0
        then ""
        else
          "  Variables ("
            <> show totalSize
            <> "):\n"
            <> "                  output       pub input      priv input    intermediate\n"
            <> "    --------------------------------------------------------------------"
            <> "\n    Field   "
            <> formLine ReadField
            <> "\n    Boolean "
            <> formLine ReadBool
            <> showUInts
            <> "\n"

-------------------------------------------------------------------------------

-- | TODO: revisit this
sizeOfConstraintModule :: ConstraintModule n -> Int
sizeOfConstraintModule cm =
  Relations.size (cmRelations cm)
    + length (cmAddL cm)
    + length (cmMulL cm)
    + length (cmEqZeros cm)
    + length (cmDivMods cm)
    + length (cmModInvs cm)

-- | Update the occurrences of a reference
class UpdateOccurrences ref where
  addOccurrence :: ref -> ConstraintModule n -> ConstraintModule n
  removeOccurrence :: ref -> ConstraintModule n -> ConstraintModule n

-- | `addOccurrence` on a set of references
addOccurrences :: (UpdateOccurrences ref) => Set ref -> ConstraintModule n -> ConstraintModule n
addOccurrences xs cm = foldl (flip addOccurrence) cm xs

-- | `removeOccurrence` on a set of references
removeOccurrences :: (UpdateOccurrences ref) => Set ref -> ConstraintModule n -> ConstraintModule n
removeOccurrences xs cm = foldl (flip removeOccurrence) cm xs

instance UpdateOccurrences (PolyL n) where
  addOccurrence poly cm =
    let limbs = Map.keysSet $ PolyL.polyLimbs poly
        refs = Map.keysSet $ PolyL.polyRefs poly
     in (addOccurrences limbs . addOccurrences refs) cm
  removeOccurrence poly cm =
    let limbs = Map.keysSet $ PolyL.polyLimbs poly
        refs = Map.keysSet $ PolyL.polyRefs poly
     in (removeOccurrences limbs . removeOccurrences refs) cm

newtype Hint = Hint (Either RefU U)
  deriving (Show, Eq, Ord)

-- | For hints
instance UpdateOccurrences Hint where
  addOccurrence ref cm =
    case ref of
      Hint (Left (RefUX width var)) -> case cmOccurrenceU cm of
        Left _ -> cm
        Right occorUB -> cm {cmOccurrenceU = Right $ OccurUB.increase width var (0, width) occorUB}
      _ -> cm
  removeOccurrence ref cm =
    case ref of
      Hint (Left (RefUX width var)) -> case cmOccurrenceU cm of
        Left _ -> cm
        Right occorUB -> cm {cmOccurrenceU = Right $ OccurUB.decrease width var (0, width) occorUB}
      _ -> cm

instance UpdateOccurrences Ref where
  addOccurrence ref cm =
    case ref of
      F refF -> addOccurrences (Set.singleton refF) cm
      B refB -> addOccurrences (Set.singleton refB) cm
  removeOccurrence ref cm =
    case ref of
      F refF -> removeOccurrences (Set.singleton refF) cm
      B refB -> removeOccurrences (Set.singleton refB) cm

instance UpdateOccurrences RefF where
  addOccurrence ref cm =
    case ref of
      RefFX var -> cm {cmOccurrenceF = OccurF.increase var (cmOccurrenceF cm)}
      _ -> cm
  removeOccurrence ref cm =
    case ref of
      RefFX var -> cm {cmOccurrenceF = OccurF.decrease var (cmOccurrenceF cm)}
      _ -> cm

instance UpdateOccurrences RefB where
  addOccurrence ref cm =
    case ref of
      RefUBit (RefUX width var) i -> case cmOccurrenceU cm of
        Left occurU -> cm {cmOccurrenceU = Left $ OccurU.increase width var occurU}
        Right occorUB -> cm {cmOccurrenceU = Right $ OccurUB.increase width var (i, i + 1) occorUB}
      RefBX var -> cm {cmOccurrenceB = OccurB.increase var (cmOccurrenceB cm)}
      _ -> cm
  removeOccurrence ref cm =
    case ref of
      RefUBit (RefUX width var) i -> case cmOccurrenceU cm of
        Left occurU -> cm {cmOccurrenceU = Left $ OccurU.decrease width var occurU}
        Right occorUB -> cm {cmOccurrenceU = Right $ OccurUB.decrease width var (i, i + 1) occorUB}
      RefBX var -> cm {cmOccurrenceB = OccurB.decrease var (cmOccurrenceB cm)}
      _ -> cm

instance UpdateOccurrences RefU where
  addOccurrence ref cm =
    case ref of
      RefUX width var -> case cmOccurrenceU cm of
        Left occurU -> cm {cmOccurrenceU = Left $ OccurU.increase width var occurU}
        Right _ -> cm
      _ -> cm
  removeOccurrence ref cm =
    case ref of
      RefUX width var -> case cmOccurrenceU cm of
        Left occurU -> cm {cmOccurrenceU = Left $ OccurU.decrease width var occurU}
        Right _ -> cm
      _ -> cm

instance UpdateOccurrences Limb where
  addOccurrence limb cm =
    case lmbRef limb of
      RefUX width var -> case cmOccurrenceU cm of
        Left _ -> cm
        Right occorUB -> cm {cmOccurrenceU = Right $ OccurUB.increase width var (lmbOffset limb, lmbOffset limb + lmbWidth limb) occorUB}
      _ -> cm
  removeOccurrence limb cm =
    case lmbRef limb of
      RefUX width var -> case cmOccurrenceU cm of
        Left _ -> cm
        Right occorUB -> cm {cmOccurrenceU = Right $ OccurUB.decrease width var (lmbOffset limb, lmbOffset limb + lmbWidth limb) occorUB}
      _ -> cm