(*
    very simple variant of 'lambda-lifting' optimization step,
    which is performed in the very beginning after the
    initial dead code elimination step.

    It does the following:
    * moves all the type definitions to the top level (i.e. global/module level).
    * moves all the exception declarations to the top level.
    * moves all the nested functions that do not access local variables/parameters
      of the outer functions to the top level. That is, those are functions that
      do not need closures. If a function calls functions or accesses values from
      the top/module level, it's not a problem, since it does not require a closure.
      In particular, this step moves C-code functions to the top level.

    Why is this step needed? This step is needed to simplify the
    inline function expansion step, i.e. it increases the number of functions that
    can potentially be inlined. It also reduces the amount of work needed to
    be done by the full-scale lambda lifting step before translation to C/machine code.
*)

open Ast
open K_form

let lift top_code =
    let new_top_code = ref ([]: kexp_t list) in
    let globals = ref IdSet.empty in
    let add_to_globals i = globals := IdSet.add i !globals in
    let add_to_globals_and_lift i e loc =
        add_to_globals i;
        new_top_code := e :: !new_top_code;
        KExpNop(loc) in
    let is_global i = IdSet.mem i !globals in

    (* first, let's see which definitions are already at the top level *)
    let _ = List.iter (fun e ->
        match e with
        | KDefVal(i, e, _) -> add_to_globals i
        | KDefFun {contents={kf_name}} -> add_to_globals kf_name
        | KDefExn {contents={ke_name}} -> add_to_globals ke_name
        | KDefVariant {contents={kvar_name}} -> add_to_globals kvar_name
        | _ -> ()) top_code in

    (* a function can be lifted to the top level (i.e. become global) if all its
       "free variables" are either global (or have been just promoted there) or
       type names, constructor names or C functions, i.e. they will
       definitely can be promoted to the top level. *)
    let can_lift_fun kf =
        let fv = free_vars_kexp (KDefFun kf) in
        let can_lift = IdSet.for_all (fun n ->
            (is_global n) ||
            (match (kinfo n) with
            | KExn _ -> true
            | KVariant _ -> true
            | KVal _ -> false
            | KFun {contents={kf_flags}} ->
                (List.mem FunInC kf_flags) || (List.mem FunConstr kf_flags)
            | KNone -> raise_compile_err (!kf.kf_loc)
                (sprintf "attempt to request type of non-existing symbol '%s' when checking free variable of function '%s'"
                (id2str n) (id2str (!kf.kf_name)))
            | _ -> false)) fv in
        (*print_set ((id2str !kf.kf_name) ^ " free vars") fv; printf "\tcan lift: %B\n" can_lift;*)
        can_lift in

    let rec walk_ktyp_n_lift t callb = t
    and walk_kexp_n_lift e callb =
        match e with
        | KDefVariant {contents={kvar_name; kvar_loc}} ->
            if (is_global kvar_name) then e
            else add_to_globals_and_lift kvar_name e kvar_loc
        | KDefExn {contents={ke_name; ke_loc}} ->
            if (is_global ke_name) then e
            else add_to_globals_and_lift ke_name e ke_loc
        | KDefFun kf ->
            let {kf_name; kf_body; kf_loc} = !kf in
            let new_body = walk_kexp_n_lift kf_body callb in
            let _ = kf := {!kf with kf_body=new_body} in
            if (is_global kf_name) then e
            else
                if not (can_lift_fun kf) then e
                else add_to_globals_and_lift kf_name e kf_loc
        | _ -> walk_kexp e callb
    in let walk_n_lift_callb =
    {
        kcb_atom = None;
        kcb_typ = Some(walk_ktyp_n_lift);
        kcb_exp = Some(walk_kexp_n_lift)
    } in

    let process top_code =
        new_top_code := [];
        List.iter (fun e ->
            let new_e = walk_kexp_n_lift e walk_n_lift_callb in
            match new_e with
            | KExpNop _ -> ()
            | _ -> new_top_code := new_e :: !new_top_code) top_code;
        List.rev !new_top_code in

    let top_code = process top_code in
    process top_code