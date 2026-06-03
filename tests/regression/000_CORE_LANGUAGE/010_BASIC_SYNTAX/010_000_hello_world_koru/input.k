// Hello World in pure Koru.
// This is the frontpage example from korulang.org.

~import "std/io"

~std.io:print.blk {
    {% if debug %}[DEBUG] {% endif %}Hello, {{ name:s }}!
    The answer is {{ count:d }}.
}
