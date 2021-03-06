(* (c) 2017 Hannes Mehnert, all rights reserved *)

open Rresult

open Vmm_core

val prepare : id -> vm_config -> (string list, [> R.msg ]) result

val shutdown : id -> vm -> (unit, [> R.msg ]) result

val exec : id -> vm_config -> string list -> (vm, [> R.msg ]) result

val destroy : vm -> unit

val close_no_err : Unix.file_descr -> unit
