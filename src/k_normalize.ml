(*
    This file is a part of ficus language project.
    See ficus/LICENSE for the licensing terms
*)

(*
    Converts the Abstract Syntax Tree (ast.ml) into K-form (K_form.ml).

    For now only the global compilation mode is supported, i.e.
    the code from all the modules, used in the program,
    is put into one global list of definitions and top-level expressions.
    Since the modules are processed in the topological order, the output
    is correct.
*)

open Ast
open K_form

(* the data type used for pattern matching transformation *)
type pat_info_t = { pinfo_p: pat_t; pinfo_typ: ktyp_t; pinfo_e: kexp_t; pinfo_tag: id_t }

let zero_env = (Env.empty : env_t)

let typ2ktyp t loc =
    let id_stack = ref ([]: id_t list) in
    let rec typ2ktyp_ t =
    let t = deref_typ t in
    match t with
    | TypVar {contents=Some(t)} -> typ2ktyp_ t
    | TypVar _ -> raise_compile_err loc "undefined type; use explicit type annotation"
    | TypInt -> KTypInt
    | TypSInt(b) -> KTypSInt(b)
    | TypUInt(b) -> KTypUInt(b)
    | TypFloat(b) -> KTypFloat(b)
    | TypString -> KTypString
    | TypChar -> KTypChar
    | TypBool -> KTypBool
    | TypVoid -> KTypVoid
    | TypExn -> KTypExn
    | TypErr -> KTypErr
    | TypCPointer -> KTypCPointer
    | TypDecl -> KTypVoid (* we will check explicitly that no declaration occurs in the end of each code block *)
    | TypModule -> KTypModule
    | TypList(t) -> KTypList(typ2ktyp_ t )
    | TypTuple(tl) -> KTypTuple(List.map typ2ktyp_ tl)
    | TypVarTuple _ ->
        raise_compile_err loc "variable tuple type cannot be inferenced; please, use explicit type annotation"
    | TypRef(t) -> KTypRef(typ2ktyp_ t)
    | TypArray(d, t) -> KTypArray(d, typ2ktyp_ t)
    | TypVarArray _ ->
        raise_compile_err loc "variable array type cannot be inferenced; please, use explicit type annotation"
    | TypVarRecord ->
        raise_compile_err loc "variable record type cannot be inferenced; please, use explicit type annotation"
    | TypFun(args, rt) -> KTypFun((List.map typ2ktyp_ args), (typ2ktyp_ rt))
    | TypRecord {contents=(relems, true)} ->
        KTypRecord(noid, List.map (fun (ni, ti, _) -> (ni, (typ2ktyp_ ti))) relems)
    | TypRecord _ ->
        raise_compile_err loc "the record type cannot be inferenced; use explicit type annotation"
    | TypApp(args, n) ->
        let t = Ast_typecheck.find_typ_instance t loc in
        (match t with
        | Some (TypApp([], n)) ->
            (match (id_info n) with
            | IdVariant {contents={dvar_cases=(_, TypRecord {contents=(relems, true)}) :: []; dvar_flags}}
                when dvar_flags.var_flag_record ->
                if (List.mem n !id_stack) then
                        raise_compile_err loc
                            (sprintf "the record '%s' directly or indirectly references itself" (id2str n))
                    else ();
                id_stack := n :: !id_stack;
                let new_t = KTypRecord(n, List.map (fun (ni, ti, _) -> (ni, (typ2ktyp_ ti))) relems) in
                id_stack := List.tl !id_stack;
                new_t
            | _ -> KTypName(n))
        | _ -> raise_compile_err loc "the proper instance of the template type is not found")
    in typ2ktyp_ t

let idx_access_stack = ref ([]: (atom_t*int) list)

