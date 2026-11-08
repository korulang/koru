// AoC 2015 Day 19 Part 2 — fewest steps to fabricate the molecule from e.
// Statement: rules e=>H, e=>O, H=>HO, H=>OH, O=>HH; target HOH → 3.
//
// Same little-endian base-B string encoding as part 1 (alphabet = the
// file's letter bytes only, pass 1). Search is iterative-deepening DFS:
// depth d = 0,1,2,... until dfs finds the target — the first d that hits
// IS the shortest (IDDFS needs no visited set; rem bounds every path).
// Each dfs node decodes its own code into a fresh digs list (freed on the
// way out); pows is global — b^j is node-independent.

import std/io
import std/fs
import std/regex
import std/list

// position of byte v in alpha, or -1
pub tor apos { alpha: *std/list:List_i64<list>, v: i64, i: i64 } -> i64

apos = std/list:get-i64(xs: alpha, i: @as(usize, @intCast(i)))
| item x -> if(x == v)
    | then -> i
    | else |> apos(alpha, v, i: i + 1): t -> t
| out-of-bounds -> 0 - 1

// string → little-endian base-b code (digit = alphabet position + 1)
pub tor encode { s: string, alpha: *std/list:List_i64<list>, b: i64 } -> i64

encode = capture { code: 0[i64], pow: 1[i64] }
! as a |> for(s)
    ! each ch |> apos(alpha, v: ch, i: 0): p
        |> captured { code: a.code + (p + 1) * a.pow, pow: a.pow * b }
| captured r -> r.code

pub tor slen { s: string } -> i64

slen = capture { n: 0[i64] }
! as a |> for(s)
    ! each _ |> captured { n: a.n + 1 }
| captured r -> r.n

// list read, 0 on out-of-bounds (bounds are proven by callers)
pub tor getv { xs: *std/list:List_i64<list>, i: i64 } -> i64

getv = std/list:get-i64(xs, i: @as(usize, @intCast(i)))
| item v -> v
| out-of-bounds -> 0

// does `from` (base-b code) match molecule digits at position i, flen digits?
pub tor matchk { digs: *std/list:List_i64<list>, pows: *std/list:List_i64<list>, from: i64, b: i64, i: i64, k: i64, flen: i64 } -> i64

matchk = if(k >= flen)
| then -> 1
| else |> getv(xs: digs, i: i + k): dm
    |> getv(xs: pows, i: k): pk
        |> if(@mod(@divTrunc(from, pk), b) == dm)
            | then |> matchk(digs, pows, from, b, i, k: k + 1, flen): t -> t
            | else -> 0

// product code: digs[0..i) ++ to ++ digs[i+flen..), little-endian base b.
pub tor mkprod { digs: *std/list:List_i64<list>, pows: *std/list:List_i64<list>, i: i64, flen: i64, tlen: i64, tocode: i64, ml: i64, b: i64, q: i64, acc: i64 } -> i64

mkprod = if(q >= ml - flen + tlen)
| then -> acc
| else |> if(q < i)
    | then |> getv(xs: digs, i: q): sd
        |> getv(xs: pows, i: q): pq
            |> mkprod(digs, pows, i, flen, tlen, tocode, ml, b, q: q + 1, acc: acc + sd * pq): t -> t
    | else |> if(q < i + tlen)
        | then |> getv(xs: pows, i: q - i): pk
            |> getv(xs: pows, i: q): pq
                |> mkprod(digs, pows, i, flen, tlen, tocode, ml, b, q: q + 1, acc: acc + @mod(@divTrunc(tocode, pk), b) * pq): t -> t
        | else |> getv(xs: digs, i: q - tlen + flen): sd
            |> getv(xs: pows, i: q): pq
                |> mkprod(digs, pows, i, flen, tlen, tocode, ml, b, q: q + 1, acc: acc + sd * pq): t -> t

// identity — lands a bound i64 as a pipeline's produced value
pub tor retv { x: i64 } -> i64

retv = if(x >= 0)
| then -> x
| else -> x

// position × rule walk inside one dfs node; 1 if any child reaches target.
pub tor tryk { digs: *std/list:List_i64<list>, pows: *std/list:List_i64<list>, rules: *std/list:List_i64<list>, cur: i64, curlen: i64, rem: i64, target: i64, b: i64, nr: i64, i: i64, r: i64 } -> i64

tryk = if(i >= curlen)
| then -> 0
| else |> if(r >= nr)
    | then |> tryk(digs, pows, rules, cur, curlen, rem, target, b, nr, i: i + 1, r: 0): t -> t
    | else |> getv(xs: rules, i: r * 4): flen
        |> getv(xs: rules, i: r * 4 + 1): tlen
            |> getv(xs: rules, i: r * 4 + 2): from
                |> getv(xs: rules, i: r * 4 + 3): tocode
                    |> matchk(digs, pows, from, b, i, k: 0, flen): mk
                        |> if(mk == 1)
                            | then |> mkprod(digs, pows, i, flen, tlen, tocode, ml: curlen, b, q: 0, acc: 0): child
                                |> dfs(cur: child, curlen: curlen - flen + tlen, rem: rem - 1, target, rules, pows, b, nr): d
                                    |> if(d == 1)
                                        | then -> 1
                                        | else |> tryk(digs, pows, rules, cur, curlen, rem, target, b, nr, i, r: r + 1): t -> t
                            | else |> tryk(digs, pows, rules, cur, curlen, rem, target, b, nr, i, r: r + 1): t -> t

