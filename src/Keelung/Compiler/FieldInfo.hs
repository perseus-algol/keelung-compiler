{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Keelung.Compiler.FieldInfo (FieldInfo (..), caseFieldType) where

import Control.DeepSeq (NFData)
import Data.Field.Galois
import Data.Proxy
import GHC.Generics (Generic)
import GHC.TypeLits
import Keelung.Field (FieldType (..))
import Data.Serialize (Serialize)

-- | Runtime info data of a field
data FieldInfo = FieldInfo
  { fieldTypeData :: FieldType,
    fieldOrder :: Integer,
    fieldChar :: Natural,
    fieldDeg :: Int,
    fieldWidth :: Int
  }
  deriving (Eq, Generic, NFData)

instance Serialize FieldInfo

caseFieldType ::
  FieldType ->
  (forall n. KnownNat n => Proxy (Prime n) -> FieldInfo -> IO ()) ->
  (forall n. KnownNat n => Proxy (Binary n) -> FieldInfo -> IO ()) ->
  IO ()
caseFieldType (Prime n) funcPrime _ = case someNatVal n of
  Just (SomeNat (_ :: Proxy n)) -> do
    let fieldNumber = asProxyTypeOf 0 (Proxy :: Proxy (Prime n))
     in funcPrime (Proxy :: Proxy (Prime n)) $
          FieldInfo
            { fieldTypeData = Prime n,
              fieldOrder = toInteger (order fieldNumber),
              fieldChar = char fieldNumber,
              fieldDeg = fromIntegral (deg fieldNumber),
              fieldWidth = ceiling (logBase (2 :: Double) (fromIntegral (order fieldNumber)))
            }
  Nothing -> return ()
caseFieldType (Binary n) _ funcBinary = case someNatVal n of
  Just (SomeNat (_ :: Proxy n)) ->
    let fieldNumber = asProxyTypeOf 0 (Proxy :: Proxy (Binary n))
     in funcBinary (Proxy :: Proxy (Binary n)) $
          FieldInfo
            { fieldTypeData = Prime n,
              fieldOrder = toInteger (order fieldNumber),
              fieldChar = char fieldNumber,
              fieldDeg = fromIntegral (deg fieldNumber),
              fieldWidth = ceiling (logBase (2 :: Double) (fromIntegral (order fieldNumber)))
            }
  Nothing -> return ()