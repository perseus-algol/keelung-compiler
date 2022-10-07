{-# LANGUAGE DataKinds #-}

module Array (fromString, fullAdder, multiplier) where

import qualified Array.Immutable as I
import Criterion
import Benchmark.Util
import Keelung (Comp, Arr, Boolean)

fromString :: Benchmark
fromString =
  bgroup
    "fromString"
    [ elaboration,
      compilation,
      constantPropagation,
      optimization1
    ]
  where
    program :: Int -> Comp (Arr (Arr Boolean))
    program n = return $ I.fromString (concat $ replicate (n * 100) "Hello world")

    elaboration :: Benchmark
    elaboration =
      bgroup
        "Elaboration"
        $ map (\i -> bench (show (i * 1000)) $ nf elaborate $ program i) [1, 2, 4, 8]

    compilation :: Benchmark
    compilation =
      bgroup
        "Compilation"
        $ map (\i -> bench (show (i * 1000)) $ nf compile $ program i) [1, 2, 4, 8]

    constantPropagation :: Benchmark
    constantPropagation =
      bgroup
        "Constant Propagation"
        $ map (\i -> bench (show (i * 1000)) $ nf optimize0 $ program i) [1, 2, 4, 8]

    optimization1 :: Benchmark
    optimization1 =
      bgroup
        "Optimization I"
        $ map (\i -> bench (show (i * 1000)) $ nf optimize1 $ program i) [1, 2, 4, 8]

fullAdder :: Benchmark
fullAdder =
  bgroup
    "fullAdder"
    [ elaboration,
      compilation,
      constantPropagation,
      optimization1
    ]
  where
    program :: Int -> Comp (Arr Boolean)
    program n = I.fullAdderT (n * 10)

    elaboration :: Benchmark
    elaboration =
      bgroup
        "Elaboration"
        $ map (\i -> bench (show (i * 10)) $ nf elaborate $ program i) [1, 2, 4, 8]

    compilation :: Benchmark
    compilation =
      bgroup
        "Compilation"
        $ map (\i -> bench (show (i * 10)) $ nf compile $ program i) [1, 2, 4, 8]

    constantPropagation :: Benchmark
    constantPropagation =
      bgroup
        "Constant Propagation"
        $ map (\i -> bench (show (i * 10)) $ nf optimize0 $ program i) [1, 2, 4, 8]

    optimization1 :: Benchmark
    optimization1 =
      bgroup
        "Optimization I"
        $ map (\i -> bench (show (i * 10)) $ nf optimize1 $ program i) [1, 2, 4, 8]

multiplier :: Benchmark
multiplier =
  bgroup
    "multiplier"
    [ elaboration,
      compilation,
      constantPropagation,
      optimization1
    ]
  where
    program :: Int -> Comp (Arr Boolean)
    program n = I.multiplierT n 4

    elaboration :: Benchmark
    elaboration =
      bgroup
        "Elaboration"
        $ map (\i -> bench (show i) $ nf elaborate $ program i) [1, 2, 4, 8]

    compilation :: Benchmark
    compilation =
      bgroup
        "Compilation"
        $ map (\i -> bench (show i) $ nf compile $ program i) [1, 2, 4, 8]

    constantPropagation :: Benchmark
    constantPropagation =
      bgroup
        "Constant Propagation"
        $ map (\i -> bench (show i) $ nf optimize0 $ program i) [1, 2, 4, 8]

    optimization1 :: Benchmark
    optimization1 =
      bgroup
        "Optimization I"
        $ map (\i -> bench (show i) $ nf optimize1 $ program i) [1, 2, 4, 8]

-- optimization3 :: Benchmark
-- optimization3 =
--   bgroup
--     "Optimization II"
--     $ map (\i -> bench (show (i * 1000)) $ nf optimize3 $ program i) [1, 2, 4, 8]
