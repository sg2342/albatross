(* (c) 2018 Hannes Mehnert, all rights reserved *)

open Rresult
open Rresult.R.Infix

(* we skip all non-albatross certificates *)
let cert_name cert =
  match X509.Extension.unsupported cert Vmm_asn.oid with
  | None -> Ok None
  | Some (_, data) ->
    let name = X509.common_name_to_string cert in
    if name = "" then
      match Vmm_asn.cert_extension_of_cstruct data with
      | Error (`Msg _) -> Error (`Msg "couldn't parse albatross extension")
      | Ok (_, `Policy_cmd (`Policy_add _)) -> Error (`Msg "policy add may not have an empty name")
      | _ -> Ok None
    else Ok (Some name)

let name chain =
  List.fold_left (fun acc cert ->
      match acc, cert_name cert with
      | Error e, _ -> Error e
      | _, Error e -> Error e
      | Ok acc, Ok None -> Ok acc
      | Ok acc, Ok Some data -> Ok (data :: acc))
    (Ok []) chain

(* this separates the leaf and top-level certificate from the chain,
   and also reverses the intermediates (to be (leaf, CA -> subCA -> subCA')
   in which subCA' signed leaf *)
let separate_chain = function
  | [] -> Error (`Msg "empty chain")
  | [ leaf ] -> Ok (leaf, [])
  | leaf :: xs -> Ok (leaf, List.rev xs)

let wire_command_of_cert version cert =
  match X509.Extension.unsupported cert Vmm_asn.oid with
  | None -> Error `Not_present
  | Some (_, data) ->
    match Vmm_asn.cert_extension_of_cstruct data with
    | Error (`Msg p) -> Error (`Parse p)
    | Ok (v, wire) ->
      if not (Vmm_commands.version_eq v version) then
        Error (`Version v)
      else
        Ok wire

let extract_policies version chain =
  List.fold_left (fun acc cert ->
      match acc, wire_command_of_cert version cert with
      | Error e, _ -> Error e
      | Ok acc, Error `Not_present -> Ok acc
      | Ok _, Error (`Parse msg) -> Error (`Msg msg)
      | Ok _, Error (`Version received) ->
        R.error_msgf "unexpected version %a (expected %a)"
          Vmm_commands.pp_version received
          Vmm_commands.pp_version version
      | Ok (prefix, acc), Ok (`Policy_cmd (`Policy_add p)) ->
        (cert_name cert >>| function
          | None -> prefix
          | Some x -> x :: prefix) >>| fun name ->
        (name, (name, p) :: acc)
      | _, Ok wire ->
        R.error_msgf "unexpected wire %a" Vmm_commands.pp wire)
    (Ok ([], [])) chain

let handle _addr version chain =
  separate_chain chain >>= fun (leaf, rest) ->
  name chain >>= fun name ->
  Logs.debug (fun m -> m "leaf is %s, chain %a"
                 (X509.common_name_to_string leaf)
                 Fmt.(list ~sep:(unit " -> ") string)
                 (List.map X509.common_name_to_string rest)) ;
  extract_policies version rest >>= fun (_, policies) ->
  (* TODO: logging let login_hdr, login_ev = Log.hdr name, `Login addr in *)
  match wire_command_of_cert version leaf with
  | Error (`Parse p) -> Error (`Msg p)
  | Error (`Not_present) ->
    Error (`Msg "leaf certificate does not contain an albatross extension")
  | Error (`Version received) ->
    R.error_msgf "unexpected version %a (expected %a)"
      Vmm_commands.pp_version received
      Vmm_commands.pp_version version
  | Ok wire ->
    (* we only allow some commands via certificate *)
    match wire with
    | `Console_cmd (`Console_subscribe _)
    | `Stats_cmd `Stats_subscribe
    | `Log_cmd (`Log_subscribe _)
    | `Vm_cmd _
    | `Policy_cmd `Policy_info -> Ok (name, policies, wire)
    | _ -> Error (`Msg "unexpected command")
