(****************************************************************************)
(*     Sail                                                                 *)
(*                                                                          *)
(*  Sail and the Sail architecture models here, comprising all files and    *)
(*  directories except the ASL-derived Sail code in the aarch64 directory,  *)
(*  are subject to the BSD two-clause licence below.                        *)
(*                                                                          *)
(*  The ASL derived parts of the ARMv8.3 specification in                   *)
(*  aarch64/no_vector and aarch64/full are copyright ARM Ltd.               *)
(*                                                                          *)
(*  Copyright (c) 2013-2021                                                 *)
(*    Kathyrn Gray                                                          *)
(*    Shaked Flur                                                           *)
(*    Stephen Kell                                                          *)
(*    Gabriel Kerneis                                                       *)
(*    Robert Norton-Wright                                                  *)
(*    Christopher Pulte                                                     *)
(*    Peter Sewell                                                          *)
(*    Alasdair Armstrong                                                    *)
(*    Brian Campbell                                                        *)
(*    Thomas Bauereiss                                                      *)
(*    Anthony Fox                                                           *)
(*    Jon French                                                            *)
(*    Dominic Mulligan                                                      *)
(*    Stephen Kell                                                          *)
(*    Mark Wassell                                                          *)
(*    Alastair Reid (Arm Ltd)                                               *)
(*                                                                          *)
(*  All rights reserved.                                                    *)
(*                                                                          *)
(*  This work was partially supported by EPSRC grant EP/K008528/1 <a        *)
(*  href="http://www.cl.cam.ac.uk/users/pes20/rems">REMS: Rigorous          *)
(*  Engineering for Mainstream Systems</a>, an ARM iCASE award, EPSRC IAA   *)
(*  KTF funding, and donations from Arm.  This project has received         *)
(*  funding from the European Research Council (ERC) under the European     *)
(*  Union’s Horizon 2020 research and innovation programme (grant           *)
(*  agreement No 789108, ELVER).                                            *)
(*                                                                          *)
(*  This software was developed by SRI International and the University of  *)
(*  Cambridge Computer Laboratory (Department of Computer Science and       *)
(*  Technology) under DARPA/AFRL contracts FA8650-18-C-7809 ("CIFV")        *)
(*  and FA8750-10-C-0237 ("CTSRD").                                         *)
(*                                                                          *)
(*  Redistribution and use in source and binary forms, with or without      *)
(*  modification, are permitted provided that the following conditions      *)
(*  are met:                                                                *)
(*  1. Redistributions of source code must retain the above copyright       *)
(*     notice, this list of conditions and the following disclaimer.        *)
(*  2. Redistributions in binary form must reproduce the above copyright    *)
(*     notice, this list of conditions and the following disclaimer in      *)
(*     the documentation and/or other materials provided with the           *)
(*     distribution.                                                        *)
(*                                                                          *)
(*  THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS''      *)
(*  AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED       *)
(*  TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A         *)
(*  PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR     *)
(*  CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,            *)
(*  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT        *)
(*  LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF        *)
(*  USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND     *)
(*  ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,      *)
(*  OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT      *)
(*  OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF      *)
(*  SUCH DAMAGE.                                                            *)
(****************************************************************************)

open Ast
open Ast_defs
open Ast_util
open Parse_ast.Attribute_data
open Parser_combinators

let find_properties { defs; _ } =
  let rec find_prop acc = function
    | DEF_aux (DEF_pragma ((("property" | "counterexample") as prop_type), command, l), _) :: defs -> begin
        match Util.find_next (function DEF_aux (DEF_val _, _) -> true | _ -> false) defs with
        | _, Some (DEF_aux (DEF_val vs, _), defs) -> find_prop ((prop_type, command, l, vs) :: acc) defs
        | _, _ -> raise (Reporting.err_general l "Property is not attached to any function signature")
      end
    | DEF_aux (DEF_val vs, def_annot) :: defs -> begin
        let attrs = get_attributes (uannot_of_def_annot def_annot) in
        match List.find_opt (fun (_, name, _) -> name = "property" || name = "counterexample") attrs with
        | Some (l, prop_type, Some (AD_aux (AD_string command, _))) ->
            find_prop ((prop_type, command, l, vs) :: acc) defs
        | Some (_, _, Some (AD_aux (_, l))) ->
            raise (Reporting.err_general l "Expected string argument for property or counterexample")
        | Some (l, prop_type, None) -> find_prop ((prop_type, "", l, vs) :: acc) defs
        | None -> find_prop acc defs
      end
    | def :: defs -> find_prop acc defs
    | [] -> acc
  in
  find_prop [] defs
  |> List.map (fun ((_, _, _, vs) as prop) -> (id_of_val_spec vs, prop))
  |> List.fold_left (fun m (id, prop) -> Bindings.add id prop m) Bindings.empty