// one IDDFS node: decode cur into a fresh digs, expand, free, return hit.
pub tor dfs { cur: i64, curlen: i64, rem: i64, target: i64, rules: *std/list:List_i64<list>, pows: *std/list:List_i64<list>, b: i64, nr: i64 } -> i64

dfs = if(rem < 0)
| then -> 0
| else |> if(cur == target)
    | then -> 1
    | else |> std/list:new(i64)
        | list cdigs |> filldigs(digs: cdigs, pows, code: cur, b, j: 0, ml: curlen): _
            |> tryk(digs: cdigs, pows, rules, cur, curlen, rem, target, b, nr, i: 0, r: 0): t
                |> std/list:free-i64(xs: cdigs)
                    |> if(t >= 0)
                        | then -> t
                        | else -> t
        | err _ -> 0

// deepen until dfs hits; answer is the first d that does.
pub tor deepest { cur: i64, curlen: i64, target: i64, d: i64, rules: *std/list:List_i64<list>, pows: *std/list:List_i64<list>, b: i64, nr: i64 } -> i64

deepest = if(d > 10)
| then -> 0 - 1
| else |> dfs(cur, curlen, rem: d, target, rules, pows, b, nr): hit
    |> if(hit == 1)
        | then -> d
        | else |> deepest(cur, curlen, target, d: d + 1, rules, pows, b, nr): t -> t

// push b^j for j in 0..n into pows (pows[j] = b^j)
pub tor fillpows { pows: *std/list:List_i64<list>, b: i64, j: i64, n: i64, acc: i64 } -> i64

fillpows = if(j >= n)
| then -> 0
| else |> std/list:push-i64(xs: pows, v: acc)
    |> fillpows(pows, b, j: j + 1, n, acc: acc * b): t -> t

// push base-b digits of code into digs, j = 0..ml-1
pub tor filldigs { digs: *std/list:List_i64<list>, pows: *std/list:List_i64<list>, code: i64, b: i64, j: i64, ml: i64 } -> i64

filldigs = if(j >= ml)
| then -> 0
| else |> getv(xs: pows, i: j): pj
    |> std/list:push-i64(xs: digs, v: @mod(@divTrunc(code, pj), b))
        |> filldigs(digs, pows, code, b, j: j + 1, ml): t -> t

std/list:new(i64)
| list alpha
    |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_192_day19_part2/input.txt")
        ! line l |> for(l)
            ! each ch |> if((ch >= 65 and ch <= 90) or (ch >= 97 and ch <= 122))
                | then |> apos(alpha, v: ch, i: 0): p
                    |> if(p < 0)
                        | then |> std/list:push-i64(xs: alpha, v: ch)
        | done _ |> std/list:len-i64(xs: alpha): al
            |> std/list:new(i64)
                | list rules
                    |> std/list:new(i64)
                        | list pows
                            |> fillpows(pows, b: @as(i64, @intCast(al)) + 1, j: 0, n: 24, acc: 1): _
                                |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_192_day19_part2/input.txt")
                                    ! line l |> std/regex:match(l)
                                        | `(?<f>[A-Za-z]+) => (?<t>[A-Za-z]+)` { f, t } |> slen(s: f): fl
                                            |> slen(s: t): tl
                                                |> encode(s: f, alpha, b: @as(i64, @intCast(al)) + 1): fc
                                                    |> encode(s: t, alpha, b: @as(i64, @intCast(al)) + 1): tc
                                                        |> std/list:push-i64(xs: rules, v: fl)
                                                            |> std/list:push-i64(xs: rules, v: tl)
                                                                |> std/list:push-i64(xs: rules, v: fc)
                                                                    |> std/list:push-i64(xs: rules, v: tc)
                                        | `(?<m>[A-Za-z]+)` { m }
                                            |> encode(s: m, alpha, b: @as(i64, @intCast(al)) + 1): mc
                                                |> encode(s: "e", alpha, b: @as(i64, @intCast(al)) + 1): sc
                                                    |> std/list:len-i64(xs: rules): rl
                                                        |> deepest(cur: sc, curlen: 1, target: mc, d: 0, rules, pows, b: @as(i64, @intCast(al)) + 1, nr: @divTrunc(@as(i64, @intCast(rl)), 4)): ans
                                                            |> std/io:print.ln("{{ ans:d }}")
                                        | no-match |> slen(s: l): nl |> if(nl > 0)
                                            | then |> std/io:print.ln("BAD: {{ l:s }}")
                                    | done _ |> std/list:free-i64(xs: pows)
                                        |> std/list:free-i64(xs: rules)
                                            |> std/list:free-i64(xs: alpha)
                                    | failed _ |> std/list:free-i64(xs: pows)
                                        |> std/list:free-i64(xs: rules)
                                            |> std/list:free-i64(xs: alpha)
                        | err _ |> std/list:free-i64(xs: rules)
                            |> std/list:free-i64(xs: alpha)
                | err _ |> std/list:free-i64(xs: alpha)
        | failed _ |> std/list:free-i64(xs: alpha)
| err e |> std/io:print.ln("ERR {{ e:s }}")
