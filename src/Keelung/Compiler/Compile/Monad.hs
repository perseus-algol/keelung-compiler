module Keelung.Compiler.Compile.Monad where

import Control.Arrow (right)
import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.State
import Data.Field.Galois (GaloisField)
import Keelung (HasWidth (widthOf))
import Keelung.Compiler.Compile.Error
import Keelung.Compiler.ConstraintModule
import Keelung.Compiler.Optimize.OccurB qualified as OccurB
import Keelung.Compiler.Optimize.OccurF qualified as OccurF
import Keelung.Compiler.Optimize.OccurU qualified as OccurU
import Keelung.Compiler.Relations (Relations)
import Keelung.Compiler.Relations qualified as Relations
import Keelung.Compiler.Relations.EquivClass qualified as EquivClass
import Keelung.Compiler.Syntax.Internal
import Keelung.Data.Constraint
import Keelung.Data.FieldInfo
import Keelung.Data.LC
import Keelung.Data.Limb (Limb (..))
import Keelung.Data.PolyL (PolyL)
import Keelung.Data.PolyL qualified as PolyL
import Keelung.Data.Reference
import Keelung.Data.U qualified as U
import Keelung.Syntax.Counters

--------------------------------------------------------------------------------

-- | Monad for compilation
type M n = ReaderT (BootstrapCompiler n) (StateT (ConstraintModule n) (Except (Error n)))

-- | Run the monad
runM :: GaloisField n => BootstrapCompiler n -> FieldInfo -> Counters -> M n a -> Either (Error n) (ConstraintModule n)
runM compilers fieldInfo counters program =
  runExcept
    ( execStateT
        (runReaderT program compilers)
        (ConstraintModule fieldInfo counters OccurF.new (OccurB.new False) OccurU.new Relations.new mempty mempty mempty mempty mempty mempty)
    )

modifyCounter :: (Counters -> Counters) -> M n ()
modifyCounter f = modify (\cs -> cs {cmCounters = f (cmCounters cs)})

freshRefF :: M n RefF
freshRefF = do
  counters <- gets cmCounters
  let index = getCount counters (Intermediate, ReadField)
  modifyCounter $ addCount (Intermediate, WriteField) 1
  return $ RefFX index

freshRefB :: M n RefB
freshRefB = do
  counters <- gets cmCounters
  let index = getCount counters (Intermediate, ReadBool)
  modifyCounter $ addCount (Intermediate, WriteBool) 1
  return $ RefBX index

freshRefB' :: M n RefB
freshRefB' = do
  counters <- gets cmCounters
  let index = getCount counters (Intermediate, ReadBool)
  return $ RefBX index

freshRefU :: Width -> M n RefU
freshRefU width = do
  counters <- gets cmCounters
  let index = getCount counters (Intermediate, ReadUInt width)
  modifyCounter $ addCount (Intermediate, WriteUInt width) 1
  return $ RefUX width index

--------------------------------------------------------------------------------

-- | We want to break the compilation module into smaller modules,
--   but Haskell forbids mutually recursive modules,
--   and functions in these small modules are mutually dependent on each other.
--   One way to do this is by "tying the knot" with a recursive data type.
data BootstrapCompiler n = BootstrapCompiler
  { boostrapCompileF :: ExprF n -> M n (LC n),
    boostrapCompileB :: ExprB n -> M n (Either RefB Bool),
    boostrapCompileU :: RefU -> ExprU n -> M n ()
  }

-- | For extracting the bootstrapped ExprB compiler
compileExprB :: (GaloisField n, Integral n) => ExprB n -> M n (Either RefB Bool)
compileExprB expr = do
  compiler <- asks boostrapCompileB
  compiler expr

-- | For extracting the bootstrapped ExprF compiler
compileExprF :: (GaloisField n, Integral n) => ExprF n -> M n (LC n)
compileExprF expr = do
  compiler <- asks boostrapCompileF
  compiler expr

