(* (c) 2017 Hannes Mehnert, all rights reserved *)

open Rresult
(* bits copied over from Bos *)
(*---------------------------------------------------------------------------
   Copyright (c) 2014 Daniel C. Bünzli

   Permission to use, copy, modify, and/or distribute this software for any
   purpose with or without fee is hereby granted, provided that the above
   copyright notice and this permission notice appear in all copies.

   THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
   WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
   MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
   ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
   WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
   ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
   OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
  ---------------------------------------------------------------------------*)
let pp_unix_error ppf e = Fmt.string ppf (Unix.error_message e)

let err_empty_line = "no command, empty command line"
let err_file f e = R.error_msgf "%a: %a" Fpath.pp f pp_unix_error e

let rec openfile fn mode perm = try Unix.openfile fn mode perm with
  | Unix.Unix_error (Unix.EINTR, _, _) -> openfile fn mode perm

let fd_for_file flag f =
  try Ok (openfile (Fpath.to_string f) flag 0o644)
  with Unix.Unix_error (e, _, _) -> err_file f e

let read_fd_for_file = fd_for_file [Unix.O_RDONLY]

let write_fd_for_file = fd_for_file [Unix.O_WRONLY ; Unix.O_APPEND]

let rec waitpid flags pid =
  try Unix.waitpid flags pid with
  | Unix.Unix_error (Unix.EINTR, _, _) -> waitpid flags pid

let null = match read_fd_for_file (Fpath.v "/dev/null") with
  | Ok fd -> fd
  | Error _ -> invalid_arg "cannot read /dev/null"

let rec create_process prog args stdout stderr =
  try Unix.create_process prog args null stdout stderr with
  | Unix.Unix_error (Unix.EINTR, _, _) ->
      create_process prog args stdout stderr

let rec close fd =
  try Unix.close fd with
  | Unix.Unix_error (Unix.EINTR, _, _) -> close fd

let close_no_err fd = try close fd with e -> ()

(* own code starts here
   (c) 2017 Hannes Mehnert, all rights reserved *)

open Vmm_core

let rec mkfifo name =
  try Unix.mkfifo name 0o640 with
  | Unix.Unix_error (Unix.EINTR, _, _) -> mkfifo name

let tmpfile vm suffix =
  let name = filename vm in
  Fpath.(v (Filename.get_temp_dir_name ()) / name + suffix)

let rec fifo_exists file =
  try Ok (Unix.((stat @@ Fpath.to_string file).st_kind = S_FIFO)) with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Error (`Msg "noent")
  | Unix.Unix_error (Unix.EINTR, _, _) -> fifo_exists file
  | Unix.Unix_error (e, _, _) ->
      R.error_msgf "file %a exists: %s" Fpath.pp file (Unix.error_message e)

let uname () =
  let cmd = Bos.Cmd.(v "uname" % "-s") in
  lazy Bos.OS.Cmd.(run_out cmd |> out_string)

let create_tap bridge =
  Lazy.force (uname ()) >>= fun (sys, _) ->
  match sys with
  | x when x = "FreeBSD" ->
    let cmd = Bos.Cmd.(v "ifconfig" % "tap" % "create") in
    Bos.OS.Cmd.run_out cmd |> Bos.OS.Cmd.out_string >>= fun (name, _) ->
    Bos.OS.Cmd.run Bos.Cmd.(v "ifconfig" % bridge % "addm" % name) >>= fun () ->
    Ok name
  | x when x = "Linux" ->
    let prefix = "vmmtap" in
    let rec find_n x =
      let nam = prefix ^ string_of_int x in
      match Bos.OS.Cmd.run Bos.Cmd.(v "ifconfig" % nam) with
      | Error _ -> nam
      | Ok _ -> find_n (succ x)
    in
    let tap = find_n 0 in
    Bos.OS.Cmd.run Bos.Cmd.(v "ip" % "tuntap" % "add" % "mode" % "tap" % tap) >>= fun () ->
    Bos.OS.Cmd.run Bos.Cmd.(v "brctl" % "addif" % bridge % tap) >>= fun () ->
    Ok tap
  | x -> Error (`Msg ("unsupported operating system " ^ x))

let destroy_tap tapname =
  Lazy.force (uname ()) >>= fun (sys, _) ->
  match sys with
  | x when x = "FreeBSD" ->
    Bos.OS.Cmd.run Bos.Cmd.(v "ifconfig" % tapname % "destroy")
  | x when x = "Linux" ->
    Bos.OS.Cmd.run Bos.Cmd.(v "ip" % "tuntap" % "del" % "dev" % tapname % "mode" % "tap")
  | x -> Error (`Msg ("unsupported operating system " ^ x))

let create_bridge bname =
  Lazy.force (uname ()) >>= fun (sys, _) ->
  match sys with
  | x when x = "FreeBSD" ->
    let cmd = Bos.Cmd.(v "ifconfig" % "bridge" % "create") in
    Bos.OS.Cmd.run_out cmd |> Bos.OS.Cmd.out_string >>= fun (name, _) ->
    Bos.OS.Cmd.run Bos.Cmd.(v "ifconfig" % name % "name" % bname)
  | x when x = "Linux" ->
    Bos.OS.Cmd.run Bos.Cmd.(v "brctl" % "addbr" % bname)
  | x -> Error (`Msg ("unsupported operating system " ^ x))

