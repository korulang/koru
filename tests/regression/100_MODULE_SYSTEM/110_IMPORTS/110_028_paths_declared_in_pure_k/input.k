// Pins the pure-Koru spelling of a self-declared import alias: no tilde on the
// declaration, no tilde on the import that uses it, no koru.json anywhere.
//
// Twin of 110_027, which holds the `.kz` axis. `paths` is a Koru feature, not a
// host-embedding one, so both spellings have to stay live — a `.k` author writing
// the tilde is an error, and so is a `.kz` author omitting it.

std/compiler:paths {
    domain: {{ ENTRY }}/test_lib/domain
}

import domain/user

domain/user:announce()
