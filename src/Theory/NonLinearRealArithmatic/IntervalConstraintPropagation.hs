{-|
  We are given a list of non-linear real constraints and an 
  interval domain for each variable that appears in one of the constraints. 
  Intervals over-approximate the variable domains. The goal is to
  contract these intervals as much as possible to improve the approximations.

  For each constraint, such as

    x^2 * y - 3.5 + x < 0

  and a variable in that constraint, like `x`, we solve the expression 
  for `x`. In general this is not possible for non-linear expressions, 
  but we can workaround it by introducing fresh variables for each 
  non-linear term:

    h = x^2 * y        <==>   x = +/- sqrt(h/y)

    h - 3.5 + x < 0    <==>   x < 3.5 - h

  Now for each constraint, we substitute each variable on the right-hand-side 
  with it's interval domain and evaluate the expression with interval 
  arithmatic. That yields new (potentially tighter) bounds for `x`.
  We repeat with other constraint/variable pairs. Since that might contract the bounds
  for variables, that `x` depends on, we can iterate and derive even 
  tighter bounds for `x`. This method is not guaranteed to narrow the bounds
  down to point intervals, but if we obtain an empty interval, we showed unsatisfiability.
  Otherwise, we stop if convergence is less some threshold.

  TODO: Also implement Newton constraction method

-}
module Theory.NonLinearRealArithmatic.IntervalConstraintPropagation  ( intervalConstraintPropagation ) where

import Theory.NonLinearRealArithmatic.Interval ( Interval ((:..:)) )
import qualified Theory.NonLinearRealArithmatic.Interval as Interval
import Theory.NonLinearRealArithmatic.Polynomial ( Polynomial, Term(Term), Monomial, exponentOf, mkPolynomial, Assignment, Assignable (eval, evalTerm) )
import qualified Theory.NonLinearRealArithmatic.Polynomial as Polynomial
import qualified Data.IntMap as M
import qualified Data.Map.Lazy as LazyMap
import qualified Data.List as List
import Control.Monad.State ( State )
import qualified Control.Monad.State as State
import Data.Containers.ListUtils ( nubOrd )
import Theory.NonLinearRealArithmatic.IntervalUnion (IntervalUnion (IntervalUnion))
import qualified Theory.NonLinearRealArithmatic.IntervalUnion as IntervalUnion
import Theory.NonLinearRealArithmatic.BoundedFloating (BoundedFloating (Val))
import Theory.NonLinearRealArithmatic.Expr (Var)
import Theory.NonLinearRealArithmatic.Constraint (Constraint, ConstraintRelation (..), varsIn)

type PreprocessState a = (Var, [Constraint a], Assignment (IntervalUnion a))

-- |
preprocess :: forall a. (Num a, Ord a, Bounded a) => Assignment (IntervalUnion a) -> [Constraint a] -> (Assignment (IntervalUnion a), [Constraint a])
preprocess initial_var_domains initial_constraints = (updated_var_domains, updated_constraints <> side_conditions)
  where
    preprocess_term :: Term a -> State (PreprocessState a) (Term a)
    preprocess_term (Term coeff monomial) =
      if Polynomial.isLinear monomial then
        return (Term coeff monomial)
      else do
        -- We map non-linear terms, say `x^2`, to fresh variables, say `h`
        (fresh_var, side_conditions, var_domains) <- State.get

        let fresh_term = Term 1 (M.singleton fresh_var 1)

        -- and create a new constraint that demands their equality, i.e.
        -- 
        --     h = x^2   <==>   0 = h - x^2
        --
        let new_side_condition :: Constraint a
            new_side_condition = (Equals, mkPolynomial [ fresh_term, Term (-coeff) monomial ] )

        -- Then we initialize the domain of the new variable by evaluating x^2
        -- via interval arithmatic (since h = x^2).
        let fresh_var_domain :: IntervalUnion a
            fresh_var_domain = eval var_domains (mkPolynomial [ Term (IntervalUnion.singleton coeff) monomial ])

        State.put
          ( fresh_var + 1
          , new_side_condition : side_conditions
          , M.insert fresh_var fresh_var_domain var_domains
          )

        return fresh_term

    preprocess_constraint :: Constraint a -> State (PreprocessState a) (Constraint a)
    preprocess_constraint (rel, polynomial) = do
      updated_terms <- mapM preprocess_term (Polynomial.getTerms polynomial)
      return (rel, mkPolynomial updated_terms)

    -- Identify the largest used variable ID, so we can generate fresh variables by just incrementing.
    max_var = maximum $ varsIn initial_constraints

    -- During the preprocessing step we introduce fresh variables, so we need keep track of the next fresh 
    -- variable and keep updating the variables domains. We also generate side conditions in the form of 
    -- additional equality constraints that we need to keep track of.
    initial_state :: PreprocessState a
    initial_state = (max_var + 1, [], initial_var_domains)

    (updated_constraints, final_state) = State.runState (mapM preprocess_constraint initial_constraints) initial_state
    (_, side_conditions, updated_var_domains) = final_state

