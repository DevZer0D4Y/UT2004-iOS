// int ut_call_on_stack(void *stack_top, int (*fn)(int, char **, char **),
//                      int argc, char **argv, char **envp);
// Runs fn(argc, argv, envp) on the given stack (16-byte aligned top) on the
// current thread and returns its result. x29 keeps pointing at this frame on
// the original stack, so frame-pointer and CFI unwinding both walk back out.
    .text
    .globl _ut_call_on_stack
    .p2align 2
_ut_call_on_stack:
    .cfi_startproc
    stp     x29, x30, [sp, #-32]!
    stp     x19, x20, [sp, #16]
    mov     x29, sp
    .cfi_def_cfa w29, 32
    .cfi_offset w20, -8
    .cfi_offset w19, -16
    .cfi_offset w30, -24
    .cfi_offset w29, -32
    mov     x19, sp
    and     x0, x0, #~15
    mov     sp, x0
    mov     x16, x1
    mov     w0, w2
    mov     x1, x3
    mov     x2, x4
    blr     x16
    mov     sp, x19
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret
    .cfi_endproc
