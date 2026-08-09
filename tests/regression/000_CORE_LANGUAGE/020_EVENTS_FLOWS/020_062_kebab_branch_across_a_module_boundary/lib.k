// A library whose outcome names are kebab — the spelling Koru allows and Zig
// does not. `std/runtime:run` declares six of these; this is the shape.
pub tor classify { n: i32 }
| parse-error { message: string, line: u32 }
| ok string
