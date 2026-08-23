SECTIONS {
 _uk_pcpuvar_align = 64;
 .uk_pcpuvar :
 {
  . = ALIGN(64);
  _uk_pcpuvar_base = .;
  _uk_pcpuvar_tmpl_start = .;
  KEEP(*(.uk_pcpuvar*))
  . = ALIGN(64);
  _uk_pcpuvar_tmpl_end = .;
  _uk_pcpuvar_tmpl_size = ABSOLUTE(_uk_pcpuvar_tmpl_end -
       _uk_pcpuvar_tmpl_start);
  FILL(0x00);
  . = _uk_pcpuvar_tmpl_start +
      (((_uk_pcpuvar_tmpl_end - _uk_pcpuvar_tmpl_start) + (64)-1) & ~((64)-1)) *
        1;
  _uk_pcpuvar_end = .;
 }
}
INSERT AFTER .data
