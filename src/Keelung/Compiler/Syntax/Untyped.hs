{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE GADTs #-}

module Keelung.Compiler.Syntax.Untyped
  ( Op (..),
    BitWidth (..),
    Width,
    bitWidthOf,
    getWidth,
    castToNumber,
    BinaryOp (..),
    Expr (..),
    TypeErased (..),
    Assignment (..),
    Bindings (..),
    insertN,
    insertB,
    insertU,
    lookupN,
    lookupB,
    lookupU,
    Relations (..),
    sizeOfExpr,
  )
where

import Data.Field.Galois (GaloisField)
import Data.IntMap (IntMap)
import qualified Data.IntMap.Strict as IntMap
import Data.Sequence (Seq (..))
import Keelung.Field (N (..))
import Keelung.Syntax.BinRep (BinReps)
import qualified Keelung.Syntax.BinRep as BinRep
import Keelung.Syntax.VarCounters
import Keelung.Types (Var)

--------------------------------------------------------------------------------

-- N-ary operators
data Op
  = Add
  | Mul
  | And
  | Or
  | Xor
  | NEq
  | Eq
  | BEq
  deriving (Eq, Show)

-- Binary operators
data BinaryOp = Sub | Div
  deriving (Eq, Show)

--------------------------------------------------------------------------------

type Width = Int

data BitWidth
  = BWNumber Width
  | BWBoolean
  | BWUInt Width
  | BWUnit
  | BWArray BitWidth Int
  deriving (Eq, Ord, Show)

getWidth :: BitWidth -> Width
getWidth (BWNumber n) = n
getWidth BWBoolean = 1
getWidth (BWUInt n) = n
getWidth BWUnit = 0
getWidth (BWArray ns n) = n * getWidth ns

-- | "Untyped" expression
data Expr n
  = -- values
    Number Width n
  | UInt Width n
  | Boolean n
  | -- variables

    -- | Array (Vector (Expr n))
    Var BitWidth Var
  | UVar Width Var
  | Rotate BitWidth Int (Expr n)
  | -- Binary operators with only 2 operands
    BinaryOp BitWidth BinaryOp (Expr n) (Expr n)
  | -- N-Ary operators with >= 2 operands
    NAryOp BitWidth Op (Expr n) (Expr n) (Seq (Expr n))
  | If BitWidth (Expr n) (Expr n) (Expr n)
  deriving (Functor)

instance Num n => Num (Expr n) where
  x + y = NAryOp (bitWidthOf x) Add x y Empty
  x - y = BinaryOp (bitWidthOf x) Sub x y
  x * y = NAryOp (bitWidthOf x) Mul x y Empty
  abs = id
  signum = const 1
  fromInteger = error "[ panic ] Dunno how to convert an Integer to a untyped expression"

instance Show n => Show (Expr n) where
  showsPrec prec expr =
    let chain :: Show n => String -> Int -> Seq (Expr n) -> String -> String
        chain delim n = showParen (prec > n) . go delim n
        go :: Show n => String -> Int -> Seq (Expr n) -> String -> String
        go _ _ Empty = showString ""
        go _ n (x :<| Empty) = showsPrec (succ n) x
        go delim n (x :<| xs') = showsPrec (succ n) x . showString delim . go delim n xs'
     in case expr of
          Number _ val -> shows val
          Boolean val -> shows val
          UInt _ val -> shows val
          Var _ var -> showString "$" . shows var
          UVar _ var -> showString "$" . shows var
          Rotate _ n x -> showString "ROTATE " . shows n . showString " " . showsPrec 11 x
          NAryOp _ op x0 x1 xs -> case op of
            Add -> chain " + " 6 $ x0 :<| x1 :<| xs
            Mul -> chain " * " 7 $ x0 :<| x1 :<| xs
            And -> chain " ∧ " 3 $ x0 :<| x1 :<| xs
            Or -> chain " ∨ " 2 $ x0 :<| x1 :<| xs
            Xor -> chain " ⊕ " 4 $ x0 :<| x1 :<| xs
            NEq -> chain " != " 5 $ x0 :<| x1 :<| xs
            Eq -> chain " == " 5 $ x0 :<| x1 :<| xs
            BEq -> chain " == " 5 $ x0 :<| x1 :<| xs
          BinaryOp _ op x0 x1 -> case op of
            Sub -> chain " - " 6 $ x0 :<| x1 :<| Empty
            Div -> chain " / " 7 $ x0 :<| x1 :<| Empty
          If _ p x y -> showParen (prec > 1) $ showString "if " . showsPrec 2 p . showString " then " . showsPrec 2 x . showString " else " . showsPrec 2 y

-- | Calculate the "size" of an expression for benchmarking
sizeOfExpr :: Expr n -> Int
sizeOfExpr expr = case expr of
  Number _ _ -> 1
  UInt _ _ -> 1
  Boolean _ -> 1
  Var _ _ -> 1
  UVar _ _ -> 1
  Rotate _ _ x -> 1 + sizeOfExpr x
  NAryOp _ _ x0 x1 xs ->
    let operands = x0 :<| x1 :<| xs
     in sum (fmap sizeOfExpr operands) + (length operands - 1)
  BinaryOp _ _ x0 x1 -> sizeOfExpr x0 + sizeOfExpr x1 + 1
  If _ x y z -> 1 + sizeOfExpr x + sizeOfExpr y + sizeOfExpr z

bitWidthOf :: Expr n -> BitWidth
bitWidthOf expr = case expr of
  Number w _ -> BWNumber w
  UInt w _ -> BWUInt w
  Boolean _ -> BWBoolean
  Var bw _ -> bw
  UVar w _ -> BWUInt w
  Rotate bw _ _ -> bw
  NAryOp bw _ _ _ _ -> bw
  BinaryOp bw _ _ _ -> bw
  If bw _ _ _ -> bw

castToNumber :: Width -> Expr n -> Expr n
castToNumber width expr = case expr of
  Number _ _ -> expr
  UInt _ n -> Number width n
  Boolean n -> Number width n
  -- Arravy xs 
  Var _ n -> Var (BWNumber width) n
  UVar _ n -> Var (BWNumber width) n
  Rotate _ n x -> Rotate (BWNumber width) n x
  BinaryOp _ op a b -> BinaryOp (BWNumber width) op a b
  NAryOp _ op a b c -> NAryOp (BWNumber width) op a b c
  If _ p a b -> If (BWNumber width) p a b

--------------------------------------------------------------------------------

data Assignment n = Assignment Var (Expr n)

instance Show n => Show (Assignment n) where
  show (Assignment var expr) = "$" <> show var <> " := " <> show expr

instance Functor Assignment where
  fmap f (Assignment var expr) = Assignment var (fmap f expr)

--------------------------------------------------------------------------------

-- | The result after type erasure
data TypeErased n = TypeErased
  { -- | The expression after type erasure
    erasedExpr :: ![Expr n],
    -- | Variable bookkeepung
    erasedVarCounters :: !VarCounters,
    -- | Relations between variables and/or expressions
    erasedRelations :: !(Relations n),
    -- | Assertions after type erasure
    erasedAssertions :: ![Expr n],
    -- | Assignments after type erasure
    erasedAssignments :: ![Assignment n],
    -- | Binary representation of Number inputs
    erasedBinReps :: BinReps,
    -- | Binary representation of custom inputs
    erasedCustomBinReps :: BinReps
  }

instance (GaloisField n, Integral n) => Show (TypeErased n) where
  show (TypeErased expr counters relations assertions assignments numBinReps customBinReps) =
    "TypeErased {\n"
      -- expressions
      <> " . expression: "
      <> show (fmap (fmap N) expr)
      <> "\n"
      -- relations
      <> show relations
      <> ( if length assignments < 20
             then "  assignments:\n    " <> show (map (fmap N) assignments) <> "\n"
             else ""
         )
      <> ( if length assertions < 20
             then "  assertions:\n    " <> show assertions <> "\n"
             else ""
         )
      <> indent (show counters)
      <> "  Boolean variables: $"
      <> show (fst (boolVarsRange counters))
      <> " .. $"
      <> show (snd (boolVarsRange counters) - 1)
      <> "\n"
      <> showBinRepConstraints
      <> "\n\
         \}"
    where
      totalBinRepConstraintSize = numInputVarSize counters + totalCustomInputSize counters
      showBinRepConstraints =
        if totalBinRepConstraintSize == 0
          then ""
          else
            "  Binary representation constriants (" <> show totalBinRepConstraintSize <> "):\n"
              <> unlines
                ( map
                    (("    " <>) . show)
                    (BinRep.toList (numBinReps <> customBinReps))
                )

--------------------------------------------------------------------------------

-- | Container for holding something for each datatypes
data Bindings n = Bindings
  { bindingsN :: IntMap n, -- Field elements
    bindingsB :: IntMap n, -- Booleans
    bindingsUs :: IntMap (IntMap n) -- Unsigned integers of different bitwidths
  }
  deriving (Eq, Functor)

instance Semigroup (Bindings n) where
  Bindings n0 b0 u0 <> Bindings n1 b1 u1 =
    Bindings (n0 <> n1) (b0 <> b1) (IntMap.unionWith (<>) u0 u1)

instance Monoid (Bindings n) where
  mempty = Bindings mempty mempty mempty

instance Show n => Show (Bindings n) where
  show (Bindings ns bs us) =
    "  Field elements: "
      <> unlines (map (("    " <>) . show) (IntMap.toList ns))
      <> "\n"
      <> "  Booleans: "
      <> unlines (map (("    " <>) . show) (IntMap.toList bs))
      <> "\n"
      <> "  Unsigned integers: "
      <> unlines
        ( map
            (("    " <>) . show)
            (concat $ IntMap.elems (fmap IntMap.toList us))
        )
      <> "\n"

instance Foldable Bindings where
  foldMap f (Bindings ns bs us) =
    foldMap f ns <> foldMap f bs <> foldMap (foldMap f) us

instance Traversable Bindings where
  traverse f (Bindings ns bs us) =
    Bindings <$> traverse f ns <*> traverse f bs <*> traverse (traverse f) us

insertN :: Var -> n -> Bindings n -> Bindings n
insertN var val (Bindings ns bs us) = Bindings (IntMap.insert var val ns) bs us

insertB :: Var -> n -> Bindings n -> Bindings n
insertB var val (Bindings ns bs us) = Bindings ns (IntMap.insert var val bs) us

insertU :: Var -> Width -> n -> Bindings n -> Bindings n
insertU var width val (Bindings ns bs us) = Bindings ns bs (IntMap.insertWith (<>) width (IntMap.singleton var val) us)

lookupN :: Var -> Bindings n -> Maybe n
lookupN var (Bindings ns _ _) = IntMap.lookup var ns

lookupB :: Var -> Bindings n -> Maybe n
lookupB var (Bindings _ bs _) = IntMap.lookup var bs

lookupU :: Width -> Var -> Bindings n -> Maybe n
lookupU width var (Bindings _ _ us) = IntMap.lookup width us >>= IntMap.lookup var

-- data Mixed n = MixedN Var n | MixedB Var n | MixedU Width Var n
--   deriving (Eq, Ord, Show)

-- pairWithKey :: Bindings n -> Bindings (Mixed n)
-- pairWithKey (Bindings ns bs us) =
--   Bindings (IntMap.mapWithKey MixedN ns) (IntMap.mapWithKey MixedB bs) (IntMap.mapWithKey (IntMap.mapWithKey . MixedU) us)

-- stripKey :: Bindings (Mixed n) -> Bindings n
-- stripKey (Bindings ns bs us) =
--   Bindings (fmap (\(MixedN _ n) -> n) ns) (fmap (\(MixedB _ n) -> n) bs) (fmap (fmap (\(MixedU _ _ n) -> n)) us)

--------------------------------------------------------------------------------

data Relations n = Relations
  { -- var = value
    valueBindings :: Bindings n,
    -- var = expression
    exprBindings :: Bindings (Expr n)
    -- [| expression |] = True
  }

instance Show n => Show (Relations n) where
  show (Relations vbs ebs) =
    "Binding of variables to values:\n" <> show vbs <> "\n"
      <> "Binding of variables to expressions:\n"
      <> show ebs
      <> "\n"

instance Semigroup (Relations n) where
  Relations vbs0 ebs0 <> Relations vbs1 ebs1 =
    Relations (vbs0 <> vbs1) (ebs0 <> ebs1)

instance Monoid (Relations n) where
  mempty = Relations mempty mempty

  