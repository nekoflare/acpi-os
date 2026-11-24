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

    call acpi_enable_cpu_features
    retq
.size acpi_load_gdt, .-acpi_load_gdt

.global acpi_enable_cpu_features
.type acpi_enable_cpu_features, @function
acpi_enable_cpu_features:
    /* Enable x87 and SSE, then discover any XSAVE-managed vector state. */
    movq %cr0, %rax
    andq $~0x0c, %rax
    orq $0x22, %rax
    movq %rax, %cr0
    movq %cr4, %rax
    andq $~0x50080, %rax
    orq $0x600, %rax
    movq %rax, %cr4

    pushq %rbx
    movl $1, %eax
    cpuid
    btl $26, %ecx
    jnc .Lvector_ready
    movq %cr4, %rax
    orq $0x40000, %rax
    movq %rax, %cr4
    movl $0xD, %eax
    xorl %ecx, %ecx
    cpuid
    /* x87, SSE, AVX and the three AVX-512 components. */
    andl $0xE7, %eax
    movl %eax, .Lxsave_mask(%rip)
    xorl %ecx, %ecx
    xorl %edx, %edx
    xsetbv
    movl $0xD, %eax
    cpuid
    cmpl $4096, %ebx
    jbe .Lvector_ready
    /* The task record reserves one aligned page for extended state. */
    movl $3, %eax
    xorl %ecx, %ecx
    xorl %edx, %edx
    xsetbv
    movl %eax, .Lxsave_mask(%rip)
.Lvector_ready:
    popq %rbx
    retq
.size acpi_enable_cpu_features, .-acpi_enable_cpu_features

/* Install an AP's private GDT/TSS and IDT, then establish its GS-local base. */
.global acpi_load_cpu_tables
.type acpi_load_cpu_tables, @function
acpi_load_cpu_tables:
    movq %rcx, %r8
    lgdt (%rdi)
    pushq $0x08
    leaq .Lcpu_reload_segments(%rip), %rax
    pushq %rax
    lretq
.Lcpu_reload_segments:
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    xorw %ax, %ax
    movw %ax, %fs
    movw %ax, %gs
    lidt (%rsi)
    ltr %dx
    movl $0xC0000101, %ecx
    movq %r8, %rax
    movq %rax, %rdx
    shrq $32, %rdx
    wrmsr
    movl $0xC0000102, %ecx
    xorl %eax, %eax
    xorl %edx, %edx
    wrmsr
    retq
.size acpi_load_cpu_tables, .-acpi_load_cpu_tables

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
    jz .Lkernel_breakpoint
    pushq $3
    jmp .Lfault_without_error
.Lkernel_breakpoint:
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

/* Cpu-local GS offsets shared with struct acpi_cpu_local in boot.c. */
.equ CPU_SCHEDULER_STACK, 0
.equ CPU_USER_KERNEL_STACK, 8
.equ CPU_USER_RSP, 16
.equ CPU_KERNEL_CR3, 24
.equ CPU_USER_FX_STATE, 32
.equ CPU_TSS, 40
.equ CPU_SELF, 48
.equ CPU_IRQ_PENDING, 56
.equ CPU_LAST_FAULT, 64
.equ CPU_FAULT_ERROR, 72
.equ CPU_FAULT_RIP, 80
.equ CPU_USER_CR3, 88

.bss
.balign 8
.Lxsave_mask:
    .long 0

.text
.global acpi_run_task
.type acpi_run_task, @function
acpi_run_task:
    /* RDI is the frame and RSI its save slot. RDX and RCX carry the
       ring-0 stack top and private CR3 for a user task, or zero.
       R8 points to the task's aligned extended-state page. */
    pushq %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    pushq %rsi
    movq %rsp, %gs:CPU_SCHEDULER_STACK
    movq %rdx, %gs:CPU_USER_KERNEL_STACK
    testq %rdx, %rdx
    jz .Ltask_tss_ready
    movq %gs:CPU_TSS, %rax
    movq %rdx, 4(%rax)
.Ltask_tss_ready:
    testq %rcx, %rcx
    jz .Lrestore_task
    movq %cr3, %rax
    movq %rax, %gs:CPU_KERNEL_CR3

    movq %r8, %gs:CPU_USER_FX_STATE
    movl .Lxsave_mask(%rip), %eax
    testl %eax, %eax
    jz .Lrestore_legacy_vectors
    xorl %edx, %edx
    xrstor64 (%r8)
    jmp .Luser_vectors_restored
.Lrestore_legacy_vectors:
    fxrstor64 (%r8)
.Luser_vectors_restored:
    xorl %eax, %eax
    /* Publish the address space before loading it; TLB shootdowns target
       CPUs by this value. Loading CR3 is serialising. */
    movq %rcx, %gs:CPU_USER_CR3
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
    testb $3, 8(%rsp)
    jz .Ltask_kernel_gs
    swapgs
