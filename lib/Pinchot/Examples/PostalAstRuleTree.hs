{-# LANGUAGE TemplateHaskell #-}
module Pinchot.Examples.PostalAstRuleTree where

import Pinchot
import Pinchot.Examples.Postal

ruleTreeToCode ''Char postal
