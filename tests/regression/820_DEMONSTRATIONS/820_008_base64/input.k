// 820_007 — base64 (RFC 4648): encode and decode text through the
// alphabet/bit-grouping codec, both directions plus a self-checking
// roundtrip. The published §10 vectors are the oracle.
//
// Pure .k. The codec's structure is Koru end to end: `encode`/`decode`
// are capture+for state machines (accumulator cells, an if-tree
// transition table), the alphabet is arithmetic in producing subflows,
// and the byte buffers are store columns borrowed through `! query` —
// the mail_merge ferry, because proc-effect arms see module scope only.
// append-char/clear/len/contains/print are the only leaves touched.

import std/io
import std/string
import std/store
import std/fmt

// One row, two owned buffers: `enc` holds the encoder's output, `dec`
// the decoder's. Both discharge at store teardown.
std/store:new(out, capacity: 2) { enc: *std/string:String<std/string:instance!>, dec: *std/string:String<std/string:instance!> }

// Append one output byte to a buffer cell (i64 in, u8 at the leaf).
tor emit.enc { b: i64 }
emit.enc = std/store:query(out)
! query o |> std/string:append-char(s: o.enc, ch: @as(u8, @intCast(b & 255)))
    | ok |> _
    | err _ |> _

tor emit.dec { b: i64 }
emit.dec = std/store:query(out)
! query o |> std/string:append-char(s: o.dec, ch: @as(u8, @intCast(b & 255)))
    | ok |> _
    | err _ |> _

// The i-th 6-bit group of the 24-bit window holding `n` left-justified
// input bytes (i in 0..3). n=3 shifts by 0; n=2,1 left-shift the partial
// group into place.
tor sextet.bits { w: i64, n: i64, i: i64 } -> i64
sextet.bits -> ((w << @as(u6, @intCast((3 - n) * 8))) >> @as(u6, @intCast(18 - i * 6))) & 63

// Output byte i of an encoded group: '=' past the sextet count (n+1),
// else the RFC 4648 alphabet — A-Z a-z 0-9 + / — as arithmetic.
tor quad.char { w: i64, n: i64, i: i64 } -> i64
quad.char = if(i > n)
| then -> 61
| else |> sextet.bits(w, n, i): v
    |> if(v < 26)
        | then -> v + 65
        | else |> if(v < 52)
            | then -> v + 71
            | else |> if(v < 62)
                | then -> v - 4
                | else |> if(v == 62)
                    | then -> 43
                    | else -> 47

// Emit one 3-byte group's 4 output chars (sextets + '=' padding).
tor emit.quad { w: i64, n: i64 }
emit.quad = quad.char(w, n, i: 0): c0 |> emit.enc(b: c0)
    |> quad.char(w, n, i: 1): c1 |> emit.enc(b: c1)
    |> quad.char(w, n, i: 2): c2 |> emit.enc(b: c2)
    |> quad.char(w, n, i: 3): c3 |> emit.enc(b: c3)

// Encode `text`: acc packs bytes big-endian; every third byte flushes a
// group; the tail emits the partial group with padding. One `captured`
// write per arm — the branch picks which cell value lands.
tor encode { text: string }
encode = capture { acc: 0[i64], n: 0[i64] }
! as a |> for(text)
    ! each ch |> if(a.n == 2)
        | then |> emit.quad(w: a.acc * 256 + @as(i64, @intCast(ch)), n: 3)
            |> captured { acc: 0, n: 0 }
        | else |> captured { acc: a.acc * 256 + @as(i64, @intCast(ch)), n: a.n + 1 }
| captured f |> if(f.n == 0)
    | then |> _
    | else |> emit.quad(w: f.acc, f.n)

// Alphabet char -> sextet value; '=' and anything outside returns -1
// (skipped by the decoder, which is also how padding terminates).
tor un.sextet { ch: i64 } -> i64
un.sextet = if(ch >= 65 and ch <= 90)
| then -> ch - 65
| else |> if(ch >= 97 and ch <= 122)
    | then -> ch - 97 + 26
    | else |> if(ch >= 48 and ch <= 57)
        | then -> ch - 48 + 52
        | else |> if(ch == 43)
            | then -> 62
            | else |> if(ch == 47)
                | then -> 63
                | else -> -1

