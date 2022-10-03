{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}

module Encode (asJSONLines) where

-- import Data.Aeson.Encoding
import Data.Aeson
import Data.Aeson.Encoding
import qualified Data.Bifunctor as Bifunctor
import Data.ByteString.Lazy (ByteString)
import qualified Data.ByteString.Lazy as BS
import Data.Field.Galois (GaloisField (char, deg))
import qualified Data.IntMap as IntMap
import qualified Data.IntSet as IntSet
import Data.Proxy
import Keelung.Constraint.Polynomial (Poly)
import qualified Keelung.Constraint.Polynomial as Poly
import Keelung.Constraint.R1C (R1C (..))
import Keelung.Constraint.R1CS (R1CS (..), toR1Cs)
import Keelung.Types (Var)

-- | J-R1CS – a JSON Lines format for R1CS
--   https://www.sikoba.com/docs/SKOR_GD_R1CS_Format.pdf

-- | Encodes a R1CS in the JSON Lines text file format
asJSONLines :: (GaloisField n, Integral n) => R1CS n -> ByteString
asJSONLines r1cs = asJSONLines_ (fieldNumberProxy r1cs) (fmap toInteger (reindexR1CS r1cs))
  where
    fieldNumberProxy :: GaloisField n => R1CS n -> n
    fieldNumberProxy _ = asProxyTypeOf 0 Proxy

--------------------------------------------------------------------------------

asJSONLines_ :: GaloisField n => n -> R1CS Integer -> ByteString
asJSONLines_ fieldNumber r1cs =
  BS.intercalate "\n" $
    map encodingToLazyByteString $
      header : map toEncoding r1cConstraints
  where
    r1cConstraints = toR1Cs r1cs

    inputAndOutputSize :: Int
    inputAndOutputSize = r1csInputVarSize r1cs + r1csOutputVarSize r1cs

    header :: Encoding
    header =
      pairs $
        pairStr "r1cs" $
          pairs $
            pairStr "version" (string "0.5.0")
              <> pairStr "field_characteristic" (integerText (toInteger (char fieldNumber)))
              <> pairStr "extension_degree" (integerText (toInteger (deg fieldNumber)))
              <> pairStr "instances" (int inputAndOutputSize) -- inputs & outputs
              <> pairStr "witness" (int (r1csVarSize r1cs - inputAndOutputSize)) -- other variables
              <> pairStr "constraints" (int (length r1cConstraints))

--------------------------------------------------------------------------------

-- | How to encode a R1C
instance ToJSON (R1C Integer) where
  toEncoding (R1C a b c) =
    pairs $
      pairStr "A" (encodeEitherConstPoly a)
        <> pairStr "B" (encodeEitherConstPoly b)
        <> pairStr "C" (encodeEitherConstPoly c)
    where
      encodeEitherConstPoly :: Either Integer (Poly Integer) -> Encoding
      encodeEitherConstPoly (Left constant) = list encodeVarCoeff [(0, constant)]
      encodeEitherConstPoly (Right poly) = toEncoding poly

-- | How to encode a Polynomial
instance ToJSON (Poly Integer) where
  toEncoding poly = case Poly.constant poly of
    0 -> list encodeVarCoeff (IntMap.toList (Poly.coeffs poly))
    n -> list encodeVarCoeff ((0, n) : IntMap.toList (Poly.coeffs poly))

-- | How to encode a variable-coefficient pair
encodeVarCoeff :: (Var, Integer) -> Encoding
encodeVarCoeff (v, c) = list f [Left v, Right c]
  where
    f (Left var) = int var
    f (Right coeff) = integerText (toInteger coeff)

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
    reindex var
      | isInputOrOutputVar var = - var
      | otherwise = var

    isInputOrOutputVar :: Var -> Bool
    isInputOrOutputVar var = var < r1csInputVarSize r1cs + r1csOutputVarSize r1cs