let rec exp2kexp e code tref sc =
    let (etyp, eloc) = get_exp_ctx e in
    let ktyp = typ2ktyp etyp eloc in
    let kctx = (ktyp, eloc) in
    (*let _ = (printf "translating "; Ast_pp.pprint_exp_x e; printf "\n") in*)
    (*
        scans through (pi, ei) pairs in for(p1<-e1, p2<-e2, ..., pn<-en) operators;
        * updates the code that needs to be put before the for loop
          (all the ei needs to be computed there),
        * generates the pattern unpack code, which should be put into the beginning of the loop body
        * generates the proxy identifiers that are used in the corresponding KExpFor/KExpMap.
        For example, the following code:
            for ((r, g, b) <- GaussianBlur(img)) { ... }
        is converted to
            val temp@@105 = GaussianBlur(img)
            for (i@@105 <- temp@@123) { val r=i@@105.0, g=i@@105.1, b = i@@105.2; ... }
    *)
    let transform_for pe_l idx_pat code sc body_sc =
        let (idom_list, code, body_code) =
            List.fold_left (fun (idom_list, code, body_code) (pi, ei) ->
                let (di, code) = exp2dom ei code sc in
                let ptyp = match di with
                    | Domain.Range _ -> KTypInt
                    | Domain.Fast i | Domain.Elem i ->
                        match (get_atom_ktyp i eloc) with
                        | KTypArray(_, et) -> et
                        | KTypList(et) -> et
                        | KTypString -> KTypChar
                        | _ -> raise_compile_err eloc "unsupported typ of the domain expression in for loop" in
                let (i, body_code) = pat_simple_unpack pi ptyp None body_code "i"
                        (default_val_flags()) body_sc
                in ((i, di) :: idom_list, code, body_code))
            ([], code, []) pe_l in
        let loc = get_pat_loc idx_pat in
        let (at_ids, body_code) = match idx_pat with
            | PatAny _ -> ([], body_code)
            | PatTyped(p, TypInt, loc) ->
                let (i, body_code) = pat_simple_unpack p KTypInt None body_code "i"
                    (default_val_flags()) body_sc in
                ([i], body_code)
            | PatTyped(p, TypTuple(tl), _) ->
                let p = pat_skip_typed p in
                (match p with
                | PatTuple(pl, _) ->
                    if (List.length pl) = (List.length tl) then () else
                        raise_compile_err loc "the '@' tuple pattern and its type do not match";
                    let (at_ids, body_code) =
                        List.fold_left2 (fun (at_ids, body_code) pi ti ->
                            if ti = TypInt then () else
                                raise_compile_err loc "some of '@' indices is not an integer";
                            let (i, body_code) = pat_simple_unpack pi KTypInt None body_code "i"
                                (default_val_flags()) body_sc in
                            (i :: at_ids, body_code)) ([], body_code) pl tl
                        in
                    ((List.rev at_ids), body_code)
                | PatIdent(idx, _) ->
                    let prefix = pp_id2str idx in
                    let (_, at_ids, ktl) = List.fold_left (fun (k, at_ids, ktl) ti ->
                        if ti = TypInt then () else
                            raise_compile_err loc "some of '@' indices is not an integer";
                        let i = gen_idk (sprintf "%s%d" prefix k) in
                        let _ = create_kdefval i KTypInt (default_val_flags()) None [] loc in
                        (k+1, (i :: at_ids), KTypInt :: ktl)) (0, [], []) tl
                        in
                    let ktyp = KTypTuple ktl in
                    let at_ids = (List.rev at_ids) in
                    let body_code = create_kdefval idx ktyp (default_val_flags())
                        (Some (KExpMkTuple ((List.map (fun i -> Atom.Id i) at_ids), (ktyp, loc)))) body_code loc in
                    (at_ids, body_code)
                | _ -> raise_compile_err loc
                    "'@' pattern is expected to be either an integer scalar or a tuple of integer scalars")
            | _ -> raise_compile_err loc
                "'@' pattern is expected to be either an integer scalar or a tuple of integer scalars"
            in
        ((List.rev idom_list), at_ids, code, body_code) in
    match e with
    | ExpNop(loc) -> ((KExpNop loc), code)
    | ExpBreak(_, loc) -> ((KExpBreak loc), code)
    | ExpContinue(loc) -> ((KExpContinue loc), code)
    | ExpRange(e1_opt, e2_opt, e3_opt, _) ->
        let process_rpart e_opt code defval =
            match e_opt with
            | Some(e) -> exp2atom e code false sc
            | _ -> (defval, code) in
        let (a1, code) = process_rpart e1_opt code (Atom.Lit LitNil) in
        let (a2, code) = process_rpart e2_opt code (Atom.Lit LitNil) in
        let (a3, code) = process_rpart e3_opt code (Atom.Lit (LitInt 1L)) in
        (KExpMkTuple(a1 :: a2 :: a3 :: [], kctx), code)
    | ExpLit(lit, _) -> (KExpAtom((Atom.Lit lit), kctx), code)
    | ExpIdent(n, _) ->
        (match ktyp with
        | KTypVoid -> ((KExpNop eloc), code)
        | _ -> (KExpAtom((Atom.Id n), kctx), code))
    | ExpBinOp(OpLogicAnd, e1, e2, _) ->
        let (e1, code) = exp2kexp e1 code false sc in
        let eloc2 = get_exp_loc e2 in
        let (e2, code2) = exp2kexp e2 [] false sc in
        let e2 = rcode2kexp (e2 :: code2) eloc2 in
        (KExpIf(e1, e2, KExpAtom((Atom.Lit (LitBool false)), (KTypBool, eloc2)), kctx), code)
    | ExpBinOp(OpLogicOr, e1, e2, _) ->
        let (e1, code) = exp2kexp e1 code false sc in
        let eloc2 = get_exp_loc e2 in
        let (e2, code2) = exp2kexp e2 [] false sc in
        let e2 = rcode2kexp (e2 :: code2) eloc2 in
        (KExpIf(e1, KExpAtom((Atom.Lit (LitBool true)), (KTypBool, eloc2)), e2, kctx), code)
    | ExpBinOp(bop, e1, e2, _) ->
        let (a1, code) = exp2atom e1 code false sc in
        let (a2, code) = exp2atom e2 code false sc in
        (match (bop, (get_atom_ktyp a1 eloc), (get_atom_ktyp a2 eloc)) with
        | (OpAdd, KTypString, KTypString)
        | (OpAdd, KTypChar, KTypString)
        | (OpAdd, KTypString, KTypChar) -> (KExpIntrin(IntrinStrConcat, [a1; a2], kctx), code)
        | _ -> (KExpBinOp(bop, a1, a2, kctx), code))
    | ExpUnOp(OpDeref, e, _) ->
        let (a_id, code) = exp2id e code false sc "a literal cannot be dereferenced" in
        (KExpUnOp(OpDeref, (Atom.Id a_id), kctx), code)
    | ExpUnOp(OpDotMinus, e, _) ->
        let (arr, idx_i) = match !idx_access_stack with
            | (arr, idx_i) :: _ -> (arr, idx_i)
            | _ -> raise_compile_err eloc ".- is only allowed inside array access op"
            in
        let (a, code) = exp2atom e code false sc in
        let args = if idx_i = 0 then [arr] else [arr; Atom.Lit (LitInt (Int64.of_int idx_i))] in
        let (sz, code) = kexp2atom "sz" (KExpIntrin (IntrinGetSize, args, (KTypInt, eloc))) false code in
        (KExpBinOp(OpSub, sz, a, kctx), code)
    | ExpUnOp(uop, e1, _) ->
        let (a1, code) = exp2atom e1 code false sc in
        (KExpUnOp(uop, a1, kctx), code)
    | ExpSeq(eseq, _) ->
        let sc = new_block_scope() :: sc in
        let (code, _) = eseq2code eseq code sc in
        (match code with
        | c :: code -> (c, code)
        | _ -> ((KExpNop eloc), code))
    | ExpMkTuple(args, _) ->
        let (args, code) = List.fold_left (fun (args, code) ei ->
                let (ai, code) = exp2atom ei code false sc in
                (ai :: args, code)) ([], code) args in
        (KExpMkTuple((List.rev args), kctx), code)
    | ExpMkArray(arows, _) ->
        let _ = if arows <> [] then () else raise_compile_err eloc "empty arrays are not supported" in
        let (krows, code) = List.fold_left (fun (krows, code) arow ->
            let (krow, code) = List.fold_left (fun (krow, code) e ->
                let (f, e) = match e with
                    | ExpUnOp(OpExpand, e, _) -> (true, e)
                    | _ -> (false, e)
                    in
                let (a, code) = exp2atom e code false sc in
                (((f, a) :: krow), code)) ([], code) arow
                in
            (((List.rev krow) :: krows), code)) ([], code) arows
            in
        (KExpMkArray((List.rev krows), kctx), code)
    | ExpMkRecord (rn, rinitelems, _) ->
        let (rn_id, ctor, relems) = match (rn, (deref_typ etyp)) with
            | (ExpIdent(rn_id, _), _) ->
                let (ctor, relems) = Ast_typecheck.get_record_elems (Some rn_id) etyp eloc in
                (rn_id, ctor, relems)
            | ((ExpNop _), TypRecord {contents=(relems, true)}) ->
                (noid, noid, relems)
            | _ -> raise_compile_err (get_exp_loc rn)
                "k-normalization: in the record construction identifier is expected after type check"
            in
        let (ratoms, code) = List.fold_left (fun (ratoms, code) (ni, ti, opt_vi) ->
            let (a, code) = try
                let (_, ej) = List.find (fun (nj, ej) -> ni = nj) rinitelems in
                exp2atom ej code false sc
            with Not_found ->
                (match opt_vi with
                | Some(vi) -> ((Atom.Lit vi), code)
                | _ -> raise_compile_err eloc
                    (sprintf
                    "there is no explicit inializer for the field '%s' nor there is default initializer for it"
                    (id2str ni)))
            in (a::ratoms, code)) ([], code) relems in
        if ctor = noid then
            (KExpMkRecord((List.rev ratoms), kctx), code)
        else
            (KExpCall(ctor, (List.rev ratoms), kctx), code)
    | ExpUpdateRecord(e, rupdelems, _) ->
        let (rec_n, code) = exp2id e code true sc "the updated record cannot be a literal" in
        let (_, relems) = Ast_typecheck.get_record_elems None etyp eloc in
        let (_, ratoms, code) = List.fold_left (fun (idx, ratoms, code) (ni, ti, _) ->
            let (a, code) = try
                let (_, ej) = List.find (fun (nj, ej) -> ni = nj) rupdelems in
                exp2atom ej code false sc
            with Not_found ->
                let ni_ = dup_idk ni in
                let ti_ = typ2ktyp ti eloc in
                let get_ni = KExpMem(rec_n, idx, (ti_, eloc)) in
                let code = create_kdefval ni_ ti_ (default_tempref_flags()) (Some get_ni) code eloc in
                ((Atom.Id ni_), code)
            in (idx + 1, a::ratoms, code)) (0, [], code) relems in
        (KExpMkRecord((List.rev ratoms), kctx), code)
    | ExpCall(f, args, _) ->
        let (f_id, code) = exp2id f code false sc "a function name cannot be a literal" in
        let (args, kwarg_opt) = match (List.rev args) with
            | (ExpMkRecord((ExpNop _), _, _) as mkrec) :: rest -> ((List.rev rest), Some mkrec)
            | _ -> (args, None)
            in
        let (args, code) = List.fold_left (fun (args, code) ei ->
            let (ai, code) = exp2atom ei code false sc in (ai :: args, code)) ([], code) args in
        let (args, code) = match kwarg_opt with
            | Some(e) ->
                let (ke, code) = exp2kexp e code false sc in
                (match ke with
                | KExpMkRecord(rest_args, _) ->
                    ((List.rev args) @ rest_args, code)
                | _ -> raise_compile_err (get_exp_loc e) "the expression should convert to KExpMkRecord()")
            | _ -> ((List.rev args), code)
            in
        (KExpCall(f_id, args, kctx), code)
    | ExpThrow(e, _) ->
        let (a_id, code) = exp2id e code false sc "a literal cannot be thrown as exception" in
        (KExpThrow(a_id, false, eloc), code)
    | ExpIf(e1, e2, e3, _) ->
        let (c, code) = exp2kexp e1 code false sc in
        let loc2 = get_exp_loc e2 in
        let loc3 = get_exp_loc e3 in
        let (e2, code2) = exp2kexp e2 [] false sc in
        let (e3, code3) = exp2kexp e3 [] false sc in
        let if_then = rcode2kexp (e2 :: code2) loc2 in
        let if_else = rcode2kexp (e3 :: code3) loc3 in
        (KExpIf(c, if_then, if_else, kctx), code)
    | ExpWhile(e1, e2, _) ->
        let loc1 = get_exp_loc e1 in
        let loc2 = get_exp_loc e2 in
        let (e1, code1) = exp2kexp e1 [] false sc in
        let (e2, code2) = exp2kexp e2 [] false sc in
        let c = rcode2kexp (e1 :: code1) loc1 in
        let body = rcode2kexp (e2 :: code2) loc2 in
        (KExpWhile(c, body, eloc), code)
    | ExpDoWhile(e1, e2, _) ->
        let (e1, code1) = exp2kexp e1 [] false sc in
        let (e2, code2) = exp2kexp e2 (e1 :: code1) false sc in
        let body = rcode2kexp code2 eloc in
        (KExpDoWhile(body, e2, eloc), code)
    | ExpFor(pe_l, idx_pat, body, flags, _) ->
        let body_sc = new_block_scope() :: sc in
        let (idom_list, at_ids, code, body_code) = transform_for pe_l idx_pat code sc body_sc in
        let (last_e, body_code) = exp2kexp body body_code false body_sc in
        let bloc = get_exp_loc body in
        let body_kexp = rcode2kexp (last_e :: body_code) bloc in
        (KExpFor(idom_list, at_ids, body_kexp, flags, eloc), code)
    | ExpMap(pew_ll, body, flags, _) ->
        (*
            process the nested for clauses. since there can be non-trivial patterns
            and non-trivial iteration domain expressions, transform_for will produce
            some "pre_code", i.e. the code that needs to be executed before (outside of)
            each clause of the nested loop and also the "body_code" that needs to be
            computed inside the loop (i.e. the pattern unpacking) in the beginning
            before all other expressions. In the case of nested loop in exp-map this
            body_code will actually become the outer code for the nested loop.
            So, it's passed to the next iteration of List.fold_left and will prepend
            the next "pre_code". Finally, the body_code from the last iteration, i.e.
            from the most inner for loop will actually become the prefix of the actual
            body code that is transformed after this List.fold_left.

            In addition, we handle clauses in certain way that is not 100% correct from
            the type consistence point of view, but it's fine and all the subsequent
            optimizations and the C code generator should handle it properly. That is,
            after unpacking the patterns inside loop for each "when <...>" clause we
            insert "if (<...>) {} else continue;" expression, e.g.:

            val upper_triangle_nz_elements = [for (i <- 0:m) for (j <- i:m when A[i,j] != 0) (i,j)]

            will be translated to

            vall odd_elements = [for (i <- 0:m) for (j <-i:m)
                { val temp=A[i,j]; if(temp != 0) {} else continue; (i, j)} ]
        *)
        let body_sc = new_block_scope() :: sc in
        let (pre_idom_ll, body_code) = List.fold_left
            (fun (pre_idom_ll, prev_body_code) (pe_l, idx_pat) ->
                let (idom_list, at_ids, pre_code, body_code) =
                    transform_for pe_l idx_pat prev_body_code sc body_sc in
                let pre_exp = rcode2kexp pre_code eloc in
                ((pre_exp, idom_list, at_ids) :: pre_idom_ll, body_code)) ([], []) pew_ll in
        let (last_e, body_code) = exp2kexp body body_code false body_sc in
        let bloc = get_exp_loc body in
        let body_kexp = rcode2kexp (last_e :: body_code) bloc in
        (KExpMap((List.rev pre_idom_ll), body_kexp, flags, kctx), code)
    | ExpAt(e, border, interp, idxlist, _) ->
        let (arr, code) = exp2atom e code true sc in
        let (_, dlist, code) = List.fold_left (fun (i, dlist, code) idx ->
            let _ = idx_access_stack := (arr, i) :: !idx_access_stack in
            let (d, code) =
                try
                    exp2dom idx code sc
                with e ->
                    idx_access_stack := List.tl !idx_access_stack;
                    raise e
                in
            let _ = idx_access_stack := List.tl !idx_access_stack in
            (i + 1, (d :: dlist), code)) (0, [], code) idxlist in
        (KExpAt(arr, border, interp, (List.rev dlist), kctx), code)
    | ExpMem(e1, elem, _) ->
        let e1loc = get_exp_loc e1 in
        let (a_id, code) = exp2id e1 code true sc "the literal does not have members to access" in
        let ktyp = get_idk_ktyp a_id e1loc in
        (match (ktyp, elem) with
        | (KTypTuple(tl), ExpLit((LitInt i_), (ityp, iloc))) ->
            let i = Int64.to_int i_ in
            let n = List.length tl in
            if 0 <= i && i < n then () else
                raise_compile_err iloc (sprintf "the tuple index is outside of the range [0, %d)" n);
            (KExpMem(a_id, i, kctx), code)
        | (KTypRecord(rn, relems), ExpIdent(n, (_, nloc))) ->
            let (i, j) = List.fold_left (fun (i, j) (ni, _) ->
                if n = ni then (j, j+1) else (i, j+1)) (-1, 0) relems in
            if i >= 0 then
                (KExpMem(a_id, i, kctx), code)
            else raise_compile_err nloc
                (sprintf "there is no record field '%s' in the record '%s'" (id2str n) (id2str rn))
        | (KTypName(vn), ExpIdent(n2, (etyp2, eloc2))) when (pp_id2str n2) = "__tag__" ->
            (KExpIntrin(IntrinVariantTag, (Atom.Id a_id) :: [], (KTypCInt, eloc)), code)
        | (_, _) ->
            raise_compile_err e1loc "unsupported access operation")
    | ExpAssign(e1, e2, _) ->
        let (a2, code) = exp2atom e2 code false sc in
        let (a_id, code) = exp2id e1 code true sc "a literal cannot be assigned" in
        let kv = get_kval a_id eloc in
        let {kv_flags; kv_typ} = kv in
        let kv_flags = match (e1, kv_typ) with
            | (ExpAt _, KTypArray _) -> {kv_flags with val_flag_subarray=true}
            | _ -> kv_flags
            in
        let kv = {kv with kv_flags = {kv_flags with val_flag_mutable=true}} in
        set_idk_entry a_id (KVal kv);
        (KExpAssign(a_id, a2, eloc), code)
    | ExpCast(e, _, _) ->
        let (a, code) = exp2atom e code false sc in
        (KExpCast(a, ktyp, eloc), code)
    | ExpTyped(e, t, _) ->
        let (a, code) = exp2atom e code false sc in
        let t = typ2ktyp t eloc in
        (KExpAtom(a, (t, eloc)), code)
    | ExpCCode(s, _) -> (KExpCCode(s, kctx), code)
    | ExpMatch(e1, cases, _) ->
        let loc1 = get_exp_loc e1 in
        let (a, code) = exp2atom e1 code false sc in
        let (b, code) = if not (is_mutable_atom a loc1) then (a, code) else
            let a_id = match a with
                | Atom.Id a_id -> a_id
                | _ -> raise_compile_err loc1 "k-norm: invalid mutable atom (id is expected)"
                in
            let t = get_atom_ktyp a loc1 in
            let b = dup_idk a_id in
            let code = create_kdefval b t (default_tempval_flags()) (Some (KExpAtom (a, (t, loc1)))) code loc1 in
            ((Atom.Id b), code)
            in
        let (k_cases, code) = transform_pat_matching b cases code sc eloc false in
        (KExpMatch(k_cases, kctx), code)
    | ExpTryCatch(e1, cases, _) ->
        let e1loc = get_exp_loc e1 in
        let try_sc = new_block_scope() :: sc in
        let (e1, body_code) = exp2kexp e1 [] false try_sc in
        let try_body = rcode2kexp (e1 :: body_code) e1loc in
        let exn_loc = match cases with
            | ((p :: _), _) :: _ -> get_pat_loc p
            | _ -> eloc in
        let exn_n = gen_temp_idk "exn" in
        let pop_e = KExpIntrin(IntrinPopExn, [], (KTypExn, exn_loc)) in
        let catch_sc = new_block_scope() :: sc in
        let catch_code = create_kdefval exn_n KTypExn (default_val_flags()) (Some pop_e) [] exn_loc in
        let (k_cases, catch_code) = transform_pat_matching (Atom.Id exn_n) cases catch_code catch_sc exn_loc true in
        let handle_exn = KExpMatch(k_cases, (ktyp, exn_loc)) in
        let handle_exn = rcode2kexp (handle_exn :: catch_code) exn_loc in
        (KExpTryCatch(try_body, handle_exn, kctx), code)
    | DefVal(p, e2, flags, _) ->
        let (e2, code) = exp2kexp e2 code true sc in
        let ktyp = get_kexp_typ e2 in
        (match (p, ktyp) with
        | (PatIdent(n, _), KTypVoid) ->
            let dv = { kv_name=n; kv_cname=""; kv_typ=ktyp; kv_flags=flags; kv_loc=eloc } in
            set_idk_entry n (KVal dv);
            (e2, code)
        | _ ->
            let (v, code) = pat_simple_unpack p ktyp (Some e2) code "v" flags sc in
            (*  if pat_simple_unpack returns (noid, code), it means that the pattern p does
                not contain variables to capture, i.e. user wrote something like
                    val _ = <exp> or
                    val (_, (_, _)) = <exp> etc.,
                which means that the assignment was not generated, but we need to retain <exp>,
                because it likely has some side effects *)
            if v = noid then (e2, code) else ((KExpNop eloc), code))
    | DefFun df ->
        let code = transform_fun df code sc in ((KExpNop eloc), code)
    | DefTyp _ -> (KExpNop(eloc), code)
    | DefVariant _ -> (KExpNop(eloc), code) (* variant declarations are handled in batch in transform_all_types_and_cons *)
    | DefExn _ -> (KExpNop(eloc), code) (* exception declarations are handled in batch in transform_all_types_and_cons *)
    | DefClass _ -> raise_compile_err eloc "classes are not supported yet"
    | DefInterface _ -> raise_compile_err eloc "interfaces are not supported yet"
    | DirImport _ -> (KExpNop(eloc), code)
    | DirImportFrom _ -> (KExpNop(eloc), code)
    | DirPragma _ -> (KExpNop(eloc), code)

