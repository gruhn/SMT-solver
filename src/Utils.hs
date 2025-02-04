module Utils where

import Data.Maybe (isJust, catMaybes, listToMaybe, mapMaybe)
import Data.Foldable (toList, concatMap)
import qualified Data.Set as S
import Data.Set (Set)
import Control.Exception (assert)
import Data.List (uncons, tails)

fixpoint :: Eq a => (a -> a) -> a -> a
fixpoint f a
  | a == f a  = a
  | otherwise = fixpoint f (f a)

rightToMaybe :: Either a b -> Maybe b
rightToMaybe = either (const Nothing) Just

takeWhileJust :: [Maybe a] -> [a]
takeWhileJust = catMaybes . takeWhile isJust

takeUntil :: (a -> Bool) -> [a] -> [a]
takeUntil p [] = []
takeUntil p (a:as) 
  | p a       = [a]
  | otherwise = a : takeUntil p as

firstJust :: (a -> Maybe b) -> [a] -> Maybe b
firstJust f = listToMaybe . mapMaybe f

combinations :: [a] -> [(a,a)]
combinations []     = []
combinations (a:as) = map (a,) as ++ combinations as

assertM :: Monad m => Bool -> m ()
assertM condition
  | condition = return ()
  | otherwise = error "assertion failure"

count :: (a -> Bool) -> [a] -> Int
count p = length . filter p

adjacentPairs :: [a] -> [(a, a)]
adjacentPairs as = zip as (tail as)
