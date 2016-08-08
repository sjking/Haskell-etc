{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}
module Main where

import UB.Prelude
import qualified UB.Internal.Config.Unresolved.Test as Unresolved
import Test.Tasty (defaultMain)

main :: IO ()
main = defaultMain Unresolved.tests