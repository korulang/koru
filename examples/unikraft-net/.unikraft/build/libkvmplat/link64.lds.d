cmd_/Users/larsde/src/koru/examples/unikraft-net/.unikraft/build/libkvmplat/link64.lds := /bin/sh /Users/larsde/src/koru/examples/unikraft-net/.unikraft/build/libkvmplat/link64.lds.cmd

source_/Users/larsde/src/koru/examples/unikraft-net/.unikraft/build/libkvmplat/link64.lds := /Users/larsde/src/koru/examples/unikraft-net/.unikraft/unikraft/plat/kvm/x86/link64.lds.S

deps_/Users/larsde/src/koru/examples/unikraft-net/.unikraft/build/libkvmplat/link64.lds := \
    $(wildcard include/config/elf/phdrs/in/pt/load.h) \
  /Users/larsde/src/koru/examples/unikraft-net/.unikraft/unikraft/include/uk/arch/limits.h \
  /Users/larsde/src/koru/examples/unikraft-net/.unikraft/unikraft/include/uk/config.h \
  /Users/larsde/src/koru/examples/unikraft-net/.unikraft/unikraft/arch/x86/x86_64/include/uk/asm/limits.h \
    $(wildcard include/config/stack/size/page/order.h) \
    $(wildcard include/config/cpu/except/stack/size/page/order.h) \
    $(wildcard include/config/auxstack/size/page/order.h) \
  /Users/larsde/src/koru/examples/unikraft-net/.unikraft/unikraft/plat/common/include/uk/plat/common/common.lds.h \

/Users/larsde/src/koru/examples/unikraft-net/.unikraft/build/libkvmplat/link64.lds: $(deps_/Users/larsde/src/koru/examples/unikraft-net/.unikraft/build/libkvmplat/link64.lds)

$(deps_/Users/larsde/src/koru/examples/unikraft-net/.unikraft/build/libkvmplat/link64.lds):