.Ltask_kernel_gs:
    iretq
.size acpi_run_task, .-acpi_run_task

.Ldevice_interrupt:
    /* The stub pushed its vector so these common bytes fit every 16-byte IDT slot. */
    testb $3, 16(%rsp)
    jz .Ldevice_kernel_gs
    swapgs
.Ldevice_kernel_gs:
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
    movzbl 120(%rsp), %eax
    movb %al, %gs:CPU_IRQ_PENDING
    cmpq $0, %gs:CPU_SCHEDULER_STACK
    je .Ldevice_idle_return
    /* Long mode saves RSP and SS even for a same-privilege interrupt.
       Move the overlapping frame down one slot, starting at RIP. */
    leaq 128(%rsp), %rsi
    leaq 120(%rsp), %rdi
    movl $5, %ecx
    cld
    rep movsq
    movq %rsp, %rdx
    jmp .Lresume_scheduler
.Ldevice_idle_return:
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
    addq $8, %rsp
    iretq
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
    /* User faults (0x81) and page faults to try (0x82) carry CR2 at frame-8,
       the error code at frame-16 and the vector at frame-24. */
    cmpb $0x81, %gs:CPU_IRQ_PENDING
    jb .Lresume_scheduler
    movq %cr2, %rax
    pushq %rax
    pushq %gs:CPU_FAULT_ERROR
    pushq %gs:CPU_LAST_FAULT
.Lresume_scheduler:
    movq %gs:CPU_KERNEL_CR3, %rax
    testq %rax, %rax
    jz .Lrestore_scheduler
    movq %rax, %cr3
    movq $0, %gs:CPU_USER_CR3
    movq $0, %gs:CPU_KERNEL_CR3
    movq %gs:CPU_USER_FX_STATE, %rcx
    movl .Lxsave_mask(%rip), %eax
    testl %eax, %eax
    jz .Lsave_legacy_vectors
    /* RDX still holds the saved interrupt frame for the scheduler. */
    movq %rdx, %r8
    xorl %edx, %edx
    xsave64 (%rcx)
    movq %r8, %rdx
    jmp .Luser_vectors_saved
.Lsave_legacy_vectors:
    fxsave64 (%rcx)
.Luser_vectors_saved:
    xorl %eax, %eax
    movw %ax, %fs
.Lrestore_scheduler:
    movq %gs:CPU_SCHEDULER_STACK, %rsp
    movq $0, %gs:CPU_SCHEDULER_STACK
    movq $0, %gs:CPU_USER_KERNEL_STACK
    popq %rsi
    movq %rdx, (%rsi)
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    movzbl %gs:CPU_IRQ_PENDING, %eax
    cld
    retq
.Lreturn_interrupt:
    iretq

/* SYSCALL does not switch stacks. FMASK has already cleared IF. */
.global acpi_syscall_entry
.type acpi_syscall_entry, @function
acpi_syscall_entry:
    swapgs
    cmpq $0, %gs:CPU_USER_KERNEL_STACK
    je .Lhalt_fatal_vector
    movq %rsp, %gs:CPU_USER_RSP
    movq %gs:CPU_USER_KERNEL_STACK, %rsp
    pushq $0x1b
    pushq %gs:CPU_USER_RSP
    pushq %r11
    andq $0x240dd5, (%rsp)
    orq $0x202, (%rsp)
    pushq $0x23
    pushq %rcx
    movb $0x80, %gs:CPU_IRQ_PENDING
    jmp .Lsave_task
.size acpi_syscall_entry, .-acpi_syscall_entry

.Lpage_fault:
    /* Ring-3 non-present reads, writes and instruction fetches may grow the
       stack or back a lazy anonymous page. */
    testb $3, 16(%rsp)
    jz .Lkernel_page_fault
    swapgs
    cmpq $0, %gs:CPU_SCHEDULER_STACK
    je .Lkernel_page_fault
    movb $0x82, %gs:CPU_IRQ_PENDING
    cmpq $4, (%rsp)
    je .Luser_fault_error
    cmpq $0x14, (%rsp)
    je .Luser_fault_error
    movb $0x81, %gs:CPU_IRQ_PENDING
    cmpq $6, (%rsp)
    jne .Luser_fault_error
.Lstack_fault:
    movb $0x82, %gs:CPU_IRQ_PENDING
.Luser_fault_error:
    /* Record the fault and save the whole user frame, so a signal handler
       can inspect and resume it. The scheduler finds CR2, the error code and
       the vector just below the saved frame. */
    movq $14, %gs:CPU_LAST_FAULT
    pushq %rax
    movq 8(%rsp), %rax
    movq %rax, %gs:CPU_FAULT_ERROR
    movq 16(%rsp), %rax
    movq %rax, %gs:CPU_FAULT_RIP
    popq %rax
    addq $8, %rsp
    jmp .Lsave_task
