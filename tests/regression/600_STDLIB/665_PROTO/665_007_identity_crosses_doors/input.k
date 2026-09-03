// Identity crosses the two doors. A compound registered as `std/types:proto`
// and a compound registered as `std/proto` with the same bare name are not
// two namespaces or two scopes: they are the same registry entry claimed
// twice. The second spelling is convenient, not separate.
import std/proto
import std/types

std/types:proto(Engine) {
    rpm: i32
}

std/proto(Engine) {
    rpm: i32
}
