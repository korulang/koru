// Phase 3 rule 1: events declared in a .k contract file MUST be ~pub.
// A private event in .k is dead syntax — no procs live in .k (those are
// implementation), so nothing inside .k can call a private event, and
// nothing outside can see it. Declaring it is a confused intent.

event compute { x: u32 } -> u32
