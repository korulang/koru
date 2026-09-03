// A compound graph must be acyclic: A reaches B reaches A, an infinite
// regress of scalars rather than a type. Refused at the declaration with
// the cycle named — the DAG law lives with the declaration, never with a
// consumer that might never walk it.
import std/proto

std/proto(A) {
    b: B
}

std/proto(B) {
    a: A
}