{-|
  Take a constraint such as
   
    x^2 - 3y + 10 < 0 

  Bring eveything to one side, except one the variable that we solve for, and flip the constraint relation if necessary:

    y > (x^2 + 10) / 3

  and evaluate the right-hand-side. It's assumed that the constraint 
  has been preprocessed before. Otherwise it's not possible, in general, 
  to solve for any variable.
-}
solveFor :: (Ord a, Num a, Bounded a, Floating a) => Var -> Constraint a -> Assignment (IntervalUnion a) -> (ConstraintRelation, IntervalUnion a)
solveFor var (rel, polynomial) var_domains =
  let
    Just (Term coeff monomial, rest_terms) = Polynomial.extractTerm var polynomial

    -- bring all other terms to the right-and-side
    rhs_terms = eval var_domains
      $ mkPolynomial (fmap (IntervalUnion.singleton . negate) <$> rest_terms)

    -- extract remaining coefficients of `var`
    divisor = evalTerm var_domains
      $ Term (IntervalUnion.singleton coeff) (M.delete var monomial)

    flip_relation :: ConstraintRelation -> ConstraintRelation
    flip_relation = \case
      Equals -> Equals
      GreaterThan -> LessThan
      GreaterEquals -> LessEquals
      LessThan -> GreaterThan
      LessEquals -> GreaterEquals

    relation :: ConstraintRelation
    relation
      | signum coeff == -1 = flip_relation rel
      | otherwise          = rel

    is_zero (IntervalUnion [ 0 :..: 0 ]) = True
    is_zero _ = False

    solution
      | is_zero divisor && relation `elem` [LessEquals, Equals, GreaterEquals] = var_domains M.! var
      | is_zero divisor && relation `elem` [LessThan, GreaterThan] = IntervalUnion.empty
      | otherwise = IntervalUnion.root (rhs_terms / divisor) (exponentOf var monomial)
  in
    (relation, solution)

type ContractionCandidate a = (Constraint a, Var)

type WeightedContractionCandidates a = LazyMap.Map a [ContractionCandidate a]

