open Ast
open C_form

let gen_std_fun cname argtyps rt =
    let n = gen_temp_idc cname in
    let cf = ref
    {
        cf_name=n; cf_typ=CTypFun(argtyps, rt); cf_cname=cname;
        cf_args=List.map (fun a -> noid) argtyps;
        cf_body=CStmtCCode("", noloc);
        cf_flags=FunInC :: FunStd :: FunImpure :: [];
        cf_scope=ScGlobal :: []; cf_loc=noloc
    } in
    set_idc_entry n (CFun cf);
    n

let gen_std_macro cname nargs =
    let n = gen_temp_idc cname in
    let cm = ref
    {
        cm_name=n; cm_cname=cname; cm_args=List.init nargs (fun _ -> noid);
        cm_body=[]; cm_scope=ScGlobal :: []; cm_loc=noloc
    } in
    set_idc_entry n (CMacro cm);
    n

let init_std_names () =
    curr_exn_val := -1024;

    std_fx_rc_t := CTypCName (get_id "fx_rc_t");
    std_fx_free_t := CTypCName (get_id "fx_free_t");
    std_fx_copy_t := CTypCName (get_id "fx_copy_t");

    std_fx_alloc := gen_std_fun "fx_alloc" (CTypSize_t :: []) std_CTypVoidPtr;
    std_fx_free := gen_std_fun "fx_free" (std_CTypVoidPtr :: []) CTypVoid;

    std_FX_CALL := gen_std_macro "FX_CALL" 2;
    std_FX_COPY_PTR := gen_std_macro "FX_COPY_PTR" 2;
    std_FX_COPY_SIMPLE := gen_std_macro "FX_COPY_SIMPLE" 2;
    std_FX_NO_FREE := gen_std_macro "FX_NO_FREE" 1;

    std_fx_free_ptr := gen_std_fun "fx_free_ptr" (std_CTypVoidPtr :: []) CTypVoid;
    std_fx_copy_ptr := gen_std_fun "fx_copy_ptr" (std_CTypConstVoidPtr :: std_CTypVoidPtr :: []) CTypVoid;

    std_fx_free_str := gen_std_fun "fx_free_str" ((make_ptr CTypString) :: []) CTypVoid;
    std_fx_copy_str := gen_std_fun "fx_copy_str" ((make_const_ptr CTypString) :: (make_ptr CTypString) :: []) CTypVoid;

    std_FX_THROW_LIGHT := gen_std_macro "FX_THROW_LIGHT" 2;
    std_FX_FREE_EXN := gen_std_macro "FX_FREE_EXN" 1;
    std_FX_COPY_EXN := gen_std_macro "FX_COPY_EXN" 2;
    std_FX_EXN_MAKE_IMPL := gen_std_macro "FX_EXN_MAKE_IMPL" 4;

    std_fx_free_exn := gen_std_fun "fx_free_exn" ((make_ptr CTypExn) :: []) CTypVoid;
    std_fx_copy_exn := gen_std_fun "fx_copy_exn" ((make_const_ptr CTypExn) :: (make_ptr CTypExn) :: []) CTypVoid;

    std_FX_LIST_FREE_IMPL := gen_std_macro "FX_LIST_FREE_IMPL" 2;
    std_FX_LIST_MAKE_IMPL := gen_std_macro "FX_LIST_MAKE_IMPL" 2;

    std_FX_CHKIDX_xD := [];
    std_FX_EPTR_xD_ := [];
    std_FX_EPTR_xD := [];
    std_fx_make_arrxd := [];

    let make_arr_args0 = CTypSize_t :: !std_fx_free_t :: !std_fx_copy_t :: (make_ptr std_CTypAnyArray) :: [] in

    for i = std_FX_MAX_DIMS - 1 downto 1 do
        std_FX_CHKIDX_xD := (gen_std_macro (sprintf "FX_CHKIDX_%dD" i) (2+i)) :: !std_FX_CHKIDX_xD;
        std_FX_EPTR_xD_ := (gen_std_macro (sprintf "FX_EPTR_%dD_" i) (2+i)) :: !std_FX_EPTR_xD_;
        std_FX_EPTR_xD := (gen_std_macro (sprintf "FX_EPTR_%dD" i) (4+i)) :: !std_FX_EPTR_xD;

        let make_arr_args = (List.init i (fun j -> CTypInt)) @ make_arr_args0 in
        std_fx_make_arrxd := (gen_std_fun (sprintf "fx_make_arr%dd" i) make_arr_args CTypCInt) :: !std_fx_make_arrxd
    done;

    std_fx_free_arr := gen_std_fun "fx_free_arr" ((make_ptr std_CTypAnyArray) :: []) CTypVoid;
    std_fx_copy_arr := gen_std_fun "fx_copy_arr"
        ((make_const_ptr std_CTypAnyArray) :: (make_ptr std_CTypAnyArray) :: []) CTypVoid;;

    std_FX_REF_FREE_IMPL := gen_std_macro "FX_REF_FREE_IMPL" 2;
    std_FX_REF_MAKE_IMPL := gen_std_macro "FX_REF_MAKE_IMPL" 2;

    std_FX_FREE_FP := gen_std_macro "FX_FREE_FP" 1;
    std_FX_COPY_FP := gen_std_macro "FX_COPY_FP" 2;
    std_fx_free_fp := gen_std_fun "fx_free_fp" (std_CTypVoidPtr :: []) CTypVoid;
    std_fx_copy_fp := gen_std_fun "fx_copy_fp" (std_CTypConstVoidPtr :: std_CTypVoidPtr :: []) CTypVoid;

    std_fx_free_cptr := gen_std_fun "fx_free_cptr" ((make_ptr CTypCSmartPointer) :: []) CTypVoid;
    std_fx_copy_cptr := gen_std_fun "fx_copy_cptr"
        ((make_const_ptr CTypCSmartPointer) :: (make_ptr CTypCSmartPointer) :: []) CTypVoid;
