SECTIONS {
 . = ALIGN(8);
 PROVIDE(uk_libparam_params_start = .);
 .uk_libparam_params : {
  KEEP(*(SORT_BY_NAME(.uk_libparam_params)));
 }
 PROVIDE(uk_libparam_params_end = .);
}
INSERT AFTER .rodata
