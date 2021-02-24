(*
    This file is a part of ficus language project.
    See ficus/LICENSE for the licensing terms
*)

(*
    Convert all non-primitive types to KTypName(...)
    (including lists, arrays, references, tuples, records etc.).
    This is a useful step to make K-form closer to the final C code.
*)

open Ast
open K_form

type mangle_map_t = (string, id_t) Hashtbl.t

let rec mangle_scope sc result loc =
    match sc with
    | ScModule(m) :: rest ->
        let mstr = pp_id2str m in
        let result = if mstr = "Builtins" then result else
                     if result = "" then mstr else mstr ^ "__" ^ result in
        mangle_scope rest result loc
    | _ :: rest -> mangle_scope rest result loc
    | [] -> result

(* [TODO] when we add support for non-English characters in the identifiers,
    they should be "transliterated" into English
    (however, it looks like recent versions of clang/GCC
    support Unicode identifiers) *)
let mangle_name n sc_opt loc =
    let sc = match sc_opt with
        | Some sc -> sc
        | _ -> get_kscope (kinfo_ n loc) in
    let prefix = mangle_scope sc "" loc in
    let nstr = pp_id2str n in
    if prefix = "" then nstr else prefix ^ "__" ^ nstr

(* try to compress the name by encoding the module name just once;
   for now it's used only for functions *)
let compress_name nstr sc loc =
    let prefix = mangle_scope sc "" loc in
    if prefix = "" then nstr
    else
        let prefix_ = prefix ^ "__" in
        let prefix_len = String.length prefix_ in
        let rx = Str.regexp ("\\([FVR]t*\\)\\([0-9]+\\)" ^ prefix_) in
        let new_nstr = Str.global_substitute rx (fun s ->
            let c = Str.matched_group 1 s in
            let len1 = int_of_string (Str.matched_group 2 s) in
            c ^ "M" ^ (string_of_int (len1 - prefix_len))) nstr in
        if new_nstr = nstr then nstr else
        "M" ^ (string_of_int (String.length prefix)) ^ prefix ^ new_nstr

(* Check if <prefix><nlen><name><suffix> is unique.
   If yes, add it to the set of mangled names and output.
   Otherwise, try <prefix><nlen+2><name>1_<suffix>,
   then <prefix><nlen+2><name>2_<suffix> etc.
   e.g. with prefix="V", name="rbtree" and suffix="1i"
   first try V6rbtree1i, then V8rbtree1_1i, V8rbtree2_1i, ..., V9rbtree10_1i etc.
   Note, that the name is preceded with its length
   (that includes the possible "1_" etc. in the end) *)
let mangle_make_unique n_id prefix name suffix mangle_map =
    let rec make_unique_ idx =
        let idxstr = if idx = 0 then "" else (string_of_int idx) ^ "_" in
        let name1 = name ^ idxstr in
        let nlen = String.length name1 in
        let candidate_base_name = prefix ^ (string_of_int nlen) ^ name1 in
        let candidate = candidate_base_name ^ suffix in
        if Hashtbl.mem mangle_map candidate then
            make_unique_ (idx + 1)
        else
            (Hashtbl.add mangle_map candidate n_id;
            (candidate_base_name, candidate))
        in
    make_unique_ 0

let add_fx str = if Utils.starts_with str "_fx_" then str else "_fx_" ^ str
let remove_fx str = if Utils.starts_with str "_fx_" then Utils.trim_left str 4 else str

(* Convert type to a string, i.e. mangle it.
   Use mangle_map to control uniqueness when mangling KTypName _ and KTypRecord _.
   Update the mangled names (cname), if needed,
   for those KTypName _ and KTypRecord _. *)
let rec mangle_ktyp t mangle_map loc =
    let rec mangle_inst_ n_id prefix targs name sc =
        let nargs = List.length targs in
        let result = List.fold_left
            (fun result targ -> mangle_ktyp_ targ result)
            [] targs in
        let (prefix, suffix) = if nargs = 0 then (prefix, "") else
            ((prefix ^ "t"), ((string_of_int nargs) ^ (String.concat "" (List.rev result)))) in
        let name = mangle_name name (Some sc) loc in
        mangle_make_unique n_id prefix name suffix mangle_map
    and mangle_typname_ n result =
        match (kinfo_ n loc) with
        | KVariant kvar ->
            let {kvar_name; kvar_cname; kvar_targs; kvar_scope} = !kvar in
            if kvar_cname = "" then
                let (base_name, cname) = mangle_inst_ kvar_name "V" kvar_targs kvar_name kvar_scope in
                let _ = kvar := {!kvar with kvar_cname=add_fx cname; kvar_base_name=get_id base_name} in
                cname :: result
            else (remove_fx kvar_cname) :: result
        | KTyp ({contents={kt_typ=KTypRecord(_,_)}} as kt) ->
            let {kt_name; kt_cname; kt_targs; kt_scope} = !kt in
            if kt_cname = "" then
                let (_, cname) = mangle_inst_ kt_name "R" kt_targs kt_name kt_scope in
                let _ = kt := {!kt with kt_cname=add_fx cname} in
                cname :: result
            else (remove_fx kt_cname) :: result
        | KTyp {contents={kt_cname}} ->
            if kt_cname = "" then
                raise_compile_err loc "KTyp does not have a proper mangled name"
            else (remove_fx kt_cname) :: result
        | _ ->
            raise_compile_err loc (sprintf "unsupported type '%s' (should be variant or record)" (id2str n))
    and mangle_ktyp_ t result =
        match t with
        | KTypInt -> "i" :: result
        | KTypSInt(8) -> "c" :: result
        | KTypSInt(16) -> "s" :: result
        | KTypSInt(32) -> "n" :: result
        (* maybe it's not very good, but essentially CInt~"int" is equivalent to "int32_t" *)
        | KTypCInt -> "n" :: result
        | KTypSInt(64) -> "l" :: result
        | KTypSInt n -> raise_compile_err loc (sprintf "unsupported typ KTypSInt(%d)" n)
        | KTypUInt(8) -> "b" :: result
        | KTypUInt(16) -> "w" :: result
        | KTypUInt(32) -> "u" :: result
        | KTypUInt(64) -> "q" :: result
        | KTypUInt n -> raise_compile_err loc (sprintf "unsupported typ KTypUInt(%d)" n)
        | KTypFloat(16) -> "h" :: result
        | KTypFloat(32) -> "f" :: result
        | KTypFloat(64) -> "d" :: result
        | KTypFloat n -> raise_compile_err loc (sprintf "unsupported typ KTypFloat(%d)" n)
        | KTypVoid -> "v" :: result
        | KTypNil -> "z" :: result
        | KTypBool -> "B" :: result
        | KTypChar -> "C" :: result
        | KTypString -> "S" :: result
        | KTypCPointer -> "p" :: result
        | KTypFun(args, rt) ->
            let result = mangle_ktyp_ rt ("FP" :: result) in
            let result = (string_of_int (List.length args)) :: result in
            List.fold_left (fun result a -> mangle_ktyp_ a result) result args
        | KTypTuple(elems) ->
            let nelems = List.length elems in
            let nstr = string_of_int nelems in
            (match elems with
            | t0 :: rest ->
                if List.for_all (fun t -> t = t0) rest then
                    mangle_ktyp_ t0 (nstr :: "Ta" :: result)
                else
                    List.fold_left (fun result t -> mangle_ktyp_ t result) (nstr :: "T" :: result) elems
            | _ -> raise_compile_err loc "the tuple has 0 elements")
        (* treat the closure type just like normal function type, because after the lambda
            lifting all the 'function pointers' are 'closures' *)
        | KTypRecord(rn, _) -> mangle_typname_ rn result
        | KTypName(n) -> mangle_typname_ n result
        | KTypArray(dims, t) ->
            let result =  (string_of_int dims) :: "A" :: result in
            mangle_ktyp_ t result
        | KTypList(t) -> mangle_ktyp_ t ("L" :: result)
        | KTypRef(t) -> mangle_ktyp_ t ("r" :: result)
        | KTypExn -> "E" :: result
        | KTypErr -> raise_compile_err loc "KTypErr cannot be mangled"
        | KTypModule -> raise_compile_err loc "KTypModule cannot be mangled"
    in String.concat "" (List.rev (mangle_ktyp_ t []))

let mangle_all kmods =
    let mangle_map = (Hashtbl.create 1000 : mangle_map_t) in
    let curr_top_code = ref ([]: kexp_t list) in
    let create_gen_typ t name_prefix loc =
        let cname = mangle_ktyp t mangle_map loc in
        try
            let i = Hashtbl.find mangle_map cname in
            KTypName i
        with Not_found ->
            let i = gen_temp_idk name_prefix in
            let kt = ref { kt_name=i; kt_cname=add_fx cname; kt_targs=[]; kt_typ=t;
                kt_props=None; kt_scope=ScGlobal::[]; kt_loc=loc } in
            Hashtbl.add mangle_map cname i;
            set_idk_entry i (KTyp kt);
            curr_top_code := (KDefTyp kt) :: !curr_top_code;
            KTypName i
        in
    let rec walk_ktyp_n_mangle t loc callb =
        let t = walk_ktyp t loc callb in
        match t with
        | KTypInt | KTypCInt | KTypSInt _ | KTypUInt _ | KTypFloat _
        | KTypVoid | KTypNil | KTypBool | KTypChar
        | KTypString | KTypCPointer | KTypExn
        | KTypErr | KTypModule -> t
        | KTypName n -> ignore(mangle_ktyp t mangle_map loc); t
        | KTypRecord(rn, _) -> ignore(mangle_ktyp t mangle_map loc); KTypName rn
        | KTypFun _ -> create_gen_typ t "fun" loc
        | KTypTuple _ -> create_gen_typ t "tup" loc
        | KTypArray _ -> t (*create_gen_typ t "arr" loc*)
        | KTypList _ -> create_gen_typ t "lst" loc
        | KTypRef _ -> create_gen_typ t "ref" loc
    and mangle_id_typ i loc callb =
        if i = noid then () else
        match (kinfo_ i loc) with
        | KVal kv ->
            let {kv_typ; kv_flags} = kv in
            let t = walk_ktyp_n_mangle kv_typ loc callb in
            let cname = match (get_val_scope kv_flags) with
                | ScBlock _ :: _ -> ""
                | sc ->
                    let bare_name = mangle_name i (Some sc) loc in
                    let (_, cname) = mangle_make_unique i "_fx_g" bare_name "" mangle_map in
                    cname
                in
            set_idk_entry i (KVal {kv with kv_typ=t; kv_cname=cname})
        | _ -> ()
    and mangle_ktyp_retain_record t loc callb =
        match t with
        | KTypRecord(rn, relems) ->
            KTypRecord(rn, List.map (fun (ni, ti) -> (ni, walk_ktyp_n_mangle ti loc callb)) relems)
        | t -> walk_ktyp_n_mangle t loc callb
    and mangle_idoml idoml at_ids loc callb =
        List.iter (fun i -> mangle_id_typ i loc callb) at_ids;
        List.iter (fun (k, _) -> mangle_id_typ k loc callb) idoml
    and walk_kexp_n_mangle e callb =
        match e with
        | KDefVal(n, e, loc) ->
            let e = walk_kexp_n_mangle e callb in
            mangle_id_typ n loc callb;
            KDefVal(n, e, loc)
        | KDefFun kf ->
            let {kf_name; kf_args; kf_rt; kf_body; kf_closure; kf_scope; kf_loc} = !kf in
            let {kci_fcv_t} = kf_closure in
            let args = List.map (fun (a, t) ->
                mangle_id_typ a kf_loc callb;
                (a, (get_idk_ktyp a kf_loc))) kf_args in
            let rt = walk_ktyp_n_mangle kf_rt kf_loc callb in
            let ktyp = get_kf_typ args rt in
            let suffix = mangle_ktyp ktyp mangle_map kf_loc in
            let suffix = String.sub suffix 2 ((String.length suffix) - 2) in
            let new_body = walk_kexp_n_mangle kf_body callb in
            let bare_name = mangle_name kf_name (Some kf_scope) kf_loc in
            let (_, cname) = mangle_make_unique kf_name "F" bare_name suffix mangle_map in
            let cname = add_fx (compress_name cname kf_scope kf_loc) in
            let mangled_ktyp = walk_ktyp_n_mangle ktyp kf_loc callb in
            let mangled_ktyp_id = match mangled_ktyp with
                | KTypName tn -> tn
                | _ -> raise_compile_err kf_loc (sprintf "mangle: cannot mangle '%s' type down to alias" cname)
                in
            (if kci_fcv_t = noid then () else
                match (kinfo_ kci_fcv_t kf_loc) with
                | KClosureVars kcv ->
                    let { kcv_freevars; kcv_loc } = !kcv in
                    let cv_cname = cname ^ "_cldata_t" in
                    let freevars = List.map (fun (n, t) -> (n, (walk_ktyp_n_mangle t kcv_loc callb))) kcv_freevars in
                    kcv := { !kcv with kcv_cname=cv_cname; kcv_freevars=freevars }
                | _ ->
                    raise_compile_err kf_loc "mangle: invalid closure datatype (should be KClosureVars)");
            kf := { !kf with kf_cname=cname; kf_args=args; kf_rt=rt; kf_body=new_body;
                kf_closure={kf_closure with kci_fp_typ=mangled_ktyp_id} };
            e
        | KDefExn ke ->
            let {ke_name; ke_typ; ke_scope; ke_std; ke_tag; ke_make; ke_loc} = !ke in
            let t = mangle_ktyp_retain_record ke_typ ke_loc callb in
            let suffix = mangle_ktyp t mangle_map ke_loc in
            let bare_name = mangle_name ke_name (Some ke_scope) ke_loc in
            let (base_cname, cname) = mangle_make_unique ke_name "E" bare_name suffix mangle_map in
            let exn_cname = add_fx cname in
            let _ = ke := { !ke with ke_cname=exn_cname; ke_typ=t; ke_base_cname=base_cname } in
            (* also, mangle the exception tag *)
            let tag_kv = get_kval ke_tag ke_loc in
            let tag_cname = if ke_std then "FX_EXN_" ^ (pp_id2str ke_name)
                            else "_FX_EXN_" ^ base_cname in
            let tag_kv = {tag_kv with kv_cname=tag_cname} in
            set_idk_entry ke_tag (KVal tag_kv);
            e
        | KDefVariant kvar ->
            let {kvar_name; kvar_cases; kvar_loc} = !kvar in
            (* compute and set kvar_cname *)
            let _ = mangle_ktyp (KTypName kvar_name) mangle_map kvar_loc in
            let tag_base_name = "_FX_" ^ (pp_id2str (!kvar).kvar_base_name) ^ "_" in
            let var_cases = List.map (fun (ni, ti) ->
                let tag_name = tag_base_name ^ (pp_id2str ni) in
                let kv = get_kval ni kvar_loc in
                let _ = set_idk_entry ni (KVal {kv with kv_cname=tag_name}) in
                let ti = match (deref_ktyp ti kvar_loc) with
                    | KTypRecord(r_id, relems) ->
                        if r_id = noid then
                            (match relems with
                            | (n, t) :: [] -> t
                            | _ -> KTypTuple(List.map (fun (_, tj) -> tj) relems))
                        else
                            (KTypName r_id)
                    | _ -> ti
                    in
                (ni, mangle_ktyp_retain_record ti kvar_loc callb)) kvar_cases in
            kvar := { !kvar with kvar_cases=var_cases };
            e
        | KDefTyp ({contents={kt_typ=KTypRecord(_, _)}} as kt) ->
            let {kt_name; kt_typ; kt_loc} = !kt in
            (* compute and set kt_cname *)
            let _ = mangle_ktyp (KTypName kt_name) mangle_map kt_loc in
            let ktyp = match (mangle_ktyp_retain_record kt_typ kt_loc callb) with
                | KTypRecord(_, _) as ktyp -> ktyp
                | _ -> raise_compile_err kt_loc "after mangling record is not a record anymore"
                in
            kt := { !kt with kt_typ=ktyp };
            e
        | KDefTyp _ ->
            (* since KDefGenTyp's are formed during this step, we should not get here.
               If we are here, retain the definition as-is *)
            e
        | KDefClosureVars kcv ->
            e
        | KExpFor (idoml, at_ids, body, flags, loc) ->
            mangle_idoml idoml at_ids loc callb;
            walk_kexp e callb
        | KExpMap (e_idoml_l, body, flags, (_, loc)) ->
            List.iter (fun (_, idoml, idx) -> mangle_idoml idoml idx loc callb) e_idoml_l;
            walk_kexp e callb
        | _ -> walk_kexp e callb
        in
    let walk_n_mangle_callb =
    {
        kcb_ktyp=Some(walk_ktyp_n_mangle);
        kcb_kexp=Some(walk_kexp_n_mangle);
        kcb_atom=None
    } in

    List.map (fun km ->
        let {km_name; km_top} = km in
        curr_top_code := [];
        List.iter (fun e ->
            let e = walk_kexp_n_mangle e walk_n_mangle_callb in
            (match e with
            | KDefVal (n, e, loc) ->
                let kv = get_kval n loc in
                let {kv_cname; kv_flags} = kv in
                if kv_cname <> "" then () else
                    (set_idk_entry n (KVal {kv with
                        kv_flags={kv_flags with val_flag_global=(ScModule km_name) :: []}});
                    mangle_id_typ n loc walk_n_mangle_callb)
            | _ -> ());
            curr_top_code := e :: !curr_top_code) km_top;
        {km with km_top=List.rev !curr_top_code}) kmods
