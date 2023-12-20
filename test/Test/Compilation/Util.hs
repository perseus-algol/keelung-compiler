{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Test.Compilation.Util
  ( -- for printing results for debugging
    debugWithOpts,
    debug,
    debugO0,
    testCompilerWithOpts,
    testCompiler,
    runSolver,
    runSolverO0,
    throwR1CS,
    throwBoth,
    assertSize,
    gf181Info,
  )
where

import Control.Arrow (left)
import Data.Field.Galois
import Data.Foldable (toList)
import Data.Proxy (Proxy (..))
import GHC.TypeLits
import Keelung hiding (Elaborated, compile)
import Keelung.Compiler (Error (..), toR1CS)
import Keelung.Compiler qualified as Compiler
import Keelung.Compiler.ConstraintModule (ConstraintModule)
import Keelung.Compiler.ConstraintSystem qualified as CS
import Keelung.Compiler.Options
import Keelung.Compiler.Syntax.Inputs qualified as Inputs
import Keelung.Compiler.Util (gf181Info)
import Keelung.Constraint.R1CS (R1CS (..))
import Keelung.Data.FieldInfo
import Keelung.Interpreter qualified as Interpreter
import Keelung.Solver qualified as Solver
import Keelung.Syntax.Encode.Syntax qualified as Encoded
import Test.Hspec

--------------------------------------------------------------------------------

-- | syntax tree interpreter
interpretSyntaxTree :: (GaloisField n, Integral n, Encode t) => FieldInfo -> Comp t -> [Integer] -> [Integer] -> Either (Error n) [Integer]
interpretSyntaxTree fieldInfo prog rawPublicInputs rawPrivateInputs = do
  elab <- left LangError (elaborateAndEncode prog)
  inputs <- left InputError (Inputs.deserialize (Encoded.compCounters (Encoded.elabComp elab)) rawPublicInputs rawPrivateInputs)
  left InterpreterError (Interpreter.run fieldInfo elab inputs)

-- | R1CS witness solver (on optimized R1CS)
solveR1CSWithOpts :: (GaloisField n, Integral n, Encode t) => Options -> Comp t -> [Integer] -> [Integer] -> Either (Error n) [Integer]
solveR1CSWithOpts options prog rawPublicInputs rawPrivateInputs = do
  r1cs <- toR1CS <$> Compiler.compileAndLinkWithOpts options prog
  inputs <- left InputError (Inputs.deserialize (r1csCounters r1cs) rawPublicInputs rawPrivateInputs)
  case Solver.run options r1cs inputs of
    Left err -> Left (SolverError err)
    Right (outputs, _) -> Right (toList $ Inputs.deserializeBinReps (r1csCounters r1cs) outputs)

solveR1CS :: (GaloisField n, Integral n, Encode t) => FieldInfo -> Comp t -> [Integer] -> [Integer] -> Either (Error n) [Integer]
solveR1CS fieldInfo = solveR1CSWithOpts (defaultOptions {optFieldInfo = fieldInfo})

-- | Generate R1CS witness solver report (on optimized R1CS)
solveR1CSCollectLog :: (GaloisField n, Integral n, Encode t) => FieldInfo -> Comp t -> [Integer] -> [Integer] -> (Maybe (Error n), Maybe (Solver.LogReport n))
solveR1CSCollectLog fieldInfo prog rawPublicInputs rawPrivateInputs = case do
  r1cs <- toR1CS <$> Compiler.compileAndLinkO1 fieldInfo prog
  inputs <- left InputError (Inputs.deserialize (r1csCounters r1cs) rawPublicInputs rawPrivateInputs)
  return (r1cs, inputs) of
  Left err -> (Just err, Nothing)
  Right (r1cs, inputs) -> case Solver.debug r1cs inputs of
    (Left err, logs) -> (Just (SolverError err), logs)
    (Right _, logs) -> (Nothing, logs)

-- | R1CS witness solver (on unoptimized R1CS)
solveR1CSO0 :: (GaloisField n, Integral n, Encode t) => FieldInfo -> Comp t -> [Integer] -> [Integer] -> Either (Error n) [Integer]
solveR1CSO0 fieldInfo = solveR1CSWithOpts (defaultOptions {optFieldInfo = fieldInfo, optOptimize = False})

-- | Generate R1CS witness solver report (on unoptimized R1CS)
solveR1CSCollectLogO0 :: (GaloisField n, Integral n, Encode t) => FieldInfo -> Comp t -> [Integer] -> [Integer] -> (Maybe (Error n), Maybe (Solver.LogReport n))
solveR1CSCollectLogO0 fieldInfo prog rawPublicInputs rawPrivateInputs = case do
  r1cs <- toR1CS <$> Compiler.compileAndLinkO0 fieldInfo prog
  inputs <- left InputError (Inputs.deserialize (r1csCounters r1cs) rawPublicInputs rawPrivateInputs)
  return (r1cs, inputs) of
  Left err -> (Just err, Nothing)
  Right (r1cs, inputs) -> case Solver.debug r1cs inputs of
    (Left err, logs) -> (Just (SolverError err), logs)
    (Right _, logs) -> (Nothing, logs)

--------------------------------------------------------------------------------

-- | Print the copmiled constraint module and R1CS
debugWithOpts :: (Encode t) => Options -> FieldType -> Comp t -> IO ()
debugWithOpts options fieldType program = caseFieldType fieldType handlePrime handleBinary
  where
    handlePrime (_ :: Proxy (Prime n)) fieldInfo = do
      let options' = options {optFieldInfo = fieldInfo}
      print (Compiler.compileWithOpts options' program :: Either (Error (N (Prime n))) (ConstraintModule (N (Prime n))))
      print (toR1CS <$> Compiler.compileAndLinkWithOpts options' program :: Either (Error (N (Prime n))) (R1CS (N (Prime n))))
    handleBinary (_ :: Proxy (Binary n)) fieldInfo = do
      let options' = options {optFieldInfo = fieldInfo}
      print (Compiler.compileWithOpts options' program :: Either (Error (N (Binary n))) (ConstraintModule (N (Binary n))))
      print (toR1CS <$> Compiler.compileAndLinkWithOpts options' program :: Either (Error (N (Binary n))) (R1CS (N (Binary n))))

debug :: (Encode t) => FieldType -> Comp t -> IO ()
debug = debugWithOpts defaultOptions

debugO0 :: (Encode t) => FieldType -> Comp t -> IO ()
debugO0 = debugWithOpts (defaultOptions {optOptimize = False})

-- | Use the interpreter to check the result of compilation + witness generation
testCompilerWithOpts :: (Encode t) => Options -> FieldType -> Comp t -> [Integer] -> [Integer] -> [Integer] -> IO ()
testCompilerWithOpts options fieldType program rawPublicInputs rawPrivateInputs expected = caseFieldType fieldType handlePrime handleBinary
  where
    handlePrime :: (KnownNat n) => Proxy (Prime n) -> FieldInfo -> IO ()
    handlePrime (_ :: Proxy (Prime n)) fieldInfo = do
      -- overwrite fieldInfo & optimization level
      let optionsO1 = options {optFieldInfo = fieldInfo, optOptimize = True}
      interpretSyntaxTree fieldInfo program rawPublicInputs rawPrivateInputs `shouldBe` (Right expected :: Either (Error (Prime n)) [Integer])
      -- constraint system interpreters
      solveR1CSWithOpts optionsO1 program rawPublicInputs rawPrivateInputs
        `shouldBe` (Right expected :: Either (Error (Prime n)) [Integer])
    -- solveR1CSO0 fieldInfo program rawPublicInputs rawPrivateInputs
    --   `shouldBe` (Right expected :: Either (Error (Prime n)) [Integer])

    handleBinary :: (KnownNat n) => Proxy (Binary n) -> FieldInfo -> IO ()
    handleBinary (_ :: Proxy (Binary n)) fieldInfo = do
      -- overwrite fieldInfo & optimization level
      let optionsO0 = options {optFieldInfo = fieldInfo, optOptimize = False}
      let optionsO1 = options {optFieldInfo = fieldInfo, optOptimize = True}
      interpretSyntaxTree fieldInfo program rawPublicInputs rawPrivateInputs `shouldBe` (Right expected :: Either (Error (Binary n)) [Integer])
      -- constraint system interpreters
      solveR1CSWithOpts optionsO1 program rawPublicInputs rawPrivateInputs
        `shouldBe` (Right expected :: Either (Error (Binary n)) [Integer])
      solveR1CSWithOpts optionsO0 program rawPublicInputs rawPrivateInputs
        `shouldBe` (Right expected :: Either (Error (Binary n)) [Integer])

testCompiler :: (Encode t) => FieldType -> Comp t -> [Integer] -> [Integer] -> [Integer] -> IO ()
testCompiler = testCompilerWithOpts defaultOptions

runSolver :: (Encode t) => FieldType -> Comp t -> [Integer] -> [Integer] -> IO ()
runSolver fieldType program rawPublicInputs rawPrivateInputs = caseFieldType fieldType handlePrime handleBinary
  where
    handlePrime :: (KnownNat n) => Proxy (Prime n) -> FieldInfo -> IO ()
    handlePrime (_ :: Proxy (Prime n)) fieldInfo = do
      let (err, logs) = solveR1CSCollectLog fieldInfo program rawPublicInputs rawPrivateInputs :: (Maybe (Error (Prime n)), Maybe (Solver.LogReport (Prime n)))
      mapM_ print err
      mapM_ print logs

    handleBinary :: (KnownNat n) => Proxy (Binary n) -> FieldInfo -> IO ()
    handleBinary (_ :: Proxy (Binary n)) fieldInfo = do
      let (err, logs) = solveR1CSCollectLog fieldInfo program rawPublicInputs rawPrivateInputs :: (Maybe (Error (Binary n)), Maybe (Solver.LogReport (Binary n)))
      mapM_ print err
      mapM_ print logs

runSolverO0 :: (Encode t) => FieldType -> Comp t -> [Integer] -> [Integer] -> IO ()
runSolverO0 fieldType program rawPublicInputs rawPrivateInputs = caseFieldType fieldType handlePrime handleBinary
  where
    handlePrime :: (KnownNat n) => Proxy (Prime n) -> FieldInfo -> IO ()
    handlePrime (_ :: Proxy (Prime n)) fieldInfo = do
      let (err, logs) = solveR1CSCollectLogO0 fieldInfo program rawPublicInputs rawPrivateInputs :: (Maybe (Error (Prime n)), Maybe (Solver.LogReport (Prime n)))
      mapM_ print err
      mapM_ print logs

    handleBinary :: (KnownNat n) => Proxy (Binary n) -> FieldInfo -> IO ()
    handleBinary (_ :: Proxy (Binary n)) fieldInfo = do
      let (err, logs) = solveR1CSCollectLogO0 fieldInfo program rawPublicInputs rawPrivateInputs :: (Maybe (Error (Binary n)), Maybe (Solver.LogReport (Binary n)))
      mapM_ print err
      mapM_ print logs

--------------------------------------------------------------------------

-- | Utilities for testing

-- | Expect R1CS interpreters to throw an error
throwR1CS :: (GaloisField n, Integral n, Encode t, Show t) => FieldType -> Comp t -> [Integer] -> [Integer] -> Error n -> IO ()
throwR1CS fieldType program rawPublicInputs rawPrivateInputs csError = caseFieldType fieldType handlePrime handleBinary
  where
    handlePrime :: (KnownNat n) => Proxy (Prime n) -> FieldInfo -> IO ()
    handlePrime (_ :: Proxy (Prime n)) fieldInfo = do
      -- syntax tree interpreters
      -- interpretSyntaxTree fieldInfo program rawPublicInputs rawPrivateInputs
      --   `shouldBe` Left (InterpreterError stError)
      -- constraint system interpreters
      solveR1CS fieldInfo program rawPublicInputs rawPrivateInputs
        `shouldBe` Left csError
      solveR1CSO0 fieldInfo program rawPublicInputs rawPrivateInputs
        `shouldBe` Left csError

    handleBinary :: (KnownNat n) => Proxy (Binary n) -> FieldInfo -> IO ()
    handleBinary (_ :: Proxy (Binary n)) fieldInfo = do
      -- constraint system interpreters
      -- interpretSyntaxTree fieldInfo program rawPublicInputs rawPrivateInputs
      --   `shouldBe` Left (InterpreterError stError)
      -- constraint system interpreters
      solveR1CS fieldInfo program rawPublicInputs rawPrivateInputs
        `shouldBe` Left csError
      solveR1CSO0 fieldInfo program rawPublicInputs rawPrivateInputs
        `shouldBe` Left csError

throwBoth :: (GaloisField n, Integral n, Encode t, Show t) => FieldType -> Comp t -> [Integer] -> [Integer] -> Error n -> Error n -> IO ()
throwBoth fieldType program rawPublicInputs rawPrivateInputs stError csError = caseFieldType fieldType handlePrime handleBinary
  where
    handlePrime :: (KnownNat n) => Proxy (Prime n) -> FieldInfo -> IO ()
    handlePrime (_ :: Proxy (Prime n)) fieldInfo = do
      -- syntax tree interpreters
      interpretSyntaxTree fieldInfo program rawPublicInputs rawPrivateInputs
        `shouldBe` Left stError
      -- constraint system interpreters
      solveR1CS fieldInfo program rawPublicInputs rawPrivateInputs
        `shouldBe` Left csError
      solveR1CSO0 fieldInfo program rawPublicInputs rawPrivateInputs
        `shouldBe` Left csError

    handleBinary :: (KnownNat n) => Proxy (Binary n) -> FieldInfo -> IO ()
    handleBinary (_ :: Proxy (Binary n)) fieldInfo = do
      -- constraint system interpreters
      interpretSyntaxTree fieldInfo program rawPublicInputs rawPrivateInputs
        `shouldBe` Left stError
      -- constraint system interpreters
      solveR1CS fieldInfo program rawPublicInputs rawPrivateInputs
        `shouldBe` Left csError
      solveR1CSO0 fieldInfo program rawPublicInputs rawPrivateInputs
        `shouldBe` Left csError

assertSize :: (Encode t) => Int -> Comp t -> IO ()
assertSize afterSize program = do
  case Compiler.asGF181N (Compiler.compileAndLinkO1 gf181Info program) of
    Left err -> print err
    Right cs -> do
      CS.numberOfConstraints cs `shouldBe` afterSize
