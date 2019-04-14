module TTImp.Elab.Check
-- Interface (or, rather, type declaration) for the main checker function,
-- used by the checkers for each construct. Also some utility functions

import Core.Context
import Core.Core
import Core.Env
import Core.Normalise
import Core.Unify
import Core.UnifyState
import Core.TT
import Core.Value

import TTImp.TTImp

import Data.IntMap

public export
data ElabMode = InType | InLHS RigCount | InExpr

-- Current elaboration state (preserved/updated throughout elaboration)
public export
record EState (vars : List Name) where
  constructor MkEState
  defining : Name
  localMetas : List (Name, Term vars) -- metavariables introduced in this scope

export
data EST : Type where

export
initEState : Name -> EState vars
initEState def = MkEState def []

weakenedEState : {auto e : Ref EST (EState vars)} ->
                 Core (Ref EST (EState (n :: vars)))
weakenedEState {e}
    = do est <- get EST
         eref <- newRef EST (MkEState (defining est) [])
         pure eref

strengthenedEState : Ref EST (EState (n :: vars)) ->
                     Core (EState vars)
strengthenedEState e
    = do est <- get EST
         pure (MkEState (defining est) [])

dumpMetas : {auto c : Ref Ctxt Defs} ->
            {auto e : Ref EST (EState vars)} ->
            Core String
dumpMetas
    = do est <- get EST
         let mtys = localMetas est
         mdefs <- traverse showDef mtys
         pure (showSep ", " (mapMaybe id mdefs))
  where
    showDef : (Name, Term vars) -> Core (Maybe String)
    showDef (n, ty)
        = do defs <- get Ctxt
             Just gdef <- lookupCtxtExact n (gamma defs)
                  | Nothing => pure Nothing
             pure (Just (show n ++ " = " ++ show (definition gdef)))

export
inScope : {auto c : Ref Ctxt Defs} ->
          {auto e : Ref EST (EState vars)} ->
          (Ref EST (EState (n :: vars)) -> Core a) -> Core a
inScope {e} elab
    = do e' <- weakenedEState
         res <- elab e'
         logC 10 $ dumpMetas {e=e'}
         st' <- strengthenedEState e'
         put {ref=e} EST st'
         pure res

export
metaVar : {auto c : Ref Ctxt Defs} ->
          {auto u : Ref UST UState} ->
          {auto e : Ref EST (EState vars)} ->
          FC -> RigCount ->
          Env Term vars -> Name -> Term vars -> Core (Term vars)
metaVar fc rig env n ty
    = do est <- get EST
         put EST (record { localMetas $= ((n, ty) ::) } est)
         newMeta fc rig env n ty

-- Elaboration info (passed to recursive calls)
public export
record ElabInfo where
  constructor MkElabInfo
  elabMode : ElabMode
  level : Nat

export
initElabInfo : ElabMode -> ElabInfo
initElabInfo m = MkElabInfo m 0

export
nextLevel : ElabInfo -> ElabInfo
nextLevel = record { level $= (+1) }

export
tryError : {vars : _} ->
           {auto c : Ref Ctxt Defs} ->
           {auto u : Ref UST UState} ->
           {auto e : Ref EST (EState vars)} ->
           Core a -> Core (Either Error a)
tryError elab
    = do ust <- get UST
         est <- get EST
         next <- getNextEntry
         let btlog = updateLog ust
         put UST (record { updateLog = Just [] } ust)
         catch (do res <- elab
                   pure (Right res))
               (\err => do ust' <- get UST
                           maybe (pure ()) undoLog (updateLog ust')
                           put UST ust
                           put EST est
                           setNextEntry next
                           pure (Left err))
  where
    undoLog : List (Int, GlobalDef) -> Core ()
    undoLog [] = pure ()
    undoLog ((i, d) :: rest)
        = do addDef (Resolved i) d
             undoLog rest

export
try : {vars : _} ->
      {auto c : Ref Ctxt Defs} ->
      {auto u : Ref UST UState} ->
      {auto e : Ref EST (EState vars)} ->
      Core a -> Core a -> Core a
try elab1 elab2
    = do Right ok <- tryError elab1
               | Left err => elab2
         pure ok

-- Implemented in TTImp.Elab.Term; delaring just the type allows us to split
-- the elaborator over multiple files more easily
export
check : {vars : _} ->
        {auto c : Ref Ctxt Defs} ->
        {auto u : Ref UST UState} ->
        {auto e : Ref EST (EState vars)} ->
        RigCount -> ElabInfo -> Env Term vars -> RawImp -> 
        Maybe (Glued vars) ->
        Core (Term vars, Glued vars)

-- As above, but doesn't add any implicit lambdas, forces, delays, etc
export
checkImp : {vars : _} ->
           {auto c : Ref Ctxt Defs} ->
           {auto u : Ref UST UState} ->
           {auto e : Ref EST (EState vars)} ->
           RigCount -> ElabInfo -> Env Term vars -> RawImp -> Maybe (Glued vars) ->
           Core (Term vars, Glued vars)

-- Check whether two terms are convertible. May solve metavariables (in Ctxt)
-- in doing so.
-- Returns a list of constraints which need to be solved for the conversion
-- to work; if this is empty, the terms are convertible.
export
convert : {vars : _} ->
          {auto c : Ref Ctxt Defs} ->
          {auto u : Ref UST UState} ->
          {auto e : Ref EST (EState vars)} ->
          FC -> ElabInfo -> Env Term vars -> Glued vars -> Glued vars ->
          Core (List Int)
convert fc elabinfo env x y
    = let umode : UnifyMode
                = case elabMode elabinfo of
                       InLHS _ => InLHS
                       _ => InTerm in
          catch (do vs <- unify umode fc env !(getNF x) !(getNF y)
                    when (holesSolved vs) $
                      solveConstraints umode Normal
                    pure (constraints vs))
                (\err => do xtm <- getTerm x
                            ytm <- getTerm y
                            -- See if we can improve the error message by
                            -- resolving any more constraints
                            catch (solveConstraints umode Normal)
                                  (\err => pure ())
                            throw (WhenUnifying fc env xtm ytm err))

-- Check whether the type we got for the given type matches the expected
-- type.
-- Returns the term and its type.
-- This may generate new constraints; if so, the term returned is a constant
-- guarded by the constraints which need to be solved.
export
checkExp : {vars : _} ->
           {auto c : Ref Ctxt Defs} ->
           {auto u : Ref UST UState} ->
           {auto e : Ref EST (EState vars)} ->
           RigCount -> ElabInfo -> Env Term vars -> FC ->
           (term : Term vars) -> 
           (got : Glued vars) -> (expected : Maybe (Glued vars)) -> 
           Core (Term vars, Glued vars)
checkExp rig elabinfo env fc tm got (Just exp) 
    = do constr <- convert fc elabinfo env got exp
         case constr of
              [] => pure (tm, got)
              cs => do defs <- get Ctxt
                       empty <- clearDefs defs
                       cty <- getTerm exp
                       ctm <- newConstant fc rig env tm cty cs
                       pure (ctm, exp)
checkExp rig elabinfo env fc tm got Nothing = pure (tm, got)