-- | For extracting the bootstrapped ExprU compiler
compileExprU :: (GaloisField n, Integral n) => RefU -> ExprU n -> M n ()
compileExprU out expr = do
  compiler <- asks boostrapCompileU
  compiler out expr

--------------------------------------------------------------------------------

writeMulWithLC :: (GaloisField n, Integral n) => LC n -> LC n -> LC n -> M n ()
writeMulWithLC as bs cs = case (as, bs, cs) of
  (Constant _, Constant _, Constant _) -> return ()
  (Constant x, Constant y, Polynomial zs) ->
    -- z - x * y = 0
    addC [CAddL $ PolyL.addConstant (-x * y) zs]
  (Constant x, Polynomial ys, Constant z) ->
    -- x * ys = z
    -- x * ys - z = 0
    case PolyL.multiplyBy x ys of
      Left _ -> return ()
      Right poly -> addC [CAddL $ PolyL.addConstant (-z) poly]
  (Constant x, Polynomial ys, Polynomial zs) -> do
    -- x * ys = zs
    -- x * ys - zs = 0
    case PolyL.multiplyBy x ys of
      Left c ->
        -- c - zs = 0
        addC [CAddL $ PolyL.addConstant (-c) zs]
      Right ys' -> case PolyL.merge ys' (PolyL.negate zs) of
        Left _ -> return ()
        Right poly -> addC [CAddL poly]
  (Polynomial xs, Constant y, Constant z) -> writeMulWithLC (Constant y) (Polynomial xs) (Constant z)
  (Polynomial xs, Constant y, Polynomial zs) -> writeMulWithLC (Constant y) (Polynomial xs) (Polynomial zs)
  (Polynomial xs, Polynomial ys, _) -> addC [CMulL xs ys (toPolyL cs)]

writeAddWithPolyL :: (GaloisField n, Integral n) => Either n (PolyL n) -> M n ()
writeAddWithPolyL xs = case xs of
  Left _ -> return ()
  Right poly -> addC [CAddL poly]

writeAddWithLC :: (GaloisField n, Integral n) => LC n -> M n ()
writeAddWithLC xs = case xs of
  Constant _ -> return ()
  Polynomial poly -> addC [CAddL poly]

writeAddWithLCAndLimbs :: (GaloisField n, Integral n) => LC n -> n -> [(Limb, n)] -> M n ()
writeAddWithLCAndLimbs lc constant limbs = case lc of
  Constant _ -> return ()
  Polynomial poly -> addC [CAddL (PolyL.insertLimbs constant limbs poly)]

addC :: (GaloisField n, Integral n) => [Constraint n] -> M n ()
addC = mapM_ addOne
  where
    execRelations :: (Relations n -> EquivClass.M (Error n) (Relations n)) -> M n ()
    execRelations f = do
      cs <- get
      result <- lift $ lift $ (EquivClass.runM . f) (cmRelations cs)
      case result of
        Nothing -> return ()
        Just relations -> put cs {cmRelations = relations}

    countBitTestAsOccurU :: (GaloisField n, Integral n) => Ref -> M n ()
    countBitTestAsOccurU (B (RefUBit _ (RefUX width var) _)) =
      modify' (\cs -> cs {cmOccurrenceU = OccurU.increase width var (cmOccurrenceU cs)})
    countBitTestAsOccurU _ = return ()

    addOne :: (GaloisField n, Integral n) => Constraint n -> M n ()
    addOne (CAddL xs) = modify' (\cs -> addOccurrencesTuple (PolyL.varsSet xs) $ cs {cmAddL = xs : cmAddL cs})
    addOne (CVarBindF x c) = do
      execRelations $ Relations.assignR x c
    addOne (CVarBindB x c) = do
      execRelations $ Relations.assignB x c
    addOne (CVarBindL x c) = do
      execRelations $ Relations.assignL x c
    addOne (CVarBindU x c) = do
      execRelations $ Relations.assignU x c
    addOne (CVarEq x y) = do
      countBitTestAsOccurU x
      countBitTestAsOccurU y
      execRelations $ Relations.relateR x 1 y 0
    addOne (CVarEqF x y) = do
      execRelations $ Relations.relateR (F x) 1 (F y) 0
    addOne (CVarEqB x y) = do
      countBitTestAsOccurU (B x)
      countBitTestAsOccurU (B y)
      execRelations $ Relations.relateB x (True, y)
    addOne (CVarEqL x y) = do
      execRelations $ Relations.relateL x y
    addOne (CVarEqU x y) = do
      execRelations $ Relations.relateU x y
    addOne (CVarNEqB x y) = do
      countBitTestAsOccurU (B x)
      countBitTestAsOccurU (B y)
      execRelations $ Relations.relateB x (False, y)
    addOne (CMulL x y (Left c)) = modify' (\cs -> addOccurrencesTuple (PolyL.varsSet x) $ addOccurrencesTuple (PolyL.varsSet y) $ cs {cmMulL = (x, y, Left c) : cmMulL cs})
    addOne (CMulL x y (Right z)) = modify (\cs -> addOccurrencesTuple (PolyL.varsSet x) $ addOccurrencesTuple (PolyL.varsSet y) $ addOccurrencesTuple (PolyL.varsSet z) $ cs {cmMulL = (x, y, Right z) : cmMulL cs})

