(*
  Validators of OCaml data whose types are defined using ATD.
*)

open Printf

open Atd_ast
open Ag_error
open Ag_mapping
open Ag_ov_mapping

let name_of_var s = "_" ^ s

let make_ocaml_validate_intf buf defs =
  List.iter (
    fun x ->
      let s = x.def_name in
      if s <> "" && s.[0] <> '_' && x.def_value <> None then (
        let full_name = Ag_ocaml.get_full_type_name x in
        let validator_params =
          String.concat "" (
            List.map
              (fun s -> sprintf "\n  ('%s -> bool) ->" s)
              x.def_param
          )
        in
	bprintf buf "\
val validate_%s :%s
  %s -> bool
  (** Validate a value of type {!%s}. *)

"
          s validator_params
          full_name
          s;
      )
  ) (flatten defs)

let nth name i len =
  let l =
    Array.to_list (Array.init len (fun j -> if i = j then name else "_")) in
  String.concat ", " l

let get_fields a =
  let all = 
    List.map (
      fun x ->
	match x.f_arepr with
	    `Field o -> (x, o.Ag_ocaml.ocaml_fname)
	  | _ -> assert false
    )
      (Array.to_list a)
  in
  List.filter (
    function
        { f_brepr = (None, shallow) }, _ -> not shallow
      | _ -> assert false
  ) all

let insert sep l =
  let rec ins sep = function
      [] -> []
    | x :: l -> sep :: x :: ins sep l
  in
  match l with
      [] -> []
    | x :: l -> x :: ins sep l


let unopt = function None -> assert false | Some x -> x

let return_true = "fun _ -> true"
let return_true_paren = "(fun _ -> true)"

let opt_validator_name = function
    None -> return_true_paren
  | Some s -> sprintf "( %s )" s

let opt_validator = function
    None -> [ `Line "fun _ -> true" ]
  | Some s -> [ `Line s ]


let prepend_validator = function
    None -> []
  | Some s -> [ `Line (sprintf "( %s ) x &&" s) ]

let prepend_validator_s v s2 =
  match v with
    None -> s2
  | Some s1 -> 
      sprintf "(fun x -> ( %s ) x && (%s) x)" s1 s2

