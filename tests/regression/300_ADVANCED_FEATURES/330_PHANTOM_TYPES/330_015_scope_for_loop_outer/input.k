import std/control
import app/fs
app/fs:open(path: "outer.txt"): outer_f |> for(0..3)
    ! each _ |> _  // outer_f is suspended here (@scope), disposed in done
    | done |> _
