// Drive koru-playground.wasm exactly as a browser would: instantiate via the
// WebAssembly API, feed Koru source, get JS back, eval it. A permissive wasi
// shim satisfies any imports (our happy path uses the embedded FS, so none of
// the real syscalls fire). Usage: node scripts/test-wasm.mjs <file.k>
import { readFileSync } from "node:fs";

const wasmPath = "zig-out/bin/koru-playground.wasm";
const srcPath = process.argv[2];
if (!srcPath) { console.error("usage: node test-wasm.mjs <file.k>"); process.exit(1); }

// Auto-stub every wasi import as a no-op returning 0, except proc_exit (surface
// it) — links the module without a real wasi runtime.
const stubModule = new Proxy({}, {
  get: (_t, name) => (name === "proc_exit"
    ? (code) => { throw new Error(`wasm called proc_exit(${code})`); }
    : (..._a) => 0),
});
const importObject = new Proxy({}, { get: () => stubModule });

const bytes = readFileSync(wasmPath);
const { instance } = await WebAssembly.instantiate(bytes, importObject);
const ex = instance.exports;
if (ex._initialize) ex._initialize(); // wasi reactor init

const mem = () => new Uint8Array(ex.memory.buffer);

function run(fnName, source) {
  const srcBytes = new TextEncoder().encode(source);
  const inPtr = ex.koru_alloc(srcBytes.length);
  mem().set(srcBytes, inPtr);
  const outPtr = ex[fnName](inPtr, srcBytes.length);
  const outLen = ex.koru_result_len();
  return new TextDecoder().decode(mem().subarray(outPtr, outPtr + outLen));
}

const source = readFileSync(srcPath, "utf8");
console.log("=== source ===\n" + source);

const js = run("koru_compile_js", source);
console.log("=== emitted JS (from wasm) ===\n" + js);

console.log("=== program output (eval'd) ===");
new Function(js)();