let prepend_validator_f v l =
  match v with
    None -> l
  | Some s -> 
      [ 
        `Line "(fun x ->";
        `Block [
          `Line (sprintf "( %s ) x && (" s);
          `Block l;
          `Line ") x)";
        ]
      ]

(*
  ('a, 'b) t ->
    validate_t validate__a validate__b
  ('a, foo) t ->
    validate_t validate__a validate_foo
  ('a, (foo, 'b) bar) t ->
    validate_t validate__a (validate_bar validate_foo validate__b)
*)
let rec get_validator_name
    ?(paren = false)
    ?(name_f = fun s -> "validate_" ^ s)
    (x : ov_mapping) : string =

  match x with
      `Unit (loc, `Unit, v)
    | `Bool (loc, `Bool, v)
    | `Int (loc, `Int _, v)
    | `Float (loc, `Float, v)
    | `String (loc, `String, v) ->
        (match v with
             (None, true) -> return_true_paren
           | (Some s, true) -> s
           | (_, false) -> assert false
        )
    | `Tvar (loc, s) -> "validate_" ^ name_of_var s
        
    | `Name (loc, s, args, None, opt) ->
        let v1 =
          let l =
            List.map (get_validator_name ~paren:true) args in
          let s = String.concat " " (name_f s :: l) in
          if paren && l <> [] then "(" ^ s ^ ")"
          else s
        in
        (match opt with
             None -> v1
           | Some (o, false) -> prepend_validator_s o v1
           | Some (o, true) -> assert false
        )

    | `External (loc, s, args, `External (module_path, ext_name), v) ->
        (match v with
             (o, false) ->
               prepend_validator_s o (
                 let f = module_path ^ "." ^ name_f ext_name in
                 let l = List.map (get_validator_name ~paren:true) args in
                 let s = String.concat " " (f :: l) in
                 if paren && l <> [] then "(" ^ s ^ ")"
                 else s
               )
           | (_, true) -> assert false
        )
          
    | _ -> assert false


let get_left_validator_name name param =
  let args = List.map (fun s -> `Tvar (dummy_loc, s)) param in
  get_validator_name (`Name (dummy_loc, name, args, None, None))

let rec make_validator (x : ov_mapping) : Ag_indent.t list =
  match x with
      `Unit _
    | `Bool _
    | `Int _
    | `Float _
    | `String _
    | `Name _
    | `External _
    | `Tvar _ -> [ `Line (get_validator_name x) ]

    | `Sum (loc, a, `Sum x, (v, shallow)) ->
        if shallow then
          opt_validator v
        else
	  let tick =
	    match x with
	        `Classic -> ""
	      | `Poly -> "`"
	  in
	  let body : Ag_indent.t list =
	    [
	      `Line "match x with";
	      `Block (
	        Array.to_list (
		  Array.map
		    (fun x -> `Inline (make_variant_validator tick x))
		    a
	        )
	      )
	    ]
	  in
	  [
	    `Annot ("fun", `Line "fun x ->");
	    `Block [
              `Inline (prepend_validator v);
              `Inline body;
            ]
	  ]

    | `Record (loc, a, `Record o, (v, shallow)) ->
        if shallow then
          opt_validator v
        else
	  [
	    `Annot ("fun", `Line "fun x ->");
	    `Block [
              `Inline (prepend_validator v);
              `Inline (make_record_validator a o);
            ]
	  ]

    | `Tuple (loc, a, `Tuple, (v, shallow)) ->
        if shallow then
          opt_validator v
        else
	  let len = Array.length a in
	  let l = Array.to_list (Array.mapi (fun i x -> (i, x)) a) in
          let l = List.filter (fun (i, x) -> not (snd x.cel_brepr)) l in
	  let l =
            List.map (
	      fun (i, x) ->
	        `Inline [
		  `Line (sprintf "(let %s = x in" (nth "x" i len));
		  `Line "(";
		  `Block (make_validator x.cel_value);
		  `Line ") x";
		  `Line ")"
	        ]
	    ) l
	  in
	  let l = 
	    insert (`Line "&&") l
	  in
          [ 
	    `Annot ("fun", `Line "fun x ->");
	    `Block [
              `Inline (prepend_validator v);
              `Inline l
            ]
	  ]

    | `List (loc, x, `List o, (v, shallow)) ->
        if shallow then
          opt_validator v
        else
          let validate =
	    match o with
                `List -> "List.for_all ("
              | `Array -> "Ag_ov_run.validate_array ("
          in
	  prepend_validator_f v [
            `Line validate;
	    `Block (make_validator x);
	    `Line ")";
	  ]

    | `Option (loc, x, `Option, (v, shallow)) ->
        if shallow then
          opt_validator v
        else
	  prepend_validator_f v [
	    `Line "Ag_ov_run.validate_option (";
	    `Block (make_validator x);
	    `Line ")";
	  ]

    | `Shared (loc, _, _, _, _) ->
        error loc "Sharing is not supported by the validator generator"

    | _ -> assert false



and make_variant_validator tick x : 
    Ag_indent.t list =
  let o =
    match x.var_arepr, x.var_brepr with
	`Variant o, (None, _) -> o
      | _ -> assert false
  in
  let ocaml_cons = o.Ag_ocaml.ocaml_cons in
  match x.var_arg with
      None ->
        [
	  `Line (sprintf "| %s%s -> true" tick ocaml_cons)
	]
    | Some v ->
        [
	  `Line (sprintf "| %s%s x ->" tick ocaml_cons);
	  `Block [
	    `Line "(";
	    `Block (make_validator v);
	    `Line ") x"
	  ]
	]

and make_record_validator a record_kind =
  let dot =
    match record_kind with
	`Record -> "."
      | `Object -> "#"
  in
  let fields = get_fields a in
  assert (fields <> []);
  let sep = `Line "&&" in
  let validate_fields : Ag_indent.t list =
    List.map (
      fun (x, ocaml_fname) ->
	`Inline [
          `Line "(";
	  `Block (make_validator x.Ag_mapping.f_value);
	  `Line (sprintf ") x%s%s" dot ocaml_fname);
	]
    ) fields
  in
  insert sep validate_fields

let rec is_function (l : Ag_indent.t list) =
  match l with
      [] -> false
    | x :: _ ->
        match x with
            `Line _ -> false
          | `Block l -> is_function l
          | `Inline l -> is_function l
          | `Annot ("fun", _) -> true
          | `Annot (_, x) -> is_function [x]

let make_ocaml_validator is_rec let1 let2 def =
  let x = match def.def_value with None -> assert false | Some x -> x in
  let name = def.def_name in
  let param = def.def_param in
  let validate = get_left_validator_name name param in
  let validator_expr = make_validator x in
  let extra_param, extra_args =
    if is_function validator_expr || not is_rec then "", ""
    else " x", " x"
  in
  [
    `Line (sprintf "%s %s%s = (" let1 validate extra_param);
    `Block (List.map Ag_indent.strip validator_expr);
    `Line (sprintf ")%s" extra_args);
  ]



let map f = function
    [] -> []
  | x :: l ->
      let y = f true x in
      y :: List.map (f false) l

let get_let ~is_rec ~is_first =
  if is_first then
    if is_rec then "let rec", "and"
    else "let", "let"
  else "and", "and"

let make_ocaml_validate_impl buf defs =
  let ll =
    List.map (
      fun (is_rec, l) ->
	let l = List.filter (fun x -> x.def_value <> None) l in
	let validators =
	  map (
	    fun is_first def ->
	      let let1, let2 = get_let ~is_rec ~is_first in
	      make_ocaml_validator is_rec let1 let2 def
	  ) l
	in
	List.flatten validators
  ) defs
  in
  Atd_indent.to_buffer buf (List.flatten ll)


(*
  Glue
*)

let translate_mapping (l : (bool * Atd_ast.module_body) list) =
  Ag_ov_mapping.defs_of_atd_modules l

let write_opens buf l =
  List.iter (fun s -> bprintf buf "open %s\n" s) l;
  bprintf buf "\n"

let make_mli
    ~header ~opens ~with_typedefs ~with_fundefs
    ocaml_typedefs defs =
  let buf = Buffer.create 1000 in
  bprintf buf "%s\n" header;
  write_opens buf opens;
  if with_typedefs then
    bprintf buf "%s\n" ocaml_typedefs;
  if with_typedefs && with_fundefs then
    bprintf buf "\n";
  if with_fundefs then
    make_ocaml_validate_intf buf defs;
  Buffer.contents buf

let make_ml
    ~header ~opens ~with_typedefs ~with_fundefs
    ocaml_typedefs defs =
  let buf = Buffer.create 1000 in
  bprintf buf "%s\n" header;
  write_opens buf opens;
  if with_typedefs then
    bprintf buf "%s\n" ocaml_typedefs;
  if with_typedefs && with_fundefs then
    bprintf buf "\n";
  if with_fundefs then
    make_ocaml_validate_impl buf defs;
  Buffer.contents buf

let make_ocaml_files
    ~opens
    ~with_typedefs 
    ~with_fundefs
    ~all_rec
    ~pos_fname
    ~pos_lnum
    ~type_aliases
    atd_file out =
  let head, m0 =
    match atd_file with
        Some file ->
          Atd_util.load_file
            ~expand:false ~inherit_fields:true ~inherit_variants:true
            ?pos_fname ?pos_lnum
            file
      | None ->
          Atd_util.read_channel
            ~expand:false ~inherit_fields:true ~inherit_variants:true
            ?pos_fname ?pos_lnum
            stdin
  in
  let m1 =
    if all_rec then
      [ (true, m0) ]
    else
      Atd_util.tsort m0
  in
  let defs1 = translate_mapping m1 in
  Ag_ox_emit.check defs1;
  let m2 = Atd_util.tsort (Atd_expand.expand_module_body ~keep_poly:true m0) in
  (* m0 = original type definitions
     m1 = original type definitions after dependency analysis
     m2 = monomorphic type definitions after dependency analysis *)
  let ocaml_typedefs =
    Ag_ocaml.ocaml_of_atd ~target:`Default ~type_aliases (head, m1) in
  let defs = translate_mapping m2 in
  let header = 
    let src =
      match atd_file with
          None -> "stdin"
        | Some path -> sprintf "%S" (Filename.basename path)
    in
    sprintf "(* Auto-generated from %s *)\n" src
  in
  let mli = 
    make_mli ~header ~opens ~with_typedefs ~with_fundefs
      ocaml_typedefs defs1
  in
  let ml =
    make_ml ~header ~opens ~with_typedefs ~with_fundefs
      ocaml_typedefs defs
  in
  Ag_ox_emit.write_ocaml out mli ml