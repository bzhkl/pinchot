{-# OPTIONS_HADDOCK not-home #-}
{-# LANGUAGE TemplateHaskell #-}
-- | Creating Earley parsers.

module Pinchot.Earley where

import Pinchot.Names
import Pinchot.RecursiveDo
import Pinchot.Rules
import Pinchot.Types

import Control.Applicative ((<|>), liftA2)
import Data.Data (Data)
import Data.Foldable (foldlM)
import Data.List.NonEmpty (NonEmpty((:|)))
import qualified Language.Haskell.TH as T
import qualified Language.Haskell.TH.Syntax as Syntax
import qualified Text.Earley

earleyTerm
  :: Eq t
  => NonEmpty t
  -> Text.Earley.Prod r e (t, a) (NonEmpty (t, a))
earleyTerm (fore :| aft) = (:|) <$> parseHead <*> parseRest
  where
    parseHead = parse fore
    parseRest = foldr (liftA2 (:) . parse) (pure []) aft
    parse t = Text.Earley.satisfy ((== t) . fst)

branchToParser
  :: Syntax.Lift t
  => String
  -- ^ Module prefix
  -> Branch t
  -> Namer T.ExpQ
branchToParser prefix (Branch name rules) = do
  case rules of
    [] -> return [| pure $constructor |]
    (Rule rule1 _ _) : xs -> do
      rule1Name <- getName rule1
      let z = [| $constructor <$> $(T.varE rule1Name) |]
          f soFar (Rule rule2 _ _) = do
            rule2Name <- getName rule2
            return [| $soFar <*> $(T.varE rule2Name) |]
      foldlM f z xs
  where
    constructor = do
      ctorName <- lookupValueName (quald prefix name)
      T.conE ctorName

-- | Creates a list of pairs.  Each pair represents a statement in
-- @do@ notation.  The first element of the pair is the name of the
-- variable to which to bind the result of the expression, which is
-- the second element of the pair.

ruleToParser
  :: (Syntax.Lift t, Data t)
  => String
  -- ^ Module prefix
  -> Rule t
  -> Namer [(T.Name, T.ExpQ)]
ruleToParser prefix (Rule nm mayDescription rt) = do
  bindName <- getName nm
  let desc = maybe nm id mayDescription
      makeRule expression = (bindName,
        [|Text.Earley.rule ($expression Text.Earley.<?> desc)|])
      constructor = do
        ctorName <- lookupValueName (quald prefix nm)
        T.conE ctorName
      wrapper wrapRule = [|fmap $constructor $(T.varE wrapRule) |]
  case rt of
    Terminal (Predicate pdct) -> return [makeRule expression]
      where
        expression = do
          ctorName <- lookupValueName (quald prefix nm)
          [| let f (c, a)
                  | $(fmap T.unType pdct) c = Just
                      ($(T.conE ctorName) (c, a))
                  | otherwise = Nothing
            in Text.Earley.terminal f |]

    NonTerminal (b1 :| bs) -> do
      let addBranch tree branch = do
            branchParserExpn <- branchToParser prefix branch
            return [| $tree <|> $branchParserExpn |]
      branch1 <- branchToParser prefix b1
      expression <- foldlM addBranch branch1 bs
      return [makeRule expression]

    Wrap (Rule innerNm _ _) -> do
      innerName <- getName innerNm
      let expression = [| fmap $constructor $(T.varE innerName) |]
      return [makeRule expression]

    Record sq -> do
      expression <- case sq of
        [] -> return [| pure $constructor |]
        Rule r1 _ _ : restFields -> do
          r1Name <- getName r1
          let fstField = [| $constructor <$> $(T.varE r1Name) |]
              addField soFar (Rule r _ _) = do
                rName <- getName r
                return [| $soFar <*> $(T.varE rName) |]
          foldlM addField fstField restFields
      return [makeRule expression]

    Opt (Rule innerNm _ _) -> do
      innerName <- getName innerNm
      let just = [| fmap Just $(T.varE innerName) |]
          expression = [| fmap $constructor (pure Nothing <|> $(just)) |]
      return [makeRule expression]

    Star (Rule innerNm _ _) -> do
      innerName <- getName innerNm
      helperName <- namerNewName
      let pList = [| liftA2 (:) $(T.varE innerName) $(T.varE helperName) |]
          pChoose = T.uInfixE [|pure []|] [|(<|>)|] pList
          nestRule = (helperName, ([|Text.Earley.rule|] `T.appE` pChoose))
      return [nestRule, makeRule (wrapper helperName)]

    Plus (Rule innerNm _ _) -> do
      innerName <- getName innerNm
      helperName <- namerNewName
      let pList = [| (:) <$> $(T.varE innerName) <*> $(T.varE helperName) |]
          pChoose = [| pure [] <|> $pList |]
          nestRule = (helperName, [|Text.Earley.rule $pChoose |])
          topExpn = [| $constructor <$>
            ( (:|) <$> $(T.varE innerName) <*> $(T.varE helperName)) |]
      return [nestRule, makeRule topExpn]

    Series neSeq -> do
      let expn = [| fmap $constructor $ earleyTerm $(Syntax.liftData neSeq) |]
      return [makeRule expn]


-- | Creates an expression that has type
--
-- 'Text.Earley.Grammar' r (Prod r String (c, a) (p c a))
--
-- where @r@ is left universally quantified; @c@ is the terminal
-- type (often 'Char'), @a@ is arbitrary metadata about each token
-- (often 'Loc') and @p@ is the data type corresponding to
-- the given 'Rule'.
--
-- Example:  'Pinchot.Examples.Earley.addressGrammar'.
earleyGrammarFromRule
  :: (Data t, Syntax.Lift t)
  => Qualifier
  -- ^ Module prefix holding the data types created with
  -- 'Pinchot.syntaxTrees'
  -> Rule t
  -- ^ Create a grammar for this 'Rule'
  -> T.Q T.Exp
earleyGrammarFromRule prefix r@(Rule top _ _) = do
  (binds, topName) <- runNamer $ do
    bnds <- fmap concat . sequence . fmap (ruleToParser prefix) . family $ r
    topN <- getName top
    return (bnds, topN)
  let final = [| return $(T.varE topName) |]
  recursiveDo binds final

-- | Creates a record data type that holds a value of type
--
-- @'Text.Earley.Prod' r 'String' (t, a) (p t a)@
--
-- where
--
-- * @r@ is left universally quantified
--
-- * @t@ is the token type (often 'Char')
--
-- * @a@ is any additional information about each token (often
-- 'Pinchot.Loc')
--
-- * @p@ is the type of the particular production
--
-- This always creates a single product type whose name is
-- @Productions@; currently the name cannot be configured.
--
-- Example: "Pinchot.Examples.AllRulesRecord".
allRulesRecord
  :: Qualifier
  -- ^ Qualifier for data types corresponding to those created from
  -- the 'Rule's
  -> [Rule t]
  -- ^ A record is created that holds a value for each 'Rule'
  -- in the 'Seq', as well as for every ancestor of these 'Rule's.
  -> T.DecsQ
  -- ^ When spliced, this will create a single declaration that is a
  -- record with the name @Productions@.
  --
  -- @a'NAME@
  --
  -- where @NAME@ is the name of the type.  Don't count on these
  -- records being in any particular order.
allRulesRecord prefix ruleSeq
  = sequence [T.dataD (return []) productions
                      tys Nothing [con] (return [])]
  where
    tys = [tyVarBndrR, tyVarBndrT, tyVarBndrA]
    con = T.recC productions
        (fmap mkRecord . families $ ruleSeq)
    mkRecord (Rule ruleNm _ _) = T.varBangType (recordName ruleNm) st
      where
        st = T.bangType (T.bang T.noSourceUnpackedness T.noSourceStrictness) ty
          where
            ty = do
              ctorName <- lookupTypeName (quald prefix ruleNm)
              [t| Text.Earley.Prod $typeR String ($typeT, $typeA)
                      ( $(T.conT ctorName) $typeT $typeA) |]

-- | Creates a 'Text.Earley.Grammar' that contains a
-- 'Text.Earley.Prod' for every given 'Rule' and its ancestors.
-- Example: 'Pinchot.Examples.Earley.addressAllProductions'.
earleyProduct
  :: (Data t, Syntax.Lift t)

  => Qualifier
  -- ^ Qualifier for data types corresponding to those created from
  -- the 'Rule's

  -> Qualifier
  -- ^ Qualifier for the type created with 'allRulesRecord'

  -> [Rule t]
  -- ^ Creates an Earley grammar that contains a 'Text.Earley.Prod'
  -- for each 'Rule' in this list, as well as all the ancestors of
  -- these 'Rule's.

  -> T.ExpQ
  -- ^ When spliced, 'earleyProduct' creates an expression whose
  -- type is @'Text.Earley.Grammar' r (Productions r t a)@, where
  -- @Productions@ is
  -- the type created by 'allRulesRecord'; @r@ is left universally
  -- quantified; @t@ is the token type (often 'Char'), and @a@ is
  -- any additional information about each token (often
  -- 'Pinchot.Loc').
earleyProduct pfxRule pfxRec ruleSeq = do
  (binds, topName) <- runNamer $ do
    let fams = families ruleSeq
    bnds <- fmap concat . sequence . fmap (ruleToParser pfxRule) $ fams
    let allRuleNames = fmap _ruleName fams
    allRuleBindNames <- traverse getName allRuleNames
    let mkRec ruleName bindName = (qualRecordName pfxRec ruleName, T.VarE bindName)
        ruleBindNamePairs = zipWith mkRec allRuleNames allRuleBindNames
        convertPair (str, expn) = do
          nm <- lookupValueName str
          return (nm, expn)
        final = do
          recName <- lookupValueName (quald pfxRec productionsStr)
          [| return $(T.recConE recName (fmap convertPair ruleBindNamePairs)) |]
    return (bnds, final)
  recursiveDo binds topName

