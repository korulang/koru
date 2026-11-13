import app/test_lib/host
import std/io

app/test_lib/host:base(): b |> app/test_lib/host:extra(): e |> std/io:print.ln("{{ b:d }}-{{ e:d }}")
