// The granted half: `--cap=fs` (COMPILER_FLAGS) grants cap fs, the gate
// resolves true, the import proceeds, and the audit sees the consult
// claimed. Pair pin of 310_153 (ungranted → refused).
import std/io

[cap(fs)]import std/io

std/io:print.ln("granted")
