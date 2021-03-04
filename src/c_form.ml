(*
    This file is a part of ficus language project.
    See ficus/LICENSE for the licensing terms
*)

(*
    C code represented in a hierarhical form (just like Ast or K_form).

    The main differences from K-form are:
    * there is no nested functions; at Lambda lifting step, all the nested functions
      are converted to closures (if needed) and moved to the top level
    * we add the closure pointer to the list of parameters in most functions
      (i.e. the pointer to the structure that contains 'free variables':
      non-local and yet non-global variables accessed by the function).
      Many of the functions do need a closure, but there is still such a parameter,
      it's just not used. The parameter is needed because when we call a function indirectly,
      via pointer, we don't know whether it needs closure or not. See k_lift module.
    * the type system is further shrinked:
      * Tuples, records, list cells, reference cells, recursive and non-recursive variants,
        "closure variables" data, function pointers (closures themselves) etc.
        are all converted to C structures.
        For some complex data types, such as strings, arrays, exceptions there are
        already standard structures defined in Ficus runtime,
        so no new structures are generated for them.
        For other complex types a unique name (signature) is generated and is used
        to reference the type and name the corresponding C structure.
        For example, KTypList(KTypInt) becomes _fx_Li_t,
        KTypTuple(KTypFloat :: KTypFloat :: KTypFloat :: []) becomes _fx_Ta3f etc.
        See k_mangle module.
    * the memory is now managed manually.
      Reference counting is involved when copying and releasing smart pointers to actual data
      (for those data structures that need it: arrays, strings, references, lists,
      recursive variants, exceptions, closures, smart "C" pointers).
      Cleanup blocks are added to each function (and often to its nested blocks, such as loops,
      "match" cases, try-blocks etc.) to free the allocated objects that are not used anymore.
    * all the data types are classified into 2 categories: dynamic and static.
      * Static types are allocated on stack.
        Those are primitive types (numbers, bool, char), tuples, records, non-recursive variants,
        arrays (their headers, not data), strings (their headers and maybe data),
        exceptions (their headers), closures (their headers).
      * Dynamic types are allocated on heap and are referenced by their pointers.
        There is also a reference counter used to track the number of 'users'
        that share the pointer. The dynamic structures are lists, references and recursive variants,
      The situation is actually more complex than that:
        * Array elements, string characters, closure free variables, exception parameters and some
          other "variable-size" data that are "underwater parts" of some data type' "icebergs",
          are also stored in the heap and supplied with the associated reference counters.
        * Even the static but non-primitive types,
          are passed to functions via pointers. They all, except for arrays,
          are passed as 'const' pointers, e.g.
          int _fx_print_vec(fx_ctx_t* fx_ctx, const _fx_v3f_t* mytup) { ... }
        * Static data types may have fields that are represented by dynamic data types.
          For example, KTypTuple(KTypBool :: KTypList(KTypInt) :: KTypList(KTypInt) :: []).
    * an expression does not represent any element of the code anymore.
      There are now expressions and statements, since it's C/C++.
    * the complex (nested) expressions are re-introduced.
      This is needed to make the final C code more readable
      and to avoid eccessive use of temporary variables. For example,
      `foo((n+1)*2)` looks much better than
      `int t0=n+1; int t1=t0*2; foo(t1)`.
      Of course, the use of expressions is limited to scalar values and
      to the cases when no exceptions may occur when computing them.
    * there is no exceptions anymore; after each function that may throw an exception
      (by itself or from within the nested calls) is called, a error check is added.
      So far, we do not use 'zero-cost exceptions' or such. This is probably TBD.
    * all the multi-dimensional array access operations are converted to the raw 1D accesses
      with proper range checks where needed.
    * comprehensions are reduced to for-loops:
      * array comprehensions are replaced with for-loops over pre-allocated arrays;
      * list comprehensions are replaced with a for-loop that constructs the output list on-fly.
*)

open Ast
open K_form

type cbinop_t =
    | COpAdd | COpSub | COpMul | COpDiv | COpMod | COpShiftLeft | COpShiftRight
    | COpBitwiseAnd | COpBitwiseOr | COpBitwiseXor | COpLogicAnd | COpLogicOr
    | COpCompareEQ | COpCompareNE | COpCompareLT | COpCompareLE
    | COpCompareGT | COpCompareGE | COpArrayElem | COpAssign
    | COpAugAdd | COpAugSub | COpAugMul | COpAugDiv | COpAugMod
    | COpAugSHL | COpAugSHR | COpAugBitwiseAnd
    | COpAugBitwiseOr | COpAugBitwiseXor | COpMacroConcat

type cunop_t =
    | COpPlus | COpNegate | COpBitwiseNot | COpLogicNot | COpDeref | COpGetAddr
    | COpPrefixInc | COpPrefixDec | COpSuffixInc | COpSuffixDec | COpMacroName | COpMacroDefined

type ctyp_attr_t = CTypConst | CTypVolatile
type carg_attr_t = CArgPassByPtr | CArgRetVal | CArgFV
type clit_t = klit_t

