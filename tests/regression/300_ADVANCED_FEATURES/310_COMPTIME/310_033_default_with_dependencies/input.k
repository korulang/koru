// Test 645: Default Steps with Dependencies
// Tests that [default|depends_on(...)] annotations work correctly
//
// Overrides all default steps with simple echos to verify:
// 1. Steps execute in dependency order
// 2. User overrides replace stdlib defaults
//
// Expected output order: compile_backend -> build -> run
//
// Paths are OUTPUT-DIRECTORY-relative, which is where a build step runs. The
// long repo-root-relative paths this test used to carry were a workaround for
// steps inheriting koruc's invocation directory; post.sh has always read a bare
// `steps.log` from the test directory, so only the writing half disagreed.

import std/build

// Override compile_backend (no dependencies)
std/build:step(name: "compile_backend") {
    echo "step:compile_backend" > steps.log
}

// Override build (depends on compile_backend)
[depends_on(compile_backend)]std/build:step(name: "build") {
    echo "step:build" >> steps.log
}

// Override run (depends on build)
[depends_on(build)]std/build:step(name: "run") {
    echo "step:run" >> steps.log
}
