.section .rodata.initramfs,"a",@progbits
.balign 8
.global acpi_initramfs_start, acpi_initramfs_end
acpi_initramfs_start:
.incbin INITRAMFS_IMAGE
acpi_initramfs_end:

.section .note.GNU-stack,"",@progbits
