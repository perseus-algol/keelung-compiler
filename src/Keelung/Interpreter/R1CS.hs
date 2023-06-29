{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TupleSections #-}

module Keelung.Interpreter.R1CS (run, run', Error (..)) where

import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.State
import Data.Bifunctor (first)
import Data.Bits qualified
import Data.Field.Galois (GaloisField (order))
import Data.Foldable (toList)
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IntMap
import Data.List qualified as List
import Data.Sequence (Seq)
import Data.Sequence qualified as Seq
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import Keelung.Compiler.Syntax.Inputs (Inputs)
import Keelung.Constraint.R1C
import Keelung.Constraint.R1CS
import Keelung.Data.Polynomial (Poly)
import Keelung.Data.Polynomial qualified as Poly
import Keelung.Interpreter.Arithmetics (U (UVal))
import Keelung.Interpreter.Arithmetics qualified as U
import Keelung.Interpreter.R1CS.Monad
import Keelung.Syntax (Var, Width)
import Keelung.Syntax.Counters

run :: (GaloisField n, Integral n) => R1CS n -> Inputs n -> Either (Error n) (Vector n)
run r1cs inputs = fst <$> run' r1cs inputs

-- | Return interpreted outputs along with the witnesses
run' :: (GaloisField n, Integral n) => R1CS n -> Inputs n -> Either (Error n) (Vector n, Vector n)
run' r1cs inputs = do
  let booleanConstraintCategories = [(Output, ReadBool), (Output, ReadAllUInts), (PublicInput, ReadBool), (PublicInput, ReadAllUInts), (PrivateInput, ReadBool), (PrivateInput, ReadAllUInts), (Intermediate, ReadBool), (Intermediate, ReadAllUInts)]
  let boolVarRanges = getRanges (r1csCounters r1cs) booleanConstraintCategories
  constraints <- fromOrdinaryConstraints r1cs
  witness <- runM boolVarRanges inputs $ goThroughManyTimes constraints

  -- extract output values from the witness
  let outputRanges = getRanges (r1csCounters r1cs) [(Output, ReadField), (Output, ReadBool), (Output, ReadAllUInts)]
  case IntMap.toList outputRanges of
    [(outputStart, outputLength)] -> return (Vector.slice outputStart outputLength witness, witness)
    _ -> return (mempty, witness)

-- | Return Constraints from a R1CS, which include:
--   1. ordinary constraints
--   2. Boolean input variable constraints
--   3. binary representation constraints
--   4. CNEQ constraints
fromOrdinaryConstraints :: (GaloisField n, Integral n) => R1CS n -> Either (Error n) (Seq (Constraint n))
fromOrdinaryConstraints (R1CS _ ordinaryConstraints _ counters eqZeros divMods modInvs) = do
  constraints <- concat <$> mapM differentiate ordinaryConstraints
  return $
    Seq.fromList constraints
      <> Seq.fromList (map BooleanConstraint booleanInputVarConstraints)
      -- <> Seq.fromList (map (BinRepConstraint2 . toList) binReps')
      <> Seq.fromList (map EqZeroConstraint eqZeros)
      <> Seq.fromList (map DivModConstaint divMods)
      <> Seq.fromList (map ModInvConstraint modInvs)
  where
    booleanInputVarConstraints =
      let generate (start, end) = [start .. end - 1]
       in concatMap generate (getBooleanConstraintRanges counters)

    differentiate :: (GaloisField n, Integral n) => R1C n -> Either (Error n) [Constraint n]
    differentiate (R1C (Left a) (Left b) (Left c)) = if a * b == c then Right [] else Left ConflictingValues
    differentiate (R1C (Left a) (Left b) (Right c)) = Right [AddConstraint $ Poly.addConstant (-a * b) c]
    differentiate (R1C (Left a) (Right b) (Left c)) = case Poly.multiplyBy a b of
      Left constant ->
        if constant == c
          then Right []
          else Left ConflictingValues
      Right poly -> Right [AddConstraint $ Poly.addConstant (-c) poly]
    differentiate (R1C (Left a) (Right b) (Right c)) = case Poly.multiplyBy (-a) b of
      Left constant -> Right [AddConstraint $ Poly.addConstant constant c]
      Right poly -> case Poly.merge poly c of
        Left constant ->
          if constant == 0
            then Right []
            else Left ConflictingValues
        Right poly' -> Right [AddConstraint poly']
    differentiate (R1C (Right a) (Left b) (Left c)) = differentiate (R1C (Left b) (Right a) (Left c))
    differentiate (R1C (Right a) (Left b) (Right c)) = differentiate (R1C (Left b) (Right a) (Right c))
    differentiate (R1C (Right a) (Right b) c) = Right [MulConstraint a b c]

goThroughManyTimes :: (GaloisField n, Integral n) => Seq (Constraint n) -> M n ()
goThroughManyTimes constraints = do
  result <- goThroughOnce constraints
  case result of
    -- keep going
    Shrinked constraints' -> goThroughManyTimes constraints'
    -- done
    Eliminated -> return ()
    NothingToDo -> return ()
    -- stuck
    Stuck _ -> do
      context <- get
      throwError (StuckError context (toList constraints))

-- Go through a sequence of constraints
goThroughOnce :: (GaloisField n, Integral n) => Seq (Constraint n) -> M n (Result (Seq (Constraint n)))
goThroughOnce constraints = mconcat <$> mapM shrink (toList constraints)

lookupVar :: Var -> M n (Maybe n)
lookupVar var = gets (IntMap.lookup var)

lookupBitsEither :: (GaloisField n, Integral n) => (Width, Either Var Integer) -> M n (Maybe U)
lookupBitsEither (width, Left var) = do
  vals <- mapM lookupVar [var .. var + width - 1]
  case sequence vals of
    Nothing -> return Nothing
    Just bitVals -> return $ Just $ UVal width $ toInteger $ sum [bitVal * (2 ^ i) | (i, bitVal) <- zip [0 :: Int ..] bitVals]
lookupBitsEither (width, Right val) = return (Just (UVal width val))

shrink :: (GaloisField n, Integral n) => Constraint n -> M n (Result (Seq (Constraint n)))
shrink (MulConstraint as bs cs) = do
  xs <- shrinkMul as bs cs >>= detectBinRep
  return $ fmap Seq.singleton xs
shrink (AddConstraint as) = do
  as' <- shrinkAdd as >>= detectBinRep
  return $ fmap Seq.singleton as'
shrink (BooleanConstraint var) = fmap (pure . BooleanConstraint) <$> shrinkBooleanConstraint var
shrink (EqZeroConstraint eqZero) = fmap (pure . EqZeroConstraint) <$> shrinkEqZero eqZero
shrink (DivModConstaint divModTuple) = fmap (pure . DivModConstaint) <$> shrinkDivMod divModTuple
-- shrink (DivModConstaint2 divModTuple) = fmap (pure . DivModConstaint) <$> shrinkDivMod divModTuple
shrink (ModInvConstraint modInv) = fmap (pure . ModInvConstraint) <$> shrinkModInv modInv

shrinkAdd :: (GaloisField n, Integral n) => Poly n -> M n (Result (Constraint n))
shrinkAdd xs = do
  bindings <- get
  case substAndView bindings xs of
    Constant c -> eliminateIfHold c 0
    Uninomial _ _ c (var, coeff) -> do
      -- c + coeff var = 0
      bindVar var (-c / coeff)
      return Eliminated
    Polynomial changed xs' -> return $ shrinkedOrStuck [changed] $ AddConstraint xs'

shrinkMul :: (GaloisField n, Integral n) => Poly n -> Poly n -> Either n (Poly n) -> M n (Result (Constraint n))
shrinkMul as bs (Left c) = do
  bindings <- get
  case (substAndView bindings as, substAndView bindings bs) of
    (Constant a, Constant b) -> eliminateIfHold (a * b) c
    (Constant a, Uninomial _ _ b (var, coeff)) -> do
      if a == 0
        then eliminateIfHold (a * b) c
        else do
          -- a * (b + coeff var) = c
          --    =>
          -- a * b + a * coeff * var = c
          --    =>
          -- a * coeff * var = c - a * b
          --    =>
          -- var = (c - a * b) / (coeff * a)
          bindVar var ((c - a * b) / (coeff * a))
          return Eliminated
    (Constant a, Polynomial _ bs') -> case Poly.multiplyBy a bs' of
      Left constant -> eliminateIfHold constant c
      Right poly -> return $ Shrinked $ AddConstraint $ Poly.addConstant (-c) poly
    (Uninomial _ _ a (var, coeff), Constant b) -> do
      if b == 0
        then eliminateIfHold (a * b) c
        else do
          -- (a + coeff var) * b = c
          bindVar var ((c - a * b) / (coeff * b))
          return Eliminated
    (Uninomial av as' _ _, Uninomial bv bs' _ _) -> return $ shrinkedOrStuck [av, bv] $ MulConstraint as' bs' (Left c)
    (Uninomial av as' _ _, Polynomial bv bs') -> return $ shrinkedOrStuck [av, bv] $ MulConstraint as' bs' (Left c)
    (Polynomial _ as', Constant b) -> case Poly.multiplyBy b as' of
      Left constant -> eliminateIfHold constant c
      Right poly -> return $ Shrinked $ AddConstraint $ Poly.addConstant (-c) poly
    (Polynomial av as', Uninomial bv bs' _ _) -> return $ shrinkedOrStuck [av, bv] $ MulConstraint as' bs' (Left c)
    (Polynomial av as', Polynomial bv bs') -> return $ shrinkedOrStuck [av, bv] $ MulConstraint as' bs' (Left c)
shrinkMul as bs (Right cs) = do
  bindings <- get
  case (substAndView bindings as, substAndView bindings bs, substAndView bindings cs) of
    (Constant a, Constant b, Constant c) -> eliminateIfHold (a * b) c
    (Constant a, Constant b, Uninomial _ _ c (var, coeff)) -> do
      -- a * b - c = coeff var
      bindVar var ((a * b - c) / coeff)
      return Eliminated
    (Constant a, Constant b, Polynomial _ cs') -> return $ Shrinked $ AddConstraint (Poly.addConstant (-a * b) cs')
    -- return $ Shrinked $ R1C (Left a) (Left b) (Right cs')
    (Constant a, Uninomial _ _ b (var, coeff), Constant c) -> do
      if a == 0
        then eliminateIfHold (a * b) c
        else do
          -- a * (b + coeff var) = c
          --    =>
          -- a * b + a * coeff * var = c
          --    =>
          -- a * coeff * var = c - a * b
          --    =>
          -- var = (c - a * b) / (coeff * a)
          bindVar var ((c - a * b) / (coeff * a))
          return Eliminated
    (Constant a, Uninomial _ bs' _ _, Uninomial _ cs' _ _) -> case Poly.multiplyBy (-a) bs' of
      Left constant -> return $ Shrinked $ AddConstraint (Poly.addConstant constant cs')
      Right poly -> case Poly.merge poly cs' of
        Left constant -> eliminateIfHold constant 0
        Right poly' -> return $ Shrinked $ AddConstraint poly'
    (Constant a, Uninomial _ bs' _ _, Polynomial _ cs') -> case Poly.multiplyBy (-a) bs' of
      Left constant -> return $ Shrinked $ AddConstraint (Poly.addConstant constant cs')
      Right poly -> case Poly.merge poly cs' of
        Left constant -> eliminateIfHold constant 0
        Right poly' -> return $ Shrinked $ AddConstraint poly'
    (Constant a, Polynomial _ bs', Constant c) -> case Poly.multiplyBy (-a) bs' of
      Left constant -> eliminateIfHold constant c
      Right poly -> return $ Shrinked $ AddConstraint (Poly.addConstant c poly)
    (Constant a, Polynomial _ bs', Uninomial _ cs' _ _) -> case Poly.multiplyBy (-a) bs' of
      Left constant -> return $ Shrinked $ AddConstraint (Poly.addConstant constant cs')
      Right poly -> case Poly.merge poly cs' of
        Left constant -> eliminateIfHold constant 0
        Right poly' -> return $ Shrinked $ AddConstraint poly'
    (Constant a, Polynomial _ bs', Polynomial _ cs') -> case Poly.multiplyBy (-a) bs' of
      Left constant -> return $ Shrinked $ AddConstraint (Poly.addConstant constant cs')
      Right poly -> case Poly.merge poly cs' of
        Left constant -> eliminateIfHold constant 0
        Right poly' -> return $ Shrinked $ AddConstraint poly'
    (Uninomial _ _ a (var, coeff), Constant b, Constant c) -> do
      if b == 0
        then eliminateIfHold 0 c
        else do
          -- (a + coeff var) * b = c
          bindVar var ((c - a * b) / (coeff * b))
          return Eliminated
    (Uninomial _ as' _ _, Constant b, Uninomial _ cs' _ _) -> case Poly.multiplyBy (-b) as' of
      Left constant -> return $ Shrinked $ AddConstraint (Poly.addConstant constant cs')
      Right poly -> case Poly.merge poly cs' of
        Left constant -> eliminateIfHold constant 0
        Right poly' -> return $ Shrinked $ AddConstraint poly'
    (Uninomial _ as' _ _, Constant b, Polynomial _ cs') -> case Poly.multiplyBy (-b) as' of
      Left constant -> return $ Shrinked $ AddConstraint (Poly.addConstant constant cs')
      Right poly -> case Poly.merge poly cs' of
        Left constant -> eliminateIfHold constant 0
        Right poly' -> return $ Shrinked $ AddConstraint poly'
    (Uninomial _ as' _ _, Uninomial _ bs' _ _, Constant c) -> return $ Shrinked $ MulConstraint as' bs' (Left c)
    (Uninomial av as' _ _, Uninomial bv bs' _ _, Uninomial cv cs' _ _) -> return $ shrinkedOrStuck [av, bv, cv] $ MulConstraint as' bs' (Right cs')
    (Uninomial av as' _ _, Uninomial bv bs' _ _, Polynomial cv cs') -> return $ shrinkedOrStuck [av, bv, cv] $ MulConstraint as' bs' (Right cs')
    (Uninomial _ as' _ _, Polynomial _ bs', Constant c) -> return $ Shrinked $ MulConstraint as' bs' (Left c)
    (Uninomial av as' _ _, Polynomial bv bs', Uninomial cv cs' _ _) -> return $ shrinkedOrStuck [av, bv, cv] $ MulConstraint as' bs' (Right cs')
    (Uninomial av as' _ _, Polynomial bv bs', Polynomial cv cs') -> return $ shrinkedOrStuck [av, bv, cv] $ MulConstraint as' bs' (Right cs')
    (Polynomial _ as', Constant b, Constant c) -> case Poly.multiplyBy (-b) as' of
      Left constant -> eliminateIfHold constant c
      Right poly -> return $ Shrinked $ AddConstraint (Poly.addConstant c poly)
    (Polynomial _ as', Constant b, Uninomial _ cs' _ _) -> case Poly.multiplyBy (-b) as' of
      Left constant -> return $ Shrinked $ AddConstraint (Poly.addConstant constant cs')
      Right poly -> case Poly.merge poly cs' of
        Left constant -> eliminateIfHold constant 0
        Right poly' -> return $ Shrinked $ AddConstraint poly'
    (Polynomial _ as', Constant b, Polynomial _ cs') -> case Poly.multiplyBy (-b) as' of
      Left constant -> return $ Shrinked $ AddConstraint (Poly.addConstant constant cs')
      Right poly -> case Poly.merge poly cs' of
        Left constant -> eliminateIfHold constant 0
        Right poly' -> return $ Shrinked $ AddConstraint poly'
    (Polynomial _ as', Uninomial _ bs' _ _, Constant c) -> return $ Shrinked $ MulConstraint as' bs' (Left c)
    (Polynomial av as', Uninomial bv bs' _ _, Uninomial cv cs' _ _) -> return $ shrinkedOrStuck [av, bv, cv] $ MulConstraint as' bs' (Right cs')
    (Polynomial av as', Uninomial bv bs' _ _, Polynomial cv cs') -> return $ shrinkedOrStuck [av, bv, cv] $ MulConstraint as' bs' (Right cs')
    (Polynomial _ as', Polynomial _ bs', Constant c) -> return $ Shrinked $ MulConstraint as' bs' (Left c)
    (Polynomial av as', Polynomial bv bs', Uninomial cv cs' _ _) -> return $ shrinkedOrStuck [av, bv, cv] $ MulConstraint as' bs' (Right cs')
    (Polynomial av as', Polynomial bv bs', Polynomial cv cs') -> return $ shrinkedOrStuck [av, bv, cv] $ MulConstraint as' bs' (Right cs')

eliminateIfHold :: (GaloisField n, Integral n) => n -> n -> M n (Result a)
eliminateIfHold expected actual =
  if expected == actual
    then return Eliminated
    else throwError ConflictingValues

-- | Trying to reduce a DivMod constraint if any of these set of variables are known:
--    1. dividend & divisor
--    1. dividend & quotient
--    2. divisor & quotient & remainder
shrinkDivMod ::
  (GaloisField n, Integral n) =>
  ((Width, Either Var Integer), (Width, Either Var Integer), (Width, Either Var Integer), (Width, Either Var Integer)) ->
  M n (Result ((Width, Either Var Integer), (Width, Either Var Integer), (Width, Either Var Integer), (Width, Either Var Integer)))
shrinkDivMod (dividendVar, divisorVar, quotientVar, remainderVar) = do
  -- check the value of the dividend first,
  -- if it's unknown, then its value can only be determined from other variables
  dividendResult <- lookupBitsEither dividendVar
  divisorResult <- lookupBitsEither divisorVar
  quotientResult <- lookupBitsEither quotientVar
  remainderResult <- lookupBitsEither remainderVar

  case dividendResult of
    Just dividendVal -> do
      -- now that we know the dividend, we can solve the relation if we know either the divisor or the quotient
      case (divisorResult, quotientResult, remainderResult) of
        (Just divisorVal, Just actualQuotientVal, Just actualRemainderVal) -> do
          let expectedQuotientVal = dividendVal `U.integerDivU` divisorVal
              expectedRemainderVal = dividendVal `U.integerModU` divisorVal
          when (expectedQuotientVal /= actualQuotientVal) $
            throwError ConflictingValues
          -- DivModQuotientError dividendVal divisorVal expectedQuotientVal actualQuotientVal
          when (expectedRemainderVal /= actualRemainderVal) $
            throwError ConflictingValues
          -- throwError $
          --   DivModRemainderError dividendVal divisorVal expectedRemainderVal actualRemainderVal
          return Eliminated
        (Just divisorVal, Just actualQuotientVal, Nothing) -> do
          let expectedQuotientVal = dividendVal `U.integerDivU` divisorVal
              expectedRemainderVal = dividendVal `U.integerModU` divisorVal
          when (expectedQuotientVal /= actualQuotientVal) $
            throwError ConflictingValues
          -- throwError $
          --   DivModQuotientError dividendVal divisorVal expectedQuotientVal actualQuotientVal
          bindBitsEither remainderVar expectedRemainderVal
          return Eliminated
        (Just divisorVal, Nothing, Just actualRemainderVal) -> do
          let expectedQuotientVal = dividendVal `U.integerDivU` divisorVal
              expectedRemainderVal = dividendVal `U.integerModU` divisorVal
          when (expectedRemainderVal /= actualRemainderVal) $
            throwError ConflictingValues
          -- throwError $
          --   DivModRemainderError dividendVal divisorVal expectedRemainderVal actualRemainderVal
          bindBitsEither quotientVar expectedQuotientVal
          return Eliminated
        (Just divisorVal, Nothing, Nothing) -> do
          let expectedQuotientVal = dividendVal `U.integerDivU` divisorVal
              expectedRemainderVal = dividendVal `U.integerModU` divisorVal
          bindBitsEither quotientVar expectedQuotientVal
          bindBitsEither remainderVar expectedRemainderVal
          return Eliminated
        (Nothing, Just actualQuotientVal, Just actualRemainderVal) -> do
          let expectedDivisorVal = dividendVal `U.integerDivU` actualQuotientVal
              expectedRemainderVal = dividendVal `U.integerModU` expectedDivisorVal
          when (expectedRemainderVal /= actualRemainderVal) $
            throwError ConflictingValues
          -- throwError $
          --   DivModRemainderError dividendVal expectedDivisorVal expectedRemainderVal actualRemainderVal
          bindBitsEither divisorVar expectedDivisorVal
          return Eliminated
        (Nothing, Just actualQuotientVal, Nothing) -> do
          let expectedDivisorVal = dividendVal `U.integerDivU` actualQuotientVal
              expectedRemainderVal = dividendVal `U.integerModU` expectedDivisorVal
          bindBitsEither divisorVar expectedDivisorVal
          bindBitsEither remainderVar expectedRemainderVal
          return Eliminated
        _ -> return $ Stuck (dividendVar, divisorVar, quotientVar, remainderVar)
    Nothing -> do
      -- we can only piece out the dividend if all of the divisor, quotient, and remainder are known
      case (divisorResult, quotientResult, remainderResult) of
        -- divisor, quotient, and remainder are all known
        (Just divisorVal, Just quotientVal, Just remainderVal) -> do
          let dividendVal = (divisorVal `U.integerMulU` quotientVal) `U.integerAddU` remainderVal
          bindBitsEither dividendVar dividendVal
          return Eliminated
        _ -> do
          return $ Stuck (dividendVar, divisorVar, quotientVar, remainderVar)

-- | Trying to reduce a Boolean constraint
shrinkBooleanConstraint :: (GaloisField n, Integral n) => Var -> M n (Result Var)
shrinkBooleanConstraint var = do
  varResult <- lookupVar var
  case varResult of
    Just val ->
      if val /= 0 && val /= 1
        then throwError $ BooleanConstraintError var val
        else return Eliminated
    Nothing -> return $ Stuck var

-- | Trying to reduce a ModInv constraint
shrinkModInv ::
  (GaloisField n, Integral n) =>
  ((Width, Either Var Integer), (Width, Either Var Integer), (Width, Either Var Integer), Integer) ->
  M n (Result ((Width, Either Var Integer), (Width, Either Var Integer), (Width, Either Var Integer), Integer))
shrinkModInv (aVar, outVar, nVar, p) = do
  aResult <- lookupBitsEither aVar
  case aResult of
    Just aVal -> do
      case U.modInv (U.uintValue aVal) p of
        Just result -> do
          let (width, _) = aVar
          -- aVal * result = n * p + 1
          let nVal = (aVal `U.integerMulU` UVal width result `U.integerSubU` UVal width 1) `U.integerDivU` UVal width p
          bindBitsEither nVar nVal
          bindBitsEither outVar (UVal width result)
          return Eliminated
        Nothing -> throwError $ ModInvError aVar p
    Nothing -> return $ Stuck (aVar, outVar, nVar, p)

-- | Trying to reduce a BinRep constraint

data FoldState = Start | Failed | Continue (IntMap (Bool, Var)) deriving (Eq, Show)

-- | Given a mapping of (Int, (Bool, Var)) pairs, where the Int indicates the power of 2, and the Bool indicates whether the coefficient is positive or negative
--   and an Integer, derive coefficients (Boolean) for each of these variables such that the sum of the coefficients times the powers of 2 is equal to the Integer
deriveCoeffs :: (GaloisField n, Integral n) => n -> IntMap (Bool, Var) -> [(Var, Bool)]
deriveCoeffs rawConstant polynomial =
  let negatedPolynomial = fmap (first not) polynomial
      (upper, lower) = boundsOf negatedPolynomial
      constant = toInteger rawConstant
      negatedConstant = negate (toInteger (order rawConstant - fromIntegral rawConstant))
      -- should flip the sign if the constant is outside the bounds of the polynomial
      shouldFlipSign = upper < negatedConstant || lower > negatedConstant
   in fst $ IntMap.foldlWithKey' go ([], if shouldFlipSign then constant else negatedConstant) polynomial
  where
    -- given coefficients, calculate the upper bound and the lower bound of the polynomial
    boundsOf :: IntMap (Bool, Var) -> (Integer, Integer)
    boundsOf =
      IntMap.foldlWithKey'
        ( \(upper, lower) power (sign, _) ->
            if sign then (upper + (2 ^ power), lower) else (upper, lower - (2 ^ power))
        )
        (0, 0)

    go :: ([(Var, Bool)], Integer) -> Int -> (Bool, Var) -> ([(Var, Bool)], Integer)
    go (acc, c) power (sign, var) =
      if Data.Bits.testBit c power
        then
          if sign
            then ((var, True) : acc, c + (2 ^ power))
            else ((var, True) : acc, c - (2 ^ power))
        else ((var, False) : acc, c)

-- | Watch out for a stuck R1C, and see if it's a binary representation
--    1. see if coefficients are all powers of 2
--    2. see if all variables are Boolean
--   NOTE: the criteria above may not be sufficient
detectBinRep :: (GaloisField n, Integral n) => Result (Constraint n) -> M n (Result (Constraint n))
detectBinRep NothingToDo = return NothingToDo
detectBinRep Eliminated = return Eliminated
detectBinRep (Shrinked polynomial) = return (Shrinked polynomial)
detectBinRep (Stuck (AddConstraint polynomial)) = do
  -- let (normalizedConstant, positive) = normalize (Poly.constant polynomial)
  boolVarRanges <- ask
  case collectCoeffs boolVarRanges polynomial of
    Start -> return (Stuck (AddConstraint polynomial))
    Failed -> return (Stuck (AddConstraint polynomial))
    Continue invertedPolynomial -> do
      let constant = Poly.constant polynomial
      -- NOTE: the criteria below is not necessary
      -- because we know that these coefficients are:
      --  2. unique
      let powers = IntMap.keys invertedPolynomial
      let powersAllUnique = length powers == length (List.nub powers)

      if powersAllUnique
        then do
          -- we have a binary representation
          -- we can now bind the variables
          forM_ (deriveCoeffs constant invertedPolynomial) $ \(var, val) -> do
            bindVar var (if val then 1 else 0)

          return Eliminated
        else do
          -- we don't have a binary representation
          -- we can't do anything
          return (Stuck (AddConstraint polynomial))
  where
    collectCoeffs :: (GaloisField n, Integral n) => Ranges -> Poly n -> FoldState
    collectCoeffs boolVarRanges xs = IntMap.foldlWithKey' go Start (Poly.coeffs xs)
      where
        isBoolean :: Var -> Bool
        isBoolean var = case IntMap.lookupLE var boolVarRanges of
          Nothing -> False
          Just (index, len) -> var < index + len

        go :: (GaloisField n, Integral n) => FoldState -> Var -> n -> FoldState
        go Start var coeff = case isPowerOf2 coeff of
          Nothing -> Failed
          Just (sign, power) -> Continue (IntMap.singleton power (sign, var))
        go Failed _ _ = Failed
        go (Continue coeffs) var coeff = case isPowerOf2 coeff of
          Nothing -> Failed
          Just (sign, power) ->
            let uniqueCoeff = IntMap.notMember power coeffs
             in if isBoolean var && uniqueCoeff
                  then Continue (IntMap.insert power (sign, var) coeffs)
                  else Failed
detectBinRep (Stuck polynomial) = return (Stuck polynomial)

-- | See if a coefficient is a power of 2
--   Note that, because these coefficients are field elements,
--    they can be powers of 2 when viewed as either "positive integers" or "negative integers"
isPowerOf2 :: (GaloisField n, Integral n) => n -> Maybe (Bool, Int)
isPowerOf2 (-2) = Just (False, 1)
isPowerOf2 (-1) = Just (False, 0)
isPowerOf2 1 = Just (True, 0)
isPowerOf2 2 = Just (True, 1)
isPowerOf2 coeff =
  let asInteger = toInteger coeff
   in if even asInteger
        then (True,) <$> check asInteger
        else (False,) <$> check (negate (fromIntegral (order coeff) - fromIntegral coeff))
  where
    -- Speed this up
    check :: Integer -> Maybe Int
    check n =
      let expected = floor (logBase 2 (fromInteger (abs n)) :: Double)
       in if abs n == 2 ^ expected
            then Just expected
            else Nothing

-- let (normalized, sign) = normalize coeff
--     expected = floor (logBase 2 (fromInteger (abs normalized)) :: Double)
--  in if abs normalized == 2 ^ expected
--       then Just (expected, sign)
--       else Nothing

-- if (x - y) = 0 then m = 0 else m = recip (x - y)
shrinkEqZero :: (GaloisField n, Integral n) => (Poly n, Var) -> M n (Result (Poly n, Var))
shrinkEqZero eqZero@(xs, m) = do
  bindings <- get
  case substAndView bindings xs of
    Constant 0 -> do
      bindVar m 0
      return Eliminated
    Constant c -> do
      bindVar m (recip c)
      return Eliminated
    Uninomial changed xs' _ _ ->
      -- only consider the polynomial shrinked if it's size has been reduced
      if changed
        then return $ Shrinked (xs', m)
        else return $ Stuck eqZero
    Polynomial changed xs' ->
      if changed
        then return $ Shrinked (xs', m)
        else return $ Stuck eqZero

--------------------------------------------------------------------------------

-- | Result of shrinking a constraint
data Result a = Shrinked a | Stuck a | Eliminated | NothingToDo
  deriving (Eq, Show)

instance Semigroup a => Semigroup (Result a) where
  NothingToDo <> x = x
  x <> NothingToDo = x
  Shrinked x <> Shrinked y = Shrinked (x <> y)
  Shrinked x <> Stuck y = Shrinked (x <> y)
  Shrinked x <> Eliminated = Shrinked x
  Stuck x <> Shrinked y = Shrinked (x <> y)
  Stuck x <> Stuck y = Stuck (x <> y)
  Stuck x <> Eliminated = Shrinked x
  Eliminated <> Shrinked x = Shrinked x
  Eliminated <> Stuck x = Shrinked x
  Eliminated <> Eliminated = Eliminated

instance Monoid a => Monoid (Result a) where
  mempty = NothingToDo

instance Functor Result where
  fmap f (Shrinked x) = Shrinked (f x)
  fmap f (Stuck x) = Stuck (f x)
  fmap _ Eliminated = Eliminated
  fmap _ NothingToDo = NothingToDo

shrinkedOrStuck :: [Bool] -> a -> Result a
shrinkedOrStuck changeds r1c = if or changeds then Shrinked r1c else Stuck r1c

-- | Substitute varaibles with values in a polynomial
substAndView :: (Num n, Eq n) => IntMap n -> Poly n -> PolyResult n
substAndView bindings xs = case Poly.substWithIntMap xs bindings of
  (Left constant, _) -> Constant constant -- reduced to a constant
  (Right poly, changed) ->
    let (constant, xs') = Poly.view poly
     in case IntMap.minViewWithKey xs' of
          Nothing -> Constant constant -- reduced to a constant
          Just ((var, coeff), xs'') ->
            if IntMap.null xs''
              then Uninomial changed poly constant (var, coeff)
              else Polynomial changed poly

-- | View of result after substituting a polynomial
data PolyResult n
  = Constant n
  | Uninomial Bool (Poly n) n (Var, n)
  | Polynomial Bool (Poly n)
  deriving (Show, Eq, Ord, Functor)
