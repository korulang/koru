// Pins string-typed record-return field lowering: `-> { skip: string, ... }`
// must lower `string` to the host text type in the emitted `Output` struct
// (the string-surface-type `lowerZigType` reaching record-return fields). Last
// piece of the `! config -> { skip, trivia }` grammar-config shape — record
// produce and `: bind` consumption already hold.
import std/io
pub event config { strict: bool } -> { skip: string, trivia: string }
config = if(strict)
    | then -> { skip: "WS", trivia: "CMT" }
    | else -> { skip: "NONE", trivia: "NONE" }
config(strict: true): r |> std/io:print.ln("skip={{ r.skip:s }} trivia={{ r.trivia:s }}")
