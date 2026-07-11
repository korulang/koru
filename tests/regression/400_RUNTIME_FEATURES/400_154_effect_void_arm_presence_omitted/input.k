// PRESENCE on a VOID optional arm, omitted case — the twin 400_146 does not
// cover. `if(note)` asks "did this consumer install `note`"; this consumer
// installs nothing, so the presence test must resolve FALSE and the impl
// must take `| else` (print 0). The tension this pins: void optional arms
// keep the 210_076 no-op contract (an omitted handler synthesizes a no-op in
// the consumer's handler struct so unguarded fires stay plain calls), and
// that synthesized decl is indistinguishable from a real install to a
// naive @hasDecl lowering — presence must see through the no-op, or the
// impl silently takes the wrong branch for every omitting consumer.
import std/io

pub event gen { n: i64 }
! ?note i64
| done i64

gen = if(note)
| then => done 1
| else => done 0

gen(n: 41)
| done r |> std/io:print.ln("{{ r:d }}")
