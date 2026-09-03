// One home's File — the airlock entry lives where the host concept lives,
// not in the consumer. Importers deref through the import; the presence
// check travels with the entry.
import std/foreign

std/foreign:struct(File) {
    path,
    handle,
}
