{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Keelung.Compiler.Compile (run) where

import Control.Monad
import Control.Monad.State
import Data.Field.Galois (GaloisField)
import Data.Foldable (Foldable (foldl'), toList)
import qualified Data.IntMap as IntMap
import qualified Data.Map.Strict as Map
import Data.Sequence (Seq (..))
import qualified Data.Set as Set
import qualified Keelung.Compiler.Constraint as Constraint
import Keelung.Compiler.Constraint2
import qualified Keelung.Compiler.Constraint2 as Constraint2
import Keelung.Compiler.Syntax.FieldBits (FieldBits (..))
import Keelung.Compiler.Syntax.Untyped
import Keelung.Syntax.Counters (Counters, VarSort (..), VarType (..), addCount, getCount)

--------------------------------------------------------------------------------

-- | Compile an untyped expression to a constraint system
run :: (GaloisField n, Integral n) => TypeErased n -> Constraint.ConstraintSystem n
run (TypeErased untypedExprs fieldWidith counters relations assertions assignments) = runM fieldWidith counters $ do
  forM_ untypedExprs $ \untypedExpr -> do
    case untypedExpr of
      ExprB x -> do
        out <- freshRefBO
        encodeExprB out x
      ExprF x -> do
        out <- freshRefFO
        encodeExprF out x
      ExprU x -> do
        out <- freshRefUO (widthOfU x)
        encodeExprU out x

  -- Compile all relations
  encodeRelations relations

  -- Compile assignments to constraints
  mapM_ encodeAssignment assignments

  -- Compile assertions to constraints
  mapM_ encodeAssertion assertions

  constraints <- gets envConstraints

  counters' <- gets envCounters

  return
    ( Constraint.ConstraintSystem
        (Set.fromList $ map (Constraint2.fromConstraint counters') constraints)
        counters'
    )

-- | Encode the constraint 'out = x'.
encodeAssertion :: (GaloisField n, Integral n) => Expr n -> M n ()
encodeAssertion expr = do
  -- 1 = expr
  case expr of
    ExprB x -> do
      out <- freshRefB
      encodeExprB out x
      add $ cAddB 1 [(out, -1)]
    ExprF x -> do
      out <- freshRefF
      encodeExprF out x
      add $ cAddF 1 [(out, -1)]
    ExprU x -> do
      out <- freshRefU (widthOfU x)
      encodeExprU out x
      add $ cAddU 1 [(out, -1)]

-- | Encode the constraint 'out = expr'.
encodeAssignment :: (GaloisField n, Integral n) => Assignment n -> M n ()
encodeAssignment (AssignmentB ref expr) = encodeExprB ref expr
encodeAssignment (AssignmentF ref expr) = encodeExprF ref expr
encodeAssignment (AssignmentU ref expr) = encodeExprU ref expr

-- encodeRelation :: (GaloisField n, Integral n) => Relation n -> M n ()
-- encodeRelation (Relation bindings assignments assertions) = do
--   forM_ (IntMap.toList bindings) $ \(var, val) -> add $ cadd val [(var, -1)]
--   forM_ (IntMap.toList assignments) $ uncurry encode
--   forM_ assertions $ \expr -> do
--       out <- freshVar
--       encode out expr
--       add $ cadd 1 [(out, -1)] -- 1 = expr

encodeValueBindings :: (GaloisField n, Integral n) => Bindings n -> M n ()
encodeValueBindings bindings = do
  forM_ (Map.toList (bindingsF bindings)) $ \(var, val) -> add $ cAddF val [(var, -1)]
  forM_ (Map.toList (bindingsB bindings)) $ \(var, val) -> add $ cAddB val [(var, -1)]
  forM_ (IntMap.toList (bindingsUs bindings)) $ \(_, bindings') ->
    forM_ (Map.toList bindings') $ \(var, val) -> add $ cAddU val [(var, -1)]

encodeExprBindings :: (GaloisField n, Integral n) => Bindings (Expr n) -> M n ()
encodeExprBindings bindings = do
  forM_ (Map.toList (bindingsF bindings)) $ \(var, ExprF val) -> encodeExprF var val
  forM_ (Map.toList (bindingsB bindings)) $ \(var, ExprB val) -> encodeExprB var val
  forM_ (IntMap.toList (bindingsUs bindings)) $ \(_, bindings') ->
    forM_ (Map.toList bindings') $ \(var, ExprU val) -> encodeExprU var val

encodeRelations :: (GaloisField n, Integral n) => Relations n -> M n ()
encodeRelations (Relations vbs ebs) = do
  encodeValueBindings vbs
  encodeExprBindings ebs

--------------------------------------------------------------------------------

-- | Monad for compilation
data Env n = Env
  { envFieldWidth :: Width,
    envCounters :: Counters,
    envConstraints :: [Constraint n]
  }

type M n = State (Env n)

runM :: GaloisField n => Width -> Counters -> M n a -> a
runM fieldWidith counters program = evalState program (Env fieldWidith counters mempty)

modifyCounter :: (Counters -> Counters) -> M n ()
modifyCounter f = modify (\env -> env {envCounters = f (envCounters env)})

add :: GaloisField n => [Constraint n] -> M n ()
add cs =
  modify (\env -> env {envConstraints = cs <> envConstraints env})

freshRefF :: M n RefF
freshRefF = do
  counters <- gets envCounters
  let index = getCount OfIntermediate OfField counters
  modifyCounter $ addCount OfIntermediate OfField 1
  return $ RefF index

-- fresh :: M n RefB
fresh :: VarSort -> VarType -> (Int -> ref) -> M n ref
fresh sort kind ctor = do
  counters <- gets envCounters
  let index = getCount sort kind counters
  modifyCounter $ addCount sort kind 1
  return $ ctor index

freshRefBO :: M n RefB
freshRefBO = fresh OfOutput OfBoolean RefBO

freshRefFO :: M n RefF
freshRefFO = fresh OfOutput OfField RefFO

freshRefUO :: Width -> M n RefU
freshRefUO width = fresh OfOutput (OfUInt width) (RefUO width)

freshRefB :: M n RefB
freshRefB = do
  counters <- gets envCounters
  let index = getCount OfIntermediate OfBoolean counters
  modifyCounter $ addCount OfIntermediate OfBoolean 1
  return $ RefB index

freshRefU :: Width -> M n RefU
freshRefU width = do
  counters <- gets envCounters
  let index = getCount OfIntermediate (OfUInt width) counters
  modifyCounter $ addCount OfIntermediate (OfUInt width) 1
  return $ RefU width index

----------------------------------------------------------------

encodeExprB :: (GaloisField n, Integral n) => RefB -> ExprB n -> M n ()
encodeExprB out expr = case expr of
  ValB val -> add $ cAddB val [(out, -1)] -- out = val
  VarB var -> do
    add $ cAddB 0 [(out, 1), (RefB var, -1)] -- out = var
  OutputVarB var -> do
    add $ cAddB 0 [(out, 1), (RefBO var, -1)] -- out = var
  InputVarB var -> do
    add $ cAddB 0 [(out, 1), (RefBI var, -1)] -- out = var
  AndB x0 x1 xs -> do
    a <- wireB x0
    b <- wireB x1
    vars <- mapM wireB xs
    case vars of
      Empty ->
        add $ cMulSimpleB a b out -- out = a * b
      (c :<| Empty) -> do
        aAndb <- freshRefB
        add $ cMulSimpleB a b aAndb -- aAndb = a * b
        add $ cMulSimpleB aAndb c out -- out = aAndb * c
      _ -> do
        -- the number of operands
        let n = 2 + fromIntegral (length vars)
        -- polynomial = n - sum of operands
        let polynomial = (n, (a, -1) : (b, -1) : [(v, -1) | v <- toList vars])
        -- if the answer is 1 then all operands must be 1
        --    (n - sum of operands) * out = 0
        add $
          cMulB
            polynomial
            (0, [(out, 1)])
            (0, [])
        -- if the answer is 0 then not all operands must be 1:
        --    (n - sum of operands) * inv = 1 - out
        inv <- freshRefB
        add $
          cMulB
            polynomial
            (0, [(inv, 1)])
            (1, [(out, -1)])
  OrB x0 x1 xs -> do
    a <- wireB x0
    b <- wireB x1
    vars <- mapM wireB xs
    case vars of
      Empty -> encodeOrB out a b
      (c :<| Empty) -> do
        -- only 3 operands
        aOrb <- freshRefB
        encodeOrB aOrb a b
        encodeOrB out aOrb c
      _ -> do
        -- more than 3 operands, rewrite it as an inequality instead:
        --      if all operands are 0           then 0 else 1
        --  =>  if the sum of operands is 0     then 0 else 1
        --  =>  if the sum of operands is not 0 then 1 else 0
        --  =>  the sum of operands is not 0
        fieldWidth <- gets envFieldWidth
        encodeExprB
          out
          ( NEqF
              (ValF fieldWidth 0)
              ( AddF
                  fieldWidth
                  (BtoF fieldWidth x0)
                  (BtoF fieldWidth x1)
                  (fmap (BtoF fieldWidth) xs)
              )
          )
  XorB x y -> do
    x' <- wireB x
    y' <- wireB y
    encodeXorB out x' y'
  NotB x -> do
    x' <- wireB x
    add $ cAddB 1 [(x', -1), (out, -1)] -- out = 1 - x
  IfB p x y -> do
    p' <- wireB p
    x' <- wireB x
    y' <- wireB y
    encodeIfB out p' x' y'
  NEqB x y -> encodeExprB out (XorB x y)
  NEqF x y -> do
    x' <- wireF x
    y' <- wireF y
    encodeEqualityF False out x' y'
  NEqU x y -> do
    x' <- wireU x
    y' <- wireU y
    encodeEqualityU False out x' y'
  EqB x y -> do
    x' <- wireB x
    y' <- wireB y
    -- Constraint 'x == y = out' ASSUMING x, y are boolean.
    --     x * y + (1 - x) * (1 - y) = out
    -- =>
    --    (1 - x) * (1 - 2y) = (out - y)
    add $
      cMulB
        (1, [(x', -1)])
        (1, [(y', -2)])
        (0, [(out, 1), (y', -1)])
  EqF x y -> do
    x' <- wireF x
    y' <- wireF y
    encodeEqualityF True out x' y'
  EqU x y -> do
    x' <- wireU x
    y' <- wireU y
    encodeEqualityU True out x' y'
  BitU x i -> do
    x' <- wireU x
    add $ cAddB 0 [(out, 1), (RefUBit (widthOfU x) x' i, -1)] -- out = var

encodeExprF :: (GaloisField n, Integral n) => RefF -> ExprF n -> M n ()
encodeExprF out expr = case expr of
  ValF _ val -> add $ cAddF val [(out, -1)] -- out = val
  VarF _ var -> do
    add $ cAddF 0 [(out, 1), (RefF var, -1)] -- out = var
  VarFO _ var -> do
    add $ cAddF 0 [(out, 1), (RefFO var, -1)] -- out = var
  VarFI _ var -> do
    add $ cAddF 0 [(out, 1), (RefFI var, -1)] -- out = var
  SubF _ x y -> do
    x' <- toTerm x
    y' <- toTerm y
    encodeTerms out (x' :<| negateTerm y' :<| Empty)
  AddF _ x y rest -> do
    terms <- mapM toTerm (x :<| y :<| rest)
    encodeTerms out terms
  MulF _ x y -> do
    x' <- wireF x
    y' <- wireF y
    add $ cMulSimpleF x' y' out
  DivF _ x y -> do
    x' <- wireF x
    y' <- wireF y
    add $ cMulSimpleF y' out x'
  IfF _ p x y -> do
    p' <- wireB p
    x' <- wireF x
    y' <- wireF y
    encodeIfF out p' x' y'
  BtoF _ x -> do
    result <- freshRefB
    encodeExprB result x
    add $ cAddF 0 [(out, 1), (RefBtoRefF result, -1)] -- out = var

encodeExprU :: (GaloisField n, Integral n) => RefU -> ExprU n -> M n ()
encodeExprU out expr = case expr of
  ValU width val -> do
    -- constraint for UInt : out = val
    add $ cAddU val [(out, -1)]
    -- constraints for BinRep of UInt
    forM_ [0 .. width - 1] $ \i -> do
      let bit = testBit val i
      add $ cAddB bit [(RefUBit width out i, -1)] -- out = var
  VarU width var -> do
    let ref = RefU width var
    -- constraint for UInt : out = ref
    add $ cAddU 0 [(out, 1), (ref, -1)]
    -- constraints for BinRep of UInt
    forM_ [0 .. width - 1] $ \i -> do
      add $ cAddB 0 [(RefUBit width out i, -1), (RefUBit width ref i, 1)] -- out[i] = ref[i]
  OutputVarU width var -> do
    add $ cAddU 0 [(out, 1), (RefU width var, -1)] -- out = var
  InputVarU width var -> do
    let ref = RefUI width var
    -- constraint for UInt : out = ref
    add $ cAddU 0 [(out, 1), (ref, -1)]
    -- constraints for BinRep of UInt
    forM_ [0 .. width - 1] $ \i -> do
      add $ cAddB 0 [(RefUBit width out i, -1), (RefUBit width ref i, 1)] -- out[i] = ref[i]
  SubU w x y -> do
    x' <- wireU x
    y' <- wireU y
    encodeSubU w out x' y'
  AddU w x y -> do
    x' <- wireU x
    y' <- wireU y
    encodeAddU w out x' y'
  MulU w x y -> do
    x' <- wireU x
    y' <- wireU y
    encodeMulU w out x' y'
  AndU w x y xs -> do
    forM_ [0 .. w - 1] $ \i -> do
      encodeExprB
        (RefUBit w out i)
        (AndB (BitU x i) (BitU y i) (fmap (`BitU` i) xs))
  OrU w x y xs -> do
    forM_ [0 .. w - 1] $ \i -> do
      encodeExprB
        (RefUBit w out i)
        (OrB (BitU x i) (BitU y i) (fmap (`BitU` i) xs))
  XorU w x y -> do
    forM_ [0 .. w - 1] $ \i -> do
      encodeExprB
        (RefUBit w out i)
        (XorB (BitU x i) (BitU y i))
  NotU w x -> do
    forM_ [0 .. w - 1] $ \i -> do
      encodeExprB
        (RefUBit w out i)
        (NotB (BitU x i))
  IfU _ p x y -> do
    p' <- wireB p
    x' <- wireU x
    y' <- wireU y
    encodeIfU out p' x' y'
  RoLU w n x -> do
    x' <- wireU x
    forM_ [0 .. w - 1] $ \i -> do
      let i' = (i - n) `mod` w
      add $ cAddB 0 [(RefUBit w out i, 1), (RefUBit w x' i', -1)]
  ShLU w n x -> do
    x' <- wireU x
    case compare n 0 of
      EQ -> add $ cAddU 0 [(out, 1), (x', -1)]
      GT -> do
        -- fill lower bits with 0s
        forM_ [0 .. n - 1] $ \i -> do
          add $ cAddB 0 [(RefUBit w out i, 1)]
        -- shift upper bits
        forM_ [n .. w - 1] $ \i -> do
          let i' = i - n
          add $ cAddB 0 [(RefUBit w out i, 1), (RefUBit w x' i', -1)]
      LT -> do
        -- shift lower bits
        forM_ [0 .. w + n - 1] $ \i -> do
          let i' = i - n
          add $ cAddB 0 [(RefUBit w out i, 1), (RefUBit w x' i', -1)]
        -- fill upper bits with 0s
        forM_ [w + n .. w - 1] $ \i -> do
          add $ cAddB 0 [(RefUBit w out i, 1)]
  BtoU w x -> do
    -- 1. wire 'out[0]' to 'x'
    -- 2. wire 'out[_]' to '0' for all other bits
    forM_ [0 .. w - 1] $ \i ->
      if i == 0
        then do
          result <- freshRefB
          encodeExprB result x
          add $ cAddB 0 [(RefUBit w out i, 1), (result, -1)]
        else do
          add $ cAddB 0 [(RefUBit w out i, 1)]

--------------------------------------------------------------------------------

-- | Pushes the constructor of Rotate inwards
-- encodeRotate :: (GaloisField n, Integral n) => Var -> Int -> ExprU n -> M n ()
-- encodeRotate out i expr = case expr of
--   -- ExprB x -> encode out (ExprB x)
--   -- ExprF x -> case x of
--   --   ValF w n -> do
--   --     n' <- rotateField w n
--   --     encode out (ExprF (ValF w n'))
--   --   VarF w var -> addRotatedBinRep out w var i
--   --   SubN {} -> error "[ panic ] dunno how to compile ROTATE SubN"
--   --   AddF w _ _ _ -> do
--   --     result <- freshVar
--   --     encode result expr
--   --     addRotatedBinRep out w result i
--   --   MulF {} -> error "[ panic ] dunno how to compile ROTATE MulF"
--   --   DivF {} -> error "[ panic ] dunno how to compile ROTATE DivF"
--   --   IfF {} -> error "[ panic ] dunno how to compile ROTATE IfF"
--   --   RoLN {} -> error "[ panic ] dunno how to compile ROTATE RoLN"
--   -- ExprU x -> case x of
--   ValU w n -> do
--     n' <- rotateField w n
--     encode out (ExprU (ValU w n'))
--   VarU w var -> addRotatedBinRep out w var i
--   SubU {} -> error "[ panic ] dunno how to compile ROTATE SubU"
--   AddU w _ _ -> do
--     result <- freshVar
--     encodeExorU result expr
--     addRotatedBinRep out w result i
--   _ -> error "[ panic ] dunno how to compile ROTATE on UInt types"
--   -- Rotate _ n x -> encodeRotate out (i + n) x
--   -- -- NAryOp _ op _ _ _ -> error $ "[ panic ] dunno how to compile ROTATE NAryOp " <> show op
--   where
--     rotateField width n = do
--       let val = toInteger n
--       -- see if we are rotating right (positive) of left (negative)
--       case i `compare` 0 of
--         EQ -> return n -- no rotation
--         -- encode out expr -- no rotation
--         LT -> do
--           let rotateDistance = (-i) `mod` width
--           -- collect the bit values of lower bits that will be rotated to higher bits
--           let lowerBits = [Data.Bits.testBit val j | j <- [0 .. rotateDistance - 1]]
--           -- shift the higher bits left by the rotate distance
--           let higherBits = Data.Bits.shiftR val rotateDistance
--           -- combine the lower bits and the higher bits
--           return $
--             fromInteger $
--               foldl'
--                 (\acc (bit, j) -> if bit then Data.Bits.setBit acc j else acc)
--                 higherBits
--                 (zip lowerBits [width - rotateDistance .. width - 1])

--         -- encode out (Val bw (fromInteger rotatedVal))
--         GT -> do
--           let rotateDistance = i `mod` width
--           -- collect the bit values of higher bits that will be rotated to lower bits
--           let higherBits = [Data.Bits.testBit val j | j <- [width - rotateDistance .. width - 1]]
--           -- shift the lower bits right by the rotate distance
--           let lowerBits = Data.Bits.shiftL val rotateDistance `mod` 2 ^ width
--           -- combine the lower bits and the higher bits
--           return $
--             fromInteger $
--               foldl'
--                 (\acc (bit, j) -> if bit then Data.Bits.setBit acc j else acc)
--                 lowerBits
--                 (zip higherBits [0 .. rotateDistance - 1])

--------------------------------------------------------------------------------

data Term n
  = Constant n -- c
  | WithVars RefF n -- cx

-- Avoid having to introduce new multiplication gates
-- for multiplication by constant scalars.
toTerm :: (GaloisField n, Integral n) => ExprF n -> M n (Term n)
toTerm (MulF _ (ValF _ m) (ValF _ n)) = return $ Constant (m * n)
toTerm (MulF _ (VarF _ var) (ValF _ n)) = return $ WithVars (RefF var) n
toTerm (MulF _ (VarFI _ var) (ValF _ n)) = return $ WithVars (RefFI var) n
toTerm (MulF _ (VarFO _ var) (ValF _ n)) = return $ WithVars (RefFO var) n
toTerm (MulF _ (ValF _ n) (VarF _ var)) = return $ WithVars (RefF var) n
toTerm (MulF _ (ValF _ n) (VarFI _ var)) = return $ WithVars (RefFI var) n
toTerm (MulF _ (ValF _ n) (VarFO _ var)) = return $ WithVars (RefFO var) n
toTerm (MulF _ (ValF _ n) expr) = do
  out <- freshRefF
  encodeExprF out expr
  return $ WithVars out n
toTerm (MulF _ expr (ValF _ n)) = do
  out <- freshRefF
  encodeExprF out expr
  return $ WithVars out n
toTerm (ValF _ n) =
  return $ Constant n
toTerm (VarF _ var) =
  return $ WithVars (RefF var) 1
toTerm (VarFI _ var) =
  return $ WithVars (RefFI var) 1
toTerm (VarFO _ var) =
  return $ WithVars (RefFO var) 1
toTerm expr = do
  out <- freshRefF
  encodeExprF out expr
  return $ WithVars out 1

-- | Negate a Term
negateTerm :: Num n => Term n -> Term n
negateTerm (WithVars var c) = WithVars var (negate c)
negateTerm (Constant c) = Constant (negate c)

encodeTerms :: GaloisField n => RefF -> Seq (Term n) -> M n ()
encodeTerms out terms =
  let (constant, varsWithCoeffs) = foldl' go (0, []) terms
   in add $ cAddF constant $ (out, -1) : varsWithCoeffs
  where
    go :: Num n => (n, [(RefF, n)]) -> Term n -> (n, [(RefF, n)])
    go (constant, pairs) (Constant n) = (constant + n, pairs)
    go (constant, pairs) (WithVars var coeff) = (constant, (var, coeff) : pairs)

-- Given a binary function 'f' that knows how to encode '_⊗_'
-- This functions replaces the occurences of '_⊗_' with 'f' in the following manner:
--      E₀ ⊗ E₁ ⊗ ... ⊗ Eₙ
--  =>
--      E₀ `f` (E₁ `f` ... `f` Eₙ)
-- encodeAndFoldExprs :: (GaloisField n, Integral n) => (Var -> Var -> Var -> M n ()) -> Var -> Expr n -> Expr n -> Seq (Expr n) -> M n ()
-- encodeAndFoldExprs f out x0 x1 xs = do
--   x0' <- wireAsVar x0
--   x1' <- wireAsVar x1
--   vars <- mapM wireAsVar xs
--   go x0' x1' vars
--   where
--     go x y Empty = f out x y
--     go x y (v :<| vs) = do
--       out' <- freshVar
--       go out' v vs
--       f out' x y

-- | If the expression is not already a variable, create a new variable
-- wireAsVar :: (GaloisField n, Integral n) => Expr n -> M n Var
-- wireAsVar (ExprB (VarB var)) = return var
-- wireAsVar (ExprF (VarF _ var)) = return var
-- wireAsVar (ExprU (VarU _ var)) = return var
-- wireAsVar expr = do
--   out <- freshVar
--   encode out expr
--   return out
wireB :: (GaloisField n, Integral n) => ExprB n -> M n RefB
wireB (VarB ref) = return (RefB ref)
wireB (OutputVarB ref) = return (RefBO ref)
wireB (InputVarB ref) = return (RefBI ref)
wireB expr = do
  out <- freshRefB
  encodeExprB out expr
  return out

wireF :: (GaloisField n, Integral n) => ExprF n -> M n RefF
wireF (VarF _ ref) = return (RefF ref)
wireF (VarFO _ ref) = return (RefFO ref)
wireF (VarFI _ ref) = return (RefFI ref)
wireF expr = do
  out <- freshRefF
  encodeExprF out expr
  return out

wireU :: (GaloisField n, Integral n) => ExprU n -> M n RefU
wireU (VarU w ref) = return (RefU w ref)
wireU (OutputVarU w ref) = return (RefUO w ref)
wireU (InputVarU w ref) = return (RefUI w ref)

wireU expr = do
  out <- freshRefU (widthOfU expr)
  encodeExprU out expr
  return out

--------------------------------------------------------------------------------

-- | Equalities are encoded with inequalities and inequalities with CNEQ constraints.
--    Constraint 'x != y = out'
--    The encoding is, for some 'm':
--        1. (x - y) * m = out
--        2. (x - y) * (1 - out) = 0
encodeEqualityU :: (GaloisField n, Integral n) => Bool -> RefB -> RefU -> RefU -> M n ()
encodeEqualityU isEq out x y =
  if x == y
    then do
      -- in this case, the variable x and y happend to be the same
      if isEq
        then encodeExprB out (ValB 1)
        else encodeExprB out (ValB 0)
    else do
      -- introduce a new variable m
      -- if diff = 0 then m = 0 else m = recip diff
      let width = case x of
            RefU w _ -> w
            RefUI w _ -> w
            RefUO w _ -> w
            RefBtoRefU _ -> 1 -- TODO: reexamine this
      m <- freshRefU width

      if isEq
        then do
          --  1. (x - y) * m = 1 - out
          --  2. (x - y) * out = 0
          add $
            cMulU
              (0, [(x, 1), (y, -1)])
              (0, [(m, 1)])
              (1, [(RefBtoRefU out, -1)])
          add $
            cMulU
              (0, [(x, 1), (y, -1)])
              (0, [(RefBtoRefU out, 1)])
              (0, [])
        else do
          --  1. (x - y) * m = out
          --  2. (x - y) * (1 - out) = 0
          add $
            cMulU
              (0, [(x, 1), (y, -1)])
              (0, [(m, 1)])
              (0, [(RefBtoRefU out, 1)])
          add $
            cMulU
              (0, [(x, 1), (y, -1)])
              (1, [(RefBtoRefU out, -1)])
              (0, [])

      --  keep track of the relation between (x - y) and m
      add $ cNEqU x y m

encodeEqualityF :: (GaloisField n, Integral n) => Bool -> RefB -> RefF -> RefF -> M n ()
encodeEqualityF isEq out x y =
  if x == y
    then do
      -- in this case, the variable x and y happend to be the same
      if isEq
        then encodeExprB out (ValB 1)
        else encodeExprB out (ValB 0)
    else do
      -- introduce a new variable m
      -- if diff = 0 then m = 0 else m = recip diff
      m <- freshRefF

      if isEq
        then do
          --  1. (x - y) * m = 1 - out
          --  2. (x - y) * out = 0
          add $
            cMulF
              (0, [(x, 1), (y, -1)])
              (0, [(m, 1)])
              (1, [(RefBtoRefF out, -1)])
          add $
            cMulF
              (0, [(x, 1), (y, -1)])
              (0, [(RefBtoRefF out, 1)])
              (0, [])
        else do
          --  1. (x - y) * m = out
          --  2. (x - y) * (1 - out) = 0
          add $
            cMulF
              (0, [(x, 1), (y, -1)])
              (0, [(m, 1)])
              (0, [(RefBtoRefF out, 1)])
          add $
            cMulF
              (0, [(x, 1), (y, -1)])
              (1, [(RefBtoRefF out, -1)])
              (0, [])

      --  keep track of the relation between (x - y) and m
      add $ cNEqF x y m

--------------------------------------------------------------------------------

-- | Encoding addition on UInts with multiple operands: O(1)
--    C = A + B - 2ⁿ * (Aₙ₋₁ * Bₙ₋₁)
encodeAddOrSubU :: (GaloisField n, Integral n) => Bool -> Width -> RefU -> RefU -> RefU -> M n ()
encodeAddOrSubU isSub width out x y = do
  -- locate the binary representations of the operands
  -- xBinRepStart <- lookupBinRep width x
  -- yBinRepStart <- lookupBinRep width y

  let multiplier = 2 ^ width
  -- We can refactor
  --    out = A + B - 2ⁿ * (Aₙ₋₁ * Bₙ₋₁)
  -- into the form of
  --    (2ⁿ * Aₙ₋₁) * (Bₙ₋₁) = (out - A - B)
  add $
    cMulU
      (0, [(RefBtoRefU (RefUBit width x (width - 1)), multiplier)])
      (0, [(RefBtoRefU (RefUBit width y (width - 1)), 1)])
      (0, [(out, 1), (x, -1), (y, if isSub then 1 else -1)])

encodeAddU :: (GaloisField n, Integral n) => Width -> RefU -> RefU -> RefU -> M n ()
encodeAddU = encodeAddOrSubU False

encodeSubU :: (GaloisField n, Integral n) => Width -> RefU -> RefU -> RefU -> M n ()
encodeSubU = encodeAddOrSubU True

-- | Encoding addition on UInts with multiple operands: O(2)
--    C + 2ⁿ * Q = A * B
encodeMulU :: (GaloisField n, Integral n) => Int -> RefU -> RefU -> RefU -> M n ()
encodeMulU width out a b = do
  -- (a) * (b) = result + 2ⁿ * quotient
  quotient <- freshRefU width
  add $ cMulU (0, [(a, 1)]) (0, [(b, 1)]) (0, [(out, 1), (quotient, 2 ^ width)])

-- | An universal way of compiling a conditional
encodeIfB :: (GaloisField n, Integral n) => RefB -> RefB -> RefB -> RefB -> M n ()
encodeIfB out p x y = do
  --  out = p * x + (1 - p) * y
  --      =>
  --  (out - x) = (1 - p) * (y - x)
  add $
    cMulB
      (1, [(p, -1)])
      (0, [(x, -1), (y, 1)])
      (0, [(x, -1), (out, 1)])

encodeIfF :: (GaloisField n, Integral n) => RefF -> RefB -> RefF -> RefF -> M n ()
encodeIfF out p x y = do
  --  out = p * x + (1 - p) * y
  --      =>
  --  (out - x) = (1 - p) * (y - x)
  add $
    cMulF
      (1, [(RefBtoRefF p, -1)])
      (0, [(x, -1), (y, 1)])
      (0, [(x, -1), (out, 1)])

encodeIfU :: (GaloisField n, Integral n) => RefU -> RefB -> RefU -> RefU -> M n ()
encodeIfU out p x y = do
  --  out = p * x + (1 - p) * y
  --      =>
  --  (out - x) = (1 - p) * (y - x)
  add $
    cMulU
      (1, [(RefBtoRefU p, -1)])
      (0, [(x, -1), (y, 1)])
      (0, [(x, -1), (out, 1)])

encodeOrB :: (GaloisField n, Integral n) => RefB -> RefB -> RefB -> M n ()
encodeOrB out x y = do
  -- (1 - x) * y = (out - x)
  add $
    cMulB
      (1, [(x, -1)])
      (0, [(y, 1)])
      (0, [(x, -1), (out, 1)])

encodeXorB :: (GaloisField n, Integral n) => RefB -> RefB -> RefB -> M n ()
encodeXorB out x y = do
  -- (1 - 2x) * (y + 1) = (1 + out - 3x)
  add $
    cMulB
      (1, [(x, -2)])
      (1, [(y, 1)])
      (1, [(x, -3), (out, 1)])