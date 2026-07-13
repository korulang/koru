// Local vocabulary A. `ping-a` exists ONLY here — a bare `ping-a` can resolve
// only if app/alpha was opened with `[with]`.
pub event ping-a { msg: []const u8 } -> []const u8
ping-a -> msg