and exp2atom e code tref sc =
    let (e, code) = exp2kexp e code tref sc in
    kexp2atom "v" e tref code

and atom2id a loc msg =
    match a with
    | Atom.Id i -> i
    | Atom.Lit _ -> raise_compile_err loc msg

and exp2id e code tref sc msg =
    let (a, code) = exp2atom e code tref sc in
    ((atom2id a (get_exp_loc e) msg), code)

and exp2dom e code sc =
    match e with
    | ExpRange _ ->
        let (ek, code) = exp2kexp e code false sc in
        (match ek with
        | KExpMkTuple(a :: b :: c :: [], _) -> (Domain.Range(a, b, c), code)
        | _ -> raise_compile_err (get_exp_loc e) "the range was not converted to a 3-element tuple as expected")
    | _ ->
        let (i, code) = exp2atom e code false sc in
        (Domain.Elem i, code)

and eseq2code eseq code sc =
    let code = transform_all_types_and_cons eseq code sc in
    let pragmas = ref ([]: (string*loc_t) list) in
    let rec knorm_eseq eseq code = (match eseq with
        | DirPragma (prl, loc) :: rest ->
            List.iter (fun pr -> pragmas := (pr, loc) :: !pragmas) prl;
            knorm_eseq rest code
        | ei :: rest ->
            let (eki, code) = exp2kexp ei code false sc in
            let code = (match eki with
                | KExpNop _ -> code
                | _ -> eki :: code) in
            knorm_eseq rest code
        | [] -> code) in
    let code = knorm_eseq eseq code in
    (code, !pragmas)

