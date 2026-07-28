// Local vocabulary. `label` and `origin` exist ONLY here — a bare `label`
// resolves only if app/alpha was opened with `[with]`.
pub tor origin {} -> string
proc origin|zig { return "threaded"; }

pub tor label { word: string, tag: string } -> string
proc label|zig { return word; }
