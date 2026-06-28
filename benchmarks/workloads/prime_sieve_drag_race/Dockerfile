# PrimeKoru — Sieve of Eratosthenes for the Plummer software drag race.
#
# Builds the Koru toolchain (koruc) FROM SOURCE inside the image, then compiles
# the Koru sieve through the full 4-stage metacircular pipeline. No pre-built
# koruc binary is fetched — satisfying the drag-race rule that a non-standard
# toolchain be built from source within the Dockerfile.
#
# Zig itself is downloaded from the official ziglang.org release (the Koru
# compiler's language toolchain, the same category as a rust:/golang: base
# image). Everything Koru-specific is compiled here.
#
# Build context = the koru repo root:
#   docker build -f benchmarks/workloads/prime_sieve_drag_race/Dockerfile -t primekoru .
#   docker run --rm primekoru
#
# For an actual submission, swap the `COPY` of the source for a
# `git clone --depth 1 --branch <pinned-tag>` of the public koru repo.

FROM debian:bookworm-slim

ARG ZIG_VERSION=0.15.2

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Zig toolchain (official release, arch-aware).
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
        amd64) zarch=x86_64 ;; \
        arm64) zarch=aarch64 ;; \
        *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${zarch}-linux-${ZIG_VERSION}.tar.xz" \
        -o /tmp/zig.tar.xz; \
    mkdir -p /opt/zig; \
    tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
    rm /tmp/zig.tar.xz; \
    /opt/zig/zig version
ENV PATH=/opt/zig:$PATH

# --- Build koruc from source ---------------------------------------------
# Only src/ + build files are needed to build the koruc binary; koru_std/ is
# read by koruc at compile time (resolved via KORU_HOME = the dir above
# zig-out/bin), so it must be present alongside the built binary.
WORKDIR /koru
COPY build.zig build.zig.zon ./
COPY src/ ./src/
COPY koru_std/ ./koru_std/
RUN zig build

# --- Compile the Koru sieve through the full pipeline --------------------
# koruc clobbers CWD (emits backend.zig/build.zig/program.ast.json/a.out into
# it), so compile in a clean /work dir. The runtime reads program.ast.json
# from CWD, so the binary is run from the same dir.
WORKDIR /work
COPY benchmarks/workloads/prime_sieve_drag_race/koru/faithful.k ./faithful.k
RUN /koru/zig-out/bin/koruc faithful.k

# Emits: `validated primes: 78498` then the official line on stdout:
#   koru;<passes>;<seconds>;1;algorithm=base,faithful=yes,bits=1
CMD ["./a.out"]
