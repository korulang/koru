#!/bin/bash
set -e

# Binary Size Comparison Script
# Generates a reproducible markdown table comparing Hello World binary sizes
# All binaries target: x86_64-linux, statically linked, stripped
#
# Uses aggressive size optimization flags across ALL languages for fair comparison:
#
# Zig/Koru:
#   -O ReleaseSmall       Optimize for size
#   -fstrip               Strip symbols
#   -fno-unwind-tables    Remove exception unwinding tables
#   -z norelro            Remove RELRO padding in ELF
#   -fno-builtin          Don't use compiler builtin optimizations
#
# C (via zig cc):
#   -Oz                   Optimize aggressively for size
#   -static               Static linking
#   -s                    Strip symbols
#   -fno-unwind-tables    Remove exception unwinding tables
#   -Wl,-z,norelro        Remove RELRO padding
#
# Go:
#   CGO_ENABLED=0         Pure Go, no C dependencies
#   -trimpath             Remove file system paths from binary
#   -ldflags '-s -w'      Strip symbols and DWARF
#
# Rust:
#   -C opt-level=z        Optimize aggressively for size
#   -C strip=symbols      Strip symbols
#   -C panic=abort        Abort on panic (no unwinding)
#   -C lto=fat            Full link-time optimization
#   -C codegen-units=1    Single codegen unit for better optimization
#   -C linker=rust-lld    Use LLD linker

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$SCRIPT_DIR/build"
KORU_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

echo "Binary Size Comparison"
echo "Target: x86_64-linux, static, stripped, size-optimized"
echo "Building in: $WORK_DIR"
echo ""

# Aggressive size optimization flags
ZIG_FLAGS="-target x86_64-linux -O ReleaseSmall -fstrip -fno-unwind-tables -z norelro -fno-builtin"
C_FLAGS="-target x86_64-linux-musl -Oz -static -s -fno-unwind-tables -Wl,-z,norelro"

#############################################
# 1. KORU
#############################################
cat > hello.kz << 'EOF'
~import "$std/io"
~std.io:print.ln("Hello, World!")
EOF

echo "Building Koru..."
"$KORU_ROOT/zig-out/bin/koruc" hello.kz > /dev/null 2>&1
zig build-exe $ZIG_FLAGS output_emitted.zig -femit-bin=hello_koru 2>/dev/null
KORU_SIZE=$(ls -la hello_koru | awk '{print $5}')

#############################################
# 2. ZIG (posix.write - same as what Koru emits)
#############################################
cat > hello_zig_posix.zig << 'EOF'
const std = @import("std");
pub fn main() void {
    _ = std.posix.write(1, "Hello, World!\n") catch {};
}
EOF

echo "Building Zig (posix.write)..."
zig build-exe $ZIG_FLAGS hello_zig_posix.zig -femit-bin=hello_zig_posix 2>/dev/null
ZIG_POSIX_SIZE=$(ls -la hello_zig_posix | awk '{print $5}')

#############################################
# 3. ZIG (std.debug.print - pulls in std.fmt)
#############################################
cat > hello_zig_debug.zig << 'EOF'
const std = @import("std");
pub fn main() void {
    std.debug.print("Hello, World!\n", .{});
}
EOF

echo "Building Zig (std.debug.print)..."
zig build-exe $ZIG_FLAGS hello_zig_debug.zig -femit-bin=hello_zig_debug 2>/dev/null
ZIG_DEBUG_SIZE=$(ls -la hello_zig_debug | awk '{print $5}')

#############################################
# 4. C (printf - fair comparison to Koru's print.ln)
#############################################
cat > hello_c_printf.c << 'EOF'
#include <stdio.h>
int main() {
    printf("Hello, World!\n");
    return 0;
}
EOF

echo "Building C (printf, musl)..."
zig cc $C_FLAGS hello_c_printf.c -o hello_c_printf 2>/dev/null
C_PRINTF_SIZE=$(ls -la hello_c_printf | awk '{print $5}')

#############################################
# 5. C (write syscall - raw, no libc formatting)
#############################################
cat > hello_c_write.c << 'EOF'
#include <unistd.h>
int main() {
    write(1, "Hello, World!\n", 14);
    return 0;
}
EOF

echo "Building C (write syscall, musl)..."
zig cc $C_FLAGS hello_c_write.c -o hello_c_write 2>/dev/null
C_WRITE_SIZE=$(ls -la hello_c_write | awk '{print $5}')

#############################################
# 6. GO (stripped, all optimizations)
#############################################
cat > hello.go << 'EOF'
package main
import "fmt"
func main() {
    fmt.Println("Hello, World!")
}
EOF

echo "Building Go..."
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags '-s -w' -o hello_go hello.go 2>/dev/null
GO_SIZE=$(ls -la hello_go | awk '{print $5}')

#############################################
# 7. RUST
#############################################
cat > hello.rs << 'EOF'
fn main() {
    println!("Hello, World!");
}
EOF

echo "Building Rust..."
rustc --target x86_64-unknown-linux-musl \
  -C opt-level=z \
  -C strip=symbols \
  -C panic=abort \
  -C lto=fat \
  -C codegen-units=1 \
  -C linker=rust-lld \
  hello.rs -o hello_rust 2>/dev/null
RUST_SIZE=$(ls -la hello_rust | awk '{print $5}')

#############################################
# OUTPUT TABLE
#############################################
echo ""
echo "=============================================="
echo "BINARY SIZE COMPARISON"
echo "Target: x86_64-linux, static, stripped"
echo "=============================================="
echo ""
echo "| Language | Binary Size | vs Koru | Notes |"
echo "|----------|-------------|---------|-------|"
printf "| **Koru** | **%'d B** | **1.0x** | string interpolation, compiles to posix.write |\n" "$KORU_SIZE"
printf "| Zig (posix.write) | %'d B | %.1fx | raw syscall, same as Koru output |\n" "$ZIG_POSIX_SIZE" "$(echo "scale=1; $ZIG_POSIX_SIZE / $KORU_SIZE" | bc)"
printf "| C (write, musl) | %'d B | %.1fx | raw syscall |\n" "$C_WRITE_SIZE" "$(echo "scale=1; $C_WRITE_SIZE / $KORU_SIZE" | bc)"
printf "| C (printf, musl) | %'d B | %.1fx | pulls in stdio formatting |\n" "$C_PRINTF_SIZE" "$(echo "scale=1; $C_PRINTF_SIZE / $KORU_SIZE" | bc)"
printf "| Zig (std.debug.print) | %'d B | %.1fx | pulls in std.fmt |\n" "$ZIG_DEBUG_SIZE" "$(echo "scale=1; $ZIG_DEBUG_SIZE / $KORU_SIZE" | bc)"
printf "| Rust | %'d B | %.0fx | println! macro |\n" "$RUST_SIZE" "$(echo "scale=0; $RUST_SIZE / $KORU_SIZE" | bc)"
printf "| Go | %'d B | %.0fx | fmt.Println |\n" "$GO_SIZE" "$(echo "scale=0; $GO_SIZE / $KORU_SIZE" | bc)"

echo ""
echo "Build commands:"
echo "  Zig/Koru: zig build-exe $ZIG_FLAGS"
echo "  C:        zig cc $C_FLAGS"
echo "  Rust:     rustc --target x86_64-unknown-linux-musl -C opt-level=z -C strip=symbols -C panic=abort -C lto=fat -C codegen-units=1 -C linker=rust-lld"
echo "  Go:       CGO_ENABLED=0 go build -trimpath -ldflags '-s -w'"
