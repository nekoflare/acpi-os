.text

.global acpi_load_gdt
.type acpi_load_gdt, @function
acpi_load_gdt:
    lgdt (%rdi)
    pushq %rsi
    leaq .Lreload_segments(%rip), %rax
    pushq %rax
    lretq
.Lreload_segments:
    movw %dx, %ds
    movw %dx, %es
    movw %dx, %ss
    xorl %eax, %eax
    movw %ax, %fs
    movw %ax, %gs

    /* Enable x87/SSE state. FXSAVE does not cover AVX or extended state. */
    movq %cr0, %rax
    andq $~0x0c, %rax
    orq $0x22, %rax
    movq %rax, %cr0
    movq %cr4, %rax
    andq $~0x50000, %rax
    orq $0x600, %rax
    movq %rax, %cr4
    retq
.size acpi_load_gdt, .-acpi_load_gdt

/* The controlled breakpoint passes its AML context in RDI. */
.global acpi_trigger_breakpoint
.type acpi_trigger_breakpoint, @function
acpi_trigger_breakpoint:
    int3
.Lafter_int3:
    retq
.size acpi_trigger_breakpoint, .-acpi_trigger_breakpoint

.global acpi_breakpoint_entry
.type acpi_breakpoint_entry, @function
acpi_breakpoint_entry:
    testb $3, 8(%rsp)
    jnz .Lfault_without_error
    pushq %rax
    leaq .Lafter_int3(%rip), %rax
    cmpq %rax, 8(%rsp)
    jne .Lunexpected_breakpoint

    /* The register list in BRKP follows the saved stack order.
       RIP, CS, RFLAGS, RSP, and SS are already present below saved RAX. */
    pushq %rcx
    pushq %rdx
    pushq %rbx
    pushq %rbp
    pushq %rsi
    pushq %rdi
    pushq %r8
    pushq %r9
    pushq %r10
    pushq %r11
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    movq %rsp, %rsi
    movl $(15 + 5) * 8, %edx
    movq %rsp, %rbp
    andq $-16, %rsp
    cld
    call aml_interrupt_BRKP
    movq %rbp, %rsp
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %r11
    popq %r10
    popq %r9
    popq %r8
    popq %rdi
    popq %rsi
    popq %rbp
    popq %rbx
    popq %rdx
    popq %rcx
    /* RAX carries the AML status back to acpi_trigger_breakpoint. */
    addq $8, %rsp
    iretq
.Lunexpected_breakpoint:
    cli
    hlt
    jmp .Lunexpected_breakpoint
.size acpi_breakpoint_entry, .-acpi_breakpoint_entry

/* The scheduler stack is nonzero only while a task owns the CPU. */
.bss
.balign 8
.Lscheduler_stack:
    .quad 0
.Luser_kernel_stack:
    .quad 0
.Luser_rsp:
    .quad 0
.Lkernel_cr3:
    .quad 0
.Luser_fx_state:
    .quad 0

.text
.global acpi_run_task
.type acpi_run_task, @function
acpi_run_task:
    /* RDI is the frame and RSI its save slot. RDX and RCX carry the
       ring-0 stack top and private CR3 for a user task, or zero.
       R8 points to the task's aligned FXSAVE area. */
    pushq %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    pushq %rsi
    movq %rsp, .Lscheduler_stack(%rip)
    movq %rdx, .Luser_kernel_stack(%rip)
    testq %rcx, %rcx
    jz .Lrestore_task
    movq %cr3, %rax
    movq %rax, .Lkernel_cr3(%rip)

    movq %r8, .Luser_fx_state(%rip)
    fxrstor64 (%r8)
    xorl %eax, %eax
    movw %ax, %gs
    movq %rcx, %cr3
.Lrestore_task:
    movq %rdi, %rsp
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %r11
    popq %r10
    popq %r9
    popq %r8
    popq %rdi
    popq %rsi
    popq %rbp
    popq %rbx
    popq %rdx
    popq %rcx
    popq %rax
    iretq
.size acpi_run_task, .-acpi_run_task

.Ldevice_interrupt:
    cmpq $0, .Lscheduler_stack(%rip)
    je .Lreturn_interrupt
