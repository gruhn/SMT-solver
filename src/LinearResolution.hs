module LinearResolution (sat) where

import CNF (conjunctiveNormalForm, CNF, Literal (..), Clause)
import Expr (Expr)
import qualified Data.Set as S
import Data.Foldable (toList)
import Control.Monad (guard)
import Utils (fixpoint)
import Data.Tree (Forest, unfoldForest, Tree (rootLabel, Node), unfoldForestM)
import Debug.Trace (trace)
import Data.Function (on)
import Data.List (sortBy)
import qualified Control.Monad.State.Lazy as State

sat :: Expr -> Bool
sat = linearResolution . conjunctiveNormalForm

linearResolution :: CNF -> Bool
linearResolution = not . any (S.empty `elem`) . searchTree

searchTree :: CNF -> Forest Clause
searchTree cnf = State.evalState (unfoldForestM expand $ toList cnf) cnf
  where
    negate :: Literal -> Literal
    negate (Pos var) = Neg var
    negate (Neg var) = Pos var

    resolve_with :: Clause -> Clause -> Literal -> Clause
    resolve_with c1 c2 lit =
      S.delete lit c1 `S.union` S.delete (negate lit) c2

    no_contradition :: Clause -> Bool
    no_contradition clause = 
      all ((`notElem` clause) . negate) (toList clause)

    next_resolvents :: Clause -> CNF -> [Clause]
    next_resolvents resolvent derived_clauses = do
      literal <- toList resolvent
      clause  <- toList derived_clauses
      guard (negate literal `elem` clause) 
      let resolvent' = resolve_with resolvent clause literal
      guard (no_contradition resolvent')
      guard (resolvent' `notElem` derived_clauses) -- skip already derived clauses
      return resolvent'

    expand :: Clause -> State.State CNF (Clause, [Clause])
    expand resolvent = do
      State.modify (S.insert resolvent)
      derived_clauses <- State.get
      return (resolvent, next_resolvents resolvent derived_clauses)