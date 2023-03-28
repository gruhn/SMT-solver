{-|
  The Simplex method is sound, complete, and in pratice efficient for finding solutions
  to sets of linear constraints. All coefficients, bounds, and solutions are of type 
  `Rational` to avoid having to deal with numeric issues at the cost of performance.
-}
module Theory.LinearArithmatic.Simplex (simplex, Assignment, Constraint, ConstraintRelation (..), eval) where

import Control.Monad (guard)
import Data.Bifunctor (bimap)
import qualified Data.IntMap.Strict as M
import qualified Data.IntMap.Merge.Strict as MM
import qualified Data.IntSet as S
import Data.Maybe (fromMaybe, mapMaybe)
import Debug.Trace

type Var = Int

data ConstraintRelation = LessThan | LessEquals | Equals | GreaterEquals | GreaterThan
  deriving (Show)

-- |
-- For example, constraint such as `3x + y <= 3` is represented as:
--
--     (3x+y, LessEquals, 3)
type Constraint = (LinearTerm, ConstraintRelation, Rational)

-- | Map from variable IDs to assigned values
type Assignment = M.IntMap Rational

-- | Map from variable IDs to coefficients
type LinearTerm = M.IntMap Rational

data BoundType = UpperBound | LowerBound
  deriving (Show)

data Tableau = Tableau
  { getBasis :: M.IntMap LinearTerm,
    getBounds :: M.IntMap (BoundType, Rational),
    getAssignment :: Assignment
  }
  deriving (Show)

varsIn :: [Constraint] -> S.IntSet
varsIn constraints = S.unions $ do
  (linear_term, _, _) <- constraints
  return $ M.keysSet linear_term

-- |
--  Transform constraints to "General From" and initialize Simplex tableau.
initTableau :: [Constraint] -> Tableau
initTableau constraints =
  let 
    original_vars = varsIn constraints
    max_original_var = if S.null original_vars then -1 else S.findMax original_vars
    fresh_vars = [max_original_var + 1 ..]

    (basis, bounds) = bimap M.fromList M.fromList $ unzip $ do
      (slack_var, (linear_term, relation, bound)) <- zip fresh_vars constraints

      let bound_type =
            case relation of
              LessEquals -> UpperBound
              GreaterEquals -> LowerBound
              other_rels -> error "TODO: extend Simplex to all constraint relations"

      return
        ( (slack_var, linear_term),
          (slack_var, (bound_type, bound))
        )

    slack_vars = M.keys bounds

    assignment :: Assignment
    assignment =
      M.fromList $
        zip (S.toList original_vars ++ slack_vars) $
          repeat 0
   in 
    Tableau basis bounds assignment

data BoundViolation = MustIncrease | MustDecrease

boundViolation :: Tableau -> Var -> Maybe BoundViolation
boundViolation (Tableau basis bounds assignment) var = do
  let current_value = assignment M.! var
  bound <- M.lookup var bounds
  case bound of 
    (UpperBound, bound_value) ->
      if current_value <= bound_value then
        Nothing
      else 
        Just MustDecrease
    (LowerBound, bound_value) -> do
      if bound_value <= current_value then
        Nothing
      else
        Just MustIncrease

violatedBasicVars :: Tableau -> [(Var, BoundViolation)]
violatedBasicVars tableau = do
  -- Following "Blend's Rule" by enumerating variables in ascending order.
  basic_var <- M.keys $ getBasis tableau
  case boundViolation tableau basic_var of
    Nothing -> []
    Just violation -> [ (basic_var, violation) ]

pivotCandidates :: Tableau -> [(Var, Var)]
pivotCandidates tableau@(Tableau basis bounds assignment) = do
  (basic_var, violation) <- violatedBasicVars tableau

  let term = basis M.! basic_var
      non_basis = M.keysSet assignment S.\\ M.keysSet basis

  non_basic_var <- S.toAscList non_basis

  let non_basic_var_coeff = M.findWithDefault 0 non_basic_var term
      non_basic_bound_type = fst <$> M.lookup non_basic_var bounds
      can_pivot =
        case (non_basic_bound_type, signum non_basic_var_coeff, violation) of
          -- If the coefficient of the non basic variable is 0, then the value of the variable
          -- is not affected by pivoting, so it can't resolve the bound violation.
          (_, 0, _) -> False
          -- If the non-basic variable is not bounded and it's coefficient is non-zero,
          -- then pivot is always possible.
          (Nothing, 1, _) -> True
          (Nothing, -1, _) -> True
          -- The value of the basic variable must be decreased. The coefficient of the non-basic
          -- variable is positive, so we need to decrease it's value. The non-basic variable is
          -- at it's upper bound so decreasing it is possible.
          (Just UpperBound, 1, MustDecrease) -> True
          -- The value of the basic variable must be increased. The coefficient of the non-basic
          -- variable is negative, so we need to decrease it's value. The non-basic variable is
          -- at it's upper bound so decreasing it is possible.
          (Just UpperBound, -1, MustIncrease) -> True
          -- The value of the basic variable must be increased. The coefficient of the non-basic
          -- variable is positive, so we need to increase it's value. The non-basic variable is
          -- at it's lower bound so increasing it is possible.
          (Just LowerBound, 1, MustIncrease) -> True
          -- The value of the basic variable must be decreased. The coefficient of the non-basic
          -- variable is negative, so we need to increase it's value. The non-basic variable is
          -- at it's lower bound so increasing it is possible.
          (Just LowerBound, -1, MustDecrease) -> True
          -- In all other cases the bound of the non-basic variable would be violated by pivoting.
          all_other_cases -> False

  guard can_pivot
  return (basic_var, non_basic_var)

