# OCaml to Ficus conversion utility.

The usage is simple: `ocaml2fx myfile.ml`
It will produce myfile.fx
(same name, different extension).

Note that the produced ficus source is half-baked.
It may not and likely will not compile. It needs to be
further tweaked, e.g. the types of function parameters
fshould be inserted.

That is, the conversion is per-module and is based on
the syntactic analysis. It does not involve type
inference or semantic checks.
