// THE LANTERN — a text adventure in pure Koru.
import std/io
import app/lantern

tor describe { room: i64 } -> string

describe = cond(room)
| c r when r == 0 -> "  Mouth of the cave. Cold air breathes out of the dark."
| c r when r == 1 -> "  The Dripping Hall. Water counts seconds on the stone."
| c r when r == 2 -> "  The Bone Ladder. Something climbed out of here once."
| c r when r == 3 -> "  A door of iron, with a keyhole shaped like a leaf."
| c _ -> "  The Vault. Gold, and the smell of very old air."

tor delve { room: i64 }

delve = if(room > 4)
| then |> std/io:print.ln("You climb back into daylight.")
| else |> describe(room): d |> std/io:print.ln(d) |> delve(room: room + 1)

std/io:print.ln("THE LANTERN")
app/lantern:light(): lamp |> delve(room: 0) |> app/lantern:douse(lamp)