let well_formedness_check (Typ_aux (aux, _)) =
  match aux with
  | Typ_app (Id_aux (Id "atom", _), [A_aux (A_nexp nexp, _)]) ->
      Some (fun exp -> mk_exp (E_app (mk_id "eq_int", [exp; mk_exp (E_sizeof nexp)])))
  | Typ_app (Id_aux (Id "atom_bool", _), [A_aux (A_bool nc, _)]) ->
      Some (fun exp -> mk_exp (E_app (mk_id "eq_bool", [exp; mk_exp (E_constraint nc)])))
  | Typ_app (Id_aux (Id "bitvector", _), [A_aux (A_nexp nexp, _)]) ->
      Some
        (fun exp ->
          mk_exp (E_app (mk_id "eq_int", [mk_exp (E_app (mk_id "bitvector_length", [exp])); mk_exp (E_sizeof nexp)]))
        )
  | _ -> None

let destruct_tuple_pat = function P_aux (P_tuple pats, annot) -> (pats, Some annot) | pat -> ([pat], None)

let reconstruct_tuple_pat pats = function
  | Some (l, tannot) -> P_aux (P_tuple pats, (l, Type_check.untyped_annot tannot))
  | None -> List.hd pats

let well_formed_function_arguments pragma_l pat =
  let wf_var n = mk_id ("wf_arg" ^ string_of_int n ^ "#") in
  function
  | Typ_aux (Typ_fn (arg_typs, _), _) ->
      let pats, pats_annot = destruct_tuple_pat pat in
      if List.compare_lengths pats arg_typs = 0 then (
        let pats, checks =
          List.combine pats arg_typs
          |> List.mapi (fun n (pat, arg_typ) ->
                 let id = wf_var n in
                 match well_formedness_check arg_typ with
                 | Some check ->
                     let pat = mk_pat (P_as (Type_check.strip_pat pat, id)) in
                     (pat, Some (check (mk_exp (E_id id))))
                 | None -> (Type_check.strip_pat pat, None)
             )
          |> List.split
        in
        (reconstruct_tuple_pat pats pats_annot, Util.option_these checks)
      )
      else
        Reporting.unreachable pragma_l __POS__
          "Function pattern and type do not match when generating well-formedness check for property"
  | _ -> Reporting.unreachable pragma_l __POS__ "Found function with non-function type"

