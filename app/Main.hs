{-# LANGUAGE DataKinds #-}

module Main where

import qualified AggregateSignature.Program as AggSig
import AggregateSignature.Util
import Control.Monad
import Control.Monad.Except

import qualified Data.ByteString.Char8 as BSC
import Data.Serialize (decode, encode)
import Keelung (elaborateAndFlatten)
import Keelung.Compiler
  ( ConstraintSystem,
    Error (..),
    comp,
    convElab,
    interpElab,
    numberOfConstraints,
    optimise,
    optimise2,
    optm,
    optmElab,
  )
import Keelung.Field
import Keelung.Syntax.Concrete
import Option
import Keelung.Constraint.R1CS (R1CS)
import Control.Arrow (left)

main :: IO ()
main = do
  options <- getOptions
  case options of
    Protocol ToCS -> do
      blob <- getContents
      let decoded = decode (BSC.pack blob) :: Either String (Either String Elaborated)
      case join decoded of
        Left err -> print err
        Right elaborated -> do
          case compFieldType (elabComp elaborated) of
            B64 -> print (optmElab elaborated :: Either (Error B64) (ConstraintSystem B64))
            GF181 -> print (optmElab elaborated :: Either (Error GF181) (ConstraintSystem GF181))
            BN128 -> print (optmElab elaborated :: Either (Error BN128) (ConstraintSystem BN128))
    Protocol ToR1CS -> do
      blob <- getContents
      let decoded = decode (BSC.pack blob) :: Either String (Either String Elaborated)
      case join decoded of
        Left err -> print err
        Right elaborated -> do
          case compFieldType (elabComp elaborated) of
            B64 -> putStrLn $ BSC.unpack $ encode (left show (convElab elaborated) :: Either String (R1CS B64))
            GF181 -> putStrLn $ BSC.unpack $ encode (left show (convElab elaborated) :: Either String (R1CS GF181))
            BN128 -> putStrLn $ BSC.unpack $ encode (left show (convElab elaborated) :: Either String (R1CS BN128))
    Protocol Interpret -> do
      blob <- getContents
      let decoded = decode (BSC.pack blob) :: Either String (Either String (Elaborated, [Integer]))
      case join decoded of
        Left err -> print err
        Right (elaborated, inputs) -> do
          case compFieldType (elabComp elaborated) of
            B64 -> putStrLn $ BSC.unpack $ encode (interpElab elaborated (map fromInteger inputs) :: Either String (Maybe B64))
            GF181 -> putStrLn $ BSC.unpack $ encode (interpElab elaborated (map fromInteger inputs) :: Either String (Maybe GF181))
            BN128 -> putStrLn $ BSC.unpack $ encode (interpElab elaborated (map fromInteger inputs) :: Either String (Maybe BN128))
    Profile dimension numOfSigs -> profile dimension numOfSigs
    Count dimension numOfSigs -> do
      putStrLn $ show dimension ++ ":" ++ show numOfSigs
      -- snarklConstraints dimension numOfSigs
      -- keelung dimension numOfSigs
      keelungConstraints dimension numOfSigs

run :: (Show n, Bounded n, Integral n, Fractional n) => ExceptT (Error n) IO () -> IO ()
run f = do
  res <- runExceptT f
  case res of
    Left err -> print err
    Right () -> return ()

--------------------------------------------------------------------------------

profile :: Int -> Int -> IO ()
profile dimension numOfSigs = run $ do
  let settings =
        Settings
          { enableAggChecking = True,
            enableSizeChecking = True,
            enableLengthChecking = True
          }
  let param = makeParam dimension numOfSigs 42 settings :: Param GF181

  -- compile & optimise
  -- erased <- liftEither $ erase (aggregateSignature setup)
  -- liftIO $ do
  --   print ("erasedExpr", Untyped.sizeOfExpr <$> erasedExpr erased)
  --   print ("erasedAssertions", length $ erasedAssertions erased, sum $ map Untyped.sizeOfExpr (erasedAssertions erased))
  --   print ("erasedAssignments", length $ erasedAssignments erased, sum $ map (\(Untyped.Assignment _ expr) -> Untyped.sizeOfExpr expr) (erasedAssignments erased))
  --   print ("erasedNumOfVars", erasedNumOfVars erased)
  --   print ("erasedInputVars size", IntSet.size $ erasedInputVars erased)
  --   print ("erasedBooleanVars size", IntSet.size $ erasedBooleanVars erased)

  -- print ("compNextVar", compNextVar computed)
  -- print ("compNextAddr", compNextAddr computed)
  -- print ("compInputVars", IntSet.size $ compInputVars computed)
  -- print ("compHeap", IntMap.size $ compHeap computed)
  -- print ("compNumAsgns", length $ compNumAsgns computed, sum $ map (\(Assignment _ expr) -> sizeOfExpr expr) (compNumAsgns computed))
  -- print ("compBoolAsgns", length $ compBoolAsgns computed, sum $ map (\(Assignment _ expr) -> sizeOfExpr expr) (compBoolAsgns computed))
  -- print ("compAssertions", length $ compAssertions computed, sum $ map sizeOfExpr (compAssertions computed))

  -- compile & optimise
  aggSig <- liftEither $ optm (AggSig.aggregateSignature param)
  liftIO $
    print (numberOfConstraints aggSig)

-- for examing the number of constraints generated by Keelung
keelungConstraints :: Int -> Int -> IO ()
keelungConstraints dimension numOfSigs = run $ do
  let settings =
        Settings
          { enableAggChecking = True,
            enableSizeChecking = True,
            enableLengthChecking = True
          }
  let param = makeParam dimension numOfSigs 42 settings :: Param GF181
  -- let input = genInputFromParam setup

  checkAgg <-
    liftEither $
      comp $
        AggSig.checkAgg $
          makeParam dimension numOfSigs 42 (Settings True False False)
  let checkAgg' = optimise2 $ optimise checkAgg :: ConstraintSystem GF181
  -- let checkAgg'' = snd $ optimiseWithInput input checkAgg'

  checkSize <-
    liftEither $
      comp $
        AggSig.checkSize $
          makeParam dimension numOfSigs 42 (Settings False True False)
  let checkSize' = optimise2 $ optimise checkSize :: ConstraintSystem GF181
  -- let checkSize'' = snd $ optimiseWithInput input checkSize'

  checkLength <-
    liftEither $
      comp $
        AggSig.checkLength $
          makeParam dimension numOfSigs 42 (Settings False False True)
  let checkLength' = optimise2 $ optimise checkLength :: ConstraintSystem GF181
  -- let checkLength'' = snd $ optimiseWithInput input checkLength'

  aggSig <- liftEither $ comp (AggSig.aggregateSignature param)
  let aggSig' = optimise2 $ optimise aggSig :: ConstraintSystem GF181
  -- let aggSig'' = snd $ optimiseWithInput input aggSig'

  liftIO $ putStrLn "  Keelung: "
  liftIO $
    putStrLn $
      "    not optimised:      "
        ++ show (numberOfConstraints aggSig)
        ++ " ( "
        ++ show (numberOfConstraints checkAgg)
        ++ " / "
        ++ show (numberOfConstraints checkSize)
        ++ " / "
        ++ show (numberOfConstraints checkLength)
        ++ " )"
  liftIO $
    putStrLn $
      "    optimised:          "
        ++ show (numberOfConstraints aggSig')
        ++ " ( "
        ++ show (numberOfConstraints checkAgg')
        ++ " / "
        ++ show (numberOfConstraints checkSize')
        ++ " / "
        ++ show (numberOfConstraints checkLength')
        ++ " )"

-- liftIO $
--   putStrLn $
--     "    patially evaluated: "
--       ++ show (numberOfConstraints aggSig''))
--       ++ " ( "
--       ++ show (numberOfConstraints checkAgg''))
--       ++ " / "
--       ++ show (numberOfConstraints checkSize''))
--       ++ " / "
--       ++ show (numberOfConstraints checkLength''))
--       ++ " )"

-- for examing the number of constraints generated by Snarkl
-- snarklConstraints :: Int -> Int -> IO ()
-- snarklConstraints dimension numOfSigs = run $ do
--   do
--     -- not optimised

--     let count =
--           show . Set.size . Snarkl.cs_constraints
--             . Snarkl.compile
--             . Snarkl.elaborate

--     liftIO $ putStrLn "  Snarkl: "
--     liftIO $
--       putStrLn $
--         "    not optimised: "
--           ++ count checkAgg
--           ++ " / "
--           ++ count checkSize
--           ++ " / "
--           ++ count checkLength
--           ++ " / "
--           ++ count aggSig

--   do
--     -- optimised
--     let count =
--           show . Set.size . Snarkl.cs_constraints . snd
--             . Snarkl.simplifyConstrantSystem False mempty
--             . Snarkl.compile
--             . Snarkl.elaborate

--     liftIO $
--       putStrLn $
--         "    optimised: "
--           ++ count checkAgg
--           ++ " / "
--           ++ count checkSize
--           ++ " / "
--           ++ count checkLength
--           ++ " / "
--           ++ count aggSig
--   where
--     checkAgg :: Snarkl.Comp 'Snarkl.TBool GF181
--     checkAgg = Snarkl.checkAgg $ makeParam dimension numOfSigs 42 $ Settings True False False

--     checkSize :: Snarkl.Comp 'Snarkl.TBool GF181
--     checkSize = Snarkl.checkSize $ makeParam dimension numOfSigs 42 $ Settings False True False

--     checkLength :: Snarkl.Comp 'Snarkl.TBool GF181
--     checkLength = Snarkl.checkLength $ makeParam dimension numOfSigs 42 $ Settings False False True

--     aggSig :: Snarkl.Comp 'Snarkl.TBool GF181
--     aggSig = Snarkl.aggregateSignature $ makeParam dimension numOfSigs 42 $ Settings True True True

-- for examing the complexity of expression generated after elaboration
keelungElaborate :: IO ()
keelungElaborate = do
  forM_ [2 :: Int .. 7] $ \i -> do
    let dimension = 2 ^ i
    let numOfSigs = 4
    let param = makeParam dimension numOfSigs 42 settings :: Param GF181

    let result = elaborateAndFlatten (AggSig.aggregateSignature param)
    case result of
      Left err -> print err
      Right elaborated -> do
        print
          ( sizeOfExpr (elabExpr elaborated),
            length (compNumAsgns (elabComp elaborated)),
            length (compBoolAsgns (elabComp elaborated)),
            compNextVar (elabComp elaborated)
          )
  where
    -- run (2 ^ i) 4

    settings :: Settings
    settings =
      Settings
        { enableAggChecking = True,
          enableSizeChecking = True,
          enableLengthChecking = True
        }