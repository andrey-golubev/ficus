(*
    This file is a part of ficus language project.
    See ficus/LICENSE for the licensing terms
*)

(*
    K-normal form (or K-form in short) definition.
    This is a greatly extended variant of K-normal form in min-caml:
    https://github.com/esumii/min-caml.

    Similarly to ficus AST, which is defined in ast.ml,
    K-form is an hierarchical (tree-like) representation of
    the compiled code. However, it's much simpler and more
    suitable for intermediate optimizations and then for
    translation to some even lower-level representation, e.g. C code.

    In particular:

    * all the symbols in K-form are resolved and unique, e.g:
        fun foo(i: int) { val i = i+1; val i = i*2; for(i<-0:i) println(i) }
      is transformed to something like
        fun foo@999(i@1000: int): int {
          val i@1001: int = i@1000+1; val i@1002: int = i@1001*2
          for ((i@1003:int) <- 0:i@1002) println@56<int->void>(i@1003)
        }
    * all the symbols have known type. If it cannot be figured out,
      type checker or the k-form generator (see k_norm.ml) report compile error.
    * at once, all the types (typ_t) are converted to k-types (ktyp_t), i.e.
      all indirections are eliminated, instances of generic types
      (TypApp(<args...>, <some_generic_type_id>)) are replaced with concrete instances
      (KTypName(<instance_type_id>)) or even actual types where applicable.
    * all complex expressions are broken down into sequences of basic operations
      with intermediate results stored in temporary values.
    * pattern matching is converted into a sequences of nested if-expressions
    * import directives are removed; we've already resolved all the symbols
    * generic types and functions are removed. Their instances, generated
      by type checker, are retained though.
    * ...
*)
open Ast

type intrin_t =
    | IntrinPopExn
    | IntrinVariantTag
    | IntrinVariantCase
    | IntrinListHead
    | IntrinListTail
    | IntrinStrConcat
    | IntrinGetSize
    | IntrinCheckIdx (* (arr_sz, idx) *)
    | IntrinCheckIdxRange (* (arr_sz, a, b, delta, scale, shift) *)

type ktprops_t =
{
    ktp_complex: bool;
    ktp_scalar: bool;
    ktp_ptr: bool;
    ktp_pass_by_ref: bool;
    ktp_custom_free: bool;
    ktp_custom_copy: bool
}

type ktyp_t =
    | KTypInt
    | KTypCInt
    | KTypSInt of int
    | KTypUInt of int
    | KTypFloat of int
    | KTypVoid
    | KTypBool
    | KTypChar
    | KTypString
    | KTypCPointer
    | KTypFun of ktyp_t list * ktyp_t
    | KTypTuple of ktyp_t list
    | KTypRecord of id_t * (id_t * ktyp_t) list
    | KTypName of id_t
    | KTypArray of int * ktyp_t
    | KTypList of ktyp_t
    | KTypRef of ktyp_t
    | KTypExn
    | KTypErr
    | KTypModule
and klit_t =
    | KLitInt of int64
    | KLitSInt of int * int64
    | KLitUInt of int * int64
    | KLitFloat of int * float
    | KLitString of string
    | KLitChar of string
    | KLitBool of bool
    | KLitNil of ktyp_t
and atom_t = AtomId of id_t | AtomLit of klit_t
and dom_t = DomainElem of atom_t | DomainFast of atom_t | DomainRange of atom_t*atom_t*atom_t
and kctx_t = ktyp_t * loc_t
and kexp_t =
    | KExpNop of loc_t
    | KExpBreak of loc_t
    | KExpContinue of loc_t
    | KExpAtom of atom_t * kctx_t
    | KExpBinOp of binop_t * atom_t * atom_t * kctx_t
    | KExpUnOp of unop_t * atom_t * kctx_t
    | KExpIntrin of intrin_t * atom_t list * kctx_t
    | KExpSeq of kexp_t list * kctx_t
    | KExpIf of kexp_t * kexp_t * kexp_t * kctx_t
    | KExpCall of id_t * atom_t list * kctx_t
    | KExpMkTuple of atom_t list * kctx_t
    | KExpMkRecord of atom_t list * kctx_t
    | KExpMkClosure of id_t * id_t * atom_t list * kctx_t (* (function id, list of actual free vars) *)
    | KExpMkArray of (bool * atom_t) list list * kctx_t
    | KExpAt of atom_t * border_t * interpolate_t * dom_t list * kctx_t
    | KExpMem of id_t * int * kctx_t
    | KExpAssign of id_t * atom_t * loc_t
    | KExpMatch of ((kexp_t list) * kexp_t) list * kctx_t
    | KExpTryCatch of kexp_t * kexp_t * kctx_t
    | KExpThrow of id_t * bool * loc_t
    | KExpCast of atom_t * ktyp_t * loc_t
    | KExpMap of (kexp_t * (id_t * dom_t) list * id_t list) list * kexp_t * for_flags_t * kctx_t
    | KExpFor of (id_t * dom_t) list * id_t list * kexp_t * for_flags_t * loc_t
    | KExpWhile of kexp_t * kexp_t * loc_t
    | KExpDoWhile of kexp_t * kexp_t * loc_t
    | KExpCCode of string * kctx_t
    | KDefVal of id_t * kexp_t * loc_t
    | KDefFun of kdeffun_t ref
    | KDefExn of kdefexn_t ref
    | KDefVariant of kdefvariant_t ref
    | KDefTyp of kdeftyp_t ref
    | KDefClosureVars of kdefclosurevars_t ref
and kdefval_t = { kv_name: id_t; kv_cname: string; kv_typ: ktyp_t;
                  kv_flags: val_flags_t; kv_loc: loc_t }
and kdefclosureinfo_t = { kci_arg: id_t; kci_fcv_t: id_t; kci_fp_typ: id_t; kci_make_fp: id_t; kci_wrap_f: id_t }
and kdeffun_t = { kf_name: id_t; kf_cname: string;
                  kf_args: (id_t * ktyp_t) list; kf_rt: ktyp_t; kf_body: kexp_t;
                  kf_flags: fun_flags_t; kf_closure: kdefclosureinfo_t;
                  kf_scope: scope_t list; kf_loc: loc_t }
and kdefexn_t = { ke_name: id_t; ke_cname: string; ke_base_cname: string;
                  ke_typ: ktyp_t; ke_std: bool; ke_tag: id_t; ke_make: id_t;
                  ke_scope: scope_t list; ke_loc: loc_t }
