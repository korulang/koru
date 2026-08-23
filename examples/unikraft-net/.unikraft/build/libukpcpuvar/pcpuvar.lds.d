cmd_/Users/larsde/src/koru/examples/unikraft-net/.unikraft/build/libukpcpuvar/pcpuvar.lds := /bin/sh /Users/larsde/src/koru/examples/unikraft-net/.unikraft/build/libukpcpuvar/pcpuvar.lds.cmd

source_/Users/larsde/src/koru/examples/unikraft-net/.unikraft/build/libukpcpuvar/pcpuvar.lds := /Users/larsde/src/koru/examples/unikraft-net/.unikraft/unikraft/lib/ukpcpuvar/pcpuvar.lds.S

deps_/Users/larsde/src/koru/examples/unikraft-net/.unikraft/build/libukpcpuvar/pcpuvar.lds := \
    $(wildcard include/config/ukplat/cpu/maxcount.h) \
  /Users/larsde/src/koru/examples/unikraft-net/.unikraft/unikraft/arch/include/uk/arch.h \
  /Users/larsde/src/koru/examples/unikraft-net/.unikraft/unikraft/arch/x86_64/include/uk/arch/arch.h \
  /Users/larsde/src/koru/examples/unikraft-net/.unikraft/unikraft/arch/x86_64/include/uk/arch/util.h \
  /Users/larsde/src/koru/examples/unikraft-net/.unikraft/unikraft/include/uk/arch/types.h \
  /Users/larsde/src/koru/examples/unikraft-net/.unikraft/unikraft/arch/x86/x86_64/include/uk/asm/intsizes.h \
  /Users/larsde/src/koru/examples/unikraft-net/.unikraft/unikraft/arch/x86/x86_64/include/uk/asm/types.h \
  /Users/larsde/src/koru/examples/unikraft-net/.unikraft/unikraft/include/uk/essentials.h \
    $(wildcard include/config/libnewlibc.h) \
    $(wildcard include/config/have/sched.h) \
  /Users/larsde/src/koru/examples/unikraft-net/.unikraft/unikraft/include/uk/config.h \

/Users/larsde/src/koru/examples/unikraft-net/.unikraft/build/libukpcpuvar/pcpuvar.lds: $(deps_/Users/larsde/src/koru/examples/unikraft-net/.unikraft/build/libukpcpuvar/pcpuvar.lds)

$(deps_/Users/larsde/src/koru/examples/unikraft-net/.unikraft/build/libukpcpuvar/pcpuvar.lds):
