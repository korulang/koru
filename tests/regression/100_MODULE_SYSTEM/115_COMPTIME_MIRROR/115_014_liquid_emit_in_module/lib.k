import std/liquid_template

pub tor run {}
run = emit("{% if is_debug %}[DEBUG] Player: {{ name }}{% endif %} Game started.", is_debug: "true", name: "Bob")
