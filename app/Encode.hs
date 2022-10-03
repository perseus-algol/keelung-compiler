{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}

module Encode where

-- import Data.Aeson.Encoding
import Data.Aeson
import Data.Aeson.Encoding
import qualified Data.Bifunctor as Bifunctor
import qualified Data.IntMap as IntMap
import qualified Data.IntSet as IntSet
import Keelung.Constraint.Polynomial (Poly)
import qualified Keelung.Constraint.Polynomial as Poly
import Keelung.Constraint.R1C (R1C (..))
import Keelung.Constraint.R1CS (R1CS (..))
import Keelung.Types (Var)

-- | J-R1CS – a JSON Lines format for R1CS
--   https://www.sikoba.com/docs/SKOR_GD_R1CS_Format.pdf

-- -- | Encodes a R1CS in the JSON Lines text file format
-- asJSONLines :: R1CS n -> ByteString
-- asJSONLines r1cs = BS.intercalate "\n" $ map encodingToLazyByteString $ encodeHeader r1cs : encodeR1Cs r1cs

-- -- instance ToJSON (R1CS n) where
-- --   toEncoding = undefined

-- encodeHeader :: R1CS n -> Encoding
-- encodeHeader r1cs = null_

-- encodeR1Cs :: R1CS n -> [Encoding]
-- encodeR1Cs r1cs = []

-- -- instance ToJSON n => ToJSON (R1C n) where
-- --   toEncoding = undefined

-- | How to encode a R1C
instance (ToJSON n, Num n, Eq n, Show n) => ToJSON (R1C n) where
  toEncoding (R1C a b c) =
    pairs $
      pairStr "A" (encodeEitherConstPoly a)
        <> pairStr "B" (encodeEitherConstPoly b)
        <> pairStr "C" (encodeEitherConstPoly c)

-- | How to encode `Either n (Poly n)`
encodeEitherConstPoly :: (ToJSON n, Num n, Eq n, Show n) => Either n (Poly n) -> Encoding
encodeEitherConstPoly (Left constant) = list encodeVarCoeff [(0, constant)]
encodeEitherConstPoly (Right poly) = toEncoding poly

-- | How to encode a Polynomial
instance (ToJSON n, Num n, Eq n, Show n) => ToJSON (Poly n) where
  toEncoding poly = case Poly.constant poly of
    0 -> list encodeVarCoeff (IntMap.toList (Poly.coeffs poly))
    n -> list encodeVarCoeff ((0, n) : IntMap.toList (Poly.coeffs poly))

-- | How to encode a variable-coefficient pair
encodeVarCoeff :: (ToJSON n, Num n, Eq n, Show n) => (Var, n) -> Encoding
encodeVarCoeff (v, c) = list f [Left v, Right c]
  where
    f (Left var) = int var
    f (Right coeff) = string (show coeff)

--------------------------------------------------------------------------------

-- | Variables of a R1CS are re-indexed so that:
--   index = 0:  reserved for the constant 1
--   index < 0:  reserved for the input & output variables
--   index > 0:  reserved for the all the other variables (witnesses)
reindexR1CS :: R1CS n -> R1CS n
reindexR1CS r1cs =
  r1cs
    { r1csConstraints = map reindexR1C (r1csConstraints r1cs),
      r1csBoolInputVars = IntSet.map reindex (r1csBoolInputVars r1cs),
      r1csCNQZPairs = map (Bifunctor.bimap reindex reindex) (r1csCNQZPairs r1cs)
    }
  where
    reindexR1C :: R1C n -> R1C n
    reindexR1C (R1C a b c) =
      R1C
        (fmap (Poly.mapVars reindex) a)
        (fmap (Poly.mapVars reindex) b)
        (fmap (Poly.mapVars reindex) c)

    reindex :: Var -> Var
    reindex var = var

--------------------------------------------------------------------------------
