import app/host
import std/io

app/host:box.make(): b
|> app/host:box.tag(b): _
|> std/io:print.ln("ok")
|> app/host:box.drop(b)
