// Local vocabulary B. `ping-b` exists ONLY here — a bare `ping-b` can resolve
// only if app/beta was opened with `[with]`.
pub event ping-b { msg: []const u8 } -> []const u8
ping-b -> msg