(* finds if the pattern contains variables to capture. We could have
   combined this and the next function into one, but then we would
   have to scan the whole pattern (or need more complex code
   to do early exit).
   Besides, most of the time (for value declarations, loop iteration variables,
   function arguments ...) we know already that a pattern does not need checks,
   so we just need have_variables for it *)
and pat_have_vars p = match p with
    | PatAny _ | PatLit _ -> false
    | PatIdent _ | PatAs _ -> true
    | PatCons(p1, p2, _) -> (pat_have_vars p1) || (pat_have_vars p2)
    | PatTyped(p, _, _) -> pat_have_vars p
    | PatTuple(pl, _) -> List.exists pat_have_vars pl
    | PatVariant(_, pl, _) -> List.exists pat_have_vars pl
    | PatRecord(_, ip_l, _) -> List.exists (fun (_, pi) -> pat_have_vars pi) ip_l
    | PatRef(p, _) -> pat_have_vars p
    | PatWhen(p, _, _) -> pat_have_vars p

(* version of Ast_typecheck.get_record_elems, but for already transformed types *)
and get_record_elems_k vn_opt t loc =
    let t = deref_ktyp t loc in
    let input_vn = match vn_opt with
        | Some(vn) -> get_orig_id vn
        | _ -> noid
        in
    match t with
    | KTypRecord (_, relems) -> ((noid, t, false), relems)
    | KTypName tn ->
        (match (kinfo_ tn loc) with
        | KVariant {contents={kvar_flags; kvar_cases=(vn0, (KTypRecord (_, relems) as rectyp))::[]}}
            when kvar_flags.var_flag_record ->
                if input_vn = noid || input_vn = (get_orig_id vn0) then ()
                else raise_compile_err loc (sprintf "mismatch in the record name: given '%s', expected '%s'"
                    (pp_id2str input_vn) (pp_id2str vn0));
                ((noid, rectyp, false), relems)
        | KVariant {contents={kvar_cases; kvar_ctors}} ->
            let kvar_cases_ctors = Utils.zip kvar_cases kvar_ctors in
            (match (List.find_opt (fun ((vn, t), c_id) -> (get_orig_id vn) = (get_orig_id input_vn)) kvar_cases_ctors) with
            | Some(((_, (KTypRecord (_, relems) (*as rectyp*))), ctor)) ->
                let rectyp = match relems with
                    | (_, t) :: [] -> t
                    | _ -> KTypTuple (List.map (fun (_, t) -> t) relems)
                    in
                ((ctor, rectyp, (List.length kvar_cases) > 1), relems)
            | _ -> raise_compile_err loc (sprintf "tag '%s' is not found or is not a record" (pp_id2str input_vn)))
        | _ -> raise_compile_err loc (sprintf "type '%s' is expected to be variant" (id2str tn)))
    | _ -> raise_compile_err loc "attempt to treat non-record and non-variant as a record"

and match_record_pat pat ptyp =
    match pat with
    | PatRecord(rn_opt, relems, loc) ->
        let ((ctor, t, multiple_cases), relems_found) = get_record_elems_k rn_opt ptyp loc in
        let typed_rec_pl = List.fold_left (fun typed_rec_pl (ni, pi) ->
            let ni_orig = get_orig_id ni in
            let (_, found_idx, found_t) = List.fold_left
                (fun (idx, found_idx, found_t) (nj, tj) ->
                    if (get_orig_id nj) = ni_orig then
                        (idx+1, idx, tj)
                    else
                        (idx+1, found_idx, found_t))
                (0, -1, KTypVoid) relems_found
                in
            if found_idx >= 0 then
                (ni, pi, found_t, found_idx) :: typed_rec_pl
            else
                raise_compile_err loc (sprintf "element '%s' is not found in the record '%s'"
                    (pp_id2str ni) (pp_id2str (Utils.opt_get rn_opt noid))))
            [] relems
            in
        ((ctor, t, multiple_cases, (List.length relems_found) > 1), typed_rec_pl)
    | _ -> raise_compile_err (get_pat_loc pat) "record (or sometimes an exception) is expected"

and get_kvariant t loc =
    let t = deref_ktyp t loc in
    match t with
    | KTypName tn ->
        (match (kinfo_ tn loc) with
        | KVariant kvar -> kvar
        | _ -> raise_compile_err loc (sprintf "type '%s' is expected to be variant" (id2str tn)))
    | _ -> raise_compile_err loc "variant (or sometimes an exception) is expected here"

and match_variant_pat pat ptyp =
    match pat with
    | PatVariant(vn0, pl, loc) ->
        let {kvar_cases; kvar_ctors; kvar_loc} = !(get_kvariant ptyp loc) in
        let kvar_cases_ctors = Utils.zip kvar_cases kvar_ctors in
        (match (List.find_opt (fun ((vn, t), c_id) -> (get_orig_id vn) = (get_orig_id vn0)) kvar_cases_ctors) with
        | Some ((_, t), ctor) ->
            let tl = match t with KTypTuple(tl) -> tl | _ -> [t] in
            let _ = if (List.length pl) = (List.length tl) then () else
                raise_compile_err loc
                (sprintf "the number of variant pattern arguments does not match the number of '%s' parameters.\nSee %s"
                (pp_id2str ctor) (loc2str kvar_loc)) in
            let typed_var_pl = List.fold_left2 (fun typed_var_pl p t -> (p, t) :: typed_var_pl) [] pl tl in
            ((ctor, t), (List.rev typed_var_pl))
        | _ -> raise_compile_err loc (sprintf "tag '%s' is not found or is not a record" (pp_id2str vn0)))
    | _ -> raise_compile_err (get_pat_loc pat) "variant pattern is expected"

