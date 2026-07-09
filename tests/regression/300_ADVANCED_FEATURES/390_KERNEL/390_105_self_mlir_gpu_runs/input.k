// Test 390_105: self|mlir[gpu] — a second GPU-execution witness (rung C).
//
// Distinct op (+= 100.0) and distinct numbers from 390_103's *2.0, so a PASS
// can't come from a fixed blob or a cached result — the M2 Pro genuinely
// computes {1,2,3} -> {101,102,103}. Same path as 390_103: emit gpu.module ->
// convert-gpu-to-spirv -> spirv-val-gated blob, then the host binary @imports
// koru_gpu_dispatch, uploads, dispatches on the local Vulkan device (MoltenVK),
// reads back. The kernel runs on the GPU of the machine that compiled it.
//
// RESIDUAL: the call-site `[gpu]` parameter is scaffolding — target selection
// belongs to the (separate) per-event selection-language endeavor.

import std/kernel
import std/io

std/kernel:shape(Body) {
    mass: f32,
}

std/kernel:init(Body) {
    { mass: 1.0 },
    { mass: 2.0 },
    { mass: 3.0 },
}
| kernel k |> std/kernel:self|mlir[gpu] { k.mass += 100.0 }
| computed c |> std/io:print.blk {
        mass[0]={{ c[0].mass:f }} mass[1]={{ c[1].mass:f }} mass[2]={{ c[2].mass:f }}
    }