and kdefvariant_t = { kvar_name: id_t; kvar_cname: string; kvar_base_name: id_t;
                      kvar_props: ktprops_t option; kvar_targs: ktyp_t list;
                      kvar_cases: (id_t * ktyp_t) list; kvar_ctors: id_t list;
                      kvar_flags: var_flags_t; kvar_scope: scope_t list; kvar_loc: loc_t }
and kdeftyp_t = { kt_name: id_t; kt_cname: string; kt_props: ktprops_t option;
                  kt_targs: ktyp_t list; kt_typ: ktyp_t; kt_scope: scope_t list; kt_loc: loc_t }
and kdefclosurevars_t = { kcv_name: id_t; kcv_cname: string;
                          kcv_freevars: (id_t * ktyp_t) list; kcv_orig_freevars: id_t list;
                          kcv_scope: scope_t list; kcv_loc: loc_t }
and kmodule_t = { km_name: id_t; km_cname: string; km_top: kexp_t list;
                  km_main: bool; km_pragmas: pragmas_t }

type kinfo_t =
    | KNone | KVal of kdefval_t | KFun of kdeffun_t ref
    | KExn of kdefexn_t ref | KVariant of kdefvariant_t ref
    | KClosureVars of kdefclosurevars_t ref
    | KTyp of kdeftyp_t ref

let _KLitVoid = KLitNil(KTypVoid)
let _ALitVoid = AtomLit(_KLitVoid)

let all_idks = dynvec_create KNone

let sprintf = Printf.sprintf
let printf = Printf.printf

let builtin_exn_NoMatchError = ref noid
let builtin_exn_OutOfRangeError = ref noid

let idks_frozen = ref true
let freeze_idks f = idks_frozen := f

let new_idk_idx() =
    let _ = if not !idks_frozen then () else
        failwith "internal error: new idk is requested when they are frozen" in
    let new_idx = dynvec_push all_ids in
    let new_kidx = dynvec_push all_idks in
    if new_idx = new_kidx then new_idx else
        failwith "internal error: unsynchronized outputs from new_id_idx() and new_idk_idx()"

let kinfo_ i loc = dynvec_get all_idks (id2idx_ i loc)

let gen_temp_idk s =
    let i_name = get_id_prefix s in
    let i_real = new_idk_idx() in
    Id.Temp(i_name, i_real)

let dup_idk old_id =
    let k = new_idk_idx() in
    match old_id with
    | Id.Name(i) -> Id.Val(i, k)
    | Id.Val(i, j) -> Id.Val(i, k)
    | Id.Temp(i, j) -> Id.Temp(i, k)

let gen_idk s =
    let i_name = get_id_prefix s in
    let i_real = new_idk_idx() in
    Id.Val(i_name, i_real)

let set_idk_entry i n =
    let idx = id2idx i in dynvec_set all_idks idx n

let init_all_idks () =
    freeze_ids true;
    freeze_idks false;
    dynvec_init all_idks all_ids.dynvec_count

let get_kexp_ctx e = match e with
    | KExpNop(l) -> (KTypVoid, l)
    | KExpBreak(l) -> (KTypVoid, l)
    | KExpContinue(l) -> (KTypVoid, l)
    | KExpAtom(_, c) -> c
    | KExpBinOp(_, _, _, c) -> c
    | KExpUnOp(_, _, c) -> c
    | KExpIntrin(_, _, c) -> c
    | KExpSeq(_, c) -> c
    | KExpIf(_, _, _, c) -> c
    | KExpCall(_, _, c) -> c
    | KExpMkTuple(_, c) -> c
    | KExpMkRecord(_, c) -> c
    | KExpMkClosure(_, _, _, c) -> c
    | KExpMkArray(_, c) -> c
    | KExpAt(_, _, _, _, c) -> c
    | KExpMem(_, _, c) -> c
    | KExpAssign(_, _, l) -> (KTypVoid, l)
    | KExpMatch(_, c) -> c
    | KExpTryCatch(_, _, c) -> c
    | KExpThrow(_, _, l) -> (KTypErr, l)
    | KExpCast(_, t, l) -> (t, l)
    | KExpMap(_, _, _, c) -> c
    | KExpFor(_, _, _, _, l) -> (KTypVoid, l)
    | KExpWhile(_, _, l) -> (KTypVoid, l)
    | KExpDoWhile(_, _, l) -> (KTypVoid, l)
    | KExpCCode(_, c) -> c
    | KDefVal (_, _, l) -> (KTypVoid, l)
    | KDefFun {contents={kf_loc}} -> (KTypVoid, kf_loc)
    | KDefExn {contents={ke_loc}} -> (KTypVoid, ke_loc)
    | KDefVariant {contents={kvar_loc}} -> (KTypVoid, kvar_loc)
    | KDefTyp {contents={kt_loc}} -> (KTypVoid, kt_loc)
    | KDefClosureVars {contents={kcv_loc}} -> (KTypVoid, kcv_loc)

let get_kexp_typ e = let (t, l) = (get_kexp_ctx e) in t
let get_kexp_loc e = let (t, l) = (get_kexp_ctx e) in l
let get_kexp_start e = let l = get_kexp_loc e in get_start_loc l
let get_kexp_end e = let l = get_kexp_loc e in get_end_loc l

let is_val_global flags = flags.val_flag_global != []
let get_val_scope flags =
    let sc = flags.val_flag_global in if sc != [] then sc else [ScBlock 0]

let get_kscope info =
    match info with
    | KNone -> ScGlobal :: []
    | KVal {kv_flags} -> get_val_scope kv_flags
    | KFun {contents = {kf_scope}} -> kf_scope
    | KExn {contents = {ke_scope}} -> ke_scope
    | KVariant {contents = {kvar_scope}} -> kvar_scope
    | KClosureVars {contents = {kcv_scope}} -> kcv_scope
    | KTyp {contents = {kt_scope}} -> kt_scope

let get_kinfo_loc info =
    match info with
    | KNone -> noloc
    | KVal {kv_loc} -> kv_loc
    | KFun {contents = {kf_loc}} -> kf_loc
    | KExn {contents = {ke_loc}} -> ke_loc
    | KVariant {contents = {kvar_loc}} -> kvar_loc
    | KTyp {contents = {kt_loc}} -> kt_loc
    | KClosureVars {contents = {kcv_loc}} -> kcv_loc

let get_idk_loc i loc = get_kinfo_loc (kinfo_ i loc)

let check_kinfo info i loc =
    match info with
    | KNone -> raise_compile_err loc (sprintf "attempt to request information about uninitialized symbol '%s'" (id2str i))
    | _ -> ()

