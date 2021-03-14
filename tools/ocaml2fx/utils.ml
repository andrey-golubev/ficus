(*
    This file is a part of ficus language project.
    See ficus/LICENSE for the licensing terms
*)

(*
   Some utility functions used by the compiler.
   [TODO] when the compiler is rewritten in Ficus,
   those functions should be put to Ficus Std Lib
*)
let num_suffix n =
    let d = n mod 10 in
    match d with
    | 1 -> "st"
    | 2 -> "nd"
    | 3 -> "rd"
    | _ -> "th"

let opt_get x_opt default_val = match x_opt with Some x -> x | _ -> default_val
let is_some x_opt = match x_opt with Some _ -> true | _ -> false
let is_none x_opt = match x_opt with Some _ -> false | _ -> true

let zip l1 l2 = List.map2 (fun i1 i2 -> (i1, i2)) l1 l2
let unzip l12 = List.fold_left (fun (l1, l2) (i, j) -> ((i :: l1), (j :: l2))) ([], []) (List.rev l12)

let rec last_elem l = match l with
    | x :: [] -> x
    | x :: rest -> last_elem rest
    | [] -> failwith "empty list"

let starts_with s subs =
    let l0 = String.length s in
    let l1 = String.length subs in
    l0 >= l1 && (String.sub s 0 l1) = subs

let ends_with s subs =
    let l0 = String.length s in
    let l1 = String.length subs in
    l0 >= l1 && (String.sub s (l0-l1) l1) = subs

let trim_left s n =
    let n0 = String.length s in
    if n >= n0 then "" else String.sub s n (n0-n)

let trim_right s n =
    let n0 = String.length s in
    if n >= n0 then "" else String.sub s 0 (n0-n)

let escaped_uni s =
    let result = ref ([]: string list) in
    String.iter (fun c ->
        match c with
        | '\n' -> result := "\\n" :: !result
        | '\r' -> result := "\\r" :: !result
        | '\t' -> result := "\\t" :: !result
        | '\'' -> result := "\\\'" :: !result
        | '\"' -> result := "\\\"" :: !result
        | '\\' -> result := "\\\\" :: !result
        | '\000' -> result := "\\0" :: !result
        | _ -> result := (String.make 1 c) :: !result) s;
    String.concat "" (List.rev !result)

let rec normalize_path dir fname =
    let sep = Filename.dir_sep in
    let seplen = String.length sep in
    if not (Filename.is_relative fname) then fname else
    if (starts_with fname ("." ^ sep)) then (normalize_path dir (trim_left fname (1+seplen))) else
    if (starts_with fname (".." ^ sep)) then
    (let parent_dir = Filename.dirname dir in
    let fname1 = trim_left fname (2+seplen) in
    normalize_path parent_dir fname1) else
    (Filename.concat dir fname)

let remove_extension fname =
    try Filename.chop_extension fname with Invalid_argument _ -> fname

let ipower a b =
    let rec ipower_ a b p =
        if b = 0L then p else
            let p = if (Int64.logand b 1L) != 0L then (Int64.mul p a) else p in
            ipower_ (Int64.mul a a) (Int64.div b 2L) p in
    ipower_ a b 1L

let dot_regexp = Str.regexp "\\."
let rec locate_module_file mname inc_dirs =
    let mfname = (Str.global_replace dot_regexp Filename.dir_sep mname) ^ ".fx" in
    try
        let mfname_full = Filename.concat
            (List.find (fun d -> Sys.file_exists (Filename.concat d mfname)) inc_dirs)
            mfname in
        Some(normalize_path (Sys.getcwd()) mfname_full)
    with Not_found -> None

let file2str filename =
    try
        let f = open_in filename in
        let all_lines = ref ([]: string list) in
        (try
            (while true do
                all_lines := ((input_line f) ^ "\n") :: !all_lines
            done;
            "")
        with End_of_file ->
            close_in f;
            String.concat "" (List.rev !all_lines))
    with Sys_error _ -> ""

let str2file str filename =
    try
        let f = open_out filename in
        Printf.fprintf f "%s" str;
        close_out f;
        true
    with Sys_error _ -> false