--------------------------------------------------------------------------------

writeMul :: (GaloisField n, Integral n) => (n, [(Ref, n)]) -> (n, [(Ref, n)]) -> (n, [(Ref, n)]) -> M n ()
writeMul as bs cs = writeMulWithLC (fromPolyL $ uncurry PolyL.fromRefs as) (fromPolyL $ uncurry PolyL.fromRefs bs) (fromPolyL $ uncurry PolyL.fromRefs cs)

writeMulWithLimbs :: (GaloisField n, Integral n) => (n, [(Limb, n)]) -> (n, [(Limb, n)]) -> (n, [(Limb, n)]) -> M n ()
writeMulWithLimbs as bs cs = case (uncurry PolyL.fromLimbs as, uncurry PolyL.fromLimbs bs) of
  (Right as', Right bs') ->
    addC
      [ CMulL as' bs' (uncurry PolyL.fromLimbs cs)
      ]
  _ -> return ()

writeAdd :: (GaloisField n, Integral n) => n -> [(Ref, n)] -> M n ()
writeAdd c as = writeAddWithPolyL (PolyL.fromRefs c as)

writeAddWithLimbs :: (GaloisField n, Integral n) => n -> [(Limb, n)] -> M n ()
writeAddWithLimbs constant limbs = case PolyL.fromLimbs constant limbs of
  Left _ -> return ()
  Right poly -> addC [CAddL poly]

writeVal :: (GaloisField n, Integral n) => Ref -> n -> M n ()
writeVal (F a) x = writeValF a x
writeVal (B a) x = writeValB a (x /= 0)

writeValF :: (GaloisField n, Integral n) => RefF -> n -> M n ()
writeValF a x = addC [CVarBindF (F a) x]

writeValB :: (GaloisField n, Integral n) => RefB -> Bool -> M n ()
writeValB a x = addC [CVarBindB a x]

writeValU :: (GaloisField n, Integral n) => RefU -> Integer -> M n ()
writeValU a x = addC [CVarBindU a x]

writeValL :: (GaloisField n, Integral n) => Limb -> Integer -> M n ()
writeValL a x = addC [CVarBindL a x]

writeEq :: (GaloisField n, Integral n) => Ref -> Ref -> M n ()
writeEq a b = addC [CVarEq a b]

writeEqF :: (GaloisField n, Integral n) => RefF -> RefF -> M n ()
writeEqF a b = addC [CVarEqF a b]

writeEqB :: (GaloisField n, Integral n) => RefB -> RefB -> M n ()
writeEqB a b = addC [CVarEqB a b]

writeNEqB :: (GaloisField n, Integral n) => RefB -> RefB -> M n ()
writeNEqB a b = addC [CVarNEqB a b]

writeEqU :: (GaloisField n, Integral n) => RefU -> RefU -> M n ()
writeEqU a b = addC [CVarEqU a b]

