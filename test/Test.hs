{-# LANGUAGE OverloadedStrings #-}
module Main where

import Hedgehog
import Hedgehog.Main (defaultMain)
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range

import TestNonLinearRealArithmatic
import TestLinearArithmatic
import TestSAT
import qualified TestUninterpretedFunctions as UF

main :: IO ()
main = defaultMain $ checkParallel <$> [ 
    Group "SAT solver" [ 
      ("DPLL is sound", prop_dpll_sound), 
      ("CDCL is sound", withTests 1000 prop_cdcl_sound), 
      ("DPLL equivalent to CDCL", withTests 1000 prop_dpll_equiv_cdcl)
    ],
    Group "Uninterpreted Functions" [
      ("Infeasible subsets are minimal", UF.prop_infeasible_subsets_are_minimal),
      ("Equalities are symmetric", UF.prop_equalities_symmetric)
    ],
    Group "Polynomial" [ 
      ("Coefficients are always non-zero", prop_all_coeffs_non_zero),
      ("Exponents are always non-zero", prop_exponents_always_non_zero),
      ("Monomials are pair-wise distinct", prop_unique_monomials)
    ],
    Group "Interval Constraint Propagation" [ 
      ("Intervals never widen", prop_intervals_never_widen),
      ("No roots are lost", prop_no_roots_are_lost)
    ], 
    Group "Linear Arithmatic" [ 
      ("Fourier-Motzkin is sound", prop_fourier_motzkin_sound),
      ("Fourier-Motzkin equivalent to Simplex", prop_fourier_motzkin_equiv_simplex),
      ("Invariant: non-basic variables always satisfy their bounds", prop_invariant_non_basic_vars_satisfy_bounds),
      ("Invariant: assignment matches basis evaluation", prop_invariant_assignment_matches_basis_evaluation),
      ("Invariant: basic and non-basic variables are disjoint", prop_invariant_disjoint_basic_and_nonbasic_vars),
      -- TODO: Invariant: slack variables are always negative, original variables always non-negative
      ("Simplex does not cycle", prop_simplex_no_cycle),
      ("Simplex is sound", prop_simplex_sound),
      ("Simplex with cutting planes is sound", prop_simplex_sound_with_cutting_plane),
      ("Branch-and-Bound is sound", prop_branch_and_bound_sound)
      -- ("Branch-and-Bound terminates quickly", prop_branch_and_bound_terminates_quickly)
    ]
  ]
