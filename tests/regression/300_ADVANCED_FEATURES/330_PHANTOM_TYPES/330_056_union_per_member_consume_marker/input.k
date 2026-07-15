import app/handle
app/handle:open(): h1 |> app/handle:finalize(h: h1)
app/handle:open(): h1 |> app/handle:start-close(h: h1): h2 |> app/handle:finalize(h: h2)