type ctyp_flag_t =
    | CTypFlagVariantNilCase of int (* if the type is a recursive variant and one of its cases has "void" type,
                                       e.g. type tree_t = Empty | None : (int, tree_t, tree_t),
                                       it makes sense to use a null pointer to identify this case
                                       reduce the amount of memory allocations
                                       (in the case of binary tree it's basically 2x reduction).
                                       We can call this variant case "nullable",
                                       and its index is stored with the flag *)
    | CTypFlagVariantHasTag (* indicates that the variant has a tag. Single-case variants do not need a tag.
                               Recursive variants with just 2 cases, where one of them is "nullable" (see above),
                               do not need a tag either. *)


type ctprops_t =
{
    ctp_scalar: bool;
    ctp_complex: bool;
    ctp_ptr: bool;
    ctp_pass_by_ref: bool;
    ctp_make: id_t list;
    ctp_free: id_t*id_t;
    ctp_copy: id_t*id_t
}

type ctyp_t =
    | CTypInt (* this is a direct mapping from TypInt and CTypInt.
                It's ~ ptrdiff_t - a signed version of size_t, i.e.
                32-bit on 32-bit platforms, 64-bit on 64-bit platforms. *)
    | CTypCInt (* this is 'int' in C. It's almost always 32-bit *)
    | CTypSize_t
    | CTypSInt of int
    | CTypUInt of int
    | CTypFloat of int
    | CTypVoid
    | CTypBool
    | CTypUniChar
    | CTypCSmartPtr
    | CTypString
    | CTypExn
    | CTypStruct of id_t option * (id_t * ctyp_t) list
    | CTypUnion of id_t option * (id_t * ctyp_t) list
    | CTypFunRawPtr of ctyp_t list * ctyp_t
    | CTypRawPtr of ctyp_attr_t list * ctyp_t
    | CTypRawArray of ctyp_attr_t list * ctyp_t
    | CTypArray of int * ctyp_t
    | CTypName of id_t
    | CTypLabel
    | CTypAny
and cctx_t = ctyp_t * loc_t
and cexp_t =
    | CExpIdent of id_t * cctx_t
    | CExpLit of clit_t * cctx_t
    | CExpBinary of cbinop_t * cexp_t * cexp_t * cctx_t
    | CExpUnary of cunop_t * cexp_t * cctx_t
    | CExpMem of cexp_t * id_t * cctx_t
    | CExpArrow of cexp_t * id_t * cctx_t
    | CExpCast of cexp_t * ctyp_t * loc_t
    | CExpTernary of cexp_t * cexp_t * cexp_t * cctx_t
    | CExpCall of cexp_t * cexp_t list * cctx_t
    | CExpInit of cexp_t list * cctx_t (* {a, b, c, ...} *)
    | CExpTyp of ctyp_t * loc_t
    | CExpCCode of string * loc_t
and cstmt_t =
    | CStmtNop of loc_t
    | CComment of string * loc_t
    | CExp of cexp_t
    | CStmtBreak of loc_t
    | CStmtContinue of loc_t
    | CStmtReturn of cexp_t option * loc_t
    | CStmtBlock of cstmt_t list * loc_t
    | CStmtIf of cexp_t * cstmt_t * cstmt_t * loc_t
    | CStmtGoto of id_t * loc_t
    | CStmtLabel of id_t * loc_t
    | CStmtFor of ctyp_t option * cexp_t list * cexp_t option * cexp_t list * cstmt_t * loc_t
    | CStmtWhile of cexp_t * cstmt_t * loc_t
    | CStmtDoWhile of cstmt_t * cexp_t * loc_t
    | CStmtSwitch of cexp_t * (cexp_t list * cstmt_t list) list * loc_t
    (* we don't parse and don't process the inline C code; just retain it as-is *)
    | CDefVal of ctyp_t * id_t * cexp_t option * loc_t
    | CDefFun of cdeffun_t ref
    | CDefTyp of cdeftyp_t ref
    | CDefForwardSym of id_t * loc_t
    | CDefForwardTyp of id_t * loc_t
    | CDefEnum of cdefenum_t ref
    | CMacroDef of cdefmacro_t ref
    | CMacroUndef of id_t * loc_t
    (* this is not universal representation of the conditional macro directives,
       because they do not have to follow the code structure,
       but it's probably good enough for our purposes *)
    | CMacroIf of (cexp_t * cstmt_t list) list * cstmt_t list * loc_t
    | CMacroInclude of string * loc_t
    | CMacroPragma of string * loc_t
and cdefval_t = { cv_name: id_t; cv_typ: ctyp_t; cv_cname: string; cv_flags: val_flags_t; cv_loc: loc_t }
and cdeffun_t = { cf_name: id_t; cf_cname: string;
                  cf_args: (id_t * ctyp_t * (carg_attr_t list)) list;
                  cf_rt: ctyp_t; cf_body: cstmt_t list;
                  cf_flags: fun_flags_t; cf_scope: scope_t list; cf_loc: loc_t }
and cdeftyp_t = { ct_name: id_t; ct_typ: ctyp_t; ct_cname: string;
                  ct_props: ctprops_t; ct_data_start: int; ct_enum: id_t;
                  ct_scope: scope_t list; ct_loc: loc_t }
and cdefenum_t = { cenum_name: id_t; cenum_members: (id_t * cexp_t option) list; cenum_cname: string;
                   cenum_scope: scope_t list; cenum_loc: loc_t }
and cdeflabel_t = { cl_name: id_t; cl_cname: string; cl_loc: loc_t }
and cdefmacro_t = { cm_name: id_t; cm_cname: string; cm_args: id_t list; cm_body: cstmt_t list;
                    cm_scope: scope_t list; cm_loc: loc_t }
and cdefexn_t = { cexn_name: id_t; cexn_cname: string; cexn_base_cname: string;
                  cexn_typ: ctyp_t; cexn_std: bool; cexn_tag: id_t; cexn_data: id_t;
                  cexn_info: id_t; cexn_make: id_t; cexn_scope: scope_t list; cexn_loc: loc_t }
and cdefmodule_t = { cmod_name: id_t; cmod_cname: string; cmod_ccode: cstmt_t list;
                    cmod_main: bool; cmod_recompile: bool; cmod_pragmas: pragmas_t }

type cinfo_t =
    | CNone | CText of string | CVal of cdefval_t | CFun of cdeffun_t ref
    | CTyp of cdeftyp_t ref | CExn of cdefexn_t ref | CEnum of cdefenum_t ref
    | CLabel of cdeflabel_t | CMacro of cdefmacro_t ref

let all_idcs = dynvec_create CNone
let idcs_frozen = ref true
let freeze_idcs f = idcs_frozen := f

let new_idc_idx() =
    let _ = if not !idcs_frozen then () else
        failwith "internal error: attempt to add new idc when they are frozen" in
    let new_idx = dynvec_push all_ids in
    let new_kidx = dynvec_push K_form.all_idks in
    let new_cidx = dynvec_push all_idcs in
    if new_idx = new_kidx && new_idx = new_cidx then new_idx else
        failwith "internal error: unsynchronized outputs from new_id_idx(), new_idk_idx() and new_idc_idx()"

let cinfo_ i loc = dynvec_get all_idcs (id2idx_ i loc)

let gen_temp_idc s =
    let i_name = get_id_prefix s in
    let i_real = new_idc_idx() in
    Id.Temp(i_name, i_real)

let gen_idc s =
    let i_name = get_id_prefix s in
    let i_real = new_idc_idx() in
    Id.Val(i_name, i_real)

let dup_idc old_id =
    let k = new_idc_idx() in
    match old_id with
    | Id.Name(i) -> Id.Val(i, k)
    | Id.Val(i, j) -> Id.Val(i, k)
    | Id.Temp(i, j) -> Id.Temp(i, k)

let set_idc_entry i n =
    let idx = id2idx i in dynvec_set all_idcs idx n

let init_all_idcs () =
    freeze_ids true; freeze_idks true; freeze_idcs false;
    dynvec_init all_idcs K_form.all_idks.dynvec_count

let get_cexp_ctx e = match e with
    | CExpIdent(_, c) -> c
    | CExpLit(_, c) -> c
    | CExpBinary(_, _, _, c) -> c
    | CExpUnary(_, _, c) -> c
    | CExpMem(_, _, c) -> c
    | CExpArrow(_, _, c) -> c
    | CExpCast(_, t, l) -> (t, l)
    | CExpTernary(_, _, _, c) -> c
    | CExpCall(_, _, c) -> c
    | CExpInit(_, c) -> c
    | CExpTyp(t, l) -> (t, l)
    | CExpCCode (_, l) -> (CTypAny, l)

let get_cexp_typ e = let (t, l) = (get_cexp_ctx e) in t
let get_cexp_loc e = let (t, l) = (get_cexp_ctx e) in l

let get_cstmt_loc s = match s with
    | CStmtNop l -> l
    | CComment (_, l) -> l
    | CExp e -> get_cexp_loc e
    | CStmtBreak l -> l
    | CStmtContinue l -> l
    | CStmtReturn (_, l) -> l
    | CStmtBlock (_, l) -> l
    | CStmtIf (_, _, _, l) -> l
    | CStmtGoto (_, l) -> l
    | CStmtLabel (_, l) -> l
    | CStmtFor (_, _, _, _, _, l) -> l
    | CStmtWhile (_, _, l) -> l
    | CStmtDoWhile (_, _, l) -> l
    | CStmtSwitch (_, _, l) -> l
    | CDefVal (_, _, _, l) -> l
    | CDefFun {contents={cf_loc}} -> cf_loc
    | CDefTyp {contents={ct_loc}} -> ct_loc
    | CDefForwardSym (_, cff_loc) -> cff_loc
    | CDefForwardTyp (_, cft_loc) -> cft_loc
    | CDefEnum {contents={cenum_loc}} -> cenum_loc
    | CMacroDef {contents={cm_loc}} -> cm_loc
    | CMacroUndef (_, l) -> l
    | CMacroIf (_, _, l) -> l
    | CMacroInclude (_, l) -> l
    | CMacroPragma (_, l) -> l

let get_cinfo_loc info =
    match info with
    | CNone | CText _ -> noloc
    | CVal {cv_loc} -> cv_loc
    | CFun {contents = {cf_loc}} -> cf_loc
    | CTyp {contents = {ct_loc}} -> ct_loc
    | CExn {contents = {cexn_loc}} -> cexn_loc
    | CEnum {contents = {cenum_loc}} -> cenum_loc
    | CLabel {cl_loc} -> cl_loc
    | CMacro {contents={cm_loc}} -> cm_loc

let get_idc_loc i loc = get_cinfo_loc (cinfo_ i loc)

let check_cinfo info i loc =
    match info with
    | CNone -> raise_compile_err loc (sprintf "check_cinfo: attempt to request type of non-existing symbol '%s'" (id2str i))
    | CText s -> raise_compile_err loc (sprintf "check_cinfo: attempt to request type of symbol '%s'" s)
    | _ -> ()

let get_cinfo_typ info i loc =
    check_cinfo info i loc;
    match info with
    | CNone -> CTypAny
    | CText _ -> CTypAny
    | CVal {cv_typ} -> cv_typ
    | CFun {contents = {cf_args; cf_rt}} ->
        CTypFunRawPtr((List.map (fun (_, t, _) -> t) cf_args), cf_rt)
    | CTyp {contents = {ct_typ}} -> ct_typ
    | CExn _ -> CTypExn
    | CMacro {contents = {cm_args}} ->
        (match cm_args with
        | [] -> CTypAny
        | _ -> CTypFunRawPtr((List.map (fun a -> CTypAny) cm_args), CTypAny))
    | CLabel _ -> CTypLabel
    | CEnum _ -> CTypCInt

let get_idc_typ i loc =
    match i with
    | Id.Name _ -> CTypAny
    | _ -> get_cinfo_typ (cinfo_ i loc) i loc

let get_idc_cname i loc =
    match i with
    | Id.Name _ -> pp_id2str i
    | _ -> (match (cinfo_ i loc) with
        | CNone -> ""
        | CText _ -> ""
        | CVal {cv_cname} -> cv_cname
        | CFun {contents = {cf_cname}} -> cf_cname
        | CTyp {contents = {ct_cname}} -> ct_cname
        | CLabel {cl_cname} -> cl_cname
        | CEnum {contents = {cenum_cname}} -> cenum_cname
        | CExn {contents = {cexn_cname}} -> cexn_cname
        | CMacro {contents = {cm_cname}} -> cm_cname)

let get_lit_ctyp l = match l with
    | KLitInt(_) -> CTypInt
    | KLitSInt(b, _) -> CTypSInt(b)
    | KLitUInt(b, _) -> CTypUInt(b)
    | KLitFloat(b, _) -> CTypFloat(b)
    | KLitString(_) -> CTypString
    | KLitChar(_) -> CTypUniChar
    | KLitBool(_) -> CTypBool
    | KLitNil(t) ->
        (match t with
        | KTypName(n) -> CTypName(n)
        | _ -> CTypRawPtr([], CTypVoid))

let create_cdefval n t flags cname e_opt code loc =
    let dv = { cv_name=n; cv_typ=t; cv_cname=cname; cv_flags=flags; cv_loc=loc } in
    match t with
    | CTypVoid -> raise_compile_err loc "values of 'void' type are not allowed"
    | _ -> ();
    set_idc_entry n (CVal dv);
    (CExpIdent(n, (t, loc)), (CDefVal(t, n, e_opt, loc)) :: code)

let add_cf_arg v ctyp cname loc =
    let cv = { cv_name=v; cv_typ=ctyp; cv_cname=cname;
        cv_flags={(default_val_flags()) with val_flag_arg=true}; cv_loc=loc }
    in set_idc_entry v (CVal cv)

let get_ccode_loc ccode default_loc =
    loclist2loc (List.map get_cstmt_loc ccode) default_loc

let filter_out_nops code =
    List.filter (fun s -> match s with
        | CStmtNop _ -> false
        | _ -> true) code

let ccode2stmt code loc =
    match (filter_out_nops code) with
    | [] -> CStmtNop(loc)
    | s :: [] -> s
    | _ ->
        let final_loc = get_ccode_loc code loc in
        CStmtBlock(code, final_loc)

let rccode2stmt code loc = match (filter_out_nops code) with
    | [] -> CStmtNop loc
    | s :: [] -> s
    | _ ->
        let final_loc = get_ccode_loc code loc in
        CStmtBlock((List.rev code), final_loc)

let stmt2ccode s =
    match s with
    | CStmtNop _ -> []
    | CStmtBlock(slist, _) -> slist
    | _ -> s :: []

let cexp2stmt e =
    match e with
    | CExpInit([], (CTypVoid, loc)) -> CStmtNop loc
    | _ -> CExp e

(* walk through a C-form and produce another one *)

type c_callb_t =
{
    ccb_ident: (id_t -> c_callb_t -> id_t) option;
    ccb_typ: (ctyp_t -> c_callb_t -> ctyp_t) option;
    ccb_exp: (cexp_t -> c_callb_t -> cexp_t) option;
    ccb_stmt: (cstmt_t -> c_callb_t -> cstmt_t) option;
}

let rec check_n_walk_ident n callb =
    match callb.ccb_ident with
    | Some(f) -> f n callb
    | _ -> n

and check_n_walk_ctyp t callb =
    match callb.ccb_typ with
    | Some(f) -> f t callb
    | _ -> walk_ctyp t callb

and check_n_walk_cexp e callb =
    match callb.ccb_exp with
    | Some(f) -> f e callb
    | _ -> walk_cexp e callb

and check_n_walk_cstmt s callb =
    match callb.ccb_stmt with
    | Some(f) -> f s callb
    | _ -> walk_cstmt s callb

and walk_ctyp t callb =
    let walk_id_ n = check_n_walk_ident n callb in
    let walk_id_opt_ n_opt = match n_opt with Some n -> Some (walk_id_ n) | _ -> None in
    let walk_ctyp_ t = check_n_walk_ctyp t callb in
    (match t with
    | CTypInt | CTypCInt | CTypSInt _ | CTypUInt _ | CTypFloat _
    | CTypSize_t | CTypVoid | CTypBool | CTypExn | CTypAny
    | CTypUniChar | CTypCSmartPtr | CTypString -> t
    | CTypStruct (n_opt, selems) ->
        CTypStruct((walk_id_opt_ n_opt), (List.map (fun (n, t) -> ((walk_id_ n), (walk_ctyp_ t))) selems))
    | CTypUnion (n_opt, uelems) ->
        CTypUnion((walk_id_opt_ n_opt), (List.map (fun (n, t) -> ((walk_id_ n), (walk_ctyp_ t))) uelems))
    | CTypFunRawPtr (args, rt) -> CTypFunRawPtr((List.map walk_ctyp_ args), (walk_ctyp_ rt))
    | CTypArray(d, et) -> CTypArray(d, walk_ctyp_ et)
    | CTypRawPtr(attrs, t) -> CTypRawPtr(attrs, (walk_ctyp_ t))
    | CTypRawArray(attrs, et) -> CTypRawArray(attrs, (walk_ctyp_ et))
    | CTypName n -> CTypName(walk_id_ n)
    | CTypLabel -> t)

and walk_cexp e callb =
    let walk_id_ n = check_n_walk_ident n callb in
    let walk_ctyp_ t = check_n_walk_ctyp t callb in
    let walk_cexp_ e = check_n_walk_cexp e callb in
    let walk_ctx_ (t, loc) = ((walk_ctyp_ t), loc) in
    (match e with
    | CExpIdent (n, ctx) -> CExpIdent((walk_id_ n), (walk_ctx_ ctx))
    | CExpLit (KLitNil (KTypName(n)), ctx) -> CExpLit(KLitNil (KTypName(walk_id_ n)), (walk_ctx_ ctx))
    | CExpLit (lit, ctx) -> CExpLit(lit, (walk_ctx_ ctx))
    | CExpBinary (bop, e1, e2, ctx) -> CExpBinary(bop, (walk_cexp_ e1), (walk_cexp_ e2), (walk_ctx_ ctx))
    | CExpUnary (uop, e, ctx) -> CExpUnary(uop, (walk_cexp_ e), (walk_ctx_ ctx))
    (* we exclude the second arguments of CExpMem/CExpArrow from the traversal procedure,
       because they are not real id's; they are just symbolic representation of the accessed record fields *)
    | CExpMem (e, m, ctx) -> CExpMem((walk_cexp_ e), m, (walk_ctx_ ctx))
    | CExpArrow (e, m, ctx) -> CExpArrow((walk_cexp_ e), m, (walk_ctx_ ctx))
    | CExpCast (e, t, loc) -> CExpCast((walk_cexp_ e), (walk_ctyp_ t), loc)
    | CExpTernary (e1, e2, e3, ctx) -> CExpTernary((walk_cexp_ e1), (walk_cexp_ e2), (walk_cexp_ e3), (walk_ctx_ ctx))
    | CExpTyp (t, loc) -> CExpTyp((walk_ctyp_ t), loc)
    | CExpCall (f, args, ctx) -> CExpCall((walk_cexp_ f), (List.map walk_cexp_ args), (walk_ctx_ ctx))
    | CExpInit (eseq, ctx) -> CExpInit((List.map walk_cexp_ eseq), (walk_ctx_ ctx))
    | CExpCCode(s, loc) -> e)

and walk_cstmt s callb =
    let walk_id_ n = check_n_walk_ident n callb in
    let walk_ctyp_ t = check_n_walk_ctyp t callb in
    let walk_ctyp_opt_ t_opt = match t_opt with
        | Some t -> Some (walk_ctyp_ t)
        | _ -> t_opt in
    let walk_cexp_ e = check_n_walk_cexp e callb in
    let walk_cel_ el = List.map walk_cexp_ el in
    let walk_cstmt_ s = check_n_walk_cstmt s callb in
    let walk_csl_ sl = List.map walk_cstmt_ sl in
    let walk_cexp_opt_ e_opt = match e_opt with
        | Some e -> Some (check_n_walk_cexp e callb)
        | _ -> e_opt in
    match s with
    | CStmtNop _ -> s
    | CComment _ -> s
    | CExp e -> CExp (walk_cexp_ e)
    | CStmtBreak _ -> s
    | CStmtContinue _ -> s
    | CStmtReturn (e_opt, l) -> CStmtReturn ((walk_cexp_opt_ e_opt), l)
    | CStmtBlock (sl, l) -> CStmtBlock ((walk_csl_ sl), l)
    | CStmtIf (e, s1, s2, l) -> CStmtIf ((walk_cexp_ e), (walk_cstmt_ s1), (walk_cstmt_ s2), l)
    | CStmtGoto (n, l) -> CStmtGoto ((walk_id_ n), l)
    | CStmtLabel (n, l) -> CStmtLabel ((walk_id_ n), l)
    | CStmtFor (t_opt, e1, e2_opt, e3, body, l) ->
        CStmtFor((walk_ctyp_opt_ t_opt), (walk_cel_ e1), (walk_cexp_opt_ e2_opt), (walk_cel_ e3), (walk_cstmt_ body), l)
    | CStmtWhile (e, body, l) ->
        CStmtWhile((walk_cexp_ e), (walk_cstmt_ body), l)
    | CStmtDoWhile (body, e, l) ->
        CStmtDoWhile((walk_cstmt_ body), (walk_cexp_ e), l)
    | CStmtSwitch (e, cases, l) ->
        CStmtSwitch((walk_cexp_ e), (List.map (fun (ll, sl) -> (walk_cel_ ll, walk_csl_ sl)) cases), l)
    | CDefVal (t, n, e_opt, l) -> CDefVal((walk_ctyp_ t), (walk_id_ n), (walk_cexp_opt_ e_opt), l)
    | CDefFun cf ->
        let { cf_name; cf_args; cf_rt; cf_body } = !cf in
        cf := { !cf with
            cf_name = (walk_id_ cf_name);
            cf_args = (List.map (fun (a, t, flags) ->
                ((walk_id_ a), (walk_ctyp_ t), flags)) cf_args);
            cf_rt = (walk_ctyp_ cf_rt);
            cf_body = (walk_csl_ cf_body) };
        s
    | CDefTyp ct ->
        let { ct_name; ct_typ; ct_enum } = !ct in
        ct := { !ct with
            ct_name = (walk_id_ ct_name);
            ct_typ = (walk_ctyp_ ct_typ);
            ct_enum = (walk_id_ ct_enum) };
        s
    | CDefForwardSym (n, loc) ->
        CDefForwardSym (walk_id_ n, loc)
    | CDefForwardTyp (n, loc) ->
        CDefForwardTyp (walk_id_ n, loc)
    | CDefEnum ce ->
        let { cenum_name; cenum_members } = !ce in
        ce := { !ce with
            cenum_name = (walk_id_ cenum_name);
            cenum_members = (List.map (fun (n, e_opt) -> ((walk_id_ n), (walk_cexp_opt_ e_opt))) cenum_members) };
        s
    | CMacroDef cm ->
        let { cm_name; cm_args; cm_body } = !cm in
        cm := { !cm with cm_name = (walk_id_ cm_name);
            cm_args = (List.map walk_id_ cm_args);
            cm_body = (List.map walk_cstmt_ cm_body) };
        s
    | CMacroUndef (n, l) -> CMacroUndef((walk_id_ n), l)
    | CMacroIf (cs_l, else_l, l) ->
        CMacroIf((List.map (fun (c, sl) -> ((walk_cexp_ c), (walk_csl_ sl))) cs_l), (walk_csl_ else_l), l)
    | CMacroInclude _ -> s
    | CMacroPragma _ -> s

(* walk through a K-normalized syntax tree and perform some actions;
   do not construct/return anything (though, it's expected that
   the callbacks collect some information about the tree) *)

type 'x c_fold_callb_t =
{
    ccb_fold_ident: (id_t -> 'x c_fold_callb_t -> unit) option;
    ccb_fold_typ: (ctyp_t -> 'x c_fold_callb_t -> unit) option;
    ccb_fold_exp: (cexp_t -> 'x c_fold_callb_t -> unit) option;
    ccb_fold_stmt: (cstmt_t -> 'x c_fold_callb_t -> unit) option;
    mutable ccb_fold_result: 'x;
}

let rec check_n_fold_ctyp t callb =
    match callb.ccb_fold_typ with
    | Some(f) -> f t callb
    | _ -> fold_ctyp t callb

and check_n_fold_cexp e callb =
    match callb.ccb_fold_exp with
    | Some(f) -> f e callb
    | _ -> fold_cexp e callb

and check_n_fold_cstmt s callb =
    match callb.ccb_fold_stmt with
    | Some(f) -> f s callb
    | _ -> fold_cstmt s callb

and check_n_fold_id n callb =
    match callb.ccb_fold_ident with
    | Some(f) -> f n callb
    | _ -> ()

and fold_ctyp t callb =
    let fold_ctyp_ t = check_n_fold_ctyp t callb in
    let fold_tl_ tl = List.iter fold_ctyp_ tl in
    let fold_id_ i = check_n_fold_id i callb in
    let fold_id_opt_ i_opt = match i_opt with Some(i) -> check_n_fold_id i callb | _ -> () in
    (match t with
    | CTypInt | CTypCInt | CTypSInt _ | CTypUInt _ | CTypFloat _
    | CTypSize_t | CTypVoid | CTypBool | CTypExn | CTypAny
    | CTypUniChar | CTypString | CTypCSmartPtr -> ()
    | CTypStruct (n_opt, selems) ->
        fold_id_opt_ n_opt; List.iter (fun (n, t) -> fold_id_ n; fold_ctyp_ t) selems
    | CTypUnion (n_opt, uelems) ->
        fold_id_opt_ n_opt; List.iter (fun (n, t) -> fold_id_ n; fold_ctyp_ t) uelems
    | CTypFunRawPtr (args, rt) -> fold_tl_ args; fold_ctyp_ rt
    | CTypRawPtr(_, t) -> fold_ctyp_ t
    | CTypRawArray(_, et) -> fold_ctyp_ et
    | CTypArray(_, t) -> fold_ctyp_ t
    | CTypName n -> fold_id_ n
    | CTypLabel -> ())

and fold_cexp e callb =
    let fold_ctyp_ t = check_n_fold_ctyp t callb in
    let fold_id_ i = check_n_fold_id i callb in
    let fold_cexp_ e = check_n_fold_cexp e callb in
    let fold_ctx_ (t, _) = fold_ctyp_ t in
    fold_ctx_ (match e with
    | CExpIdent (n, ctx) -> fold_id_ n; ctx
    | CExpLit (KLitNil (KTypName(n)), ctx) -> fold_id_ n; ctx
    | CExpLit (_, ctx) -> ctx
    | CExpBinary (_, e1, e2, ctx) -> fold_cexp_ e1; fold_cexp_ e2; ctx
    | CExpUnary (_, e, ctx) -> fold_cexp_ e; ctx
    | CExpMem (e, _, ctx) -> fold_cexp_ e; ctx
    | CExpArrow (e, _, ctx) -> fold_cexp_ e; ctx
    | CExpCast (e, t, loc) -> fold_cexp_ e; (t, loc)
    | CExpTernary (e1, e2, e3, ctx) -> fold_cexp_ e1; fold_cexp_ e2; fold_cexp_ e3; ctx
    | CExpCall (f, args, ctx) -> fold_cexp_ f; List.iter fold_cexp_ args; ctx
    | CExpInit (eseq, ctx) -> List.iter fold_cexp_ eseq; ctx
    | CExpTyp (t, loc) -> (t, loc)
    | CExpCCode (s, loc) -> (CTypAny, loc))

and fold_cstmt s callb =
    let fold_cstmt_ s = check_n_fold_cstmt s callb in
    let fold_csl_ sl = List.iter fold_cstmt_ sl in
    let fold_ctyp_ t = check_n_fold_ctyp t callb in
    let fold_id_ k = check_n_fold_id k callb in
    let fold_cexp_ e = check_n_fold_cexp e callb in
    let fold_cel_ el = List.iter fold_cexp_ el in
    let fold_cexp_opt_ e_opt = match e_opt with
        | Some e -> fold_cexp_ e
        | _ -> () in
    match s with
    | CStmtNop _ -> ()
    | CComment _ -> ()
    | CExp e -> fold_cexp_ e
    | CStmtBreak _ -> ()
    | CStmtContinue _ -> ()
    | CStmtReturn (e_opt, _) -> fold_cexp_opt_ e_opt
    | CStmtBlock (sl, _) -> fold_csl_ sl
    | CStmtIf (e, s1, s2, _) -> fold_cexp_ e; fold_cstmt_ s1; fold_cstmt_ s2
    | CStmtGoto (n, _) -> fold_id_ n
    | CStmtLabel (n, _) -> fold_id_ n
    | CStmtFor (t_opt, e1, e2_opt, e3, body, _) ->
        (match t_opt with Some t -> fold_ctyp_ t | _ -> ());
        fold_cel_ e1; fold_cexp_opt_ e2_opt; fold_cel_ e3; fold_cstmt_ body
    | CStmtWhile (e, body, _) ->
        fold_cexp_ e; fold_cstmt_ body
    | CStmtDoWhile (body, e, _) ->
        fold_cstmt_ body; fold_cexp_ e
    | CStmtSwitch (e, cases, l) ->
        fold_cexp_ e; List.iter (fun (ll, sl) -> fold_cel_ ll; fold_csl_ sl) cases
    | CDefVal (t, n, e_opt, _) ->
        fold_ctyp_ t; fold_id_ n; fold_cexp_opt_ e_opt
    | CDefFun cf ->
        let { cf_name; cf_args; cf_rt; cf_body } = !cf in
        fold_id_ cf_name;
        List.iter (fun (a, t, _) -> fold_id_ a; fold_ctyp_ t) cf_args;
        fold_ctyp_ cf_rt;
        fold_csl_ cf_body
    | CDefTyp ct ->
        let { ct_name; ct_typ; ct_enum } = !ct in
        fold_id_ ct_name; fold_ctyp_ ct_typ; fold_id_ ct_enum
    | CDefForwardSym (n, _) ->
        fold_id_ n
    | CDefForwardTyp (n, _) ->
        fold_id_ n
    | CDefEnum ce ->
        let { cenum_name; cenum_members } = !ce in
        fold_id_ cenum_name;
        List.iter (fun (n, e_opt) -> fold_id_ n; fold_cexp_opt_ e_opt) cenum_members
    | CMacroDef cm ->
        let { cm_name; cm_args; cm_body } = !cm in
        fold_id_ cm_name; List.iter fold_id_ cm_args; List.iter fold_cstmt_ cm_body
    | CMacroUndef (n, _) -> fold_id_ n
    | CMacroIf (cs_l, else_l, _) ->
        List.iter (fun (c, sl) -> fold_cexp_ c; fold_csl_ sl) cs_l;
        fold_csl_ else_l
    | CMacroInclude _ -> ()
    | CMacroPragma _ -> ()

let rec ctyp2str t loc =
    match t with
    | CTypInt -> ("int_", noid)
    | CTypCInt -> ("int", noid)
    | CTypSize_t -> ("size_t", noid)
    | CTypSInt(b) -> (("int" ^ (string_of_int b) ^ "_t"), noid)
    | CTypUInt(b) -> (("uint" ^ (string_of_int b) ^ "_t"), noid)
    | CTypFloat(16) -> ("float16_t", noid)
    | CTypFloat(32) -> ("float", noid)
    | CTypFloat(64) -> ("double", noid)
    | CTypFloat(b) -> raise_compile_err loc (sprintf "invalid type CTypFloat(%d)" b)
    | CTypString -> ("fx_str_t", noid)
    | CTypUniChar -> ("char_", noid)
    | CTypBool -> ("bool", noid)
    | CTypVoid -> ("void", noid)
    | CTypExn -> ("fx_exn_t", noid)
    | CTypFunRawPtr(args, rt) ->
        raise_compile_err loc "ctyp2str: raw function pointer type is not supported; use CTypName(...) instead"
    | CTypCSmartPtr -> ("fx_cptr_t", noid)
    | CTypStruct (_, _) ->
        raise_compile_err loc "ctyp2str: CTypStruct(...) is not supported; use CTypName(...) instead"
    | CTypUnion (_, _) ->
        raise_compile_err loc "ctyp2str: CTypUnion(...) is not supported; use CTypName(...) instead"
    | CTypRawPtr (attrs, t) ->
        let (s, _) = ctyp2str t loc in
        let s = if (List.mem CTypConst attrs) then ("const " ^ s) else s in
        let s = if (List.mem CTypVolatile attrs) then ("volatile " ^ s) else s in
        ((s ^ "*"), noid)
    | CTypRawArray (attrs, t) ->
        let (s, _) = ctyp2str t loc in
        let s = if (List.mem CTypConst attrs) then ("const " ^ s) else s in
        let s = if (List.mem CTypVolatile attrs) then ("volatile " ^ s) else s in
        ((s ^ " []"), noid)
    | CTypArray _ -> ("fx_arr_t", noid)
    | CTypName n -> let cname = get_idc_cname n loc in (cname, n)
    | CTypLabel ->
        raise_compile_err loc "ctyp2str: CTypLabel is not supported"
    | CTypAny ->
        raise_compile_err loc "ctyp2str: CTypAny is not supported"

let make_ptr t = match t with
    | CTypAny -> CTypRawPtr([], CTypVoid)
    | _ -> CTypRawPtr([], t)
let make_const_ptr t = match t with
    | CTypAny -> CTypRawPtr([CTypConst], CTypVoid)
    | _ -> CTypRawPtr([CTypConst], t)

let std_CTypVoidPtr = make_ptr CTypVoid
let std_CTypConstVoidPtr = make_const_ptr CTypVoid
let std_CTypAnyArray = CTypArray(0, CTypAny)

let make_lit_exp l loc = let t = get_lit_ctyp l in CExpLit (l, (t, loc))
let make_int__exp i loc = CExpLit ((KLitInt i), (CTypInt, loc))
let make_int_exp i loc = CExpLit ((KLitInt (Int64.of_int i)), (CTypInt, loc))
let make_bool_exp b loc = CExpLit ((KLitBool b), (CTypBool, loc))
let make_nullptr loc = CExpLit (KLitNil(KTypVoid), (std_CTypVoidPtr, loc))
let make_id_exp i loc = let t = get_idc_typ i loc in CExpIdent(i, (t, loc))
let make_id_t_exp i t loc = CExpIdent(i, (t, loc))
let make_label basename loc =
    let basename = if Utils.starts_with basename "_fx_" then basename else "_fx_" ^ basename in
    let li = gen_temp_idc basename in
    let cname = if basename = "_fx_cleanup" then basename else "" in
    set_idc_entry li (CLabel {cl_name=li; cl_cname=cname; cl_loc=loc});
    li

let make_call f args rt loc =
    let f_exp = make_id_exp f loc in
    CExpCall(f_exp, args, (rt, loc))

let make_dummy_exp loc = CExpInit([], (CTypVoid, loc))
let make_assign lhs rhs =
    let loc = get_cexp_loc rhs in
    CExpBinary(COpAssign, lhs, rhs, (CTypVoid, loc))

let cexp_get_addr e =
    match e with
    | CExpUnary(COpDeref, x, _) -> x
    | CExpBinary(COpArrayElem, x, i, (t, loc)) ->
        CExpBinary(COpAdd, x, i, ((make_ptr t), loc))
    | _ ->
        let (t, loc) = get_cexp_ctx e in
        let t = CTypRawPtr([], (match t with CTypAny -> CTypVoid | _ -> t)) in
        CExpUnary(COpGetAddr, e, (t, loc))

let cexp_deref_typ t =
    match t with
    | CTypRawPtr(_, CTypVoid) -> CTypAny
    | CTypRawPtr(_, t) -> t
    | _ -> CTypAny

let cexp_deref e =
    match e with
    | CExpUnary(COpGetAddr, x, _) -> x
    | CExpBinary(COpAdd, x, i, (t, loc)) ->
        CExpBinary(COpArrayElem, x, i, ((cexp_deref_typ t), loc))
    | _ ->
        let (t, loc) = get_cexp_ctx e in
        let t = cexp_deref_typ t in
        CExpUnary(COpDeref, e, (t, loc))

let cexp_arrow e m_id t =
    let loc = get_cexp_loc e in
    match e with
    | CExpUnary(COpGetAddr, x, _) -> CExpMem(x, m_id, (t, loc))
    | _ -> CExpArrow(e, m_id, (t, loc))

let cexp_mem e m_id t =
    let loc = get_cexp_loc e in
    match e with
    | CExpUnary(COpDeref, x, _) -> CExpArrow(x, m_id, (t, loc))
    | _ -> CExpMem(e, m_id, (t, loc))

let std_FX_MAX_DIMS = 5
let std_sizeof = ref noid

let std_fx_malloc = ref noid
let std_fx_free = ref noid
let std_fx_free_t = ref CTypVoid
let std_fx_copy_t = ref CTypVoid
let std_FX_INCREF = ref noid
let std_FX_DECREF = ref noid

let std_FX_REC_VARIANT_TAG = ref noid
let std_FX_MAKE_RECURSIVE_VARIANT_IMPL_START = ref noid
let std_FX_MAKE_FP_IMPL_START = ref noid
let std_FX_CALL = ref noid
let std_FX_COPY_PTR = ref noid
let std_FX_COPY_SIMPLE = ref noid
let std_FX_COPY_SIMPLE_BY_PTR = ref noid
let std_FX_NOP = ref noid
let std_FX_BREAK = ref noid
let std_FX_CONTINUE = ref noid
let std_FX_CHECK_BREAK = ref noid
let std_FX_CHECK_BREAK_ND = ref noid
let std_FX_CHECK_CONTINUE = ref noid
let std_FX_CHECK_EXN = ref noid
let std_FX_CHECK_ZERO_STEP = ref noid
let std_FX_LOOP_COUNT = ref noid
let std_FX_CHECK_EQ_SIZE = ref noid

let std_fx_copy_ptr = ref noid

let std_FX_STR_LENGTH = ref noid
let std_FX_STR_CHKIDX = ref noid
let std_FX_STR_ELEM = ref noid
let std_FX_MAKE_STR = ref noid
let std_FX_FREE_STR = ref noid
let std_fx_free_str = ref noid
let std_FX_COPY_STR = ref noid
let std_fx_copy_str = ref noid
let std_fx_substr = ref noid

let std_fx_exn_info_t = ref CTypVoid
let std_FX_REG_SIMPLE_EXN = ref noid
let std_FX_REG_SIMPLE_STD_EXN = ref noid
let std_FX_REG_EXN = ref noid
let std_FX_MAKE_EXN_IMPL_START = ref noid

let std_FX_THROW = ref noid
let std_FX_FAST_THROW = ref noid
let std_FX_FREE_EXN = ref noid
let std_FX_COPY_EXN = ref noid
let std_FX_MAKE_EXN_IMPL = ref noid
let std_fx_free_exn = ref noid
let std_fx_copy_exn = ref noid
let std_FX_RETHROW = ref noid

let std_FX_FREE_LIST_SIMPLE = ref noid
let std_fx_free_list_simple = ref noid
let std_fx_list_length = ref noid
let std_FX_FREE_LIST_IMPL = ref noid
let std_FX_MAKE_LIST_IMPL = ref noid
let std_FX_LIST_APPEND = ref noid
let std_FX_MOVE_LIST = ref noid

let std_FX_CHKIDX1 = ref noid
let std_FX_CHKIDX = ref noid
let std_FX_PTR_xD = ref ([] : id_t list)

let std_FX_ARR_SIZE = ref noid
let std_FX_FREE_ARR = ref noid
let std_FX_MOVE_ARR = ref noid
let std_fx_free_arr = ref noid
let std_fx_copy_arr = ref noid
let std_fx_copy_arr_data = ref noid
let std_fx_make_arr = ref noid
let std_fx_subarr = ref noid

let std_FX_FREE_REF_SIMPLE = ref noid
let std_fx_free_ref_simple = ref noid
let std_FX_FREE_REF_IMPL = ref noid
let std_FX_MAKE_REF_IMPL = ref noid

let std_FX_FREE_FP = ref noid
let std_FX_COPY_FP = ref noid
let std_fx_free_fp = ref noid
let std_fx_copy_fp = ref noid

let std_fx_free_cptr = ref noid
let std_fx_copy_cptr = ref noid
