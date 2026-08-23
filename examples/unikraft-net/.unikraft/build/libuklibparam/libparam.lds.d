cmd_/Users/larsde/src/koru/examples/unikraft-net/.unikraft/build/libuklibparam/libparam.lds := /bin/sh /Users/larsde/src/koru/examples/unikraft-net/.unikraft/build/libuklibparam/libparam.lds.cmd

source_/Users/larsde/src/koru/examples/unikraft-net/.unikraft/build/libuklibparam/libparam.lds := /Users/larsde/src/koru/examples/unikraft-net/.unikraft/unikraft/lib/uklibparam/libparam.lds.S

deps_/Users/larsde/src/koru/examples/unikraft-net/.unikraft/build/libuklibparam/libparam.lds := \
  /Users/larsde/src/koru/examples/unikraft-net/.unikraft/unikraft/lib/uklibparam/include/uk/libparam.h \
    $(wildcard include/config/libuklibparam.h) \
  /Users/larsde/src/koru/examples/unikraft-net/.unikraft/unikraft/include/uk/config.h \

/Users/larsde/src/koru/examples/unikraft-net/.unikraft/build/libuklibparam/libparam.lds: $(deps_/Users/larsde/src/koru/examples/unikraft-net/.unikraft/build/libuklibparam/libparam.lds)

$(deps_/Users/larsde/src/koru/examples/unikraft-net/.unikraft/build/libuklibparam/libparam.lds):
