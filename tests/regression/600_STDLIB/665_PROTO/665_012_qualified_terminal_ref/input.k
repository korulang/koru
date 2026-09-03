// A compound names another home's terminal explicitly. `health:
// app/alpha:Health` resolves by address — alpha's declaration — never by
// spelling. Unqualified refs name a terminal exactly one home declares.
import app/alpha
import std/io
import std/proto

std/proto(Player) {
    health: app/alpha:Health
}

std/io:print.ln("qualified")