-- | Assert that two limbs are equal
--   If the width of the limb happens to the same as the width of the RefU, then we can use CVarEqU instead
writeEqL :: (GaloisField n, Integral n) => Limb -> Limb -> M n ()
writeEqL a b =
  let widthOfA = lmbWidth a
      widthOfB = lmbWidth b
      widthOfARefU = widthOf (lmbRef a)
      widthOfBRefU = widthOf (lmbRef b)
   in if widthOfA == widthOfB && widthOfA == widthOfARefU && widthOfB == widthOfBRefU
        then writeEqU (lmbRef a) (lmbRef b)
        else addC [CVarEqL a b]

--------------------------------------------------------------------------------

-- | Hints
addEqZeroHint :: (GaloisField n, Integral n) => n -> [(Ref, n)] -> RefF -> M n ()
addEqZeroHint c xs m = case PolyL.fromRefs c xs of
  Left 0 -> writeValF m 0
  Left constant -> writeValF m (recip constant)
  Right poly -> modify' $ \cs -> cs {cmEqZeros = (poly, m) : cmEqZeros cs}

addEqZeroHintWithPoly :: (GaloisField n, Integral n) => Either n (PolyL n) -> RefF -> M n ()
addEqZeroHintWithPoly (Left 0) m = writeValF m 0
addEqZeroHintWithPoly (Left constant) m = writeValF m (recip constant)
addEqZeroHintWithPoly (Right poly) m = modify' $ \cs -> cs {cmEqZeros = (poly, m) : cmEqZeros cs}

addDivModHint :: (GaloisField n, Integral n) => Width -> Either RefU Integer -> Either RefU Integer -> Either RefU Integer -> Either RefU Integer -> M n ()
addDivModHint w x y q r = modify' $ \cs -> cs {cmDivMods = (right (U.new w) x, right (U.new w) y, right (U.new w) q, right (U.new w) r) : cmDivMods cs}

addCLDivModHint :: (GaloisField n, Integral n) => Width -> Either RefU Integer -> Either RefU Integer -> Either RefU Integer -> Either RefU Integer -> M n ()
addCLDivModHint w x y q r = modify' $ \cs -> cs {cmCLDivMods = (right (U.new w) x, right (U.new w) y, right (U.new w) q, right (U.new w) r) : cmCLDivMods cs}

addModInvHint :: (GaloisField n, Integral n) => Width -> Either RefU Integer -> Either RefU Integer -> Either RefU Integer -> Integer -> M n ()
addModInvHint w a output n p = modify' $ \cs -> cs {cmModInvs = (right (U.new w) a, right (U.new w) output, right (U.new w) n, U.new w p) : cmModInvs cs}

--------------------------------------------------------------------------------

-- | Equalities are compiled with inequalities and inequalities with CNEQ constraints.
--    introduce a new variable m
--    if polynomial = 0 then m = 0 else m = recip polynomial
--    Equality:
--      polynomial * m = 1 - out
--      polynomial * out = 0
--    Inequality:
--      polynomial * m = out
--      polynomial * (1 - out) = 0
eqZero :: (GaloisField n, Integral n) => Bool -> LC n -> M n (Either RefB Bool)
eqZero isEq (Constant constant) = return $ Right $ if isEq then constant == 0 else constant /= 0
eqZero isEq (Polynomial polynomial) = do
  m <- freshRefF
  out <- freshRefB
  if isEq
    then do
      writeMulWithLC
        (Polynomial polynomial)
        (1 @ F m)
        (Constant 1 <> neg (1 @ B out))
      writeMulWithLC
        (Polynomial polynomial)
        (1 @ B out)
        (Constant 0)
    else do
      writeMulWithLC
        (Polynomial polynomial)
        (1 @ F m)
        (1 @ B out)
      writeMulWithLC
        (Polynomial polynomial)
        (Constant 1 <> neg (1 @ B out))
        (Constant 0)
  --  keep track of the relation between (x - y) and m
  addEqZeroHintWithPoly (Right polynomial) m
  return (Left out)