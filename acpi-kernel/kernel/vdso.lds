/* The vDSO is one read-only, executable PT_LOAD that starts with its own ELF
 * header, so the kernel maps the file image as it is and its link addresses
 * equal file offsets. The data page sits one page below it. */
SECTIONS
{
    . = SIZEOF_HEADERS;
    .hash : { *(.hash) } :text
    .gnu.hash : { *(.gnu.hash) }
    .dynsym : { *(.dynsym) }
    .dynstr : { *(.dynstr) }
    .gnu.version : { *(.gnu.version) }
    .gnu.version_d : { *(.gnu.version_d) }
    .gnu.version_r : { *(.gnu.version_r) }
    .dynamic : { *(.dynamic) } :text :dynamic
    .rodata : { *(.rodata*) } :text
    .eh_frame_hdr : { *(.eh_frame_hdr) } :text :eh_frame_hdr
    .eh_frame : { KEEP (*(.eh_frame)) } :text
    .text : { *(.text*) } :text
    /DISCARD/ : { *(.data*) *(.bss*) *(.note*) *(.comment) }
}

PHDRS
{
    text PT_LOAD FLAGS(5) FILEHDR PHDRS;
    dynamic PT_DYNAMIC FLAGS(4);
    eh_frame_hdr PT_GNU_EH_FRAME;
}
