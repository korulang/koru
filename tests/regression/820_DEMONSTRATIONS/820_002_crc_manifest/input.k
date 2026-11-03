// 820_001 — checksum-manifest verification, the `cksum -c` task: each
// manifest line claims `path crc32`; the program rebuilds each payload's
// bytes from its lines, checksums the reconstruction, and reports.
// Structure is all Koru — an owned String<instance!> accumulates each
// file's text inside a nested read-lines (the view→instance obligation
// discharges exactly once per outcome), the regex names the manifest
// schema, and verify's outcomes (ok / mismatch / unreadable) are
// constructed by subflow. The only procs are std leaves.

import std/io
import std/fs
import std/regex
import std/string
import std/compress

pub tor verify { path: string, want: usize }
| ok
| mismatch { want: usize, got: usize }
| unreadable

verify = capture { lost: 0[i64], got: 0[usize] }
! as a |> std/string:from-page(text: "")
    | err _ |> captured { lost: 1 }
    | ok h |> std/string:take(s: h): buf |> std/fs:read-lines(path)
        ! line l |> std/string:append(s: buf, text: l)
            | ok |> std/string:append(s: buf, text: "\n")
                | ok |> _
                | err _ |> captured { lost: 1 }
            | err _ |> captured { lost: 1 }
        | done _ |> std/compress:crc32(buf.data): g
            |> std/string:free(s: buf) |> captured { got: g }
        | failed _ |> std/string:free(s: buf) |> captured { lost: 1 }
| captured r |> if(r.lost == 1)
    | then => unreadable
    | else |> if(r.got == want)
        | then => ok
        | else => mismatch { want, r.got }

capture { ok: 0[i64], bad: 0[i64] }
! as t |> std/fs:read-lines(path: "tests/regression/820_DEMONSTRATIONS/820_002_crc_manifest/input.txt")
    ! line l |> std/regex:match(l)
        | `(?<name>[^ ]+) (?<want>[0-9]+)` { name: string, want: usize }
            |> verify(path: name, want)
            | ok |> std/io:print.ln("{{ name:s }} OK") |> captured { ok: t.ok + 1 }
            | mismatch m |> std/io:print.ln("{{ name:s }} FAILED got {{ m.got:d }} want {{ m.want:d }}")
                |> captured { bad: t.bad + 1 }
            | unreadable |> std/io:print.ln("{{ name:s }} UNREADABLE") |> captured { bad: t.bad + 1 }
        | no-match |> std/io:print.ln("BAD LINE {{ l:s }}")
    | done _ |> _
    | failed e |> std/io:print.ln("FAILED {{ e:s }}")
| captured total |> std/io:print.ln("{{ total.ok:d }} ok, {{ total.bad:d }} bad")
