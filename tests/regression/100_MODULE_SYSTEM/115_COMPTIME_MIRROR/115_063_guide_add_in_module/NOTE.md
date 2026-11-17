Aspirational: guides:add inside an impl flow (`probe = std/guides:add(...) { lesson }`)
fails KORU080 — the `{...}` source block binds to the OUTER tor's impl body,
not add's `source` param, leaving add() argless. Entry-file top-level adds
work (480_001 green). Needs grammar disambiguation for block-in-flow-position
or an explicit source: spelling. Flip to MUST_RUN when resolved.
