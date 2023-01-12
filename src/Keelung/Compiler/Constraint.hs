{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveFunctor #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Use list comprehension" #-}

module Keelung.Compiler.Constraint
  ( RefF (..),
    RefB (..),
    RefU (..),
    reindexRefF,
    reindexRefB,
    reindexRefU,
    Constraint (..),
    cAddF,
    cAddB,
    cAddU,
    cVarEqF,
    cVarEqB,
    cVarEqU,
    cVarBindF,
    cVarBindB,
    cVarBindU,
    cMulB,
    cMulF,
    cMulU,
    cMulSimpleB,
    cMulSimpleF,
    cNEqF,
    cNEqU,
    fromConstraint,
    ConstraintSystem (..),
    relocateConstraintSystem,
  )
where

import Data.Bifunctor (first)
import Data.Field.Galois (GaloisField)
import qualified Data.IntMap.Strict as IntMap
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Keelung.Compiler.Relocated as Relocated
import Keelung.Constraint.Polynomial (Poly)
import qualified Keelung.Constraint.Polynomial as Poly
import qualified Keelung.Constraint.R1CS as Constraint
import Keelung.Data.Struct (Struct (..))
import Keelung.Syntax.Counters
import Keelung.Types

fromConstraint :: Integral n => Counters -> Constraint n -> Relocated.Constraint n
fromConstraint counters (CAddB as) = Relocated.CAdd (fromPolyB_ counters as)
fromConstraint counters (CAddF as) = Relocated.CAdd (fromPolyF_ counters as)
fromConstraint counters (CAddU as) = Relocated.CAdd (fromPolyU_ counters as)
fromConstraint counters (CVarEqF x y) = case Poly.buildEither 0 [(reindexRefF counters x, 1), (reindexRefF counters y, -1)] of
  Left _ -> error "CVarEqF: two variables are the same"
  Right xs -> Relocated.CAdd xs
fromConstraint counters (CVarEqB x y) = case Poly.buildEither 0 [(reindexRefB counters x, 1), (reindexRefB counters y, -1)] of
  Left _ -> error "CVarEqB: two variables are the same"
  Right xs -> Relocated.CAdd xs
fromConstraint counters (CVarEqU x y) = case Poly.buildEither 0 [(reindexRefU counters x, 1), (reindexRefU counters y, -1)] of
  Left _ -> error "CVarEqU: two variables are the same"
  Right xs -> Relocated.CAdd xs
fromConstraint counters (CVarBindF x n) = Relocated.CAdd (Poly.bind (reindexRefF counters x) n)
fromConstraint counters (CVarBindB x n) = Relocated.CAdd (Poly.bind (reindexRefB counters x) n)
fromConstraint counters (CVarBindU x n) = Relocated.CAdd (Poly.bind (reindexRefU counters x) n)
fromConstraint counters (CMulF as bs cs) =
  Relocated.CMul
    (fromPolyF_ counters as)
    (fromPolyF_ counters bs)
    ( case cs of
        Left n -> Left n
        Right xs -> fromPolyF counters xs
    )
fromConstraint counters (CMulB as bs cs) =
  Relocated.CMul
    (fromPolyB_ counters as)
    (fromPolyB_ counters bs)
    ( case cs of
        Left n -> Left n
        Right xs -> fromPolyB counters xs
    )
fromConstraint counters (CMulU as bs cs) =
  Relocated.CMul
    (fromPolyU_ counters as)
    (fromPolyU_ counters bs)
    ( case cs of
        Left n -> Left n
        Right xs -> fromPolyU counters xs
    )
fromConstraint counters (CNEqF x y m) = Relocated.CNEq (Constraint.CNEQ (Left (reindexRefF counters x)) (Left (reindexRefF counters y)) (reindexRefF counters m))
fromConstraint counters (CNEqU x y m) = Relocated.CNEq (Constraint.CNEQ (Left (reindexRefU counters x)) (Left (reindexRefU counters y)) (reindexRefU counters m))

--------------------------------------------------------------------------------

data RefB = RefBI Var | RefBO Var | RefB Var | RefUBit Width RefU Int
  deriving (Eq, Ord)

instance Show RefB where
  show (RefBI x) = "$BI" ++ show x
  show (RefBO x) = "$BO" ++ show x
  show (RefB x) = "$B" ++ show x
  show (RefUBit _ x i) = show x ++ "[" ++ show i ++ "]"

data RefF = RefFI Var | RefFO Var | RefF Var | RefBtoRefF RefB
  deriving (Eq, Ord)

instance Show RefF where
  show (RefFI x) = "$FI" ++ show x
  show (RefFO x) = "$FO" ++ show x
  show (RefF x) = "$F" ++ show x
  show (RefBtoRefF x) = show x

data RefU = RefUI Width Var | RefUO Width Var | RefU Width Var | RefBtoRefU RefB
  deriving (Eq, Ord)

instance Show RefU where
  show ref = case ref of
    RefUI w x -> "$UI" ++ toSubscript w ++ show x
    RefUO w x -> "$UO" ++ toSubscript w ++ show x
    RefU w x -> "$U" ++ toSubscript w ++ show x
    RefBtoRefU x -> show x
    where
      toSubscript :: Int -> String
      toSubscript = map go . show
        where
          go c = case c of
            '0' -> '₀'
            '1' -> '₁'
            '2' -> '₂'
            '3' -> '₃'
            '4' -> '₄'
            '5' -> '₅'
            '6' -> '₆'
            '7' -> '₇'
            '8' -> '₈'
            '9' -> '₉'
            _ -> c

--------------------------------------------------------------------------------

reindexRefF :: Counters -> RefF -> Var
reindexRefF counters (RefFI x) = reindex counters OfInput OfField x
reindexRefF counters (RefFO x) = reindex counters OfOutput OfField x
reindexRefF counters (RefF x) = reindex counters OfIntermediate OfField x
reindexRefF counters (RefBtoRefF x) = reindexRefB counters x

reindexRefB :: Counters -> RefB -> Var
reindexRefB counters (RefBI x) = reindex counters OfInput OfBoolean x
reindexRefB counters (RefBO x) = reindex counters OfOutput OfBoolean x
reindexRefB counters (RefB x) = reindex counters OfIntermediate OfBoolean x
reindexRefB counters (RefUBit w x i) =
  let i' = i `mod` w
   in case x of
        RefUI _ x' -> reindex counters OfInput (OfUIntBinRep w) x' + i'
        RefUO _ x' -> reindex counters OfOutput (OfUIntBinRep w) x' + i'
        RefU _ x' -> reindex counters OfIntermediate (OfUIntBinRep w) x' + i'
        RefBtoRefU x' ->
          if i' == 0
            then reindexRefB counters x'
            else error "reindexRefB: RefUBit"

reindexRefU :: Counters -> RefU -> Var
reindexRefU counters (RefUI w x) = reindex counters OfInput (OfUInt w) x
reindexRefU counters (RefUO w x) = reindex counters OfOutput (OfUInt w) x
reindexRefU counters (RefU w x) = reindex counters OfIntermediate (OfUInt w) x
reindexRefU counters (RefBtoRefU x) = reindexRefB counters x

--------------------------------------------------------------------------------

-- | Like Poly but with using Refs instead of Ints as variables
data Poly' ref n = Poly' n (Map ref n)
  deriving (Eq, Functor, Ord)

instance (Show n, Ord n, Eq n, Num n, Show ref) => Show (Poly' ref n) where
  show (Poly' n xs)
    | n == 0 =
      if firstSign == " + "
        then concat restOfTerms
        else "- " <> concat restOfTerms
    | otherwise = concat (show n : termStrings)
    where
      (firstSign : restOfTerms) = termStrings

      termStrings = concatMap printTerm $ Map.toList xs
      -- return a pair of the sign ("+" or "-") and the string representation
      printTerm :: (Show n, Ord n, Eq n, Num n, Show ref) => (ref, n) -> [String]
      printTerm (x, c)
        | c == 0 = error "printTerm: coefficient of 0"
        | c == 1 = [" + ", show x]
        | c == -1 = [" - ", show x]
        | c < 0 = [" - ", show (Prelude.negate c) <> show x]
        | otherwise = [" + ", show c <> show x]

buildPoly' :: (GaloisField n, Ord ref) => n -> [(ref, n)] -> Either n (Poly' ref n)
buildPoly' c xs =
  let result = Map.filter (/= 0) $ Map.fromListWith (+) xs
   in if Map.null result
        then Left c
        else Right (Poly' c result)

fromPolyF :: Integral n => Counters -> Poly' RefF n -> Either n (Poly n)
fromPolyF counters (Poly' c xs) = Poly.buildEither c (map (first (reindexRefF counters)) (Map.toList xs))

fromPolyB :: Integral n => Counters -> Poly' RefB n -> Either n (Poly n)
fromPolyB counters (Poly' c xs) = Poly.buildEither c (map (first (reindexRefB counters)) (Map.toList xs))

fromPolyU :: Integral n => Counters -> Poly' RefU n -> Either n (Poly n)
fromPolyU counters (Poly' c xs) = Poly.buildEither c (map (first (reindexRefU counters)) (Map.toList xs))

fromPolyF_ :: Integral n => Counters -> Poly' RefF n -> Poly n
fromPolyF_ counters xs = case fromPolyF counters xs of
  Left _ -> error "[ panic ] fromPolyF_: Left"
  Right p -> p

fromPolyB_ :: Integral n => Counters -> Poly' RefB n -> Poly n
fromPolyB_ counters xs = case fromPolyB counters xs of
  Left _ -> error "[ panic ] fromPolyB_: Left"
  Right p -> p

fromPolyU_ :: Integral n => Counters -> Poly' RefU n -> Poly n
fromPolyU_ counters xs = case fromPolyU counters xs of
  Left _ -> error "[ panic ] fromPolyU_: Left"
  Right p -> p

--------------------------------------------------------------------------------

-- | Constraint
--      CAdd: 0 = c + c₀x₀ + c₁x₁ ... cₙxₙ
--      CMul: ax * by = c or ax * by = cz
--      CNEq: if (x - y) == 0 then m = 0 else m = recip (x - y)
data Constraint n
  = CAddF !(Poly' RefF n)
  | CAddB !(Poly' RefB n)
  | CAddU !(Poly' RefU n)
  | CVarEqF RefF RefF -- when x == y
  | CVarEqB RefB RefB -- when x == y
  | CVarEqU RefU RefU -- when x == y
  | CVarBindF RefF n -- when x = val
  | CVarBindB RefB n -- when x = val
  | CVarBindU RefU n -- when x = val
  | CMulF !(Poly' RefF n) !(Poly' RefF n) !(Either n (Poly' RefF n))
  | CMulB !(Poly' RefB n) !(Poly' RefB n) !(Either n (Poly' RefB n))
  | CMulU !(Poly' RefU n) !(Poly' RefU n) !(Either n (Poly' RefU n))
  | CNEqF RefF RefF RefF
  | CNEqU RefU RefU RefU

instance GaloisField n => Eq (Constraint n) where
  xs == ys = case (xs, ys) of
    (CAddF x, CAddF y) -> x == y
    (CAddB x, CAddB y) -> x == y
    (CVarEqU x y, CVarEqU u v) -> (x == u && y == v) || (x == v && y == u)
    (CVarBindU x y, CVarBindU u v) -> x == u && y == v
    (CVarBindF x y, CVarBindF u v) -> x == u && y == v
    (CMulF x y z, CMulF u v w) ->
      (x == u && y == v || x == v && y == u) && z == w
    (CMulB x y z, CMulB u v w) ->
      (x == u && y == v || x == v && y == u) && z == w
    (CMulU x y z, CMulU u v w) ->
      (x == u && y == v || x == v && y == u) && z == w
    (CNEqF x y z, CNEqF u v w) ->
      (x == u && y == v || x == v && y == u) && z == w
    (CNEqU x y z, CNEqU u v w) ->
      (x == u && y == v || x == v && y == u) && z == w
    _ -> False

instance Functor Constraint where
  fmap f (CAddF x) = CAddF (fmap f x)
  fmap f (CAddB x) = CAddB (fmap f x)
  fmap f (CAddU x) = CAddU (fmap f x)
  fmap _ (CVarEqF x y) = CVarEqF x y
  fmap _ (CVarEqB x y) = CVarEqB x y
  fmap _ (CVarEqU x y) = CVarEqU x y
  fmap f (CVarBindF x y) = CVarBindF x (f y)
  fmap f (CVarBindB x y) = CVarBindB x (f y)
  fmap f (CVarBindU x y) = CVarBindU x (f y)
  fmap f (CMulF x y (Left z)) = CMulF (fmap f x) (fmap f y) (Left (f z))
  fmap f (CMulF x y (Right z)) = CMulF (fmap f x) (fmap f y) (Right (fmap f z))
  fmap f (CMulB x y (Left z)) = CMulB (fmap f x) (fmap f y) (Left (f z))
  fmap f (CMulB x y (Right z)) = CMulB (fmap f x) (fmap f y) (Right (fmap f z))
  fmap f (CMulU x y (Left z)) = CMulU (fmap f x) (fmap f y) (Left (f z))
  fmap f (CMulU x y (Right z)) = CMulU (fmap f x) (fmap f y) (Right (fmap f z))
  fmap _ (CNEqF x y z) = CNEqF x y z
  fmap _ (CNEqU x y z) = CNEqU x y z

-- | Smart constructor for the CAddF constraint
cAddF :: GaloisField n => n -> [(RefF, n)] -> [Constraint n]
cAddF !c !xs = case buildPoly' c xs of
  Left _ -> []
  Right xs' -> [CAddF xs']

-- | Smart constructor for the CAddB constraint
cAddB :: GaloisField n => n -> [(RefB, n)] -> [Constraint n]
cAddB !c !xs = case buildPoly' c xs of
  Left _ -> []
  Right xs' -> [CAddB xs']

-- | Smart constructor for the CAddU constraint
cAddU :: GaloisField n => n -> [(RefU, n)] -> [Constraint n]
cAddU !c !xs = case buildPoly' c xs of
  Left _ -> []
  Right xs' -> [CAddU xs']

-- | Smart constructor for the CVarEqF constraint
cVarEqF :: GaloisField n => RefF -> RefF -> [Constraint n]
cVarEqF x y = if x == y then [] else [CVarEqF x y]

-- | Smart constructor for the CVarEqB constraint
cVarEqB :: GaloisField n => RefB -> RefB -> [Constraint n]
cVarEqB x y = if x == y then [] else [CVarEqB x y]

-- | Smart constructor for the CVarEqU constraint
cVarEqU :: GaloisField n => RefU -> RefU -> [Constraint n]
cVarEqU x y = if x == y then [] else [CVarEqU x y]

-- | Smart constructor for the cVarBindF constraint
cVarBindF :: GaloisField n => RefF -> n -> [Constraint n]
cVarBindF x n = [CVarBindF x n]

-- | Smart constructor for the cVarBindB constraint
cVarBindB :: GaloisField n => RefB -> n -> [Constraint n]
cVarBindB x n = [CVarBindB x n]

-- | Smart constructor for the cVarBindU constraint
cVarBindU :: GaloisField n => RefU -> n -> [Constraint n]
cVarBindU x n = [CVarBindU x n]

cMulSimple :: GaloisField n => (Poly' ref n -> Poly' ref n -> Either n (Poly' ref n) -> Constraint n) -> ref -> ref -> ref -> [Constraint n]
cMulSimple ctor !x !y !z =
  [ ctor (Poly' 0 (Map.singleton x 1)) (Poly' 0 (Map.singleton y 1)) (Right (Poly' 0 (Map.singleton z 1)))
  ]

cMulSimpleF :: GaloisField n => RefF -> RefF -> RefF -> [Constraint n]
cMulSimpleF = cMulSimple CMulF

cMulSimpleB :: GaloisField n => RefB -> RefB -> RefB -> [Constraint n]
cMulSimpleB = cMulSimple CMulB

-- | Smart constructor for the CMul constraint
cMul ::
  (GaloisField n, Ord ref) =>
  (Poly' ref n -> Poly' ref n -> Either n (Poly' ref n) -> Constraint n) ->
  (n, [(ref, n)]) ->
  (n, [(ref, n)]) ->
  (n, [(ref, n)]) ->
  [Constraint n]
cMul ctor (a, xs) (b, ys) (c, zs) = case ( do
                                             xs' <- buildPoly' a xs
                                             ys' <- buildPoly' b ys
                                             return $ ctor xs' ys' (buildPoly' c zs)
                                         ) of
  Left _ -> []
  Right result -> [result]

-- | Smart constructor for the CMulF constraint
cMulF :: GaloisField n => (n, [(RefF, n)]) -> (n, [(RefF, n)]) -> (n, [(RefF, n)]) -> [Constraint n]
cMulF = cMul CMulF

-- | Smart constructor for the CMulB constraint
cMulB :: GaloisField n => (n, [(RefB, n)]) -> (n, [(RefB, n)]) -> (n, [(RefB, n)]) -> [Constraint n]
cMulB = cMul CMulB

-- | Smart constructor for the CMulU constraint
cMulU :: GaloisField n => (n, [(RefU, n)]) -> (n, [(RefU, n)]) -> (n, [(RefU, n)]) -> [Constraint n]
cMulU = cMul CMulU

-- | Smart constructor for the CNEq constraint
cNEqF :: GaloisField n => RefF -> RefF -> RefF -> [Constraint n]
cNEqF x y m = [CNEqF x y m]

cNEqU :: GaloisField n => RefU -> RefU -> RefU -> [Constraint n]
cNEqU x y m = [CNEqU x y m]

instance (GaloisField n, Integral n) => Show (Constraint n) where
  show (CAddF xs) = "AF " <> show xs <> " = 0"
  show (CAddB xs) = "AB " <> show xs <> " = 0"
  show (CAddU xs) = "AU " <> show xs <> " = 0"
  show (CVarEqF x y) = "VF " <> show x <> " = " <> show y
  show (CVarEqB x y) = "VB " <> show x <> " = " <> show y
  show (CVarEqU x y) = "VU " <> show x <> " = " <> show y
  show (CVarBindF x n) = "BF " <> show x <> " = " <> show n
  show (CVarBindB x n) = "BB " <> show x <> " = " <> show n
  show (CVarBindU x n) = "BU " <> show x <> " = " <> show n
  show (CMulF aV bV cV) = "MF " <> show aV <> " * " <> show bV <> " = " <> show cV
  show (CMulB aV bV cV) = "MB " <> show aV <> " * " <> show bV <> " = " <> show cV
  show (CMulU aV bV cV) = "MU " <> show aV <> " * " <> show bV <> " = " <> show cV
  show (CNEqF x y m) = "QF " <> show x <> " " <> show y <> " " <> show m
  show (CNEqU x y m) = "QU " <> show x <> " " <> show y <> " " <> show m

--------------------------------------------------------------------------------

-- | A constraint system is a collection of constraints
data ConstraintSystem n = ConstraintSystem
  { csCounters :: !Counters,
    csVarEqF :: [(RefF, RefF)], -- when x == y
    csVarEqB :: [(RefB, RefB)], -- when x == y
    csVarEqU :: [(RefU, RefU)], -- when x == y
    csVarBindF :: [(RefF, n)], -- when x = val
    csVarBindB :: [(RefB, n)], -- when x = val
    csVarBindU :: [(RefU, n)], -- when x = val
    csAddF :: [Poly' RefF n],
    csAddB :: [Poly' RefB n],
    csAddU :: [Poly' RefU n],
    csMulF :: [(Poly' RefF n, Poly' RefF n, Either n (Poly' RefF n))],
    csMulB :: [(Poly' RefB n, Poly' RefB n, Either n (Poly' RefB n))],
    csMulU :: [(Poly' RefU n, Poly' RefU n, Either n (Poly' RefU n))],
    csNEqF :: [(RefF, RefF, RefF)],
    csNEqU :: [(RefU, RefU, RefU)]
  }
  deriving (Eq)

instance (GaloisField n, Integral n) => Show (ConstraintSystem n) where
  show cs =
    "ConstraintSystem {\n"
      <> showVarEqU
      <> showVarBindU
      <> showVarBindF
      <> showAddF
      <> showAddB
      <> showBooleanConstraints
      <> showBinRepConstraints
      <> showVariables
      <> "}"
    where
      counters = csCounters cs
      -- sizes of constraint groups
      totalBinRepConstraintSize = getBinRepConstraintSize counters
      booleanConstraintSize = getBooleanConstraintSize counters

      adapt :: String -> [a] -> (a -> String) -> String
      adapt name xs f =
        let size = length xs
         in if size == 0
              then ""
              else "  " <> name <> " (" <> show size <> "):\n\n" <> unlines (map (("    " <>) . f) xs) <> "\n"

      -- Boolean constraints
      showBooleanConstraints =
        if booleanConstraintSize == 0
          then ""
          else
            "  Boolean constriants (" <> show booleanConstraintSize <> "):\n\n"
              <> unlines (map ("    " <>) (prettyBooleanConstraints counters))
              <> "\n"

      -- BinRep constraints
      showBinRepConstraints =
        if totalBinRepConstraintSize == 0
          then ""
          else
            "  Binary representation constriants (" <> show totalBinRepConstraintSize <> "):\n\n"
              <> unlines (map ("    " <>) (prettyBinRepConstraints counters))
              <> "\n"

      showAddF = adapt "AddF" (csAddF cs) show
      showAddB = adapt "AddB" (csAddB cs) show

      showVarEqU = adapt "VarEqU" (csVarEqU cs) show

      showVarBindU = adapt "VarBindU" (csVarBindU cs) $ \(var, val) -> show var <> " = " <> show val
      showVarBindF = adapt "VarBindF" (csVarBindF cs) $ \(var, val) -> show var <> " = " <> show val

      showVariables :: String
      showVariables =
        let totalSize = getTotalCount counters
            padRight4 s = s <> replicate (4 - length s) ' '
            padLeft12 n = replicate (12 - length (show n)) ' ' <> show n
            formLine typ = padLeft12 (getCount OfOutput typ counters) <> "  " <> padLeft12 (getCount OfInput typ counters) <> "      " <> padLeft12 (getCount OfIntermediate typ counters)
            toSubscript = map go . show
              where
                go c = case c of
                  '0' -> '₀'
                  '1' -> '₁'
                  '2' -> '₂'
                  '3' -> '₃'
                  '4' -> '₄'
                  '5' -> '₅'
                  '6' -> '₆'
                  '7' -> '₇'
                  '8' -> '₈'
                  '9' -> '₉'
                  _ -> c
            uint w = "\n    UInt" <> padRight4 (toSubscript w) <> formLine (OfUInt w)
            showUInts (Counters o _ _ _ _) =
              let xs = map uint (IntMap.keys (structU o))
               in if null xs then "\n    UInt            none          none              none" else mconcat xs
         in if totalSize == 0
              then ""
              else
                "  Variables (" <> show totalSize <> "):\n"
                  <> "                  output         input      intermediate\n"
                  <> "\n    Field   "
                  <> formLine OfField
                  <> "\n    Boolean "
                  <> formLine OfBoolean
                  <> showUInts counters
                  <> "\n"

relocateConstraintSystem :: (GaloisField n, Integral n) => ConstraintSystem n -> Relocated.RelocatedConstraintSystem n
relocateConstraintSystem cs =
  Relocated.RelocatedConstraintSystem
    { Relocated.csCounters = counters,
      Relocated.csConstraints = varEqUs <> varBindUs <> addFs <> addBs <> mulFs <> mulBs <> mulUs <> nEqFs <> nEqUs
    }
  where
    counters = csCounters cs
    uncurry3 f (a, b, c) = f a b c
    varEqUs = Set.fromList $ map (fromConstraint counters . uncurry CVarEqU) $ csVarEqU cs
    varBindUs = Set.fromList $ map (fromConstraint counters . uncurry CVarBindU) $ csVarBindU cs
    addFs = Set.fromList $ map (fromConstraint counters . CAddF) $ csAddF cs
    addBs = Set.fromList $ map (fromConstraint counters . CAddB) $ csAddB cs
    mulFs = Set.fromList $ map (fromConstraint counters . uncurry3 CMulF) $ csMulF cs
    mulBs = Set.fromList $ map (fromConstraint counters . uncurry3 CMulB) $ csMulB cs
    mulUs = Set.fromList $ map (fromConstraint counters . uncurry3 CMulU) $ csMulU cs
    nEqFs = Set.fromList $ map (\(x, y, m) -> Relocated.CNEq (Constraint.CNEQ (Left (reindexRefF counters x)) (Left (reindexRefF counters y)) (reindexRefF counters m))) $ csNEqF cs
    nEqUs = Set.fromList $ map (\(x, y, m) -> Relocated.CNEq (Constraint.CNEQ (Left (reindexRefU counters x)) (Left (reindexRefU counters y)) (reindexRefU counters m))) $ csNEqU cs

-- sizeOfConstraintSystem :: ConstraintSystem n -> Int
-- sizeOfConstraintSystem cs =
--   length (csVarEqU cs)
--     + length (csVarBindU cs)
--     + length (csAddF cs)
--     + length (csAddB cs)
--     + length (csMulF cs)
--     + length (csMulB cs)
--     + length (csMulU cs)
--     + length (csNEqF cs)
--     + length (csNEqU cs)