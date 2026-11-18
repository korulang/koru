FROM ubuntu:24.04@sha256:73b999393d07f2bf65a40373778a44dc9a6d54ad7718d29247d8ff9413c4d6a8

# The dated archive pins transitive packages as well as the requested tools.
RUN apt-get -o APT::Update::Error-Mode=any update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && sed -i 's|http://archive.ubuntu.com/ubuntu/|https://snapshot.ubuntu.com/ubuntu/20261117T000000Z/|; s|http://security.ubuntu.com/ubuntu/|https://snapshot.ubuntu.com/ubuntu/20261117T000000Z/|' /etc/apt/sources.list.d/ubuntu.sources \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get -o APT::Update::Error-Mode=any update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       ca-certificates curl xz-utils git python3 build-essential pkg-config \
       libsqlite3-dev zlib1g-dev libssl-dev ripgrep procps \
       mlir-19-tools llvm-19 clang-19 spirv-tools iverilog yosys \
       libvulkan-dev mesa-vulkan-drivers \
    && rm -rf /var/lib/apt/lists/*

RUN apt-get -o APT::Update::Error-Mode=any update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       golang-go cargo rustc hyperfine jq bc libyaml-dev \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSLo /tmp/zig.tar.xz https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz \
    && echo '02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239  /tmp/zig.tar.xz' | sha256sum -c - \
    && mkdir /opt/zig \
    && tar -xJf /tmp/zig.tar.xz --strip-components=1 -C /opt/zig \
    && curl -fsSLo /tmp/node.tar.xz https://nodejs.org/dist/v22.16.0/node-v22.16.0-linux-x64.tar.xz \
    && echo 'f4cb75bb036f0d0eddf6b79d9596df1aaab9ddccd6a20bf489be5abe9467e84e  /tmp/node.tar.xz' | sha256sum -c - \
    && tar -xJf /tmp/node.tar.xz --strip-components=1 -C /usr/local \
    && rm /tmp/zig.tar.xz /tmp/node.tar.xz

ENV PATH="/opt/zig:/workspace/koru/zig-out/bin:${PATH}" \
    KORU_STDLIB=/workspace/koru/koru_std
RUN mkdir -p /workspace/koru /usr/local/lib \
    && ln -s /workspace/koru /usr/local/lib/koru \
    && mkdir -p /opt/homebrew/opt \
    && ln -s /usr/lib/llvm-19 /opt/homebrew/opt/llvm \
    && ln -s /usr/bin/spirv-val /usr/local/bin/spirv-val
WORKDIR /workspace/koru
CMD ["bash"]
