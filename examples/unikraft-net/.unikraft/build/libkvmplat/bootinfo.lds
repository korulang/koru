SECTIONS {
 . = ALIGN(8);
 .uk_bootinfo :
 {
  KEEP(*(.uk_bootinfo))
 }
}
INSERT AFTER .data
