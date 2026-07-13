// Local vocabulary B — ALSO defines `ping`. The collision with app/alpha is the
// whole point of this pin.
pub event ping { msg: []const u8 } -> []const u8
ping -> msg
