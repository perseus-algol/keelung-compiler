module Keelung.Data.Constraint
  ( Constraint (..),
    pinnedRef,
    pinnedRefB,
    pinnedRefU,
  )
where

import Data.Field.Galois (GaloisField)
import Keelung.Data.PolyG (PolyG)
import Keelung.Data.Reference

--------------------------------------------------------------------------------

pinnedRef :: Ref -> Bool
pinnedRef (B ref) = pinnedRefB ref
pinnedRef (F ref) = pinnedRefF ref
pinnedRef (U ref) = pinnedRefBin ref

pinnedRefF :: RefF -> Bool
pinnedRefF (RefFO _) = True
pinnedRefF (RefFI _) = True
pinnedRefF (RefFP _) = True
pinnedRefF (RefFX _) = False

pinnedRefB :: RefB -> Bool
pinnedRefB (RefBI _) = True
pinnedRefB (RefBP _) = True
pinnedRefB (RefBO _) = True
pinnedRefB (RefUBit _ ref _) = pinnedRefU ref
pinnedRefB (RefBX _) = False

pinnedRefU :: RefU -> Bool
pinnedRefU (RefUI _ _) = True
pinnedRefU (RefUP _ _) = True
pinnedRefU (RefUO _ _) = True
pinnedRefU (RefUX _ _) = False

pinnedRefBin :: RefBin -> Bool
pinnedRefBin = pinnedRefU . refBinRefU

--------------------------------------------------------------------------------

-- | Constraint
--      CAdd: 0 = c + c₀x₀ + c₁x₁ ... cₙxₙ
--      CMul: ax * by = c or ax * by = cz
--      CNEq: if (x - y) == 0 then m = 0 else m = recip (x - y)
data Constraint n
  = CAddF !(PolyG Ref n)
  | CVarEq Ref Ref -- when x == y
  | CVarEqF RefF RefF -- when x == y
  | CVarEqB RefB RefB -- when x == y
  | CVarNEqB RefB RefB -- when x = ¬ y
  | CVarBindF Ref n -- when x = val
  | CVarBindB RefB Bool -- when x = val
  | CMulF !(PolyG Ref n) !(PolyG Ref n) !(Either n (PolyG Ref n))

instance GaloisField n => Eq (Constraint n) where
  xs == ys = case (xs, ys) of
    (CAddF x, CAddF y) -> x == y
    (CVarBindF x y, CVarBindF u v) -> x == u && y == v
    (CMulF x y z, CMulF u v w) ->
      (x == u && y == v || x == v && y == u) && z == w
    _ -> False

instance Functor Constraint where
  fmap f (CAddF x) = CAddF (fmap f x)
  fmap _ (CVarEq x y) = CVarEq x y
  fmap _ (CVarEqF x y) = CVarEqF x y
  fmap _ (CVarNEqB x y) = CVarNEqB x y
  fmap _ (CVarEqB x y) = CVarEqB x y
  fmap f (CVarBindF x y) = CVarBindF x (f y)
  fmap _ (CVarBindB x y) = CVarBindB x y
  fmap f (CMulF x y (Left z)) = CMulF (fmap f x) (fmap f y) (Left (f z))
  fmap f (CMulF x y (Right z)) = CMulF (fmap f x) (fmap f y) (Right (fmap f z))

instance (GaloisField n, Integral n) => Show (Constraint n) where
  show (CAddF xs) = "AF " <> show xs <> " = 0"
  show (CVarEq x y) = "EQ " <> show x <> " = " <> show y
  show (CVarEqF x y) = "VF " <> show x <> " = " <> show y
  show (CVarEqB x y) = "VB " <> show x <> " = " <> show y
  show (CVarNEqB x y) = "VN " <> show x <> " = ¬ " <> show y
  show (CVarBindF x n) = "BF " <> show x <> " = " <> show n
  show (CVarBindB x n) = "BB " <> show x <> " = " <> show n
  show (CMulF aV bV cV) = "MF " <> show aV <> " * " <> show bV <> " = " <> show cV