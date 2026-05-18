# Outside-the-bubble test for the @korulang/koru npm package.
# Goal: install the published tarball on a clean Debian image and run a real
# Koru program through the full 4-stage pipeline.

FROM debian:bookworm-slim

ARG ZIG_VERSION=0.15.2

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl xz-utils nodejs npm \
    && rm -rf /var/lib/apt/lists/*

# Install Zig (needed by Stages B and D — koruc shells out to `zig build`)
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
        amd64) zarch=x86_64 ;; \
        arm64) zarch=aarch64 ;; \
        *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    url="https://ziglang.org/download/${ZIG_VERSION}/zig-${zarch}-linux-${ZIG_VERSION}.tar.xz"; \
    curl -fsSL "$url" -o /tmp/zig.tar.xz; \
    mkdir -p /opt/zig; \
    tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
    rm /tmp/zig.tar.xz; \
    ln -s /opt/zig/zig /usr/local/bin/zig; \
    zig version

# Install the Koru npm package from the local tarball.
COPY korulang-koru-0.1.6.tgz /tmp/koru.tgz
RUN npm install -g /tmp/koru.tgz && rm /tmp/koru.tgz && koruc --version || true

WORKDIR /work
COPY hello/ /work/hello/
COPY tests/ /work/tests/
COPY run_tests.sh /work/run_tests.sh
RUN chmod +x /work/run_tests.sh

CMD ["bash"]
