{-# LANGUAGE DataKinds #-}

module Test.Data.IntervalSet (tests, run) where

import Control.Monad (foldM, forM_)
import Keelung.Data.IntervalSet (IntervalSet)
import Keelung.Data.IntervalSet qualified as IntervalSet
import Keelung.Data.IntervalTable qualified as IntervalTable
import Test.Hspec
import Test.QuickCheck

run :: IO ()
run = hspec tests

tests :: SpecWith ()
tests = describe "Interval Sets" $ do
  describe "IntervalSet.adjust" $ do
    it "should preserve invariants after applying randomized adjustments" $ do
      property $ \operations -> do
        let intervals = foldr applyOperation IntervalSet.new operations
        IntervalSet.totalCount intervals `shouldBe` sum (map countOfOperation operations)
        IntervalSet.isValid intervals `shouldBe` True

  describe "IntervalSet.toIntervalTable" $ do
    it "should generate well-behaved IntervalTable" $ do
      property $ \(NonOverlappingOperations operations points) -> do
        let intervals = foldr applyOperation IntervalSet.new operations
        let table = IntervalSet.toIntervalTable 200 intervals
        IntervalTable.size table `shouldBe` sum (map sizeOfOperation operations)
        forM_ points $ \point -> do
          IntervalTable.member (point, point + 1) table `shouldBe` memberOfNonOverlappingOperations (NonOverlappingOperations operations points) point

  -- describe "IntervalSet.intervalsWithin" $ do
  --   it "should result in correct intervals" $ do
  --     property $ \(operations, Interval interval) -> do
  --       let xs = foldr applyOperation IntervalSet.new (operations :: [Operation])
  --       let intervals = IntervalSet.intervalsWithin xs interval
  --       let withinIntervals x = any (\(start, end) -> x >= start && x < end) intervals
  --       let (left, rest) = IntervalSet.split xs (fst interval)
  --       let (middle, right) = IntervalSet.split rest (snd interval)
  --       putStrLn ""
  --       putStrLn $ "interval: " <> show interval
  --       putStrLn $ "set:      " <> show xs
  --       putStrLn $ "left:     " <> show left
  --       putStrLn $ "middle    " <> show middle
  --       putStrLn $ "right:    " <> show right
  --       putStrLn $ "result:   " <> show intervals
  --       -- all points within the computed intervals should be members of the interval set
  --       forM_ [fst interval .. snd interval - 1] $ \point -> do
  --         let expected = IntervalSet.member xs point
  --         let actual = withinIntervals point
  --         putStrLn $ "  at       @" <> show point
  --         putStrLn $ "  expected  " <> show expected
  --         putStrLn $ "  actual    " <> show actual
  --         expected `shouldBe` actual

--------------------------------------------------------------------------------

newtype Interval = Interval (Int, Int) deriving (Eq, Show)

instance Arbitrary Interval where
  arbitrary = do
    start <- chooseInt (0, 100)
    len <- chooseInt (0, 5)
    pure $ Interval (start, start + len)

--------------------------------------------------------------------------------

-- | Datatype for testing operations on interval sets
data Operation = Adjust (Int, Int) Int deriving (Eq, Show)

-- | Generate a random operation
instance Arbitrary Operation where
  arbitrary = do
    Interval interval <- arbitrary
    amount <- chooseInt (-100, 100)
    pure $ Adjust interval amount

-- | Apply an operation to an interval set
applyOperation :: Operation -> IntervalSet -> IntervalSet
applyOperation (Adjust interval amount) = IntervalSet.adjust interval amount

-- | Calculate the total count of an operation
countOfOperation :: Operation -> Int
countOfOperation (Adjust (start, end) amount) = amount * (end - start)

-- | Calculate the total size of an operation
sizeOfOperation :: Operation -> Int
sizeOfOperation (Adjust (start, end) amount) = if amount == 0 then 0 else end - start

--------------------------------------------------------------------------------

-- | Datatype for testing operations on non-overlapping interval sets
data NonOverlappingOperations = NonOverlappingOperations [Operation] [Int] deriving (Eq, Show)

-- | Generate a random operation
instance Arbitrary NonOverlappingOperations where
  arbitrary = do
    numberOfEntries <- chooseInt (0, 20)
    entries <-
      fst
        <$> foldM
          ( \(acc, prevEnd) _ -> do
              gap <- chooseInt (0, 4)
              let start = prevEnd + gap
              x@(Adjust (_, end) _) <- genOperation start
              return (x : acc, end)
          )
          ([], 0)
          [1 .. numberOfEntries]

    points <- listOf $ chooseInt (0, 100)

    return $ NonOverlappingOperations entries points
    where
      genOperation start = do
        len <- chooseInt (0, 10)
        let end = start + len
        amount <- chooseInt (0, 10)
        pure (Adjust (start, end) amount)

memberOfNonOverlappingOperations :: NonOverlappingOperations -> Int -> Bool
memberOfNonOverlappingOperations (NonOverlappingOperations operations _) point =
  any (\(Adjust (start, end) amount) -> amount /= 0 && start <= point && point < end) operations