{-|
  Contraction is performed using a constraint and a variable that appears in that constraint. 
  Such a constraint/variable pair is called a constraction candidate. The number of choices
  for contraction candidates is potentially large and the contraction gain is generally not 
  predictable, so we choose contraction candidates heuristically: We assign a weight between 
  0 and 1 to each contraction candidate (initially 0.1) and always pick the candidate with 
  the highest weight. After contracting, we compute the relative contraction, that was achieved, 
  and update the weight of the contraction candidate. 

  The contraction candidates are stored in a Map from weights to lists of contraction 
  candidates (all with the same weight). Note that the Map is strict in the keys but lazy in the 
  values, so we may never compute the full list of contraction candidates.
-}
chooseContractionCandidate :: Ord a => State (WeightedContractionCandidates a) (a, ContractionCandidate a)
chooseContractionCandidate = do
  candidates <- State.get
  case LazyMap.maxViewWithKey candidates of
    Just ((_, []), candidates') -> do
      -- maximum weight has no candidates associated anymore, so clean up and choose again
      State.put candidates'
      chooseContractionCandidate
    Just ((weight, cc : ccs), candidates') -> do
      -- Maximum weight has one or more candidates associated with it, so pick the first one 
      -- and put the rest pack into the Map.
      State.put (LazyMap.insert weight ccs candidates')
      return (weight, cc)
    Nothing ->
      -- This should not happen. The set of contraction candidates should always be the same.
      -- Although we extract them above, they must be put back into the Map with updated weights.
      error "no contraction candidates"

contractWith :: forall a. (Num a, Ord a, Floating a, Bounded a, Show a) => ContractionCandidate a -> Assignment (IntervalUnion a) -> IntervalUnion a
contractWith (constraint, var) var_domains = new_domain
  where
    (relation, solution) = solveFor var constraint var_domains

    restrictWith :: Interval a -> Interval a -> Interval a
    restrictWith (lower_bound :..: upper_bound) (lower_bound' :..: upper_bound') =
      case relation of
        Equals        -> max lower_bound lower_bound' :..: min upper_bound upper_bound'
        LessEquals    -> lower_bound :..: min upper_bound upper_bound'
        GreaterEquals -> max lower_bound lower_bound' :..: upper_bound
        LessThan 
          | lower_bound >= upper_bound' -> Interval.empty
          | otherwise                   -> lower_bound :..: min upper_bound upper_bound'
        GreaterThan 
          | upper_bound <= lower_bound' -> Interval.empty
          | otherwise                   -> max lower_bound lower_bound' :..: upper_bound

    old_domain = var_domains M.! var
    new_domain = IntervalUnion.reduce $ IntervalUnion $ do
      interval  <- IntervalUnion.getIntervals old_domain
      interval' <- IntervalUnion.getIntervals solution
      return $ interval `restrictWith` interval'           

relativeContraction :: (Num a, Ord a, Fractional a) => IntervalUnion a -> IntervalUnion a -> a
relativeContraction old_domain new_domain
  | old_diameter == 0 = 0
  | otherwise         = (old_diameter - new_diameter) / old_diameter
  where
    old_diameter = IntervalUnion.diameter old_domain
    new_diameter = IntervalUnion.diameter new_domain

{-|

  TODO: 

  1) ICP does not behave well on linear constraints. 
     Partition constraints into linear and non-linear,
     and solve the linear constraints with simplex.

  2) splitting intervals can help with contraction, if 
     the interval contains multiple roots, so split if
     this can be detected

  3) Terminate based on some measure of slow down of convergence
     instead of just doing a fixed number of iterations.

  4) Initial weight of 0.1 is a magic number. Pick something  
     more principled.