.Lsave_task:
    pushq %rax
    pushq %rcx
    pushq %rdx
    pushq %rbx
    pushq %rbp
    pushq %rsi
    pushq %rdi
    pushq %r8
    pushq %r9
    pushq %r10
    pushq %r11
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    movq %rsp, %rdx
.Lresume_scheduler:
    movq .Lkernel_cr3(%rip), %rax
    testq %rax, %rax
    jz .Lrestore_scheduler
    movq %rax, %cr3
    movq $0, .Lkernel_cr3(%rip)
    movq .Luser_fx_state(%rip), %rax
    fxsave64 (%rax)
    xorl %eax, %eax
    movw %ax, %fs
    movw %ax, %gs
.Lrestore_scheduler:
    movq .Lscheduler_stack(%rip), %rsp
    movq $0, .Lscheduler_stack(%rip)
    movq $0, .Luser_kernel_stack(%rip)
    popq %rsi
    movq %rdx, (%rsi)
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    movzbl acpi_irq_pending(%rip), %eax
    cld
    retq
.Lreturn_interrupt:
    iretq

/* SYSCALL does not switch stacks. FMASK has already cleared IF. */
.global acpi_syscall_entry
.type acpi_syscall_entry, @function
acpi_syscall_entry:
    cmpq $0, .Luser_kernel_stack(%rip)
    je .Lunhandled_vector
    movq %rsp, .Luser_rsp(%rip)
    movq .Luser_kernel_stack(%rip), %rsp
    pushq $0x1b
    pushq .Luser_rsp(%rip)
    pushq %r11
    andq $0x240dd5, (%rsp)
    orq $0x202, (%rsp)
    pushq $0x23
    pushq %rcx
    movb $0x80, acpi_irq_pending(%rip)
    jmp .Lsave_task
.size acpi_syscall_entry, .-acpi_syscall_entry

.Lfault_with_error:
    testb $3, 16(%rsp)
    jmp .Lcheck_fault
.Lfault_without_error:
    testb $3, 8(%rsp)
.Lcheck_fault:
    jz .Lunhandled_vector
    cmpq $0, .Lscheduler_stack(%rip)
    je .Lunhandled_vector
    movb $0x81, acpi_irq_pending(%rip)
    xorl %edx, %edx
    jmp .Lresume_scheduler

.Lexit_interrupt:
    cmpq $0, .Lscheduler_stack(%rip)
    je .Lunhandled_vector
    movb $0, acpi_irq_pending(%rip)
    xorl %edx, %edx
    jmp .Lresume_scheduler

.global acpi_task_exit
.type acpi_task_exit, @function
acpi_task_exit:
    int $0x22
    ud2
.size acpi_task_exit, .-acpi_task_exit

/* The boot test observes this task before allowing it to return. */
.global acpi_task_test
.type acpi_task_test, @function
acpi_task_test:
    movq $1, (%rdi)
    movabsq $0x123456789abcdef0, %r8
.Ltest_wait:
    pause
    cmpq $2, (%rdi)
    jne .Ltest_wait
    movabsq $0x123456789abcdef0, %r9
    cmpq %r8, %r9
    jne .Ltest_failed
    movq $3, (%rdi)
    retq
.Ltest_failed:
    movq $4, (%rdi)
    retq
.size acpi_task_test, .-acpi_task_test

/* Each 16-byte slot is the entry point for its own IDT vector. */
.balign 16
.global acpi_vector_entries
.type acpi_vector_entries, @function
acpi_vector_entries:
.set vector, 0
.rept 256
    .if vector == 3
        jmp acpi_breakpoint_entry
    .elseif vector == 0x20 || vector == 0x21 || vector == 0x23
        /* Interrupt gates clear IF. Leave the EOI to the ASL dispatcher. */
        movb $vector, acpi_irq_pending(%rip)
        jmp .Ldevice_interrupt
    .elseif vector == 0x22
        jmp .Lexit_interrupt
    .elseif vector == 10 || vector == 11 || vector == 12 || vector == 13 || vector == 14 || vector == 17 || vector == 21 || vector == 29 || vector == 30
        movl $vector, %eax
        jmp .Lfault_with_error
    .elseif vector < 32 && vector != 2 && vector != 8 && vector != 18
        movl $vector, %eax
        jmp .Lfault_without_error
    .elseif vector == 0xff
        /* Spurious LAPIC interrupts have no in-service bit to acknowledge. */
        iretq
    .else
        /* Fatal entries do not unwind frames, with or without error codes. */
        movl $vector, %eax
        jmp .Lunhandled_vector
    .endif
    .balign 16, 0x90
    .set vector, vector + 1
.endr
.size acpi_vector_entries, .-acpi_vector_entries
.Lunhandled_vector:
    cli
    hlt
    jmp .Lunhandled_vector

.section .note.GNU-stack,"",@progbits