let get_kinfo_cname info loc =
    match info with
    | KNone -> raise_compile_err loc "attempt to request cname of uninitialized symbol"
    | KVal {kv_cname} -> kv_cname
    | KFun {contents = {kf_cname}} -> kf_cname
    | KExn {contents = {ke_cname}} -> ke_cname
    | KVariant {contents = {kvar_cname}} -> kvar_cname
    | KClosureVars {contents = {kcv_cname}} -> kcv_cname
    | KTyp {contents = {kt_cname}} -> kt_cname

let get_idk_cname i loc =
    let info = kinfo_ i loc in
    check_kinfo info i loc;
    get_kinfo_cname info loc

let idk2str i loc =
    match i with
    | Id.Name _ -> id2str i
    | _ ->
        let cname = get_idk_cname i loc in
        if cname = "" then id2str i else cname

let get_kf_typ kf_args kf_rt =
    KTypFun((List.map (fun (a, t) -> t) kf_args), kf_rt)

let get_kinfo_typ info i loc =
    check_kinfo info i loc;
    match info with
    | KNone -> KTypVoid
    | KVal {kv_typ} -> kv_typ
    | KFun {contents = {kf_args; kf_rt}} -> get_kf_typ kf_args kf_rt
    | KExn {contents = {ke_typ}} -> ke_typ
    | KVariant {contents = {kvar_name}} -> KTypName(kvar_name)
    | KClosureVars {contents = {kcv_name; kcv_freevars}} -> KTypRecord(kcv_name, kcv_freevars)
    | KTyp {contents={kt_typ=KTypRecord(_, _) as kt_typ}} -> kt_typ
    | KTyp {contents={kt_name}} -> KTypName(kt_name)

let get_idk_ktyp i loc = get_kinfo_typ (kinfo_ i loc) i loc

(* used by the type checker *)
let get_lit_ktyp l = match l with
    | KLitInt(_) -> KTypInt
    | KLitSInt(b, _) -> KTypSInt(b)
    | KLitUInt(b, _) -> KTypUInt(b)
    | KLitFloat(b, _) -> KTypFloat(b)
    | KLitString(_) -> KTypString
    | KLitChar(_) -> KTypChar
    | KLitBool(_) -> KTypBool
    | KLitNil(t) -> t

let get_atom_ktyp a loc =
    match a with
    | AtomId i -> get_idk_ktyp i loc
    | AtomLit l -> get_lit_ktyp l

let intrin2str iop = match iop with
    | IntrinPopExn -> "INTRIN_POP_EXN"
    | IntrinVariantTag -> "INTRIN_VARIANT_TAG"
    | IntrinVariantCase -> "INTRIN_VARIANT_CASE"
    | IntrinListHead -> "INTRIN_LIST_HD"
    | IntrinListTail -> "INTRIN_LIST_TL"
    | IntrinStrConcat -> "INTRIN_STR_CONCAT"
    | IntrinGetSize -> "INTRIN_GET_SIZE"
    | IntrinCheckIdx -> "INTRIN_CHECK_IDX"
    | IntrinCheckIdxRange -> "INTRIN_CHECK_IDX_RANGE"

let get_code_loc code default_loc =
    loclist2loc (List.map get_kexp_loc code) default_loc

let code2kexp code loc =
    match code with
    | [] -> KExpNop(loc)
    | e :: [] -> e
    | _ ->
        let t = get_kexp_typ (Utils.last_elem code) in
        let final_loc = get_code_loc code loc in
        KExpSeq(code, (t, final_loc))

let filter_out_nops code =
    List.filter (fun e -> match e with
        | KExpNop _ -> false
        | _ -> true) code

let rcode2kexp code loc = match (filter_out_nops code) with
    | [] -> KExpNop(loc)
    | e :: [] -> e
    | e :: rest ->
        let t = get_kexp_typ e in
        let final_loc = get_code_loc code loc in
        KExpSeq((List.rev code), (t, final_loc))

let kexp2code e =
    match e with
    | KExpNop _ -> []
    | KExpSeq(elist, _) -> elist
    | _ -> e :: []

(* walk through a K-normalized syntax tree and produce another tree *)

type k_callb_t =
{
    kcb_ktyp: (ktyp_t -> loc_t -> k_callb_t -> ktyp_t) option;
    kcb_kexp: (kexp_t -> k_callb_t -> kexp_t) option;
    kcb_atom: (atom_t -> loc_t -> k_callb_t -> atom_t) option;
}

let rec check_n_walk_ktyp t loc callb =
    match callb.kcb_ktyp with
    | Some(f) -> f t loc callb
    | _ -> walk_ktyp t loc callb

and check_n_walk_kexp e callb =
    match callb.kcb_kexp with
    | Some(f) -> f e callb
    | _ -> walk_kexp e callb

and check_n_walk_atom a loc callb =
    match callb.kcb_atom with
    | Some(f) -> f a loc callb
    | _ ->
        (match a with
        | AtomLit (KLitNil t) -> AtomLit(KLitNil (check_n_walk_ktyp t loc callb))
        | _ -> a)

and check_n_walk_al al loc callb =
    List.map (fun a -> check_n_walk_atom a loc callb) al

and check_n_walk_dom d loc callb =
    match d with
    | DomainElem a -> DomainElem (check_n_walk_atom a loc callb)
    | DomainFast a -> DomainFast (check_n_walk_atom a loc callb)
    | DomainRange (a, b, c) ->
        DomainRange ((check_n_walk_atom a loc callb),
                      (check_n_walk_atom b loc callb),
                      (check_n_walk_atom c loc callb))

and check_n_walk_id n loc callb =
    match callb.kcb_atom with
    | Some(f) ->
        (match f (AtomId n) loc callb with
        | AtomId n -> n
        | _ -> raise_compile_err loc
            "internal error: inside walk_id the callback returned a literal, not id, which is unexpected.")
    | _ -> n

and walk_ktyp t loc callb =
    let walk_ktyp_ t = check_n_walk_ktyp t loc callb in
    let walk_ktl_ tl = List.map walk_ktyp_ tl in
    let walk_id_ k = check_n_walk_id k loc callb in
    (match t with
    | KTypInt | KTypCInt | KTypSInt _ | KTypUInt _ | KTypFloat _
    | KTypVoid | KTypBool | KTypChar | KTypString | KTypCPointer
    | KTypExn | KTypErr | KTypModule -> t
    | KTypFun (args, rt) -> KTypFun((walk_ktl_ args), (walk_ktyp_ rt))
    | KTypTuple elems -> KTypTuple(walk_ktl_ elems)
    | KTypRecord (rn, relems) ->
            KTypRecord((walk_id_ rn),
                (List.map (fun (ni, ti) -> ((walk_id_ ni), (walk_ktyp_ ti))) relems))
    | KTypName k -> KTypName(walk_id_ k)
    | KTypArray (d, t) -> KTypArray(d, (walk_ktyp_ t))
    | KTypList t -> KTypList(walk_ktyp_ t)
    | KTypRef t -> KTypRef(walk_ktyp_ t))