let prepare vm =
  let vmimage = tmpfile vm "img" in
  (match vm.vmimage with
   | `Ukvm_amd64, blob -> Ok blob
   | _ -> Error (`Msg "no amd64 ukvm image found")) >>= fun image ->
  Bos.OS.File.write vmimage (Cstruct.to_string image) >>= fun () ->
  let fifo = tmpfile vm "fifo" in
  (match fifo_exists fifo with
   | Ok true -> Ok ()
   | Ok false -> Error (`Msg ("file " ^ Fpath.to_string fifo ^ " exists and is not a fifo"))
   | Error _ ->
     try Ok (mkfifo (Fpath.to_string fifo)) with
     | Unix.Unix_error (e, f, _) ->
       Logs.err (fun m -> m "%a error in %s: %a" Fpath.pp fifo f pp_unix_error e) ;
       Error (`Msg "while creating fifo")) >>= fun () ->
  List.fold_left (fun acc b ->
      acc >>= fun acc ->
      create_tap b >>= fun tap ->
      Ok (tap :: acc))
    (Ok []) vm.network >>= fun taps ->
  Ok (fifo, vmimage, List.rev taps)

let shutdown vm =
  List.fold_left (fun r n -> r >>= fun () -> destroy_tap n) (Ok ()) vm.taps >>= fun () ->
  let fifo = tmpfile vm.config "fifo" in
  Bos.OS.File.delete fifo >>= fun () ->
  let vmimage = tmpfile vm.config "img" in
  Bos.OS.File.delete vmimage

let cpuset cpu =
  Lazy.force (uname ()) >>= fun (sys, _) ->
  let cpustring = string_of_int cpu in
  match sys with
  | x when x = "FreeBSD" ->
    Ok ([ "cpuset" ; "-l" ; cpustring ])
  | x when x = "Linux" ->
    Ok ([ "taskset" ; "-c" ; cpustring ])
  | x -> Error (`Msg ("unsupported operating system " ^ x))

let exec dir vm fifo vmimage taps =
  (* TODO: --net-mac=xx *)
  let net = List.map (fun t -> "--net=" ^ t) taps in
  let argv = match vm.argv with None -> [] | Some xs -> xs in
  (match taps with
   | [] -> Ok Fpath.(dir / "ukvm-bin.none")
   | [_] -> Ok Fpath.(dir / "ukvm-bin.net")
   | _ -> Error (`Msg "cannot handle multiple network interfaces")) >>= fun bin ->
  cpuset vm.cpuid >>= fun cpuset ->
  let mem = "--mem=" ^ string_of_int vm.memory in
  let cmd = Bos.Cmd.(of_list cpuset % p bin % mem %% of_list net % "--" % p vmimage %% of_list argv) in
  let line = Bos.Cmd.to_list cmd in
  let prog = try List.hd line with Failure _ -> failwith err_empty_line in
  let line = Array.of_list line in
  Logs.debug (fun m -> m "write fd for fifo %a" Fpath.pp fifo);
  write_fd_for_file fifo >>= fun stdout ->
  Logs.debug (fun m -> m "opened file descriptor!");
  try
    Logs.debug (fun m -> m "creating process");
    let pid = create_process prog line stdout stdout in
    Logs.debug (fun m -> m "created process %d: %a" pid Bos.Cmd.pp cmd) ;
    (* on FreeBSD we need to chmod g+rw /dev/vmm/ukvm$pid to run
       bhyvectl --get-stats --vm=ukvm$pid as non-priviliged user *)
    (Lazy.force (uname ()) >>= fun (sys, _) ->
     match sys with
     | x when x = "FreeBSD" ->
       let dev = "/dev/vmm/ukvm" ^ string_of_int pid in
       Bos.OS.Cmd.run Bos.Cmd.(v "chmod" % "g+rw" % dev)
     | _ -> Ok ()) >>= fun () ->
    Ok { config = vm ; cmd ; pid ; taps ; stdout }
  with
    Unix.Unix_error (e, _, _) ->
    close_no_err stdout;
    R.error_msgf "cmd %a exits: %a" Bos.Cmd.pp cmd pp_unix_error e

let destroy vm = Unix.kill vm.pid 15 (* 15 is SIGTERM *)