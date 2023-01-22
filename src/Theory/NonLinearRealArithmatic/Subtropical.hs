module Theory.NonLinearRealArithmatic.Subtropical where

import qualified Theory.NonLinearRealArithmatic.Expr as Expr
import qualified Data.List as L
import qualified Data.IntMap as M
import Data.IntMap ( IntMap )
import Theory.NonLinearRealArithmatic.Polynomial

-- |
-- The frame of a polynomial is a set of points, obtained from the 
-- exponents of the individual monomials. E.g. for a polynomial over 
-- variables x,y like 
-- 
--   y + 2xy^3 - 3x^2y^2 - x^3 - 4x^4y^4
-- 
-- we get the following points 
--
--   (0,1), (1,3), (2,2), (4,4) 
--
-- The points are then partitioned by the sign of the coefficient.
--
--   pos: (0,1) 
--   neg: (1,3), (2,2), (4,4) 
-- 
-- Computing the frame is the basis for identifiying a term that
-- dominates the polynomial for sufficently large variables values.
-- That in turn is sufficient to find solutions to inequality 
-- constraints.
frame :: (Ord a, Num a) => Polynomial a -> ([Monomial], [Monomial])
frame polynomial = undefined -- TODO
  where
    (pos_terms, neg_terms) 
      = L.partition ((> 0) . getCoeff) 
      $ L.filter ((/= 0) . getCoeff) (getTerms polynomial)

findDominatingDirection :: (Num a, Ord a) => Polynomial a -> Maybe (IntMap Int)
findDominatingDirection terms = undefined
  where
    pos_terms = filter ((> 0) . getCoeff) (getTerms terms)
    
-- |
-- Returns True iff the polynomial evaluates to something positive under 
-- the given variable assignment.
isPositiveSolution :: (Num a, Ord a) => Polynomial a -> IntMap a -> Bool
isPositiveSolution polynomial solution = eval solution polynomial > 0

-- |
positiveSolution :: (Num a, Ord a) => Polynomial a -> Maybe (IntMap a)
positiveSolution polynomial = do 
  normal_vector <- findDominatingDirection polynomial
  
  -- For a sufficiently large base the polynomial should evaluate 
  -- to something positive.
  let bases = [ 2^n | n <- [1..] ]
  let candidates = [ M.map (b^) normal_vector | b <- bases ]      

  L.find (isPositiveSolution polynomial) candidates
  
-- newtype Solution a = Sol { getValues :: IntMap a }

-- instance Num a => Num (Solution a) where
--   (Sol s1) + (Sol s2) = Sol $ M.unionWith (+) s1 s2
--   (Sol s1) * (Sol s2) = Sol $ M.unionWith (*) s1 s2
--   abs (Sol s1) = Sol $ M.map abs s1
--   negate (Sol s1) = Sol $ M.map negate s1
--   signum (Sol s1) = Sol $ M.map signum s1
--   fromInteger i = error "TODO: define this"
  
-- |
-- Returns True if the polynomial evaluates to 0 under the given 
-- variable assignment.
isSolution :: (Num a, Ord a) => Polynomial a -> IntMap a -> Bool
isSolution polynomial solution = eval solution polynomial == 0
  
-- | 
findSolution :: forall a. (Num a, Ord a) => Polynomial a -> Maybe (IntMap a)
findSolution polynomial
  | eval one polynomial < 0 = go one polynomial
  | eval one polynomial > 0 = go one (negate polynomial)
  | otherwise = Just one
  where
    -- solution that maps all variables to one
    one = M.fromSet (const 1) (varsIn polynomial)
    
    go :: IntMap a -> Polynomial a -> Maybe (IntMap a)
    go neg_sol polynomial = do
      pos_sol <- positiveSolution polynomial
      
      -- TODO: solve for t element [0;1]
      -- neg_sol + t * (pos_sol - neg_sol)
      let t = 1
      
      return 
        $ M.unionWith (+) neg_sol 
        $ M.map (* t) 
        $ M.unionWith (-) pos_sol neg_sol
      