and walk_kexp e callb =
    let loc = get_kexp_loc e in
    let walk_atom_ a = check_n_walk_atom a loc callb in
    let walk_al_ al = List.map walk_atom_ al in
    let walk_ktyp_ t = check_n_walk_ktyp t loc callb in
    let walk_id_ i = check_n_walk_id i loc callb in
    let walk_kexp_ e = check_n_walk_kexp e callb in
    let walk_kctx_ (t, loc) = ((walk_ktyp_ t), loc) in
    let walk_dom_ d = check_n_walk_dom d loc callb in
    let walk_idomlist_ idoml = List.map (fun (i, d) -> ((walk_id_ i), (walk_dom_ d))) idoml in
    (match e with
    | KExpNop (_) -> e
    | KExpBreak _ -> e
    | KExpContinue _ -> e
    | KExpAtom (a, ctx) -> KExpAtom((walk_atom_ a), (walk_kctx_ ctx))
    | KExpBinOp(bop, a1, a2, ctx) ->
        KExpBinOp(bop, (walk_atom_ a1), (walk_atom_ a2), (walk_kctx_ ctx))
    | KExpUnOp(uop, a, ctx) -> KExpUnOp(uop, (walk_atom_ a), (walk_kctx_ ctx))
    | KExpIntrin(iop, args, ctx) -> KExpIntrin(iop, (walk_al_ args), (walk_kctx_ ctx))
    | KExpIf(c, then_e, else_e, ctx) ->
        KExpIf((walk_kexp_ c), (walk_kexp_ then_e), (walk_kexp_ else_e), (walk_kctx_ ctx))
    | KExpSeq(elist, ctx) ->
        let rec process_elist elist result =
            match elist with
            | e :: rest ->
                let new_e = walk_kexp_ e in
                let new_result = match new_e with
                    | KExpNop _ -> if rest != [] then result
                                   else new_e :: result
                    | KExpSeq(el, _) -> (List.rev el) @ result
                    | _ -> new_e :: result in
                process_elist rest new_result
            | _ -> List.rev result in
        let new_elist = process_elist elist [] in
        let (new_ktyp, loc) = walk_kctx_ ctx in
        (match new_elist with
        | [] -> KExpNop(loc)
        | e :: [] -> e
        | _ -> KExpSeq(new_elist, (new_ktyp, loc)))
    | KExpMkTuple(alist, ctx) -> KExpMkTuple((walk_al_ alist), (walk_kctx_ ctx))
    | KExpMkRecord(alist, ctx) -> KExpMkRecord((walk_al_ alist), (walk_kctx_ ctx))
    | KExpMkClosure(make_fp, f, args, ctx) ->
        KExpMkClosure((walk_id_ make_fp), (walk_id_ f), (walk_al_ args), (walk_kctx_ ctx))
    | KExpMkArray(elems, ctx) -> KExpMkArray((List.map (List.map (fun (f, a) -> (f, walk_atom_ a))) elems), (walk_kctx_ ctx))
    | KExpCall(f, args, ctx) -> KExpCall((walk_id_ f), (walk_al_ args), (walk_kctx_ ctx))
    | KExpAt(a, border, interp, idx, ctx) ->
        KExpAt((walk_atom_ a), border, interp, (List.map walk_dom_ idx), (walk_kctx_ ctx))
    | KExpAssign(lv, rv, loc) -> KExpAssign((walk_id_ lv), (walk_atom_ rv), loc)
    | KExpMem(k, member, ctx) -> KExpMem((walk_id_ k), member, (walk_kctx_ ctx))
    | KExpThrow(k, f, loc) -> KExpThrow((walk_id_ k), f, loc)
    | KExpWhile(c, e, loc) -> KExpWhile((walk_kexp_ c), (walk_kexp_ e), loc)
    | KExpDoWhile(e, c, loc) -> KExpDoWhile((walk_kexp_ e), (walk_kexp_ c), loc)
    | KExpFor(idoml, at_ids, body, flags, loc) ->
        KExpFor((walk_idomlist_ idoml), (List.map walk_id_ at_ids), (walk_kexp_ body), flags, loc)
    | KExpMap(e_idoml_l, body, flags, ctx) ->
        KExpMap((List.map (fun (e, idoml, at_ids) ->
            ((walk_kexp_ e), (walk_idomlist_ idoml), (List.map walk_id_ at_ids))) e_idoml_l),
                (walk_kexp_ body), flags, (walk_kctx_ ctx))
    | KExpMatch(cases, ctx) ->
        KExpMatch((List.map (fun (checks_i, ei) ->
            ((List.map (fun cij -> walk_kexp_ cij) checks_i), (walk_kexp_ ei))) cases),
            (walk_kctx_ ctx))
    | KExpTryCatch(e1, e2, ctx) ->
        KExpTryCatch((walk_kexp_ e1), (walk_kexp_ e2), (walk_kctx_ ctx))
    | KExpCast(a, t, loc) -> KExpCast((walk_atom_ a), (walk_ktyp_ t), loc)
    | KExpCCode(str, ctx) -> KExpCCode(str, (walk_kctx_ ctx))
    | KDefVal(k, e, loc) ->
        KDefVal((walk_id_ k), (walk_kexp_ e), loc)
    | KDefFun(kf) ->
        let { kf_name; kf_args; kf_rt; kf_body; kf_closure } = !kf in
        let {kci_arg; kci_fcv_t; kci_fp_typ; kci_make_fp; kci_wrap_f} = kf_closure in
        kf := { !kf with kf_name = (walk_id_ kf_name);
                kf_args = (List.map (fun (a, t) ->
                    let a = walk_id_ a in
                    let t = walk_ktyp_ t in (a, t)) kf_args);
                kf_rt = walk_ktyp_ kf_rt;
                kf_body = (walk_kexp_ kf_body);
                kf_closure = {kci_arg=(walk_id_ kci_arg); kci_fcv_t=(walk_id_ kci_fcv_t);
                    kci_fp_typ=(walk_id_ kci_fp_typ); kci_make_fp=(walk_id_ kci_make_fp);
                    kci_wrap_f=(walk_id_ kci_wrap_f)} };
        e
    | KDefExn(ke) ->
        let { ke_name; ke_cname; ke_tag; ke_make; ke_typ } = !ke in
        ke := { !ke with ke_name = (walk_id_ ke_name); ke_typ=(walk_ktyp_ ke_typ);
                ke_tag=(walk_id_ ke_tag); ke_make=(walk_id_ ke_make) };
        e
    | KDefVariant(kvar) ->
        let { kvar_name; kvar_cases; kvar_ctors } = !kvar in
        kvar := { !kvar with kvar_name = (walk_id_ kvar_name);
            kvar_cases = (List.map (fun (n, t) -> ((walk_id_ n), (walk_ktyp_ t))) kvar_cases);
            kvar_ctors = (List.map walk_id_ kvar_ctors) };
        e
    | KDefTyp(kt) ->
        let { kt_name; kt_typ } = !kt in
        kt := { !kt with kt_name = (walk_id_ kt_name); kt_typ = walk_ktyp_ kt_typ };
        e
    | KDefClosureVars(kcv) ->
        let { kcv_name; kcv_freevars; kcv_orig_freevars } = !kcv in
        kcv := { !kcv with kcv_name = (walk_id_ kcv_name);
            kcv_freevars = (List.map (fun (n, t) -> ((walk_id_ n), (walk_ktyp_ t))) kcv_freevars);
            kcv_orig_freevars = (List.map walk_id_ kcv_orig_freevars) };
        e)

