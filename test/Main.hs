{-# LANGUAGE DataKinds #-}

module Main where

import Test.Compilation qualified as Compilation
import Test.Data.IntervalSet qualified as Data.IntervalSet
import Test.Data.IntervalTable qualified as Data.IntervalTable
import Test.Data.LC qualified as Data.LC
import Test.Data.PolyRS qualified as Data.PolyL
import Test.Hspec (hspec)
import Test.Intergration qualified as Intergration
import Test.Optimization qualified as Optimization
import Test.Relations qualified as Relations
import Test.Solver qualified as Solver

main :: IO ()
main = hspec $ do
  Solver.tests
  Compilation.tests
  Optimization.tests
  Data.IntervalTable.tests
  Relations.tests
  Intergration.tests
  Data.LC.tests
  Data.PolyL.tests
  Data.IntervalSet.tests
