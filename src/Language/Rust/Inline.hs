{-|
Module      : Language.Rust.Inline
Description : Quasiquotes for writing Rust code inline in Haskell
Copyright   : (c) Alec Theriault, 2017
License     : BSD-style
Maintainer  : alec.theriault@gmail.com
Stability   : experimental
Portability : GHC
-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE TemplateHaskell #-}

module Language.Rust.Inline (
  -- * Quasiquoters
  --
  -- $quasiquoters
  --
  -- ** Safe
  --
  -- $safe
  rust,
  rustIO,
  -- ** Unsafe
  --
  -- $unsafe
  rustUnsafe,
  rustUnsafeIO,
  -- ** Interruptible
  --
  -- $interruptible
  rustInterruptible,
  rustInterruptibleIO,

  -- * Top-level Rust items
  emitCodeBlock,
 
  -- * Contexts
  Context(..),
  RType,
  HType,
  -- ** Using and defining contexts
  setContext,
  singleton,
  mkContext,
  lookupTypeInContext,
  -- ** Built-in contexts
  basic,
  libc,
) where

import Language.Rust.Inline.Context 
import Language.Rust.Inline.Internal
import Language.Rust.Inline.Parser
import Language.Rust.Inline.Pretty

import Language.Haskell.TH.Syntax
import Language.Haskell.TH.Quote               ( QuasiQuoter(..) )

import Control.Monad                           ( void )
import Data.List                               ( intercalate )
import Data.Traversable                        ( for )


-- $quasiquoters
--
-- Rust is (like Haskell) an expression based language, so it is sufficient to
-- make quasiquoters for expressions only. Note that `{ <stmt>; ... }` is a
-- valid Rust block expression.
--
-- As Rust does not distinguish between pure and impure expressions, it is
-- entirely up to the user of this library to use the correct quasiquoter.
-- Quasiquoters with `IO` are meant for impure expressions and the rest are for
-- pure expressions. Incorrectly annotating an impure expression as pure will
-- /not/ cause a compile-time error but may break type safety and referential
-- transparency.


-- $safe
--
-- Safe quasiquoters are the most simple ones. When in doubt and not overly in
-- need of performance, use these.

-- | Safe and pure expression quasiquoter. It is up the user to make sure the
-- Rust expression they use is pure.
--
-- @
--     rustInc x :: Int32 -> Int32
--     rustInc x = [rust| i32 { 1i32 + $(x: i32) } |]
-- @ 
rust :: QuasiQuoter
rust = rustQuasiQuoter Safe True

-- | Safe and impure expression quasiquoter.
--
-- @
--     rustHello :: Int32 -> IO ()
--     rustHello n = [rustIO| () { println!("Your number: {}", $(n: i32)) } |]
-- @ 
rustIO :: QuasiQuoter
rustIO = rustQuasiQuoter Safe False


-- $unsafe
--
-- Unsafe quasiquoters have less overhead than safe ones, but they can have
-- problems if the Rust expression calls back into the Haskell runtime or
-- if the Rust expression blocks indefinitely.
--
-- This [wiki page](wiki.haskell.org/Foreign_Function_Interface#Unsafe_calls)
-- and the [Haskell Report](www.haskell.org/definition/haskell2010.pdf) section
-- on "Import Declarations" detail the caveats of `unsafe`.

-- | Unsafe but pure expression quasiquoter. It is up the user to make sure the
-- Rust expression they use is pure, doesn't block, and doesn't call
-- back into the Haskell runtime.
--
-- Faster, but use with caution.
rustUnsafe :: QuasiQuoter
rustUnsafe = rustQuasiQuoter Unsafe True

-- | Unsafe and impure expression quasiquoter. It is up the user to make sure
-- the Rust expression they use doesn't block and doesn't call back into the
-- Haskell runtime.
--
-- Faster, but use with caution.
rustUnsafeIO :: QuasiQuoter
rustUnsafeIO = rustQuasiQuoter Unsafe False


-- $interruptible
--
-- Interruptible quasiquoters are slightly stronger (and slower) than safe ones:
-- they additionally try to make the foreign call promptly return when a
-- 'throwTo' is directed at a thread making the call.
--
-- The [GHC Docs](downloads.haskell.org/~ghc/latest/docs/html/users_guide/ffi-chap.html#interruptible-foreign-calls)
-- detail the behaviour of 'interruptible'.

-- | Interrupt and pure expression quasiquoter. It is up the user to make sure the
-- Rust expression they use is pure.
--
-- Slower, but safer around exception-heavy code.
rustInterruptible :: QuasiQuoter
rustInterruptible = rustQuasiQuoter Interruptible True

-- | Interrupt and impure expression quasiquoter.
--
-- Slower, but safer around exception-heavy code.
rustInterruptibleIO :: QuasiQuoter
rustInterruptibleIO = rustQuasiQuoter Interruptible False


-- | Make an expression quasiquoter. This packages together the work of parsing
-- the quasiquote contents, generating Haskell FFI bindings, generating and
-- compiling Rust source, then linking in the Rust object file.
rustQuasiQuoter :: Safety -> Bool -> QuasiQuoter
rustQuasiQuoter safety isPure = QuasiQuoter { quoteExp = expQuoter
                                            , quotePat = err 
                                            , quoteType = err
                                            , quoteDec = err 
                                            }
  where
    err = fail "(inline-rust): Only expressions can be quasiquoted"

    expQuoter qq = do
      parsed <- parseQQ qq
      processQQ safety isPure parsed


-- | This function sums up the packages. What it does:
--
--    1. Map the Rust type annotations in the quasiquote to their Haskell types.
--
--    2. Generate a Haskell FFI signature for passing all the captured Haskell
--       variables to Rust.
--
--    3. Generate a Rust function compatible with the Haskell FFI, and emit it
--       to a temporary file (the same file is kept for the whole module)
--
--    4. Generate and return a Haskell call to this function, slotting in the
--       right Haskell arguments.
--
processQQ :: Safety -> Bool -> RustQuasiquoteParse -> Q Exp
processQQ safety isPure (QQParse rustRet rustBody rustArgs) = do

  -- Make a name to thread through Haskell/Rust (see Trac #13054)
  qqName' <- newName "quasiquote"
  qqName <- newName (show qqName')
  let qqStrName = show qqName

  -- Find out what the corresponding Haskell representations are for the
  -- argument and return types
  haskRet <- lookupType (void rustRet)
  haskArgs <- traverse (\(_, rustArg) -> lookupType (void rustArg)) rustArgs

  -- Generate the Haskell FFI import declaration and emit it
  haskSig <- foldr (\l r -> [t| $(pure l) -> $r |])
                   (if isPure then pure haskRet else [t| IO $(pure haskRet) |])
                   haskArgs
  let ffiImport = ForeignD (ImportF CCall safety qqStrName qqName haskSig)
  addTopDecls [ffiImport]

  -- Generate the Haskell FFI call
  haskArgsE <- for rustArgs $ \(argStr, _) -> do 
                 arg <- lookupValueName argStr
                 case arg of
                   Nothing -> fail ("could not find Haskell variable `" ++ argStr ++ "'")
                   Just argName -> pure (VarE argName)
  let haskCall = foldl AppE (VarE qqName) haskArgsE

  -- Generate the Rust function
  void . emitCodeBlock . unlines $
    [ "#[no_mangle]"
    , "pub extern \"C\" fn " ++ qqStrName ++ "("
    , intercalate ", " (map (\(s,t) -> s ++ ": " ++ renderType t) rustArgs)
    , ") -> " ++ renderType rustRet
    , renderTokens rustBody
    ]

  -- Return the Haskell call to the FFI import
  pure haskCall