(* walk through a K-normalized syntax tree and perform some actions;
   do not construct/return anything (though, it's expected that
   the callbacks collect some information about the tree) *)

type 'x k_fold_callb_t =
{
    kcb_fold_ktyp: (ktyp_t -> loc_t -> 'x k_fold_callb_t -> unit) option;
    kcb_fold_kexp: (kexp_t -> 'x k_fold_callb_t -> unit) option;
    kcb_fold_atom: (atom_t -> loc_t -> 'x k_fold_callb_t -> unit) option;
    mutable kcb_fold_result: 'x;
}

let rec check_n_fold_ktyp t loc callb =
    match callb.kcb_fold_ktyp with
    | Some(f) -> f t loc callb
    | _ -> fold_ktyp t loc callb

and check_n_fold_kexp e callb =
    match callb.kcb_fold_kexp with
    | Some(f) -> f e callb
    | _ -> fold_kexp e callb

and check_n_fold_atom a loc callb =
    match callb.kcb_fold_atom with
    | Some(f) -> f a loc callb
    | _ ->
        match a with
        | AtomLit(KLitNil t) -> check_n_fold_ktyp t loc callb
        | _ -> ()

and check_n_fold_al al loc callb =
    List.iter (fun a -> check_n_fold_atom a loc callb) al

and check_n_fold_dom d loc callb =
    match d with
    | DomainElem a -> check_n_fold_atom a loc callb
    | DomainFast a -> check_n_fold_atom a loc callb
    | DomainRange (a, b, c) ->
        check_n_fold_atom a loc callb;
        check_n_fold_atom b loc callb;
        check_n_fold_atom c loc callb

and check_n_fold_id k loc callb =
    match callb.kcb_fold_atom with
    | Some(f) when k != noid -> f (AtomId k) loc callb
    | _ -> ()

and fold_ktyp t loc callb =
    let fold_ktyp_ t = check_n_fold_ktyp t loc callb in
    let fold_ktl_ tl = List.iter fold_ktyp_ tl in
    let fold_id_ i = check_n_fold_id i loc callb in
    (match t with
    | KTypInt | KTypCInt | KTypSInt _ | KTypUInt _ | KTypFloat _
    | KTypVoid | KTypBool | KTypChar | KTypString | KTypCPointer
    | KTypExn | KTypErr | KTypModule -> ()
    | KTypFun (args, rt) -> fold_ktl_ args; fold_ktyp_ rt
    | KTypTuple elems -> fold_ktl_ elems
    | KTypRecord (rn, relems) -> fold_id_ rn;
        List.iter (fun (ni, ti) -> fold_id_ ni; fold_ktyp_ ti) relems
    | KTypName i -> fold_id_ i
    | KTypArray (d, t) -> fold_ktyp_ t
    | KTypList t -> fold_ktyp_ t
    | KTypRef t -> fold_ktyp_ t)

and fold_kexp e callb =
    let loc = get_kexp_loc e in
    let fold_atom_ a = check_n_fold_atom a loc callb in
    let fold_al_ al = List.iter fold_atom_ al in
    let fold_ktyp_ t = check_n_fold_ktyp t loc callb in
    let fold_id_ k = check_n_fold_id k loc callb in
    let fold_kexp_ e = check_n_fold_kexp e callb in
    let fold_kctx_ (t, _) = fold_ktyp_ t in
    let fold_dom_ d = check_n_fold_dom d loc callb in
    let fold_idoml_ idoml = List.iter (fun (k, d) -> fold_id_ k; fold_dom_ d) idoml in
    fold_kctx_ (match e with
    | KExpNop (l) -> (KTypVoid, l)
    | KExpBreak (l) -> (KTypVoid, l)
    | KExpContinue (l) -> (KTypVoid, l)
    | KExpAtom (a, ctx) -> fold_atom_ a; ctx
    | KExpBinOp(_, a1, a2, ctx) ->
        fold_atom_ a1; fold_atom_ a2; ctx
    | KExpUnOp(_, a, ctx) -> fold_atom_ a; ctx
    | KExpIntrin(_, args, ctx) -> fold_al_ args; ctx
    | KExpIf(c, then_e, else_e, ctx) ->
        fold_kexp_ c; fold_kexp_ then_e; fold_kexp_ else_e; ctx
    | KExpSeq(elist, ctx) -> List.iter fold_kexp_ elist; ctx
    | KExpMkTuple(alist, ctx) -> fold_al_ alist; ctx
    | KExpMkRecord(alist, ctx) -> fold_al_ alist; ctx
    | KExpMkClosure(make_fp, f, args, ctx) -> fold_id_ make_fp; fold_id_ f; fold_al_ args; ctx
    | KExpMkArray(elems, ctx) -> List.iter (List.iter (fun (_, a) -> fold_atom_ a)) elems; ctx
    | KExpCall(f, args, ctx) -> fold_id_ f; fold_al_ args; ctx
    | KExpAt(a, border, interp, idx, ctx) -> fold_atom_ a; List.iter fold_dom_ idx; ctx
    | KExpAssign(lv, rv, loc) -> fold_id_ lv; fold_atom_ rv; (KTypVoid, loc)
    | KExpMem(k, _, ctx) -> fold_id_ k; ctx
    | KExpThrow(k, _, loc) -> fold_id_ k; (KTypErr, loc)
    | KExpWhile(c, e, loc) -> fold_kexp_ c; fold_kexp_ e; (KTypErr, loc)
    | KExpDoWhile(e, c, loc) -> fold_kexp_ e; fold_kexp_ c; (KTypErr, loc)
    | KExpFor(idoml, at_ids, body, _, loc) ->
        fold_idoml_ idoml; List.iter fold_id_ at_ids; fold_kexp_ body; (KTypVoid, loc)
    | KExpMap(e_idoml_l, body, _, ctx) ->
        List.iter (fun (e, idoml, at_ids) -> fold_kexp_ e; fold_idoml_ idoml; List.iter fold_id_ at_ids) e_idoml_l;
        fold_kexp_ body; ctx
    | KExpMatch(cases, ctx) ->
        List.iter (fun (checks_i, ei) ->
            List.iter (fun cij -> fold_kexp_ cij) checks_i; fold_kexp_ ei) cases;
        ctx
    | KExpTryCatch(e1, e2, ctx) ->
        fold_kexp_ e1; fold_kexp_ e2; ctx
    | KExpCast(a, t, loc) ->
        fold_atom_ a; (t, loc)
    | KExpCCode(_, ctx) -> ctx
    | KDefVal(k, e, loc) ->
        fold_id_ k; fold_kexp_ e; (KTypVoid, loc)
    | KDefFun(df) ->
        let { kf_name; kf_args; kf_rt; kf_body; kf_closure; kf_loc } = !df in
        let { kci_arg; kci_fcv_t; kci_fp_typ; kci_make_fp; kci_wrap_f } = kf_closure in
        fold_id_ kf_name; List.iter (fun (a, t) -> fold_id_ a; fold_ktyp_ t) kf_args;
        fold_ktyp_ kf_rt; fold_id_ kci_arg; fold_id_ kci_fcv_t; fold_id_ kci_fp_typ;
        fold_id_ kci_make_fp; fold_id_ kci_wrap_f; fold_kexp_ kf_body;
        (KTypVoid, kf_loc)
    | KDefExn(ke) ->
        let { ke_name; ke_typ; ke_tag; ke_make; ke_loc } = !ke in
        fold_id_ ke_name; fold_ktyp_ ke_typ;
        fold_id_ ke_tag; fold_id_ ke_make;
        (KTypVoid, ke_loc)
    | KDefVariant(kvar) ->
        let { kvar_name; kvar_cases; kvar_ctors; kvar_loc } = !kvar in
        fold_id_ kvar_name;
        List.iter (fun (n, t) -> fold_id_ n; fold_ktyp_ t) kvar_cases;
        List.iter fold_id_ kvar_ctors;
        (KTypVoid, kvar_loc)
    | KDefTyp(kt) ->
        let { kt_name; kt_typ; kt_loc } = !kt in
        fold_id_ kt_name; fold_ktyp_ kt_typ;
        (KTypVoid, kt_loc)
    | KDefClosureVars(kcv) ->
        let { kcv_name; kcv_freevars; kcv_orig_freevars; kcv_loc } = !kcv in
        fold_id_ kcv_name;
        List.iter (fun (n, t) -> fold_id_ n; fold_ktyp_ t) kcv_freevars;
        List.iter fold_id_ kcv_orig_freevars;
        (KTypVoid, kcv_loc))

let add_to_used1 i callb =
    if i = noid then ()
    else
        let (used_set, decl_set) = callb.kcb_fold_result in
        callb.kcb_fold_result <- ((IdSet.add i used_set), decl_set)

let add_to_used uv_set callb =
    let (used_set, decl_set) = callb.kcb_fold_result in
    callb.kcb_fold_result <- ((IdSet.union uv_set used_set), decl_set)

let add_to_decl1 i callb =
    if i = noid then ()
    else
        let (used_set, decl_set) = callb.kcb_fold_result in
        callb.kcb_fold_result <- (used_set, (IdSet.add i decl_set))

let add_to_decl dv_set callb =
    let (used_set, decl_set) = callb.kcb_fold_result in
    callb.kcb_fold_result <- (used_set, (IdSet.union dv_set decl_set))

let rec used_by_atom_ a loc callb =
    match a with
    | AtomId (Id.Name i) -> ()
    | AtomId i -> add_to_used1 i callb
    | AtomLit(KLitNil t) -> used_by_ktyp_ t loc callb
    | _ -> ()
and used_by_ktyp_ t loc callb = fold_ktyp t loc callb
and used_by_kexp_ e callb =
    match e with
    | KDefVal(i, e, _) ->
        let (uv, dv) = used_decl_by_kexp e in
        add_to_used uv callb;
        add_to_decl dv callb;
        add_to_decl1 i callb
    | KDefFun {contents={kf_name; kf_args; kf_rt; kf_closure; kf_body; kf_loc}} ->
        (* the function arguments are not included into the "used variables" set by default,
            they should be referenced by the function body to be included *)
        let {kci_arg; kci_fcv_t; kci_fp_typ; kci_make_fp; kci_wrap_f} = kf_closure in
        let kf_typ = get_kf_typ kf_args kf_rt in
        let uv_typ = used_by_ktyp kf_typ kf_loc in
        let (uv_body, dv_body) = used_decl_by_kexp kf_body in
        let uv = IdSet.union uv_typ (IdSet.remove kf_name uv_body) in
        add_to_decl1 kci_arg callb;
        add_to_used1 kci_arg callb;
        add_to_used1 kci_fcv_t callb;
        add_to_used uv callb;
        add_to_decl dv_body callb;
        add_to_decl1 kf_name callb;
        List.iter (fun (a, _) -> add_to_decl1 a callb) kf_args
    (* closure vars structure contains names of free variables and their types, as well as
       "weak" backward reference to the function. we do not need to add any of those into the "used" set *)
    | KDefClosureVars {contents={kcv_name}} ->
        add_to_decl1 kcv_name callb
    | KDefExn {contents={ke_name; ke_typ; ke_tag; ke_make; ke_loc}} ->
        let uv = used_by_ktyp ke_typ ke_loc in
        add_to_used uv callb;
        add_to_used1 ke_tag callb;
        add_to_used1 ke_make callb;
        add_to_decl1 ke_name callb
    | KDefVariant {contents={kvar_name; kvar_cases; kvar_loc}} ->
        let uv = List.fold_left (fun uv (ni, ti) ->
            let uv = IdSet.add ni uv in
            let uv_ti = IdSet.remove kvar_name (used_by_ktyp ti kvar_loc) in
            IdSet.union uv_ti uv) IdSet.empty kvar_cases in
        add_to_used uv callb;
        add_to_decl1 kvar_name callb
    | KDefTyp {contents={kt_name; kt_typ; kt_loc}} ->
        let uv = used_by_ktyp kt_typ kt_loc in
        let uv = IdSet.remove kt_name uv in
        add_to_used uv callb;
        add_to_decl1 kt_name callb
    | KExpMap (clauses, body, _, (t, _)) ->
        fold_kexp e callb;
        List.iter (fun (_, id_l, at_ids) ->
            List.iter (fun i -> add_to_decl1 i callb) at_ids;
            List.iter (fun (i, _) -> add_to_decl1 i callb) id_l) clauses
    | KExpFor (id_l, at_ids, body, _, _) ->
        fold_kexp e callb;
        List.iter (fun i -> add_to_decl1 i callb) at_ids;
        List.iter (fun (i, _) -> add_to_decl1 i callb) id_l
    | _ -> fold_kexp e callb

and new_used_vars_callb () =
    {
        kcb_fold_atom = Some(used_by_atom_);
        kcb_fold_ktyp = Some(used_by_ktyp_);
        kcb_fold_kexp = Some(used_by_kexp_);
        kcb_fold_result = (IdSet.empty, IdSet.empty)
    }
and used_by_ktyp t loc =
    let callb = new_used_vars_callb() in
    let _ = used_by_ktyp_ t loc callb in
    let (used_set, _) = callb.kcb_fold_result in
    used_set
and used_decl_by_kexp e =
    let callb = new_used_vars_callb() in
    let _ = used_by_kexp_ e callb in
    callb.kcb_fold_result
and used_by_kexp e =
    let (used_set, _) = used_decl_by_kexp e in
    used_set

let used_by code =
    let e = code2kexp code noloc in
    used_by_kexp e

let free_vars_kexp e =
    let (uv, dv) = used_decl_by_kexp e in
    IdSet.diff uv dv

let is_mutable i loc =
    let info = kinfo_ i loc in
    check_kinfo info i loc;
    match info with
    | KNone -> false
    | KVal {kv_flags} -> kv_flags.val_flag_mutable
    | KFun _ -> false
    | KExn _ -> false
    | KClosureVars _ | KVariant _ | KTyp _ -> false

let is_mutable_atom a loc =
    match a with
    | AtomId i -> is_mutable i loc
    | _ -> false

let is_subarray i loc =
    let info = kinfo_ i loc in
    check_kinfo info i loc;
    match info with
    | KVal {kv_flags} -> kv_flags.val_flag_subarray
    | _ -> false

let get_closure_freevars f loc =
    match (kinfo_ f loc) with
    | KFun {contents={kf_closure={kci_fcv_t}}} ->
        if kci_fcv_t = noid then ([], []) else
        (match (kinfo_ kci_fcv_t loc) with
        | KClosureVars {contents={kcv_freevars; kcv_orig_freevars}} -> (kcv_freevars, kcv_orig_freevars)
        | _ -> raise_compile_err loc
            (sprintf "invalid description of a closure data '%s' (should KClosureVars ...)" (id2str kci_fcv_t)))
    | _ -> raise_compile_err loc
        (sprintf "get_closure_freevars argument '%s' is not a function" (id2str f))

let make_empty_kf_closure () =
    {kci_arg=noid; kci_fcv_t=noid; kci_fp_typ=noid; kci_make_fp=noid; kci_wrap_f=noid}

let get_kval i loc =
    let info = kinfo_ i loc in
    check_kinfo info i loc;
    match info with
    | KVal kv -> kv
    | _ ->
        let loc = if loc!=noloc then loc else get_kinfo_loc info in
        raise_compile_err loc (sprintf "symbol '%s' is expected to be KVal ..." (id2str i))

let rec deref_ktyp kt loc =
    match kt with
    | KTypName (Id.Name _) -> kt
    | KTypName i ->
        (match (kinfo_ i loc) with
        | KTyp {contents={kt_typ; kt_loc}} -> deref_ktyp kt_typ kt_loc
        | KVariant _ -> kt
        | _ -> raise_compile_err loc (sprintf "named 'type' '%s' does not represent a type" (id2str i)))
    | _ -> kt

let is_ktyp_scalar ktyp = match ktyp with
    | KTypInt | KTypCInt | KTypSInt _ | KTypUInt _ | KTypFloat _ | KTypBool | KTypChar -> true
    | _ -> false

let is_ktyp_integer t allow_bool =
    match t with
    | KTypCInt | KTypInt | KTypSInt _ | KTypUInt _ -> true
    | KTypBool -> allow_bool
    | _ -> false

let create_kdefval n ktyp flags e_opt code loc =
    let dv = { kv_name=n; kv_cname=""; kv_typ=ktyp; kv_flags=flags; kv_loc=loc } in
    match ktyp with
    | KTypVoid -> raise_compile_err loc "values of 'void' type are not allowed"
    | _ -> ();
    set_idk_entry n (KVal dv);
    match e_opt with
    | Some(e) -> KDefVal(n, e, loc) :: code
    | _ -> code

let kexp2atom prefix e tref code =
    match e with
    | KExpAtom (a, _) -> (a, code)
    | _ ->
        let tmp_id = gen_temp_idk prefix in
        let (ktyp, kloc) = get_kexp_ctx e in
        let _ = if ktyp <> KTypVoid then () else
            raise_compile_err kloc "'void' expression or declaration cannot be converted to an atom" in
        let tref = match e with
            | KExpMem _ | KExpAt (_, BorderNone, InterpNone, _, _) | KExpUnOp(OpDeref, _, _) -> tref
            | _ -> false
            in
        let code = create_kdefval tmp_id ktyp
            {(default_val_flags()) with val_flag_tempref=tref}
            (Some e) code kloc in
        ((AtomId tmp_id), code)

let create_kdeffun n args rt flags body_opt code sc loc =
    let body = match body_opt with
        | Some body -> body
        | _ -> KExpNop loc
        in
    let kf = ref { kf_name=n; kf_cname=""; kf_args=args; kf_rt = rt;
        kf_body=body; kf_flags=flags; kf_closure=make_empty_kf_closure(); kf_scope=sc; kf_loc=loc }
        in
    set_idk_entry n (KFun kf);
    (KDefFun kf) :: code

let create_kdefconstr n argtyps rt ctor code sc loc =
    let (_, args) = List.fold_left (fun (idx, args) t ->
        let arg = gen_idk (sprintf "arg%d" idx) in
        let _ = create_kdefval arg t {(default_val_flags()) with val_flag_arg=true} None [] loc in
        (idx + 1, (arg, t) :: args)) (0, []) argtyps in
    create_kdeffun n (List.rev args) rt
        {(default_fun_flags()) with fun_flag_ctor=ctor}
        None code sc loc

let rec ktyp2str t =
    match t with
    | KTypInt -> "KTypInt"
    | KTypCInt -> "KTypCInt"
    | KTypSInt n -> sprintf "KTypSInt(%d)" n
    | KTypUInt n -> sprintf "KTypUInt(%d)" n
    | KTypFloat n -> sprintf "KTypFloat(%d)" n
    | KTypVoid -> "KTypVoid"
    | KTypBool -> "KTypBool"
    | KTypChar -> "KTypChar"
    | KTypString -> "KTypString"
    | KTypCPointer -> "KTypCPtr"
    | KTypFun(argtyps, rt) ->
        "KTypFun(<" ^ (ktl2str argtyps) ^
        ">, " ^ (ktyp2str rt) ^ ")"
    | KTypTuple tl ->
        "KTypTuple(" ^ (ktl2str tl) ^ ")"
    | KTypRecord (n, _) -> "KTypRecord(" ^ (idk2str n noloc) ^ ")"
    | KTypName n -> "KTypName(" ^ (idk2str n noloc) ^ ")"
    | KTypArray (d, t) -> sprintf "KTypArray(%d, %s)" d (ktyp2str t)
    | KTypList t -> "KTypList(" ^ (ktyp2str t) ^ ")"
    | KTypRef t -> "KTypRef(" ^ (ktyp2str t) ^ ")"
    | KTypExn -> "KTypExn"
    | KTypErr -> "KTypErr"
    | KTypModule -> "KTypModule"
and klit2str lit cmode loc =
    let add_dot s suffix =
        (if (String.contains s '.') || (String.contains s 'e') then s else s ^ ".") ^ suffix
    in
    match lit with
    | KLitInt(v) -> sprintf "%Li" v
    | KLitSInt(64, v) -> if cmode then sprintf "%LiLL" v else sprintf "%Lii%d" v 64
    | KLitUInt(64, v) -> if cmode then sprintf "%LiULL" v else sprintf "%Lii%d" v 64
    | KLitSInt(b, v) -> if cmode then sprintf "%Li" v else sprintf "%Lii%d" v b
    | KLitUInt(b, v) -> if cmode then sprintf "%LuU" v else sprintf "%Luu%d" v b
    | KLitFloat(16, v) -> let s = sprintf "%.4g" v in (add_dot s "h")
    | KLitFloat(32, v) -> let s = sprintf "%.8g" v in (add_dot s "f")
    | KLitFloat(64, v) -> let s = sprintf "%.16g" v in (add_dot s "")
    | KLitFloat(b, v) -> raise_compile_err loc (sprintf "invalid literal LitFloat(%d, %.16g)" b v)
    | KLitString(s) -> "\"" ^ (Utils.escaped_uni s) ^ "\""
    | KLitChar(c) -> "\'" ^ (Utils.escaped_uni c) ^ "\'"
    | KLitBool(true) -> "true"
    | KLitBool(false) -> "false"
    | KLitNil _ -> "nullptr"
and ktl2str tl = String.concat ", " (List.map (fun t -> ktyp2str t) tl)
and atom2str a = match a with AtomId i -> idk2str i noloc | AtomLit l -> klit2str l false noloc
and kexp2str e =
    let l = get_kexp_loc e in
    match e with
    | KExpNop _ -> "KExpNop"
    | KExpBreak _ -> "KExpBreak"
    | KExpContinue _ -> "KExpContinue"
    | KExpAtom (a, _) -> "KExpAtom(" ^ (atom2str a) ^ ")"
    | KExpBinOp (bop, a, b, _) -> sprintf "KExpBinOp(%s, %s, %s)"
        (binop_to_string bop) (atom2str a) (atom2str b)
    | KExpUnOp (uop, a, _) -> sprintf "KExpUnOp(%s, %s)" (unop_to_string uop) (atom2str a)
    | KExpIntrin (i, _, _) -> sprintf "KExpIntrin(%s, ...)" (intrin2str i)
    | KExpSeq _ -> "KExpSeq(...)"
    | KExpIf _ -> "KExpIf(...)"
    | KExpCall(f, args, _) -> sprintf "KExpCall(%s, ...)" (idk2str f l)
    | KExpMkTuple _ -> "KExpMkTuple(...)"
    | KExpMkRecord _ -> "KExpMkRecord(...)"
    | KExpMkClosure (_, f, _, _) -> sprintf "KExpMkClosure(...%s...)" (idk2str f l)
    | KExpMkArray _ -> "KExpMkArray(...)"
    | KExpAt _ -> "KExpAt(...)"
    | KExpMem (i, _, _) -> sprintf "KExpMem(%s.*)" (idk2str i l)
    | KExpAssign (i, _, _) -> sprintf "KExpAssign(%s=...)" (idk2str i l)
    | KExpMatch _ -> "KExpMatch(...)"
    | KExpTryCatch _ -> "KExpTryCatch(...)"
    | KExpThrow (i, f, _) -> sprintf "KExp%s(%s)" (if f then "ReThrow" else "Throw") (idk2str i l)
    | KExpCast _ -> "KExpCast(...)"
    | KExpMap _ -> "KExpMap(...)"
    | KExpFor _ -> "KExpFor(...)"
    | KExpWhile _ -> "KExpWhile(...)"
    | KExpDoWhile _ -> "KExpDoWhile(...)"
    | KExpCCode _ -> "KExpCCode(...)"
    | KDefVal (i, _, _) -> sprintf "KDefVal(%s=...)" (idk2str i l)
    | KDefFun {contents={kf_name}} -> sprintf "KDefFun(%s=...)" (idk2str kf_name l)
    | KDefExn {contents={ke_name}} -> sprintf "KDefExn(%s=...)" (idk2str ke_name l)
    | KDefVariant {contents={kvar_name}} -> sprintf "KDefVar(%s=...)" (idk2str kvar_name l)
    | KDefTyp {contents={kt_name}} -> sprintf "KDefTyp(%s=...)" (idk2str kt_name l)
    | KDefClosureVars {contents={kcv_name}} -> sprintf "KDefClosureVars(%s=...)" (idk2str kcv_name l)
