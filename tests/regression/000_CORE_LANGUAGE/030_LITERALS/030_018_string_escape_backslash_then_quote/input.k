// Pins string-literal escape lexing when `\\` (literal backslash) is
// immediately followed by `\"` (literal quote): the decoded value is
// backslash-quote, and the statement must survive to emission. Guards the
// silent-drop shape where a mis-lexed escape sequence terminates the string
// early, garbles the line, and the flow vanishes from the program with a
// green exit — the value below must actually print.
import std/io
std/io:print.ln("a\\\"b")
