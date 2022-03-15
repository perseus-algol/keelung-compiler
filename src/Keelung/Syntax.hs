-- Datatype of the DSL
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}

module Keelung.Syntax where

--------------------------------------------------------------------------------

data Type
  = Num -- numbers
  | Bool -- booleans (well, special numbers!)
  | Arr -- a bunch of numbers
  deriving (Show)

--------------------------------------------------------------------------------

-- | Values are parameterised by some field and indexed by Type
data Value :: * -> Type -> * where
  Number :: n -> Value n 'Num
  Boolean :: Bool -> Value n 'Bool
  Array :: Type -> Int -> Value n ty

instance Show n => Show (Value n ty) where
  show (Number n) = show n
  show (Boolean b) = show b
  show (Array _ n) = "@" <> show n

--------------------------------------------------------------------------------

-- | Variables are indexed by Type
data Variable :: Type -> * where
  Variable :: Int -> Variable ty

instance Show (Variable ty) where
  show (Variable i) = "$" <> show i

--------------------------------------------------------------------------------

-- | Expressions are parameterised by some field and indexed by Type
data Expr :: * -> Type -> * where
  -- value
  Val :: Value n ty -> Expr n ty
  -- variable
  Var :: Variable ty -> Expr n ty
  -- operators on numbers
  Add :: Expr n 'Num -> Expr n 'Num -> Expr n 'Num
  Sub :: Expr n 'Num -> Expr n 'Num -> Expr n 'Num
  Mul :: Expr n 'Num -> Expr n 'Num -> Expr n 'Num
  Div :: Expr n 'Num -> Expr n 'Num -> Expr n 'Num
  Eq :: Expr n 'Num -> Expr n 'Num -> Expr n 'Bool
  -- operators on booleans
  And :: Expr n 'Bool -> Expr n 'Bool -> Expr n 'Bool
  Or :: Expr n 'Bool -> Expr n 'Bool -> Expr n 'Bool
  Xor :: Expr n 'Bool -> Expr n 'Bool -> Expr n 'Bool
  BEq :: Expr n 'Num -> Expr n 'Num -> Expr n 'Bool

instance Show n => Show (Expr n ty) where
  showsPrec prec expr = case expr of
    Val val -> shows val
    Var var -> shows var
    Add x y -> showParen (prec > 6) $ showsPrec 6 x . showString " + " . showsPrec 7 y
    Sub x y -> showParen (prec > 6) $ showsPrec 6 x . showString " - " . showsPrec 7 y
    Mul x y -> showParen (prec > 7) $ showsPrec 7 x . showString " * " . showsPrec 8 y
    Div x y -> showParen (prec > 7) $ showsPrec 7 x . showString " / " . showsPrec 8 y
    Eq x y -> showParen (prec > 5) $ showsPrec 6 x . showString " = " . showsPrec 6 y
    And x y -> showParen (prec > 3) $ showsPrec 4 x . showString " ∧ " . showsPrec 3 y
    Or x y -> showParen (prec > 2) $ showsPrec 3 x . showString " ∨ " . showsPrec 2 y
    Xor x y -> showParen (prec > 4) $ showsPrec 5 x . showString " ⊕ " . showsPrec 4 y
    BEq x y -> showParen (prec > 5) $ showsPrec 6 x . showString " = " . showsPrec 6 y