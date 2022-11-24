{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE GADTs #-}

module Keelung.Compiler.Syntax.Untyped
  ( Width,
    widthOfU,
    Expr (..),
    ExprB (..),
    ExprN (..),
    ExprU (..),
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
    -- sizeOfExpr,
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

type Width = Int

data ExprB n
  = ValB n
  | VarB Var
  | InputVarB Var
  | -- logical operators
    AndB (ExprB n) (ExprB n) (Seq (ExprB n))
  | OrB (ExprB n) (ExprB n) (Seq (ExprB n))
  | XorB (ExprB n) (ExprB n)
  | NotB (ExprB n)
  | IfB (ExprB n) (ExprB n) (ExprB n)
  | -- comparison operators
    NEqB (ExprB n) (ExprB n)
  | NEqN (ExprN n) (ExprN n)
  | NEqU (ExprU n) (ExprU n)
  | EqB (ExprB n) (ExprB n)
  | EqN (ExprN n) (ExprN n)
  | EqU (ExprU n) (ExprU n)
  | BitU (ExprU n) Int
  deriving (Functor)

instance (Integral n, Show n) => Show (ExprB n) where
  showsPrec prec expr = case expr of
    ValB 0 -> showString "F"
    ValB _ -> showString "T"
    VarB var -> showString "$" . shows var
    InputVarB var -> showString "$B" . shows var
    AndB x0 x1 xs -> chain prec " ∧ " 3 $ x0 :<| x1 :<| xs
    OrB x0 x1 xs -> chain prec " ∨ " 2 $ x0 :<| x1 :<| xs
    XorB x0 x1 -> chain prec " ⊕ " 4 $ x0 :<| x1 :<| Empty
    NotB x -> chain prec "¬ " 5 $ x :<| Empty
    IfB p x y -> showParen (prec > 1) $ showString "if " . showsPrec 2 p . showString " then " . showsPrec 2 x . showString " else " . showsPrec 2 y
    NEqB x0 x1 -> chain prec " != " 5 $ x0 :<| x1 :<| Empty
    NEqN x0 x1 -> chain prec " != " 5 $ x0 :<| x1 :<| Empty
    NEqU x0 x1 -> chain prec " != " 5 $ x0 :<| x1 :<| Empty
    EqB x0 x1 -> chain prec " == " 5 $ x0 :<| x1 :<| Empty
    EqN x0 x1 -> chain prec " == " 5 $ x0 :<| x1 :<| Empty
    EqU x0 x1 -> chain prec " == " 5 $ x0 :<| x1 :<| Empty
    BitU x i -> showsPrec prec x . showString "[" . shows i . showString "]"

--------------------------------------------------------------------------------

data ExprN n
  = ValN Width n
  | VarN Width Var
  | InputVarN Width Var
  | -- arithmetic operators
    SubN Width (ExprN n) (ExprN n)
  | AddN Width (ExprN n) (ExprN n) (Seq (ExprN n))
  | MulN Width (ExprN n) (ExprN n)
  | DivN Width (ExprN n) (ExprN n)
  | -- logical operators
    IfN Width (ExprB n) (ExprN n) (ExprN n)
  | BtoN Width (ExprB n)
  deriving (Functor)

instance (Show n, Integral n) => Show (ExprN n) where
  showsPrec prec expr = case expr of
    ValN _ n -> shows n
    VarN _ var -> showString "$" . shows var
    InputVarN _ var -> showString "$N" . shows var
    SubN _ x y -> chain prec " - " 6 $ x :<| y :<| Empty
    AddN _ x0 x1 xs -> chain prec " + " 6 $ x0 :<| x1 :<| xs
    MulN _ x y -> chain prec " * " 7 $ x :<| y :<| Empty
    DivN _ x y -> chain prec " / " 7 $ x :<| y :<| Empty
    IfN _ p x y -> showParen (prec > 1) $ showString "if " . showsPrec 2 p . showString " then " . showsPrec 2 x . showString " else " . showsPrec 2 y
    BtoN _ x -> showString "B→N " . showsPrec prec x

--------------------------------------------------------------------------------

data ExprU n
  = ValU Width n
  | VarU Width Var
  | InputVarU Width Var
  | -- arithmetic operators
    SubU Width (ExprU n) (ExprU n)
  | AddU Width (ExprU n) (ExprU n)
  | MulU Width (ExprU n) (ExprU n)
  | -- logical operators
    AndU Width (ExprU n) (ExprU n) (Seq (ExprU n))
  | OrU Width (ExprU n) (ExprU n) (Seq (ExprU n))
  | XorU Width (ExprU n) (ExprU n)
  | NotU Width (ExprU n)
  | IfU Width (ExprB n) (ExprU n) (ExprU n)
  | RoLU Width Int (ExprU n)
  | BtoU Width (ExprB n)
  deriving (Functor)

instance (Show n, Integral n) => Show (ExprU n) where
  showsPrec prec expr = case expr of
    ValU _ n -> shows n
    VarU _ var -> showString "$" . shows var
    InputVarU _ var -> showString "$U" . shows var
    SubU _ x y -> chain prec " - " 6 $ x :<| y :<| Empty
    AddU _ x y -> chain prec " + " 6 $ x :<| y :<| Empty
    MulU _ x y -> chain prec " * " 7 $ x :<| y :<| Empty
    AndU _ x0 x1 xs -> chain prec " ∧ " 3 $ x0 :<| x1 :<| xs
    OrU _ x0 x1 xs -> chain prec " ∨ " 2 $ x0 :<| x1 :<| xs
    XorU _ x0 x1 -> chain prec " ⊕ " 4 $ x0 :<| x1 :<| Empty
    NotU _ x -> showParen (prec > 8) $ showString "¬ " . showsPrec 9 x
    IfU _ p x y -> showParen (prec > 1) $ showString "if " . showsPrec 2 p . showString " then " . showsPrec 2 x . showString " else " . showsPrec 2 y
    RoLU _ n x -> showParen (prec > 8) $ showString "RoL " . showsPrec 9 n . showString " " . showsPrec 9 x
    BtoU _ x -> showString "B→U " . showsPrec prec x

instance Num n => Num (ExprU n) where
  x + y = AddU (widthOfU x) x y
  x - y = SubU (widthOfU x) x y
  x * y = MulU (widthOfU x) x y
  abs = id
  signum = const 1
  fromInteger = error "[ panic ] Dunno how to convert an Integer to an UInt"

--------------------------------------------------------------------------------

-- | "Untyped" expression
data Expr n
  = ExprB (ExprB n) -- Boolean expression
  | ExprN (ExprN n) -- Field expression
  | ExprU (ExprU n) -- UInt expression
  deriving ( Functor)

instance Num n => Num (ExprN n) where
  x + y = AddN (widthOfN x) x y Empty
  x - y = SubN (widthOfN x) x y
  x * y = MulN (widthOfN x) x y
  abs = id
  signum = const 1
  fromInteger = error "[ panic ] Dunno how to convert an Integer to a Number"

chain :: Show n => Int -> String -> Int -> Seq n -> ShowS
chain prec delim n = showParen (prec > n) . go
  where
    go :: Show n => Seq n -> String -> String
    go Empty = showString ""
    go (x :<| Empty) = showsPrec (succ n) x
    go (x :<| xs') = showsPrec (succ n) x . showString delim . go xs'

instance (Integral n, Show n) => Show (Expr n) where
  showsPrec _prec expr = case expr of
    ExprB x -> shows x
    ExprN x -> shows x
    ExprU x -> shows x

widthOfN :: ExprN n -> Width
widthOfN expr = case expr of
  ValN w _ -> w
  VarN w _ -> w
  InputVarN w _ -> w
  SubN w _ _ -> w
  AddN w _ _ _ -> w
  MulN w _ _ -> w
  DivN w _ _ -> w
  IfN w _ _ _ -> w
  BtoN w _ -> w

widthOfU :: ExprU n -> Width
widthOfU expr = case expr of
  ValU w _ -> w
  VarU w _ -> w
  InputVarU w _ -> w
  SubU w _ _ -> w
  AddU w _ _ -> w
  MulU w _ _ -> w
  AndU w _ _ _ -> w
  OrU w _ _ _ -> w
  XorU w _ _ -> w
  NotU w _ -> w
  IfU w _ _ _ -> w
  RoLU w _ _ -> w
  BtoU w _ -> w

--------------------------------------------------------------------------------

data Assignment n
  = AssignmentN Var (ExprN n)
  | AssignmentU Var (ExprU n)
  | AssignmentB Var (ExprB n)

instance (Integral n, Show n) => Show (Assignment n) where
  show (AssignmentN var expr) = show var ++ " = " ++ show expr
  show (AssignmentU var expr) = show var ++ " = " ++ show expr
  show (AssignmentB var expr) = show var ++ " = " ++ show expr

-- show (Assignment var expr) = "$" <> show var <> " := " <> show expr

instance Functor Assignment where
  fmap f (AssignmentN var expr) = AssignmentN var (fmap f expr)
  fmap f (AssignmentU var expr) = AssignmentU var (fmap f expr)
  fmap f (AssignmentB var expr) = AssignmentB var (fmap f expr)

-- fmap f (Assignment var expr) = Assignment var (fmap f expr)

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

--------------------------------------------------------------------------------

data Relations n = Relations
  { -- var = value
    valueBindings :: Bindings n,
    -- var = expression
    exprBindings :: Bindings (Expr n)
    -- [| expression |] = True
  }

instance (Integral n, Show n) => Show (Relations n) where
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
