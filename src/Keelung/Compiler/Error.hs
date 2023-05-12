{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}

module Keelung.Compiler.Error where

import Control.DeepSeq (NFData)
import Data.Field.Galois (GaloisField)
import Data.Serialize (Serialize)
import GHC.Generics (Generic)
import Keelung.Compiler.Compile.Error qualified as Compiler
import Keelung.Compiler.R1CS (ExecError)
import Keelung.Error qualified as Lang
import Keelung.Interpreter.Error qualified as Interpreter

data Error n
  = ExecError (ExecError n)
  | InterpretError (Interpreter.Error n)
  | CompileError (Compiler.Error n)
  | LangError Lang.Error
  deriving (Eq, Generic, NFData, Functor)

instance Serialize n => Serialize (Error n)

instance (GaloisField n, Integral n) => Show (Error n) where
  show (ExecError e) = "Execution Error: " ++ show e
  show (InterpretError e) = "Interpret Error: " ++ show e
  show (CompileError e) = "Compile Error: " ++ show e
  show (LangError e) = "Language Error: " ++ show e
