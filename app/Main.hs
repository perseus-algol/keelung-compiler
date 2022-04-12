{-# LANGUAGE DataKinds #-}

module Main where

import qualified AggregateSignature.Program.Keelung as Keelung
import qualified AggregateSignature.Program.Snarkl as Snarkl
import AggregateSignature.Util
import Control.Monad
import Control.Monad.Except
import qualified Data.Set as Set
import Keelung (GF181)
import qualified Keelung
import qualified Snarkl

main :: IO ()
main = do
  let parameters =
        [ (1, 1),
          (10, 1),
          (1, 10),
          (10, 10),
          (512, 1),
          (512, 2),
          (512, 4)
        ]

  forM_ parameters $ \(dimension, numOfSigs) -> do
    putStrLn $ show dimension ++ ":" ++ show numOfSigs
    -- snarklConstraints dimension numOfSigs
    keelungConstraints dimension numOfSigs

run :: ExceptT String IO () -> IO ()
run f = do
  res <- runExceptT f
  case res of
    Left err -> putStrLn err
    Right () -> return ()

-- for examing the number of constraints generated by Keelung
keelungConstraints :: Int -> Int -> IO ()
keelungConstraints dimension numOfSigs = run $ do
  let settings =
        Settings
          { enableAggSigChecking = True,
            enableSigSizeChecking = True,
            enableSigLengthChecking = True
          }
  let setup = makeSetup dimension numOfSigs 42 settings :: Setup GF181
  let input = genInputFromSetup setup

  checkAgg <-
    liftEither $
      Keelung.comp $
        Keelung.checkAgg $
          makeSetup dimension numOfSigs 42 (Settings True False False)
  let checkAgg' = Keelung.optimise checkAgg
  let checkAgg'' = snd $ Keelung.optimiseWithInput input checkAgg'

  checkSize <-
    liftEither $
      Keelung.comp $
        Keelung.checkSize $
          makeSetup dimension numOfSigs 42 (Settings False True False)
  let checkSize' = Keelung.optimise checkSize
  let checkSize'' = snd $ Keelung.optimiseWithInput input checkSize'

  checkLength <-
    liftEither $
      Keelung.comp $
        Keelung.checkLength $
          makeSetup dimension numOfSigs 42 (Settings False False True)
  let checkLength' = Keelung.optimise checkLength
  let checkLength'' = snd $ Keelung.optimiseWithInput input checkLength'

  aggSig <- liftEither $ Keelung.comp (Keelung.aggregateSignature setup)
  let aggSig' = Keelung.optimise aggSig
  let aggSig'' = snd $ Keelung.optimiseWithInput input aggSig'

  liftIO $ putStrLn "  Keelung: "
  liftIO $
    putStrLn $
      "    not optimised:      "
        ++ show (Set.size (Keelung.csConstraints aggSig))
        ++ " ( "
        ++ show (Set.size (Keelung.csConstraints checkAgg))
        ++ " / "
        ++ show (Set.size (Keelung.csConstraints checkSize))
        ++ " / "
        ++ show (Set.size (Keelung.csConstraints checkLength))
        ++ " )"
  liftIO $
    putStrLn $
      "    optimised:          "
        ++ show (Set.size (Keelung.csConstraints aggSig'))
        ++ " ( "
        ++ show (Set.size (Keelung.csConstraints checkAgg'))
        ++ " / "
        ++ show (Set.size (Keelung.csConstraints checkSize'))
        ++ " / "
        ++ show (Set.size (Keelung.csConstraints checkLength'))
        ++ " )"
  liftIO $
    putStrLn $
      "    patially evaluated: "
        ++ show (Set.size (Keelung.csConstraints aggSig''))
        ++ " ( "
        ++ show (Set.size (Keelung.csConstraints checkAgg''))
        ++ " / "
        ++ show (Set.size (Keelung.csConstraints checkSize''))
        ++ " / "
        ++ show (Set.size (Keelung.csConstraints checkLength''))
        ++ " )"

-- for examing the number of constraints generated by Snarkl
snarklConstraints :: Int -> Int -> IO ()
snarklConstraints dimension numOfSigs = run $ do
  do
    -- not optimised

    let count =
          show . Set.size . Snarkl.cs_constraints
            . Snarkl.compile
            . Snarkl.elaborate

    liftIO $ putStrLn "  Snarkl: "
    liftIO $
      putStrLn $
        "    not optimised: "
          ++ count checkAgg
          ++ " / "
          ++ count checkSize
          ++ " / "
          ++ count checkLength
          ++ " / "
          ++ count aggSig

  do
    -- optimised
    let count =
          show . Set.size . Snarkl.cs_constraints . snd
            . Snarkl.simplifyConstrantSystem False mempty
            . Snarkl.compile
            . Snarkl.elaborate

    liftIO $
      putStrLn $
        "    optimised: "
          ++ count checkAgg
          ++ " / "
          ++ count checkSize
          ++ " / "
          ++ count checkLength
          ++ " / "
          ++ count aggSig
  where
    checkAgg :: Snarkl.Comp 'Snarkl.TBool GF181
    checkAgg = Snarkl.checkAgg $ makeSetup dimension numOfSigs 42 $ Settings True False False

    checkSize :: Snarkl.Comp 'Snarkl.TBool GF181
    checkSize = Snarkl.checkSize $ makeSetup dimension numOfSigs 42 $ Settings False True False

    checkLength :: Snarkl.Comp 'Snarkl.TBool GF181
    checkLength = Snarkl.checkLength $ makeSetup dimension numOfSigs 42 $ Settings False False True

    aggSig :: Snarkl.Comp 'Snarkl.TBool GF181
    aggSig = Snarkl.aggregateSignature $ makeSetup dimension numOfSigs 42 $ Settings True True True

-- for examing the complexity of expression generated after elaboration
keelungElaborate :: IO ()
keelungElaborate = do
  forM_ [2 :: Int .. 7] $ \i -> do
    let dimension = 2 ^ i
    let numOfSigs = 4
    let setup = makeSetup dimension numOfSigs 42 settings :: Setup GF181

    let result = Keelung.elaborate (Keelung.aggregateSignature setup)
    case result of
      Left err -> print err
      Right elaborated -> do
        print
          ( Keelung.sizeOfExpr <$> Keelung.elabExpr elaborated,
            length (Keelung.compNumAsgns (Keelung.elabComp elaborated)),
            length (Keelung.compBoolAsgns (Keelung.elabComp elaborated)),
            Keelung.compNextVar (Keelung.elabComp elaborated)
          )
  where
    -- run (2 ^ i) 4

    settings :: Settings
    settings =
      Settings
        { enableAggSigChecking = True,
          enableSigSizeChecking = True,
          enableSigLengthChecking = True
        }