and pat_need_checks p ptyp =
    let check_if_exn e loc =
        match (deref_ktyp ptyp loc) with
        | KTypExn -> true (* in the case of exceptions we always need to check the tag,
                            so the response from pat_need_checks() is 'true' *)
        | _ -> raise e
        in
    match p with
    | PatAny _ | PatIdent _ | PatAs _ -> false
    | PatLit _ -> true
    | PatCons(_, _, _) -> true (* the check for non-empty list is needed *)
    | PatTyped(p, _, _) -> pat_need_checks p ptyp
    | PatTuple(pl, loc) ->
        let tl = match ptyp with
            | KTypTuple(tl) -> tl
            | _ -> raise_compile_err loc "this pattern needs a tuple as argument" in
        List.exists2 (fun pi ti -> pat_need_checks pi ti) pl tl
    | PatVariant(vn, pl, loc) ->
        (try
            let {kvar_cases; kvar_ctors} = !(get_kvariant ptyp loc) in
            (List.length kvar_cases) > 1 ||
            (let (_, typed_var_pl) = match_variant_pat p ptyp in
            List.exists (fun (p, t) -> pat_need_checks p t) typed_var_pl)
        with (CompileError _) as e -> check_if_exn e loc)
    | PatRecord (rn_opt, _, loc) ->
        (try
            let ((_, _, multiple_cases, _), typed_rec_pl) = match_record_pat p ptyp in
            multiple_cases || (List.exists (fun (_, pi, ti, _) -> pat_need_checks pi ti) typed_rec_pl)
        with (CompileError _) as e -> check_if_exn e loc)
    | PatRef (p, loc) ->
        let t = match ptyp with
            | KTypRef t -> t
            | _ -> raise_compile_err loc "this pattern needs a reference as argument"
            in
        pat_need_checks p t
    | PatWhen _ -> true

and pat_propose_id p ptyp temp_prefix is_simple mutable_leaves sc =
    let p = pat_skip_typed p in
    match p with
    | PatAny _ -> (p, noid, false)
    | PatIdent(n, _) -> (p, n, false)
    | PatAs(p, n, ploc) ->
        if mutable_leaves then
            raise_compile_err ploc "'as' pattern cannot be used with var's, only with values"
        else ();
        ((pat_skip_typed p), n, true)
    | _ ->
        if (pat_have_vars p) || (not is_simple && (pat_need_checks p ptyp))
        then (p, (gen_temp_idk temp_prefix), true)
        else (p, noid, false)

and pat_simple_unpack p ptyp e_opt code temp_prefix flags sc =
    let (tup_elems, need_tref) = match e_opt with
        | Some e ->
            (match e with
            | KExpIntrin _ | KExpAt _ | KExpMem _ | KExpUnOp(OpDeref, _, _) -> ([], true)
            | KExpMkTuple(elems, _) -> (elems, false)
            | _ -> ([], false))
        | None -> ([], true)
        in
    let mutable_leaves = flags.val_flag_mutable in
    let n_flags = {flags with val_flag_mutable=false; val_flag_tempref=false} in
    let (p, n, tref) = pat_propose_id p ptyp temp_prefix true mutable_leaves sc in
    let tref = tref && need_tref in
    if n = noid then
        (n, code)
    else
    let loc = get_pat_loc p in
    let n_flags = if mutable_leaves && not tref then {n_flags with val_flag_mutable=true}
                else if tref then {n_flags with val_flag_tempref=true} else n_flags in
    let n_flags = match sc with
        | ScGlobal :: _ | ScModule _ :: _ -> {n_flags with val_flag_global=sc}
        | _ -> n_flags
        in
    let code = create_kdefval n ptyp n_flags e_opt code loc in
    let code =
    (match p with
    | PatTuple(pl, loc) ->
        let tl = match ptyp with
            | KTypTuple(tl) ->
                if (List.length tl) != (List.length pl) then
                    raise_compile_err loc "the number of elements in the pattern and in the tuple type are different"
                else
                    tl
            | _ -> raise_compile_err loc "invalid type of the tuple pattern (it must be a tuple as well)" in
        let (_, code) = List.fold_left2 (fun (idx, code) pi ti ->
            let loci = get_pat_loc pi in
            let ei =
                if tup_elems <> [] then
                    KExpAtom((List.nth tup_elems idx), (ti, loc))
                else
                    KExpMem(n, idx, (ti, loci))
                in
            let (_, code) = pat_simple_unpack pi ti (Some ei) code temp_prefix flags sc in
            (idx + 1, code)) (0, code) pl tl in
        code
    | PatIdent _ -> code
    | PatVariant (vn, _, loc) ->
        let ((_, vt), typed_var_pl) = match_variant_pat p ptyp in
        let get_vcase = KExpIntrin(IntrinVariantCase, [(Atom.Id n); (Atom.Id vn)], (vt, loc)) in
        (match typed_var_pl with
        | (p, t) :: [] ->
            let (_, code) = pat_simple_unpack p t (Some get_vcase) code temp_prefix flags sc in
            code
        | _ ->
            let (ve, code) = kexp2atom "vcase" get_vcase true code in
            let ve_id = atom2id ve loc "variant case extraction should produce id, not literal" in
            let (_, code) = List.fold_left (fun (idx, code) (pi, ti) ->
                let loci = get_pat_loc pi in
                let ei = KExpMem(ve_id, idx, (ti, loci)) in
                let (_, code) = pat_simple_unpack pi ti (Some ei) code temp_prefix flags sc in
                (idx + 1, code)) (0, code) typed_var_pl
                in
            code)
    | PatRecord (rn_opt, _, _) ->
        let ((ctor, rectyp, _, multiple_relems), typed_rec_pl) = match_record_pat p ptyp in
        let (r_id, get_vcase, code2) = if ctor = noid then (n, (KExpNop loc), code) else
            let case_id = match rn_opt with (Some rn) -> rn | _ -> raise_compile_err loc "record tag should be non-empty here" in
            let get_vcase = KExpIntrin(IntrinVariantCase, [(Atom.Id n); (Atom.Id case_id)], (rectyp, loc)) in
            let (r, code2) = kexp2atom "vcase" get_vcase true code in
            ((atom2id r loc "variant case extraction should produce id, not literal"), get_vcase, code2)
            in
        (match ((ctor <> noid), multiple_relems, typed_rec_pl) with
        | (true, false, (_, p, t, _) :: []) ->
            let (_, code) = pat_simple_unpack p t (Some get_vcase) code temp_prefix flags sc in
            code
        | _ ->
            List.fold_left (fun code (_, pi, ti, ii) ->
                let ei = KExpMem(r_id, ii, (ti, loc)) in
                let (_, code) = pat_simple_unpack pi ti (Some ei) code temp_prefix flags sc in
                code) code2 typed_rec_pl)
    | PatAs _ ->
        let e = KExpAtom(Atom.Id n, (ptyp, loc)) in
        let (_, code) = pat_simple_unpack p ptyp (Some e) code temp_prefix flags sc in
        code
    | PatRef(p, loc) ->
        let t = match ptyp with
            | KTypRef(t) -> t
            | _ -> raise_compile_err loc "the argument of ref() pattern must be a reference"
            in
        let e = KExpUnOp(OpDeref, (Atom.Id n), (t, loc)) in
        let (_, code) = pat_simple_unpack p t (Some e) code temp_prefix n_flags sc in
        code
    | _ ->
        (*printf "pattern: "; Ast_pp.pprint_pat_x p; printf "\n";*)
        raise_compile_err loc "this type of pattern cannot be used here") in
    (n, code)