type Equation = (Var, LinearTerm)

-- |
--  Solve an equation for a given variable. For example solving
--
--    y = 3x + 10
--
--  for x, yields
--
--    x = 1/3 y - 10/3
solveFor :: Equation -> Var -> Maybe Equation
solveFor (y, right_hand_side) x = do
  coeff_of_x <- M.lookup x right_hand_side
  guard (coeff_of_x /= 0)
  return $
    (x,)
    -- divide by coefficient: x = -1/3y - 10/3
    $
      M.map (/ (-coeff_of_x))
      -- exchange x and y: -3x = -y + 10
      $
        M.insert y (-1) $
          M.delete x right_hand_side

-- |
--  Given two equations, such as
--
--    e1: x = w + 2z
--    e2: y = 3x + 4z
--
--  rewrite x in e2 using e1:
--
--    y = 3(w + 2z) + 4z
--      = 3w + 10z
rewrite :: Equation -> Equation -> Equation
rewrite (x, term_x) (y, term_y) =
  let coeff_of_x = M.findWithDefault 0 x term_y
      term_x' = M.map (* coeff_of_x) term_x
      term_y' = M.unionWith (+) (M.delete x term_y) term_x'
   in (y, term_y')

eval :: Assignment -> LinearTerm -> Rational
eval assignment term =
  sum $
    MM.merge
      MM.dropMissing
      MM.dropMissing
      (MM.zipWithMatched (const (*)))
      assignment
      term

-- |
--  TODO: make sure:
--
--    - only slack variables are pivoted
--    - non-basic variables must violate bound
--    - basic variable is suitable for pivoting
pivot :: Var -> Var -> Tableau -> Tableau
pivot basic_var non_basic_var (Tableau basis bounds assignment) =
  let from_just msg (Just a) = a
      from_just msg Nothing = error msg

      term =
        from_just "Given variable is not actually in the basis ==> invalid pivot pair" $
          M.lookup basic_var basis

      equation =
        from_just "Can't solve for non-basic variable ==> invalid pivot pair" $
          solveFor (basic_var, term) non_basic_var

      basis' =
        uncurry M.insert equation $
          M.mapWithKey (\y term_y -> snd $ rewrite equation (y, term_y)) $
            M.delete basic_var basis

      old_value_basic_var = assignment M.! basic_var
      new_value_basic_var =
        from_just "Basic variable doesn't have a bound so it's not actually violated" $
          snd <$> M.lookup basic_var bounds

      non_basic_var_coeff = term M.! non_basic_var

      old_value_non_basic_var = assignment M.! non_basic_var
      new_value_non_basic_var = old_value_non_basic_var + (old_value_basic_var - new_value_basic_var) / non_basic_var_coeff

      assignment' =
        M.insert non_basic_var new_value_non_basic_var $
          M.insert basic_var new_value_basic_var assignment

      assignment'' = M.union (eval assignment' <$> basis') assignment'
   in Tableau basis' bounds assignment''

{-| 
  Tableau rows with only zero entries correspond to constant constraints 
  like 0 < 1. These rows can be ignored during simplex. Also, if the 
  bound of the corresponding slack variable is violated, then there is
  a constant constraint that is unsatisfiable, such as 1 < 0, and we can
  immediately terminate.
-}
eliminateZeroRows :: Tableau -> Maybe Tableau
eliminateZeroRows tableau@(Tableau basis bounds assignment) = 
  let 
    (zero_rows, basis') = M.partition (all (== 0)) basis
    zero_row_slack_vars = M.keysSet zero_rows

    violated_bounds = mapMaybe (boundViolation tableau) (S.toList zero_row_slack_vars)
  in 
    if null violated_bounds then
      Just $ Tableau
        basis' 
        (bounds `M.withoutKeys` zero_row_slack_vars)
        (assignment `M.withoutKeys` zero_row_slack_vars)
    else
      Nothing

-- |
--  TODO:
--    in case of UNSAT include explanation, i.e. minimal infeasible subset of constraints.
simplex :: [Constraint] -> Maybe Assignment
simplex constraints = do
  let go :: Tableau -> Tableau
      go tableau =
        case pivotCandidates tableau of
          [] -> tableau
          ((basic_var, non_basic_var) : _) ->
            go (pivot basic_var non_basic_var tableau)

  tableau_0 <- eliminateZeroRows $ initTableau constraints

  -- traceShowM $ getBasis tableau_0

  let tableau_n = go tableau_0

      original_vars = varsIn constraints
      assignment = M.restrictKeys (getAssignment tableau_n) original_vars
  
  if null (violatedBasicVars tableau_n) then 
    Just assignment
  else 
    Nothing

-----------------------------------------------------------

example1 =
  simplex
    [ (M.fromList [(0, 1), (1, 1)], LessEquals, 3)
    , (M.fromList [(0, 1), (1, 1)], GreaterEquals, 1)
    , (M.fromList [(0, 1), (1, -1)], LessEquals, 3)
    , (M.fromList [(0, 1), (1, -1)], GreaterEquals, 1)
    ]
