{-# LANGUAGE DataKinds #-}

module Test.Compilation.UInt.ModInv (tests, run) where

import Control.Monad
import Keelung hiding (compile)
import Keelung.Data.U qualified as U
import Test.Compilation.Util
import Test.HUnit
import Test.Hspec
import Test.QuickCheck

run :: IO ()
run = hspec tests

--------------------------------------------------------------------------------

tests :: SpecWith ()
tests =
  describe "ModInv" $ do
    it "modInv 123 (mod 2833) on Word32" $ do
      let program = return $ modInv (123 :: UInt 32) 2833
      testCompiler gf181 program [] [] [2119]
      testCompiler (Prime 17) program [] [] [2119]

    it "modInv 123 (mod 2833) on Word12" $ do
      let program = return $ modInv (123 :: UInt 12) 2833
      testCompiler gf181 program [] [] [2119]
      testCompiler (Prime 17) program [] [] [2119]

    it "modInv 3 (mod 7) on Word4" $ do
      let program = return $ modInv (3 :: UInt 4) 7
      testCompiler gf181 program [] [] [5]
      testCompiler (Prime 17) program [] [] [5]

    it "modInv N (mod 2833)" $ do
      let prime = 2833
      let program = do
            x <- input Public :: Comp (UInt 32)
            return $ modInv x prime
      let genPair = do
            -- only choosing from 1 to prime - 1
            a <- choose (1, prime - 1)
            let expected = U.modInv a prime
            return (a, expected)
      forAll genPair $ \(a, result) -> do
        case result of
          Nothing -> assertFailure "[ panic ] modInv: cannot find the inverse"
          Just inverse -> do
            let expected = [fromInteger inverse]
            testCompiler gf181 program [a] [] expected

    it "modInv 345 (mod 7919)" $ do
      let program = return $ modInv (345 :: UInt 32) 7919
      testCompiler gf181 program [] [] [3466]
      testCompiler (Prime 17) program [] [] [3466]

    let genPair prime = do
          -- only choosing from 1 to prime - 1
          a <- choose (1, prime - 1)
          let expected = U.modInv a prime
          return (a, expected)

    -- too slow
    -- it "modInv N (mod 7919)" $ do
    --   let prime = 7919
    --   let program = do
    --         x <- input Public :: Comp (UInt 32)
    --         return $ modInv x prime
    --   forAll (genPair prime) $ \(a, result) -> do
    --     case result of
    --       Nothing -> assertFailure "[ panic ] modInv: cannot find the inverse"
    --       Just inverse -> do
    --         let expected = [fromInteger inverse]
    --         forM_ [gf181, Prime 17, Binary 7] $ \field -> do
    --           testCompiler field program [a] [] expected

    it "modInv N (mod 71)" $ do
      let prime = 71
      let program = do
            x <- input Public :: Comp (UInt 8)
            return $ modInv x prime
      forAll (genPair prime) $ \(a, result) -> do
        case result of
          Nothing -> assertFailure "[ panic ] modInv: cannot find the inverse"
          Just inverse -> do
            let expected = [fromInteger inverse]
            forM_ [gf181, Prime 17, Binary 7] $ \field -> do
              testCompiler field program [a] [] expected

    it "modInv N (mod 7)" $ do
      -- 6 * 6 = 7 * 5 + 1 (mod GF181)
      let prime = 7
      let program = do
            x <- input Public :: Comp (UInt 4)
            return $ modInv x prime
      forAll (genPair prime) $ \(a, result) -> do
        case result of
          Nothing -> assertFailure "[ panic ] modInv: cannot find the inverse"
          Just inverse -> do
            let expected = [fromInteger inverse]
            forM_ [gf181, Prime 17, Binary 7] $ \field -> do
              testCompiler field program [a] [] expected
