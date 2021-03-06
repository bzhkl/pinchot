{-# OPTIONS_HADDOCK not-home #-}
{-# LANGUAGE TemplateHaskell #-}
module Pinchot.Terminalize where

import Control.Monad (join)
import Data.List.NonEmpty (NonEmpty((:|)), toList)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Foldable (foldlM)
import Data.Map (Map)
import qualified Data.Map as Map
import qualified Language.Haskell.TH as T

import Pinchot.Names
import Pinchot.Types
import Pinchot.Rules

-- | For all the given rules and their ancestors, creates
-- declarations that reduce the rule and all its ancestors to
-- terminal symbols.  Each rule gets a declaration named
-- @t'RULE_NAME@ where @RULE_NAME@ is the name of the rule.  The
-- type of the declaration is either
--
-- Production a -> [(t, a)]
--
-- or
--
-- Production a -> NonEmpty (t, a)
--
-- where @Production@ is the production corresponding to the given
-- 'Rule', @t@ is the terminal token type (often 'Char'), and @a@ is
-- arbitrary metadata about each token (often 'Loc').  'NonEmpty' is
-- returned for productions that must always contain at least one
-- terminal symbol; for those that can be empty, 'Seq' is returned.
--
-- Example: "Pinchot.Examples.Terminalize".
terminalizers
  :: Qualifier
  -- ^ Qualifier for the module containing the data types created
  -- from the 'Rule's
 
  -> [Rule t]
  -> T.Q [T.Dec]

terminalizers qual
  = fmap concat
  . traverse (terminalizer qual)
  . families

-- | For the given rule, creates declarations that reduce the rule
-- to terminal symbols.  No ancestors are handled.  Each rule gets a
-- declaration named @t'RULE_NAME@ where @RULE_NAME@ is the name of
-- the rule.  The
-- type of the declaration is either
--
-- Production a -> [(t, a)]
--
-- or
--
-- Production a -> NonEmpty (t, a)
--
-- where @Production@ is the production corresponding to the given
-- 'Rule', @t@ is the terminal token type (often 'Char'), and @a@ is
-- arbitrary metadata about each token (often 'Loc').  'NonEmpty' is
-- returned for productions that must always contain at least one
-- terminal symbol; for those that can be empty, 'Seq' is returned.

terminalizer
  :: Qualifier
  -- ^ Qualifier for the module containing the data types created
  -- from the 'Rule's
 
  -> Rule t
  -> T.Q [T.Dec]

terminalizer qual rule@(Rule nm _ _) = sequence [sig, expn]
  where
    declName = "t'" ++ nm
    anyType = T.varT (T.mkName "a")
    charType = T.varT (T.mkName "t")
    sig
      | atLeastOne rule = do
          ctorName <- lookupTypeName (quald qual nm)
          T.sigD (T.mkName declName)
            . T.forallT [tyVarBndrT , tyVarBndrA ] (return [])
            $ [t| $(T.conT ctorName) $(charType) $(anyType)
              -> NonEmpty ($(charType), $(anyType)) |]
      | otherwise = do
          ctorName <- lookupTypeName (quald qual nm)
          T.sigD (T.mkName declName)
            . T.forallT [ tyVarBndrT , tyVarBndrA ] (return [])
            $ [t| $(T.conT ctorName) $(charType) $(anyType)
                -> [($(charType), $(anyType))] |]
    expn = T.valD (T.varP $ T.mkName declName)
      (T.normalB (terminalizeRuleExp qual rule)) []

-- | For the given rule, returns an expression that has type of
-- either
--
-- Production a -> [(t, a)]
--
-- or
--
-- Production a -> NonEmpty (t, a)
--
-- where @Production@ is the production corresponding to the given
-- 'Rule', and @t@ is the terminal token type.  'NonEmpty' is
-- returned for productions that must always contain at least one
-- terminal symbol; for those that can be empty, 'Seq' is returned.
--
-- Example:  'Pinchot.Examples.Terminalize.terminalizeAddress'.
terminalizeRuleExp
  :: Qualifier
  -> Rule t
  -> T.Q T.Exp
terminalizeRuleExp qual rule@(Rule nm _ _) = do
  let allRules = family rule 
  lkp <- ruleLookupMap allRules
  let mkDec r@(Rule rn _ _) =
        let expn = terminalizeSingleRule qual lkp r
            decName = lookupName lkp rn
        in T.valD (T.varP decName) (T.normalB expn) []
  T.letE (fmap mkDec $ allRules) (T.varE (lookupName lkp nm))

-- | Creates a 'Map' where each key is the name of the 'Rule' and
-- each value is a name corresponding to that 'Rule'.  No
-- ancestors are used.
ruleLookupMap
  :: Foldable c
  => c (Rule t)
  -> T.Q (Map RuleName (T.Name))
ruleLookupMap = foldlM f Map.empty
  where
    f mp (Rule nm _ _) = do
      name <- T.newName $ "rule" ++ nm
      return $ Map.insert nm name mp

lookupName
  :: Map RuleName T.Name
  -> RuleName
  -> T.Name
lookupName lkp n = case Map.lookup n lkp of
  Nothing -> error $ "lookupName: name not found: " ++ n
  Just r -> r

-- | For the given rule, returns an expression that has type
-- of either
--
-- Production a -> [(t, a)]
--
-- or
--
-- Production a -> NonEmpty (t, a)
--
-- where @Production@ is the production corresponding to the given
-- 'Rule', and @t@ is the terminal token type.  'NonEmpty' is
-- returned for productions that must always contain at least one
-- terminal symbol; for those that can be empty, 'Seq' is returned.
-- Gets no ancestors.
terminalizeSingleRule
  :: Qualifier
  -- ^ Module qualifier for module containing the generated types
  -- corresponding to all 'Rule's
  -> Map RuleName T.Name
  -- ^ For a given Rule, looks up the name of the expression that
  -- will terminalize that rule.
  -> Rule t
  -> T.Q T.Exp
terminalizeSingleRule qual lkp rule@(Rule nm _ ty) = case ty of
  Terminal _ -> do
    x <- T.newName "x"
    ctorName <- lookupValueName (quald qual nm)
    let pat = T.conP ctorName [T.varP x]
    [| \ $(pat) -> ( $(T.varE x) :| [] ) |]

  NonTerminal bs -> do
    x <- T.newName "x"
    let fTzn | atLeastOne rule = terminalizeProductAtLeastOne
             | otherwise = terminalizeProductAllowsZero
        tzr (Branch name sq)
          = fmap (\(pat, expn) -> T.match pat (T.normalB expn) [])
          (fTzn qual lkp name sq)
    ms <- traverse tzr . toList $ bs
    T.lamE [T.varP x] (T.caseE (T.varE x) ms)

  Wrap (Rule inner _ _) -> do
    x <- T.newName "x"
    ctorName <- lookupValueName (quald qual nm)
    let pat = T.conP ctorName [T.varP x]
    [| \ $(pat) -> $(T.varE (lookupName lkp inner)) $(T.varE x) |]

  Record rs -> do
    (pat, expn) <- fTzr qual lkp nm rs
    [| \ $(pat) -> $(expn) |]
    where
      fTzr | atLeastOne rule = terminalizeProductAtLeastOne
           | otherwise = terminalizeProductAllowsZero

  Opt r@(Rule inner _ _) -> do
    x <- T.newName "x"
    ctorName <- lookupValueName (quald qual nm)
    let pat = T.conP ctorName [T.varP x]
    [| \ $(pat) -> maybe [] 
          $(convert (T.varE (lookupName lkp inner))) $(T.varE x) |]
    where
      convert expn | atLeastOne r = [| NonEmpty.toList . $(expn) |]
                   | otherwise = expn

  Star r@(Rule inner _ _) -> do
    x <- T.newName "x"
    ctorName <- lookupValueName (quald qual nm)
    let pat = T.conP ctorName [T.varP x]
        convert e | atLeastOne r = [| NonEmpty.toList . $(e) |]
                  | otherwise = e
    [| \ $(pat) -> join . fmap $(convert (T.varE (lookupName lkp inner)))
          $ $(T.varE x) |]

  Plus r@(Rule inner _ _)
    | atLeastOne r -> do
        x <- T.newName "x"
        ctorName <- lookupValueName (quald qual nm)
        let pat = T.conP ctorName [T.varP x]
        [| \ $(pat) ->
            let getTermNonEmpty = $(T.varE (lookupName lkp inner))
                getTerms (e1 :| es)
                  = join . fmap getTermNonEmpty
                  $ (e1 :| es)
           in getTerms $(T.varE x)
          |]

    | otherwise -> do
        x <- T.newName "x"
        [| let getTermSeq = $(T.varE (lookupName lkp inner))
               getTerms (e1 :| es) = getTermSeq e1
                `mappend` (join (fmap getTermSeq es))
           in getTerms $(T.varE x)
          |]

  Series _ -> do
    x <- T.newName "x"
    ctorName <- lookupValueName (quald qual nm)
    let pat = T.conP ctorName [T.varP x]
    [| \ $(pat) -> $(T.varE x) |]

terminalizeProductAllowsZero
  :: Qualifier
  -> Map RuleName T.Name
  -> String
  -- ^ Rule name or branch name, as applicable
  -> [Rule t]
  -> T.Q (T.PatQ, T.ExpQ)
terminalizeProductAllowsZero qual lkp name bs = do
  pairs <- traverse (terminalizeProductRule lkp) $ bs
  ctorName <- lookupValueName (quald qual name)
  let pat = T.conP ctorName (fmap (fst . snd) pairs)
      body = case pairs of
        [] -> [| [] |]
        x:xs -> foldl f start xs
          where
            f acc trip = [| $(acc) `mappend` $(procTrip trip) |]
            start = procTrip x
            procTrip (rule, (_, expn))
              | atLeastOne rule = [| NonEmpty.toList $(expn) |]
              | otherwise = expn
  return (pat, body)

prependList :: [a] -> NonEmpty a -> NonEmpty a
prependList [] ne = ne
prependList (x:xs) (a :| as) = (x :| (xs ++ (a : as)))

appendList :: NonEmpty a -> [a] -> NonEmpty a
appendList (a :| as) xs = a :| (as ++ xs)

terminalizeProductAtLeastOne
  :: Qualifier
  -> Map RuleName T.Name
  -> String
  -- ^ Rule name or branch name, as applicable
  -> [Rule t]
  -> T.Q (T.PatQ, T.ExpQ)
terminalizeProductAtLeastOne qual lkp name bs = do
  pairs <- traverse (terminalizeProductRule lkp) $ bs
  ctorName <- lookupValueName (quald qual name)
  let pat = T.conP ctorName (fmap (fst . snd) pairs)
      body = [| ( $(leadSeq) `prependList` $(firstNonEmpty))
                `appendList` $(trailSeq) |]
        where
          (leadRules, lastRules) = span (not . atLeastOne . fst) pairs
          (firstNonEmptyRule, trailRules) = case lastRules of
            [] -> error $ "terminalizeProductAtLeastOne: failure 1: " ++ name
            x:xs -> (x, xs)
          leadSeq = case fmap (snd . snd) leadRules of
            [] -> [| [] |]
            x:xs -> foldl f x xs
              where
                f acc expn = [| $(acc) `mappend` $(expn) |]
          firstNonEmpty = [| $(snd . snd $ firstNonEmptyRule) |]

          trailSeq = foldl f [| [] |] trailRules
            where
              f acc (rule, (_, expn))
                | atLeastOne rule =
                    [| $(acc) `mappend` NonEmpty.toList $(expn) |]
                | otherwise =
                    [| $(acc) `mappend` $(expn) |]
  return (pat, body)

terminalizeProductRule
  :: Map RuleName T.Name
  -> Rule t
  -> T.Q (Rule t, (T.Q T.Pat, T.Q T.Exp))
terminalizeProductRule lkp r@(Rule nm _ _) = do
  x <- T.newName $ "terminalizeProductRule'" ++ nm
  let getTerms = [| $(T.varE (lookupName lkp nm)) $(T.varE x) |]
  return (r, (T.varP x, getTerms))

-- | Examines a rule to determine whether when terminalizing it will
-- always return at least one terminal symbol.
atLeastOne
  :: Rule t
  -> Bool
  -- ^ True if the rule will always have at least one terminal
  -- symbol.
atLeastOne (Rule _ _ ty) = case ty of
  Terminal _ -> True
  NonTerminal bs -> all branchAtLeastOne bs
    where
      branchAtLeastOne (Branch _ rs) = any atLeastOne rs
  Wrap r -> atLeastOne r
  Record rs -> any atLeastOne rs
  Opt _ -> False
  Star _ -> False
  Plus r -> atLeastOne r
  Series _ -> True

