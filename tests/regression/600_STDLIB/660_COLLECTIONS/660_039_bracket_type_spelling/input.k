// PINS: `Name[params]` is a TYPE spelling that resolves to the already-
// synthesized concrete decl — specialization is synthesis, not generics
// (frag-specialization-is-synthesis-not-generics). `Heap[i64]` denotes
// `Heap_i64`, `List[i64]` → `List_i64`, `Map[string,i64]` →
// `Map_string_i64` — an additive alias; the underscore spellings keep
// working. Covers param AND return positions, qualified `mod/path:` and
// phantom `<state>` tails intact.
//
// Expected output: heap=2
import std/io
import std/heap
import std/list
import std/string-map

pub tor id-heap { h: *std/heap:Heap[i64]<heap> } -> *std/heap:Heap[i64]<heap>
id-heap -> h

pub tor id-list { xs: *std/list:List[i64]<list> } -> *std/list:List[i64]<list>
id-list -> xs

pub tor id-map { m: *std/string-map:Map[string,i64]<map> } -> *std/string-map:Map[string,i64]<map>
id-map -> m

pub tor use-heap { h: *std/heap:Heap[i64]<heap> } -> i64
use-heap = std/heap:push-i64(xs: h, key: 7)
    |> std/heap:push-i64(xs: h, key: 3)
    |> std/heap:len-i64(xs: h)

std/heap:new-i64()
    | list hp
        |> use-heap(h: hp): r
        |> std/io:print.ln("heap={{ r:d }}")
    | err _
        |> std/io:print.ln("err")
