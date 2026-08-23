SECTIONS {
 . = ALIGN(8);
 PROVIDE(uk_boot_earlytab_start = .);
 .uk_boot_earlytab : {
  KEEP(*(SORT_BY_NAME(.uk_boot_earlytab[0-9])));
 }
 PROVIDE(uk_boot_earlytab_end = .);
}
INSERT AFTER .rodata