and transform_pat_matching a cases code sc loc catch_mode =
    (*
        We dynamically maintain 3 lists of the sub-patterns to consider next.
        Each new sub-pattern occuring during recursive processing of the top-level pattern
        is classified and is then either discarded or added to one of the 3 lists:
        * pl_c - the patterns that needs some checks to verify, but have no captured variables
        * pl_uc - need checks and have variables to capture
        * pl_u - need no checks, but have variables to capture.
        The first list pl_c grows from the both ends:
            * literals, as the easiest to check patterns, are added to the beginning of the list.
              So they get a higher priority.
            * other patterns are added to the end

        When we need to select the next sub-pattern to process, we first look at the first list (pl_c),
        if it's empty then we look at the second list (pl_uc) and finally we look at the third list (pl_u).
        Some sub-patterns in pl_uc could be then added to pl_c or pl_u (or discarded).

        We do such dispatching in order to minimize the number of read operations from a complex structure.
        That is, why capture a variable until all the checks are complete and we know we have a match.
        The algorithm does not always produce the most optimal sequence of operations
        (e.g. some checks are easier to do than the others etc., but it's probably good enough approximation)
    *)
    let dispatch_pat pinfo (pl_c, pl_cu, pl_u) =
        let { pinfo_p=p; pinfo_typ=ptyp } = pinfo in
        let need_checks = pat_need_checks p ptyp in
        let have_vars = pat_have_vars p in
        match (need_checks, have_vars) with
        | (true, false) ->
            (match p with
            | PatLit _ -> (pinfo :: pl_c, pl_cu, pl_u)
            | _ -> (pl_c @ (pinfo :: []), pl_cu, pl_u))
        | (true, true) ->
            (pl_c, pinfo :: pl_cu, pl_u)
        | (false, true) ->
            (pl_c, pl_cu, pinfo :: pl_u)
        | _ ->
            (* nothing to do with p, just discard it *)
            (pl_c, pl_cu, pl_u)
    in
    let get_extract_tag_exp a atyp loc =
        match (deref_ktyp atyp loc) with
        | KTypExn -> KExpIntrin(IntrinVariantTag, a :: [], (KTypCInt, loc))
        | KTypRecord _ -> KExpAtom(Atom.Lit (LitInt 0L), (KTypCInt, loc))
        | KTypName tn -> (match (kinfo_ tn loc) with
            | KVariant {contents={kvar_cases}} ->
                (match kvar_cases with
                | (n, _) :: [] -> KExpAtom((Atom.Id n), (KTypCInt, loc))
                | _ -> KExpIntrin(IntrinVariantTag, a :: [], (KTypCInt, loc)))
            | _ -> raise_compile_err loc (sprintf
                "k-normalize: enxpected type '%s'; record, variant of exception is expected here" (id2str tn)))
        | t -> raise_compile_err loc (sprintf
            "k-normalize: enxpected type '%s'; record, variant of exception is expected here" (ktyp2str t))
    in

    let rec process_next_subpat plists (checks, code) case_sc =
        let temp_prefix = "v" in
        let process_pat_list tup_id pti_l plists alt_ei_opt =
            match pti_l with
            | (PatAny _, _, _) :: [] -> plists
            | _ ->
                let (_, plists_delta) = List.fold_left (fun (idx, plists_delta) (pi, ti, idxi) ->
                let loci = get_pat_loc pi in
                let ei = match alt_ei_opt with
                    | Some(ei) ->
                        if idx = 0 then () else raise_compile_err loci
                            "a code for singe-argument variant case handling is used with a case with multiple patterns";
                        ei
                    | _ ->
                        KExpMem(tup_id, idxi, (ti, loci)) in
                let pinfo_i = {pinfo_p=pi; pinfo_typ=ti; pinfo_e=ei; pinfo_tag=noid} in
                (idx + 1, pinfo_i :: plists_delta)) (0, []) pti_l in
                let plists = List.fold_left (fun plists pinfo -> dispatch_pat pinfo plists) plists plists_delta in
                plists
        in
        let get_var_tag_cmp_and_extract n pinfo (checks, code) vn sc loc =
            (* [TODO] avoid tag check when the variant has just a single case *)
            let {pinfo_tag=var_tag0; pinfo_typ} = pinfo in
            let (c_args, vn_tag_val, vn_case_val) = match (kinfo_ vn loc) with
                | KFun {contents={kf_args; kf_flags}} ->
                    let (_, c_args) = Utils.unzip kf_args in
                    let ctor = get_fun_ctor kf_flags in
                    let vn_val = match ctor with CtorVariant tv -> (Atom.Id tv) | _ -> Atom.Lit (LitInt 0L) in
                    (c_args, vn_val, vn_val)
                | KExn {contents={ke_typ; ke_tag}} ->
                    ((match ke_typ with
                    | KTypTuple(args) -> args
                    | KTypVoid -> []
                    | _ -> ke_typ :: []), (Atom.Id ke_tag), (Atom.Id vn))
                | KVal {kv_flags} ->
                    let ctor_id = get_val_ctor kv_flags in
                    let vn_val = if ctor_id <> noid then (Atom.Id ctor_id) else Atom.Lit (LitInt 0L) in
                    ([], vn_val, vn_val)
                | k ->
                    raise_compile_err loc (sprintf "a variant constructor ('%s') is expected here" (id2str vn)) in

            let (tag_n, code) =
                if var_tag0 != noid then (var_tag0, code) else
                (let tag_n = gen_temp_idk "tag" in
                let extract_tag_exp = get_extract_tag_exp (Atom.Id n) pinfo_typ loc in
                let code = create_kdefval tag_n KTypCInt (default_val_flags())
                    (Some extract_tag_exp) code loc in
                (tag_n, code))
                in
            let cmp_tag_exp = KExpBinOp(OpCompareEQ, (Atom.Id tag_n), vn_tag_val, (KTypBool, loc)) in
            let checks = (rcode2kexp (cmp_tag_exp :: code) loc) :: checks in
            let (case_n, code, alt_e_opt) = match c_args with
                | [] -> (noid, [], None)
                | _ ->
                    let (is_tuple, case_typ) = match c_args with t :: [] -> (false, t) | _ -> (true, KTypTuple(c_args)) in
                    let extract_case_exp = KExpIntrin(IntrinVariantCase,
                        (Atom.Id n) :: vn_case_val :: [], (case_typ, loc)) in
                    if is_tuple then
                        let case_n = gen_temp_idk "vcase" in
                        let code = create_kdefval case_n case_typ
                            (default_tempref_flags()) (Some extract_case_exp) [] loc in
                        (case_n, code, None)
                    else
                        (noid, [], (Some extract_case_exp))
            in (case_n, c_args, checks, code, alt_e_opt)
        in
        let (p_opt, plists) = match plists with
            | (p :: pl_c, pl_cu, pl_u) -> ((Some p), (pl_c, pl_cu, pl_u))
            | ([], p :: pl_cu, pl_u) -> ((Some p), ([], pl_cu, pl_u))
            | ([], [], p :: pl_u) -> ((Some p), ([], [], pl_u))
            | _ -> (None, ([], [], [])) in
        match p_opt with
        | Some(pinfo) ->
            let {pinfo_p=p; pinfo_typ=ptyp; pinfo_e=ke; pinfo_tag=var_tag0} = pinfo in
            let (p, n, tref) = pat_propose_id p ptyp temp_prefix false false case_sc in
            if n = noid then process_next_subpat plists (checks, code) case_sc else
            let loc = get_pat_loc p in
            let (n, code) = match (ke, tref) with
                | (KExpAtom((Atom.Id n0), _), true) -> (n0, code)
                | _ ->
                    let flags = if (is_ktyp_scalar ptyp) then (default_tempval_flags())
                        else (default_tempref_flags()) in
                    let code = create_kdefval n ptyp flags (Some ke) code loc in
                    (n, code) in
            let (plists, checks, code) =
            (match p with
            | PatLit (l, _) ->
                let code = KExpBinOp(OpCompareEQ, (Atom.Id n), (Atom.Lit l), (KTypBool, loc)) :: code in
                let c_exp = rcode2kexp code loc in
                (plists, c_exp :: checks, [])
            | PatIdent _ -> (plists, checks, code)
            | PatCons(p1, p2, _) ->
                let code = KExpBinOp(OpCompareNE, (Atom.Id n), (Atom.Lit LitNil), (KTypBool, loc)) :: code in
                let c_exp = rcode2kexp code loc in
                let et = match ptyp with
                        | KTypList et -> et
                        | _ -> raise_compile_err loc "the pattern needs list type" in
                let get_hd_exp = KExpIntrin(IntrinListHead, (Atom.Id n) :: [], (et, loc)) in
                let get_tl_exp = KExpIntrin(IntrinListTail, (Atom.Id n) :: [], (ptyp, loc)) in
                let p_hd = {pinfo_p=p1; pinfo_typ=et; pinfo_e=get_hd_exp; pinfo_tag=noid} in
                let p_tl = {pinfo_p=p2; pinfo_typ=ptyp; pinfo_e=get_tl_exp; pinfo_tag=noid} in
                let plists = dispatch_pat p_hd plists in
                let plists = dispatch_pat p_tl plists in
                (plists, c_exp :: checks, [])
            | PatTuple(pl, loc) ->
                let tl = match ptyp with
                    | KTypTuple(tl) -> tl
                    | _ -> raise_compile_err loc "invalid type of the tuple pattern (it must be a tuple as well)" in
                let (_, pti_l) = List.fold_left2 (fun (idx, pti_l) pi ti ->
                    (idx+1, ((pi, ti, idx) :: pti_l))) (0, []) pl tl in
                let plists = process_pat_list n pti_l plists None in
                (plists, checks, code)
            | PatVariant(vn, pl, loc) ->
                let (case_n, tl, checks, code, alt_e_opt) =
                    get_var_tag_cmp_and_extract n pinfo (checks, code) vn case_sc loc in
                let plists =
                    if case_n = noid && (Utils.is_none alt_e_opt) then plists
                    else
                        let (_, pti_l) = List.fold_left2 (fun (idx, pti_l) pi ti ->
                            (idx+1, ((pi, ti, idx) :: pti_l))) (0, []) pl tl in
                        process_pat_list case_n pti_l plists alt_e_opt
                    in
                (plists, checks, code)
            | PatRecord(rn_opt, _, loc) ->
                let (case_n, _, checks, code, alt_e_opt) = match rn_opt with
                    | Some rn -> get_var_tag_cmp_and_extract n pinfo (checks, code) rn case_sc loc
                    | _ -> (n, [], checks, code, None)
                    in
                let plists = if case_n = noid && (Utils.is_none alt_e_opt) then plists
                    else
                        let (_, ktyp_rec_pl) = match_record_pat p ptyp in
                        let pti_l = List.map (fun (_, pi, ti, idxi) -> (pi, ti, idxi)) ktyp_rec_pl in
                        process_pat_list case_n pti_l plists alt_e_opt
                    in
                (plists, checks, code)
            | PatAs (p, _, _) ->
                let pinfo = {pinfo_p=p; pinfo_typ=ptyp; pinfo_e=KExpAtom((Atom.Id n), (ptyp, loc)); pinfo_tag=var_tag0} in
                let plists = dispatch_pat pinfo plists in
                (plists, checks, code)
            | PatRef (p, _) ->
                let t = match ptyp with
                    | KTypRef t -> t
                    | _ -> raise_compile_err loc "the ref() pattern needs reference type" in
                let get_val = KExpUnOp(OpDeref, (Atom.Id n), (t, loc)) in
                let pinfo_p = {pinfo_p=p; pinfo_typ=t; pinfo_e=get_val; pinfo_tag=noid} in
                let plists = dispatch_pat pinfo_p plists in
                (plists, checks, code)
            | PatWhen (p, e, _) ->
                let pinfo = {pinfo_p=p; pinfo_typ=ptyp; pinfo_e=KExpAtom((Atom.Id n), (ptyp, loc)); pinfo_tag=var_tag0} in
                let plists = dispatch_pat pinfo plists in
                (* process everything inside *)
                let (checks, code) = process_next_subpat plists (checks, code) case_sc in
                (* and add the final check in the end *)
                let (ke, code) = exp2kexp e code true sc in
                let c_exp = rcode2kexp (ke :: code) loc in
                (([], [], []), (c_exp :: checks), [])
            | _ ->
                (*printf "pattern: "; Ast_pp.pprint_pat_x p; printf "\n";*)
                raise_compile_err loc "this type of pattern is not supported yet")
            in process_next_subpat plists (checks, code) case_sc
        | _ -> (checks, code)
    in
    let atyp = get_atom_ktyp a loc in
    let is_variant = match atyp with
        | KTypExn -> true
        | KTypName(tname) -> (match (kinfo_ tname loc) with
            | KVariant _ -> true
            | _ -> false)
        | _ -> false in
    let (var_tag0, code) = if not is_variant then (noid, code) else
        (let tag_n = gen_temp_idk "tag" in
        let extract_tag_exp = get_extract_tag_exp a atyp loc in
        let code = create_kdefval tag_n KTypCInt (default_val_flags()) (Some extract_tag_exp) code loc in
        (tag_n, code)) in
    let have_else = ref false in
    let k_cases = List.map (fun (pl, e) ->
        let ncases = List.length pl in
        let p0 = List.hd pl in
        let ploc = get_pat_loc p0 in
        let _ = if ncases = 1 then () else
            raise_compile_err ploc "multiple alternative patterns are not supported yet" in
        let pinfo={pinfo_p=p0; pinfo_typ=atyp; pinfo_e=KExpAtom(a, (atyp, loc)); pinfo_tag=var_tag0} in
        let _ = if not !have_else then () else
            raise_compile_err ploc "unreacheable pattern matching case" in
        let plists = dispatch_pat pinfo ([], [], []) in
        let case_sc = new_block_scope() :: sc in
        let (checks, case_code) = process_next_subpat plists ([], []) case_sc in
        let (ke, case_code) = exp2kexp e case_code false case_sc in
        let eloc = get_exp_loc e in
        let ke = rcode2kexp (ke :: case_code) eloc in
        if checks = [] then have_else := true else ();
        ((List.rev checks), ke)) cases in
    let k_cases = if !have_else then k_cases else
        if catch_mode then
            let rethrow_exp = KExpThrow((atom2id a loc "internal error: a literal cannot occur here"), true, loc) in
            k_cases @ [([], rethrow_exp)]
        else
            let _ = if !builtin_exn_NoMatchError != noid then () else
                raise_compile_err loc "internal error: NoMatchError exception is not found" in
            let nomatch_err = KExpThrow(!builtin_exn_NoMatchError, false, loc) in
            k_cases @ [([], nomatch_err)]
    in (k_cases, code)

and transform_fun df code sc =
    let {df_name; df_templ_args; df_templ_inst; df_body; df_loc} = !df in
    let is_private_fun = match sc with ScGlobal :: _ | ScModule _ :: _ -> false | _ -> true in
    let inst_list = if df_templ_args = [] then df_name :: [] else df_templ_inst in
    List.fold_left (fun code inst ->
        match (id_info inst) with
        | IdFun inst_df ->
            let {df_name=inst_name; df_args=inst_args;
                df_typ=inst_typ; df_body=inst_body; df_flags=inst_flags; df_loc=inst_loc} = !inst_df in
            let ktyp = typ2ktyp inst_typ df_loc in
            let (argtyps, rt) = match ktyp with
                | KTypFun(argtyps, rt) -> (argtyps, rt)
                | _ -> raise_compile_err inst_loc
                    (sprintf "the type of non-constructor function '%s' should be TypFun(_,_)" (id2str inst_name)) in
            let (inst_args, argtyps, inst_body) =
                if not inst_flags.fun_flag_has_keywords then (inst_args, argtyps, inst_body) else
                match ((List.rev inst_args), (List.rev argtyps), inst_body) with
                | (_ :: rest_inst_args, KTypRecord (_, relems) :: rest_argtyps,
                    ExpSeq((DefVal(PatRecord(_, relems_pats, _), ExpIdent(_, _), _, loc)) :: rest_inst_body, body_ctx)) ->
                    if (List.length relems) = (List.length relems_pats) then ()
                    else raise_compile_err loc "the number of pattern elems in the unpack operation is incorrect";
                    if (List.length rest_argtyps) = (List.length rest_inst_args) then ()
                    else raise_compile_err loc "the number of positional arguments and their types do not match";
                    let (inst_args, argtyps) = List.fold_left2 (fun (inst_args, argtyps) (ni, ti) (ni_, pi) ->
                        if ni = ni_ then () else raise_compile_err loc
                        (sprintf "the record field '%s' does not match the record pattern field '%s'" (id2str ni) (id2str ni_));
                        (pi :: inst_args, ti :: argtyps)) (rest_inst_args, rest_argtyps) relems relems_pats
                        in
                    ((List.rev inst_args), (List.rev argtyps), ExpSeq(rest_inst_body, body_ctx))
                | _ ->
                    raise_compile_err df_loc
                    "the function with keyword parameters must have the anonymous record as the last parameter and should start with the record unpacking"
                in
            let nargs = List.length inst_args in
            let nargtypes = List.length argtyps in
            let _ = if nargs = nargtypes then () else
                raise_compile_err inst_loc
                    (sprintf "the number of argument patterns (%d) and the number of argument types (%d) do not match"
                    nargs nargtypes) in
            let body_sc = new_block_scope() :: sc in
            let (_, args, body_code) = List.fold_left2 (fun (idx, args, body_code) pi ti ->
                let arg_defname = "arg" ^ (string_of_int idx) in
                let (i, body_code) = pat_simple_unpack pi ti None body_code arg_defname
                    (default_val_flags()) body_sc in
                let i = match i with Id.Name _ -> dup_idk i | _ -> i in
                let _ = create_kdefval i ti (default_arg_flags()) None [] inst_loc in
                (idx+1, ((i, ti) :: args), body_code)) (0, [], []) inst_args argtyps in
            let inst_flags = {inst_flags with fun_flag_ccode =
                (match inst_body with ExpCCode _ -> true | _ -> false);
                fun_flag_private=is_private_fun} in
            (* create initial function definition to handle recursive functions *)
            let _ = create_kdeffun inst_name (List.rev args) rt inst_flags None code sc inst_loc in
            let body_loc = get_exp_loc inst_body in
            let (e, body_code) = exp2kexp inst_body body_code false body_sc in
            let body_kexp = rcode2kexp (e :: body_code) body_loc in
            create_kdeffun inst_name (List.rev args) rt inst_flags (Some body_kexp) code sc inst_loc
        | i -> raise_compile_err (get_idinfo_loc i)
            (sprintf "the entry '%s' (an instance of '%s'?) is supposed to be a function, but it's not"
                (id2str inst) (id2str df_name)))
    code inst_list

and transform_all_types_and_cons elist code sc =
    List.fold_left (fun code e -> match e with
        | DefVariant {contents={dvar_name; dvar_templ_args; dvar_cases; dvar_templ_inst; dvar_scope; dvar_loc}} ->
            let inst_list = if dvar_templ_args = [] then dvar_name :: [] else dvar_templ_inst in
            let tags = List.map (fun (n, _) ->
                if n = noid then noid else
                    let tag_id = dup_idk n in
                    let tag_flags = {(default_val_flags()) with val_flag_global=dvar_scope} in
                    let _ = create_kdefval tag_id KTypInt tag_flags None [] dvar_loc in
                    tag_id) dvar_cases in
            List.fold_left (fun code inst ->
                match (id_info inst) with
                | IdVariant {contents={dvar_name=inst_name; dvar_alias=inst_alias; dvar_cases;
                                       dvar_ctors; dvar_flags; dvar_scope; dvar_loc=inst_loc}} ->
                    let targs = match (deref_typ inst_alias) with
                                | TypApp(targs, _) -> List.map (fun t -> typ2ktyp t inst_loc) targs
                                | _ -> raise_compile_err inst_loc
                                    (sprintf "invalid variant type alias '%s'; should be TypApp(_, _)" (id2str inst_name))
                                in
                    let code = (match (dvar_cases, dvar_flags.var_flag_record) with
                    | (((rn, TypRecord {contents=(relems, _)}) :: []), true) ->
                        let rec_elems=List.map (fun (i, t, _) -> (i, typ2ktyp t inst_loc)) relems in
                        let kt = ref { kt_name=inst_name; kt_cname=""; kt_targs=targs; kt_props=None;
                            kt_typ = KTypRecord(inst_name, rec_elems);
                            kt_scope=sc; kt_loc=inst_loc } in
                        let _ = set_idk_entry inst_name (KTyp kt) in
                        (KDefTyp kt) :: code
                    | _ ->
                        let kvar_cases = List.map2 (fun (i, t) tag -> (tag, typ2ktyp t inst_loc)) dvar_cases tags in
                        let kvar = ref { kvar_name=inst_name; kvar_cname=""; kvar_base_name=noid; kvar_targs=targs;
                                        kvar_props=None; kvar_cases=kvar_cases; kvar_ctors=dvar_ctors;
                                        kvar_flags=dvar_flags; kvar_scope=sc; kvar_loc=inst_loc } in
                        (*let cases_str = String.concat "| " (List.map (fun (n, t) ->
                            sprintf "%s: %s" (id2str n) (ktyp2str t)) kvar_cases) in
                        let _ = printf "kvar_cases: %s\n" cases_str in*)
                        let _ = set_idk_entry inst_name (KVariant kvar) in
                        let code = (KDefVariant kvar) :: code in
                        let new_rt = KTypName inst_name in
                        List.fold_left2 (fun code constr tag ->
                            match (id_info constr) with
                            | IdFun {contents={df_name; df_typ}} ->
                                let argtyps = match df_typ with
                                    | TypFun((TypRecord {contents=(relems, true)}) :: [], _) ->
                                        List.map (fun (n, t, _) -> t) relems
                                    | TypFun(argtyps, _) -> argtyps
                                    | _ -> []
                                    in
                                let kargtyps = List.map (fun t -> typ2ktyp t dvar_loc) argtyps in
                                let code = match kargtyps with
                                | [] ->
                                    let e0 = KExpAtom((Atom.Id tag), (new_rt, dvar_loc)) in
                                    let cflags = {(default_val_flags()) with val_flag_global=sc;
                                        val_flag_mutable=true; val_flag_ctor=tag}
                                        in
                                    create_kdefval df_name new_rt cflags (Some e0) code dvar_loc
                                | _ ->
                                    create_kdefconstr df_name kargtyps new_rt (CtorVariant tag) code sc dvar_loc
                                in code
                            | _ -> raise_compile_err dvar_loc
                                (sprintf "the constructor '%s' of variant '%s' is not a function apparently" (id2str constr) (id2str inst)))
                            code dvar_ctors tags)
                    in code
                | _ -> raise_compile_err dvar_loc
                        (sprintf "the instance '%s' of variant '%s' is not a variant" (id2str inst) (id2str dvar_name)))
            code inst_list
        | DefExn {contents={dexn_name; dexn_typ; dexn_loc; dexn_scope}} ->
            let is_std = match (dexn_scope, (deref_typ dexn_typ)) with
                (((ScModule m) :: _), TypVoid) when (pp_id2str m) = "Builtins" ->
                    let exn_name_str = pp_id2str dexn_name in
                    if exn_name_str = "OutOfRangeError" then
                        builtin_exn_OutOfRangeError := dexn_name
                    else if exn_name_str = "NoMatchError" then
                        builtin_exn_NoMatchError := dexn_name
                    else
                        ();
                    true
                | _ -> false in
            let tagname = gen_idk ((pp_id2str dexn_name) ^ "_tag") in
            let tag_sc = get_module_scope sc in
            let tag_flags = {(default_val_flags()) with val_flag_global=tag_sc; val_flag_mutable=true} in
            let decl_tag = create_kdefval tagname KTypCInt tag_flags
                (Some (KExpAtom(Atom.Lit (LitInt 0L), (KTypInt, dexn_loc))))
                [] dexn_loc in
            let code = if is_std then code else decl_tag @ code in
            let dexn_typ = match (deref_typ dexn_typ) with
                | TypRecord {contents=(relems, true)} ->
                    TypTuple(List.map (fun (_, t, _) -> t) relems)
                | _ -> dexn_typ
                in
            let ke_typ = typ2ktyp dexn_typ dexn_loc in
            let (make_id, delta_code) = match ke_typ with
                | KTypVoid -> (noid, [])
                | _ ->
                    let make_id = gen_idk ("make_" ^ (pp_id2str dexn_name)) in
                    let argtyps = match ke_typ with
                        | KTypTuple(telems) -> telems
                        | _ -> ke_typ :: []
                        in
                    let delta_code = create_kdefconstr make_id argtyps KTypExn
                        (CtorExn dexn_name) [] dexn_scope dexn_loc in
                    (make_id, delta_code)
                in
            let ke = ref { ke_name=dexn_name; ke_cname=""; ke_base_cname="";
                ke_typ=ke_typ; ke_std=is_std; ke_tag=tagname; ke_make=make_id;
                ke_scope=sc; ke_loc=dexn_loc } in
            set_idk_entry dexn_name (KExn ke);
            delta_code @ ((KDefExn ke) :: code)
        | _ -> code) code elist

let normalize_mod m is_main =
    let _ = idx_access_stack := [] in
    let minfo = !(get_module m) in
    let modsc = (ScModule m) :: [] in
    let (kcode, pragmas) = eseq2code (minfo.dm_defs) [] modsc in
    {km_name=m; km_cname=(pp_id2str m); km_top=(List.rev kcode);
    km_main=is_main; km_pragmas=parse_pragmas pragmas}
