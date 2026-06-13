// std/switch:char set dispatch. `aeiou` matches any one of those chars.
import std/switch
import std/io

std/switch:char('e')
| `aeiou` _ |> std/io:print.ln("vowel")
| no-match |> std/io:print.ln("consonant")

std/switch:char('b')
| `aeiou` _ |> std/io:print.ln("vowel")
| no-match |> std/io:print.ln("consonant")
