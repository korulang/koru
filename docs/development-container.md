# Pinned Linux development environment

Build the amd64 image from the repository root:

```sh
docker build --platform linux/amd64 -f scripts/Dockerfile -t koru-dev .
```

The image includes digest-pinned Ubuntu 24.04, checksum-verified Zig 0.15.2
and Node 22.16.0, development libraries, LLVM/MLIR, Vulkan software drivers,
FPGA tools and benchmark toolchains. CA certificates are installed from Ubuntu's
stock signed archive first; remaining apt packages use the 2026-11-17 snapshot
over verified HTTPS.

Clone `korulang/koru-libs` and `korulang/orisha` alongside `koru` under
`~/repos`, then run:

```sh
docker run --rm -it --platform linux/amd64 --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$HOME/repos/koru:/workspace/koru" -v "$HOME/repos/koru-libs:/workspace/koru-libs:ro" -v "$HOME/repos/orisha:/workspace/orisha:ro" koru-dev
```

`/usr/local/lib/koru` points to the mounted checkout and `KORU_STDLIB` to its
`koru_std`; sibling mounts satisfy library imports and router test paths.
Inside the container:

```sh
pgrep -fl 'run_regression|zig build' # also check the host for other sessions
zig build
zig build test
./run_regression.sh --parallel 8
bash hooks/install.sh
```

Never rebuild or edit compiler sources while a suite is live. Compile standalone
programs outside the repository root: generated build files can overwrite its
`build.zig`.

Hooks install into the mounted `.git/hooks`. Build first; pre-commit runs the
invariant gate, whose judgment checks need `OPENROUTER_API_KEY` passed at runtime
with `-e OPENROUTER_API_KEY`. Use your Git author identity and the required
`## World Model` / `## Membrane` commit sections; credentials are not embedded.

Known Linux-unportable tests include macOS app bundles, the bridge mount test's
`.dylib` path, and GPU dispatch's hardcoded MoltenVK ICD. The standard board is
Zig-only; opt-in .NET cross-target checks require a separate SDK.
