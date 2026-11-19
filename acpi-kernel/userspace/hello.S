.equ SYS_READ, 0
.equ SYS_WRITE, 1
.equ SYS_EXIT, 60
.equ STDOUT, 1
.equ EINTR, 4
.equ NAME_MAX, 63

.section .rodata
.Lprompt:
    .ascii "What is your name?\n"
.set prompt_length, . - .Lprompt
.Lgreeting:
    .ascii "\nHello, "
.set greeting_length, . - .Lgreeting
.Ldefault:
    .ascii "stranger"
.set default_length, . - .Ldefault
.Lend:
    .ascii "!\n"
.set end_length, . - .Lend
.Lerase:
    .ascii "\b \b"
.set erase_length, . - .Lerase

.bss
.Lname:
    .skip NAME_MAX
.Lkey:
    .skip 1

.text
.global _start
.type _start, @function
_start:
    leaq .Lprompt(%rip), %rsi
    movl $prompt_length, %edx
    call .Lwrite

    leaq .Lname(%rip), %r13
    xorl %r12d, %r12d
.Lread:
    movl $SYS_READ, %eax
    xorl %edi, %edi
    leaq .Lkey(%rip), %rsi
    movl $1, %edx
    syscall
    cmpq $-EINTR, %rax
    je .Lread
    testq %rax, %rax
    js .Lfailed
    je .Lgreet

    movzbl .Lkey(%rip), %eax
    cmpb $10, %al
    je .Lgreet
    cmpb $8, %al
    je .Lbackspace
    cmpb $127, %al
    je .Lbackspace
    cmpb $32, %al
    jb .Lread
    cmpq $NAME_MAX, %r12
    jae .Lread
    movb %al, (%r13,%r12)
    incq %r12
    leaq .Lkey(%rip), %rsi
    movl $1, %edx
    call .Lwrite
    jmp .Lread

.Lbackspace:
    testq %r12, %r12
    je .Lread
    decq %r12
    leaq .Lerase(%rip), %rsi
    movl $erase_length, %edx
    call .Lwrite
    jmp .Lread

.Lgreet:
    leaq .Lgreeting(%rip), %rsi
    movl $greeting_length, %edx
    call .Lwrite
    movq %r13, %rsi
    movq %r12, %rdx
    testq %rdx, %rdx
    jne .Lwrite_name
    leaq .Ldefault(%rip), %rsi
    movl $default_length, %edx
.Lwrite_name:
    call .Lwrite
    leaq .Lend(%rip), %rsi
    movl $end_length, %edx
    call .Lwrite
    xorl %edi, %edi
    jmp .Lexit

.Lwrite:
    movl $STDOUT, %edi
.Lwrite_next:
    movl $SYS_WRITE, %eax
    syscall
    cmpq $-EINTR, %rax
    je .Lwrite_next
    testq %rax, %rax
    jle .Lfailed
    addq %rax, %rsi
    subq %rax, %rdx
    jne .Lwrite_next
    ret

.Lfailed:
    movl $1, %edi
.Lexit:
    movl $SYS_EXIT, %eax
    syscall
    ud2
.size _start, . - _start

.section .note.GNU-stack,"",@progbits