let add_property_guards props ast =
  let open Type_check in
  let open Type_error in
  let rec add_property_guards' acc = function
    | (DEF_aux (DEF_fundef (FD_aux (FD_function (r_opt, t_opt, funcls), fd_aux) as fdef), def_annot) as def) :: defs ->
      begin
        match Bindings.find_opt (id_of_fundef fdef) props with
        | Some (_, _, pragma_l, VS_aux (VS_val_spec (TypSchm_aux (TypSchm_ts (quant, fn_typ), _), _, _), _)) -> begin
            match quant_split quant with
            | _, constraints ->
                let add_checks_to_funcl (FCL_aux (FCL_funcl (id, pexp), (def_annot, fcl_tannot))) =
                  let pat, guard, exp, (pexp_l, pexp_tannot) = destruct_pexp pexp in
                  let pat, checks = well_formed_function_arguments pragma_l pat fn_typ in
                  let exp =
                    mk_exp
                      (E_block
                         (List.map
                            (fun check -> mk_exp (E_app (mk_id "sail_assume", [check])))
                            (mk_exp (E_constraint (List.fold_left nc_and nc_true constraints)) :: checks)
                         @ [strip_exp exp]
                         )
                      )
                  in
                  let pexp =
                    construct_pexp (pat, Option.map strip_exp guard, exp, (pexp_l, Type_check.untyped_annot pexp_tannot))
                  in
                  try
                    Type_check.check_funcl (env_of_tannot fcl_tannot)
                      (FCL_aux (FCL_funcl (id, pexp), (def_annot, Type_check.untyped_annot fcl_tannot)))
                      (typ_of_tannot fcl_tannot)
                  with Type_error (l, err) ->
                    let msg =
                      "\n\
                       Type error when generating guard for a property.\n\
                       When generating guards we convert type quantifiers from the function signature\n\
                       into runtime checks so it must be possible to reconstruct the quantifier from\n\
                       the function arguments. For example:\n\n\
                       function f : forall 'n, 'n <= 100. (x: int('n)) -> bool\n\n\
                       would cause the runtime check x <= 100 to be added to the function body.\n\
                       To fix this error, ensure that all quantifiers have corresponding function arguments.\n"
                    in
                    let original_msg, hint = Type_error.string_of_type_error err in
                    raise (Reporting.err_typ ?hint pragma_l (original_msg ^ msg))
                in

                let funcls = List.map add_checks_to_funcl funcls in
                let fdef = FD_aux (FD_function (r_opt, t_opt, funcls), fd_aux) in

                add_property_guards' (DEF_aux (DEF_fundef fdef, def_annot) :: acc) defs
          end
        | None -> add_property_guards' (def :: acc) defs
      end
    | def :: defs -> add_property_guards' (def :: acc) defs
    | [] -> List.rev acc
  in
  { ast with defs = add_property_guards' [] ast.defs }

let rewrite defs = add_property_guards (find_properties defs) defs

type event = Overflow | Assertion | Assumption | Match | Return

type query =
  | Q_all of event (* All events of type are true *)
  | Q_exist of event (* Some event of type is true *)
  | Q_not of query
  | Q_and of query list
  | Q_or of query list

let default_query =
  Q_or
    [Q_and [Q_not (Q_exist Assertion); Q_all Return; Q_not (Q_exist Match)]; Q_exist Overflow; Q_not (Q_all Assumption)]

module Event = struct
  type t = event
  let compare e1 e2 =
    match (e1, e2) with
    | Overflow, Overflow -> 0
    | Assertion, Assertion -> 0
    | Assumption, Assumption -> 0
    | Match, Match -> 0
    | Return, Return -> 0
    | Overflow, _ -> 1
    | _, Overflow -> -1
    | Assertion, _ -> 1
    | _, Assertion -> -1
    | Assumption, _ -> 1
    | _, Assumption -> -1
    | Match, _ -> 1
    | _, Match -> -1
end

let string_of_event = function
  | Overflow -> "overflow"
  | Assertion -> "assertion"
  | Assumption -> "assumption"
  | Match -> "match_failure"
  | Return -> "return"

let rec _string_of_query = function
  | Q_all ev -> "A " ^ string_of_event ev
  | Q_exist ev -> "E " ^ string_of_event ev
  | Q_not q -> "~(" ^ _string_of_query q ^ ")"
  | Q_and qs -> "(" ^ Util.string_of_list " & " _string_of_query qs ^ ")"
  | Q_or qs -> "(" ^ Util.string_of_list " | " _string_of_query qs ^ ")"

let parse_query =
  let amp = token (function Str.Delim "&" -> Some () | _ -> None) in
  let bar = token (function Str.Delim "|" -> Some () | _ -> None) in
  let lparen = token (function Str.Delim "(" -> Some () | _ -> None) in
  let rparen = token (function Str.Delim ")" -> Some () | _ -> None) in
  let quant =
    token (function
      | Str.Text ("A" | "all") -> Some (fun x -> Q_all x)
      | Str.Text ("E" | "exist") -> Some (fun x -> Q_exist x)
      | _ -> None
      )
  in
  let event =
    token (function
      | Str.Text "overflow" -> Some Overflow
      | Str.Text "assertion" -> Some Assertion
      | Str.Text "assumption" -> Some Assumption
      | Str.Text "match_failure" -> Some Match
      | Str.Text "return" -> Some Return
      | _ -> None
      )
  in
  let tilde = token (function Str.Delim "~" -> Some () | _ -> None) in

  let rec exp0 () =
    pchoose
      ( exp1 () >>= fun x ->
        bar >>= fun _ ->
        exp0 () >>= fun y -> preturn (Q_or [x; y])
      )
      (exp1 ())
  and exp1 () =
    pchoose
      ( exp2 () >>= fun x ->
        amp >>= fun _ ->
        exp1 () >>= fun y -> preturn (Q_and [x; y])
      )
      (exp2 ())
  and exp2 () =
    pchoose
      ( tilde >>= fun _ ->
        exp3 () >>= fun x -> preturn (Q_not x)
      )
      (exp3 ())
  and exp3 () =
    pchoose
      ( lparen >>= fun _ ->
        exp0 () >>= fun x ->
        rparen >>= fun _ -> preturn x
      )
      ( quant >>= fun f ->
        event >>= fun ev -> preturn (f ev)
      )
  in
  parse (exp0 ()) "[ \n\t]+\\|(\\|)\\|&\\||\\|~"

type pragma = { query : query; litmus : string list }

let default_pragma = { query = default_query; litmus = [] }

let parse_pragma l input =
  let key = Str.regexp ":[a-z]+" in
  let tokens = Str.full_split key input in
  let rec process_toks pragma = function
    | Str.Delim ":query" :: Str.Text query :: rest -> begin
        match parse_query query with
        | Some q -> process_toks { pragma with query = q } rest
        | None -> raise (Reporting.err_general l ("Could not parse query " ^ String.trim query))
      end
    | Str.Delim ":litmus" :: rest ->
        let args, rest = Util.take_drop (function Str.Text _ -> true | _ -> false) rest in
        process_toks { pragma with litmus = List.map (function Str.Text t -> t | _ -> assert false) args } rest
    | [] -> pragma
    | _ -> raise (Reporting.err_general l "Could not parse pragma")
  in
  process_toks default_pragma tokens