.Lkernel_page_fault:
    movl $14, %eax
    jmp .Lfatal_with_error

/* User exceptions: the stub pushed its vector above the error code, if any. */
.Lfault_with_error:
    testb $3, 24(%rsp)
    jz .Lfault_fatal_with_error
    swapgs
    cmpq $0, %gs:CPU_SCHEDULER_STACK
    je .Lfault_fatal_with_error
    pushq %rax
    movq 8(%rsp), %rax
    movq %rax, %gs:CPU_LAST_FAULT
    movq 16(%rsp), %rax
    movq %rax, %gs:CPU_FAULT_ERROR
    movq 24(%rsp), %rax
    movq %rax, %gs:CPU_FAULT_RIP
    popq %rax
    addq $16, %rsp
    movb $0x81, %gs:CPU_IRQ_PENDING
    jmp .Lsave_task
.Lfault_fatal_with_error:
    popq %rax
    jmp .Lfatal_with_error
.Lfault_without_error:
    testb $3, 16(%rsp)
    jz .Lfault_fatal_without_error
    swapgs
    cmpq $0, %gs:CPU_SCHEDULER_STACK
    je .Lfault_fatal_without_error
    pushq %rax
    movq 8(%rsp), %rax
    movq %rax, %gs:CPU_LAST_FAULT
    movq $0, %gs:CPU_FAULT_ERROR
    movq 16(%rsp), %rax
    movq %rax, %gs:CPU_FAULT_RIP
    popq %rax
    addq $8, %rsp
    movb $0x81, %gs:CPU_IRQ_PENDING
    jmp .Lsave_task
.Lfault_fatal_without_error:
    popq %rax
    jmp .Lfatal_without_error

/* TLB shootdown IPI: flush, acknowledge and return to whatever was running,
   user or kernel, without entering the scheduler. */
.Ltlb_shootdown:
    testb $3, 8(%rsp)
    jz .Ltlb_kernel_gs
    swapgs
.Ltlb_kernel_gs:
    pushq %rax
    pushq %rcx
    pushq %rdx
    pushq %rsi
    pushq %rdi
    pushq %r8
    pushq %r9
    pushq %r10
    pushq %r11
    call acpi_tlb_shootdown_interrupt
    popq %r11
    popq %r10
    popq %r9
    popq %r8
    popq %rdi
    popq %rsi
    popq %rdx
    popq %rcx
    popq %rax
    testb $3, 8(%rsp)
    jz .Ltlb_return
    swapgs
.Ltlb_return:
    iretq

.Lexit_interrupt:
    cmpq $0, %gs:CPU_SCHEDULER_STACK
    jne .Lresume_exit
    movl $0x22, %eax
    jmp .Lfatal_without_error
.Lresume_exit:
    movb $0, %gs:CPU_IRQ_PENDING
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
    .elseif vector == 0x20 || vector == 0x21 || vector == 0x23 || vector == 0x24 || vector == 0x25 || vector == 0x27
        /* Interrupt gates clear IF. Leave the EOI to the ASL dispatcher. */
        pushq $vector
        jmp .Ldevice_interrupt
    .elseif vector == 0x22
        jmp .Lexit_interrupt
    .elseif vector == 0x26
        jmp .Ltlb_shootdown
    .elseif vector == 14
        jmp .Lpage_fault
    .elseif vector == 8
        movl $vector, %eax
        jmp .Lfatal_with_error
    .elseif vector == 10 || vector == 11 || vector == 12 || vector == 13 || vector == 17 || vector == 21 || vector == 29 || vector == 30
        pushq $vector
        jmp .Lfault_with_error
    .elseif vector < 32 && vector != 2 && vector != 8 && vector != 18
        pushq $vector
        jmp .Lfault_without_error
    .elseif vector == 0xff
        /* Spurious LAPIC interrupts have no in-service bit to acknowledge. */
        iretq
    .else
        movl $vector, %eax
        jmp .Lfatal_without_error
    .endif
    .balign 16, 0x90
    .set vector, vector + 1
.endr
.size acpi_vector_entries, .-acpi_vector_entries
.Lfatal_with_error:
    movq (%rsp), %rdx
    addq $8, %rsp
    jmp .Llog_fatal_vector
.Lfatal_without_error:
    xorl %edx, %edx
.Llog_fatal_vector:
    cli
    cld
    movl %eax, %r12d
    movl %eax, %edi
    movq (%rsp), %rsi
    movq 8(%rsp), %rcx
    movq %cr2, %r8
    movq 24(%rsp), %r9
    andq $-16, %rsp
    call acpi_log_fatal_vector
    movl %r12d, %eax
.Lhalt_fatal_vector:
    hlt
    jmp .Lhalt_fatal_vector

.section .note.GNU-stack,"",@progbits