// Decode `text`: acc holds `bits` low bits of the bit stream; each
// sextet adds 6; once a byte is complete it emits and the remainder
// keeps accumulating. acc stays masked to `bits` so it cannot overflow.
tor decode { text: string }
decode = capture { acc: 0[i64], bits: 0[i64] }
! as a |> for(text)
    ! each ch |> un.sextet(ch: @as(i64, @intCast(ch))): v
        |> if(v >= 0 and a.bits >= 2)
            | then |> emit.dec(b: (a.acc * 64 + v) >> @as(u6, @intCast(a.bits - 2)))
                |> captured { acc: (a.acc * 64 + v) & ((@as(i64, 1) << @as(u6, @intCast(a.bits - 2))) - 1), bits: a.bits - 2 }
            | else |> if(v >= 0)
                | then |> captured { acc: a.acc * 64 + v, bits: a.bits + 6 }

// Length of a bare string, counted in a flow — the decoder-side mirror
// of `std/string:len` for literal inputs.
tor text.len { s: string } -> i64
text.len = capture { n: 0[i64] }
! as a |> for(s)
    ! each _ |> captured { n: a.n + 1 }
| captured r -> r.n

// ---- driver ----

std/string:from-page(text: "")
| ok e0 |> std/string:take(s: e0): e |> std/string:from-page(text: "")
    | ok d0 |> std/string:take(s: d0): d |> std/store:insert(out) { enc: e, dec: d }
        | row _ |> _
    | err _ |> _
| err _ |> _

// Check-halves: encode/decode into the buffers and print produced next
// to the RFC/want string — the oracle pairs them.
tor check.encode { text: string, want: string }
check.encode = std/store:query(out)
! query o |> std/string:clear(s: o.enc) |> encode(text)
    |> std/io:print.ln("encode {{ text:s }} -> {{ o.enc:S }} (rfc: {{ want:s }})")

tor check.decode { text: string, want: string }
check.decode = std/store:query(out)
! query o |> std/string:clear(s: o.dec) |> decode(text)
    |> std/io:print.ln("decode {{ text:s }} -> {{ o.dec:S }} (want: {{ want:s }})")

// RFC 4648 section 10 test vectors.
check.encode(text: "", want: "")
check.encode(text: "f", want: "Zg==")
check.encode(text: "fo", want: "Zm8=")
check.encode(text: "foo", want: "Zm9v")
check.encode(text: "foob", want: "Zm9vYg==")
check.encode(text: "fooba", want: "Zm9vYmE=")
check.encode(text: "foobar", want: "Zm9vYmFy")

check.decode(text: "Zg==", want: "f")
check.decode(text: "Zm8=", want: "fo")
check.decode(text: "Zm9v", want: "foo")
check.decode(text: "Zm9vYg==", want: "foob")
check.decode(text: "Zm9vYmE=", want: "fooba")
check.decode(text: "Zm9vYmFy", want: "foobar")

// Roundtrip: the produced encoding crosses *String -> string through the
// fmt.blk render plus a one-piece split (sep "" is split's documented
// whole-slice path; `! piece` binds an unqualified string `for` accepts).
// The verdict is computed — decoded length equals the payload's AND the
// payload occurs inside it — not merely printed for the oracle.
std/store:query(out)
! query o |> std/string:clear(s: o.enc) |> std/string:clear(s: o.dec)
    |> encode(text: "The quick brown fox jumps over the lazy dog.")
    |> std/fmt:fmt.blk {
        {{ o.enc:S }}
    }: dump |> std/string:split(s: dump, sep: "")
        ! piece p |> decode(text: p)
            |> std/string:len(s: o.dec): dl |> text.len(s: "The quick brown fox jumps over the lazy dog."): pl
            |> if(@as(i64, @intCast(dl)) == pl)
                | then |> std/string:contains(s: o.dec, needle: "The quick brown fox jumps over the lazy dog.")
                    | yes |> std/io:print.ln("roundtrip MATCH: {{ o.dec:S }}")
                    | no |> std/io:print.ln("roundtrip MISMATCH: {{ o.dec:S }}")
                | else |> std/io:print.ln("roundtrip MISMATCH: {{ o.dec:S }}")
        | done _ |> _