-}
intervalConstraintPropagation :: forall a. (Num a, Ord a, Bounded a, Floating a, Show a) => [Constraint a] -> Assignment (IntervalUnion a) -> Assignment (IntervalUnion a)
intervalConstraintPropagation [] domains0 = domains0
intervalConstraintPropagation constraints0 domains0 
  | null (varsIn constraints0) = domains0
  | otherwise                  = last $ take 10 iterations
  where
    (domains1, constraints1) = preprocess domains0 constraints0

    contraction_candidates :: WeightedContractionCandidates a
    contraction_candidates = LazyMap.singleton 0.1 $ do
      constraint <- constraints1
      var <- varsIn [ constraint ]
      return (constraint, var)

    iterations = State.evalState (go domains1) contraction_candidates 

    go :: Assignment (IntervalUnion a) -> State (WeightedContractionCandidates a) [Assignment (IntervalUnion a)]
    go domains = do
      (old_weight, (constraint, var)) <- chooseContractionCandidate

      let old_domain = domains M.! var
          new_domain = contractWith (constraint, var) domains
          new_weight = relativeContraction old_domain new_domain

      State.modify (LazyMap.insertWith (<>) new_weight [(constraint, var)])

      let domains' = M.insert var new_domain domains
          
      -- If variable domain was contracted to an empty interval, it shows that the 
      -- constraints are unsatisfiable. 
      if IntervalUnion.isEmpty new_domain then
        return [ domains' ]
      else
        (domains :) <$> go domains'


--------------------------------------------------------

example1 =
  let
    -- x0^2 * x1^2
    terms = [ Polynomial.Term (Val 1.0) $ M.fromList [(0, 2), (1, 2)] ]

    constraint = (Equals, mkPolynomial terms)

    dom = IntervalUnion [ Val (-1) :..: Val 1 ]

    domains_before = M.fromList [ (0, dom), (1, dom) ]
    domains_after = intervalConstraintPropagation [ constraint ] domains_before
  in 
    domains_after

example2 = 
  let
    -- 0.13883655 - x0
    terms = [ Term (-1) (M.fromList [ (0,1) ]), Term 0.13883655 M.empty ]

    constraint = (Equals, mkPolynomial terms)

    dom = IntervalUnion [ Val (-1) :..: Val 1 ]

    domains_before = M.fromList [ (0, dom) ]
    domains_after = intervalConstraintPropagation [ constraint ] domains_before
  in 
    domains_after

example3 = 
  let
    -- -x0 + 2x1^2 - 3x1 + 2
    terms = 
      [ Term (-1) (M.singleton 0 1)
      , Term 2 (M.singleton 1 2)
      , Term (-3) (M.singleton 1 1)
      , Term 2 M.empty ]

    constraint = (Equals, mkPolynomial terms)

    dom_x0 = IntervalUnion [ Val (-5) :..: Val 17 ]
    dom_x1 = IntervalUnion [ Val (-5) :..: Val 5 ]

    domains_before = M.fromList [ (0, dom_x0), (1, dom_x1) ]
    domains_after = intervalConstraintPropagation [ constraint ] domains_before
  in 
    domains_after

example4 =
  let
    -- 17x + 33x + x^2 + 561
    terms = 
      [ Term 17 (M.singleton 0 1)
      , Term 33 (M.singleton 0 1)
      , Term 1 (M.singleton 0 2)
      , Term 561 M.empty ]

    -- roots: -33, -17

    constraint = (Equals, mkPolynomial terms)

    dom_x = IntervalUnion [ Val (-34) :..: Val (-16) ]

    domains_before = M.fromList [ (0, dom_x) ]
    domains_after = intervalConstraintPropagation [ constraint ] domains_before
  in 
    domains_after

example5 =
  let
    -- x * y = 0
    terms = 
      [ Term 1 (M.fromList [(0,1), (1,1)]) ]

    constraint = (Equals, mkPolynomial terms)

    dom = IntervalUnion [ Val (-1) :..: Val 1 ]

    domains_before = M.fromList [ (0, dom), (1, dom) ]
    domains_after = intervalConstraintPropagation [ constraint ] domains_before
  in 
    domains_after

example6 =         
  let 
    terms = 
      [ Term (-0.40836024) $ M.fromList [ (0,2),(3,1),(4,2),(5,2),(7,1),(8,2) ]
      , Term (-3.9482565) $ M.fromList [(2,1)]
      , Term (-5.6101594) $ M.fromList [(3,2),(5,2),(9,2),(1,2) ]
      ]

    constraint = (LessThan, Polynomial.mkPolynomial terms)

    dom = IntervalUnion [ Val (-2) :..: Val 2 ]

    domains_before = M.fromList $ zip (varsIn [constraint]) (repeat dom)
    domains_after = intervalConstraintPropagation [ constraint ] domains_before
  in 
    domains_after
