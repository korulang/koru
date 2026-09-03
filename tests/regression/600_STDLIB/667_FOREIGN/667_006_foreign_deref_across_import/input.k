// Cross-file deref check: the entry is declared in the imported lib, the
// deref in the consumer. `f.bogus` names no registered claim, so the Koru
// layer refuses it here — entries travel across imports; the check is not
// confined to the declaring module. The CONTAINS in EXPECT discriminates
// the layer (Zig's error never names `bogus`).
import app/lib

pub tor get-bogus { f: *File } -> string

get-bogus -> f.bogus
