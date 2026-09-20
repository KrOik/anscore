// PicoRV32 minimal runtime: .data copy, .bss zero, call main.
// No CSR access -- PicoRV32 has no mtvec; its trap output halts instead.
// sp is already loaded with STACKADDR (0x90002000) by the core itself.

    .section .text.start
    .globl _start
_start:
    la   a0, _data_lma
    la   a1, _data_vma
    la   a2, _edata
1:  beq  a1, a2, 2f
    lw   t0, 0(a0)
    sw   t0, 0(a1)
    addi a0, a0, 4
    addi a1, a1, 4
    j    1b
2:
    la   a1, _sbss
    la   a2, _ebss
3:  beq  a1, a2, 4f
    sw   zero, 0(a1)
    addi a1, a1, 4
    j    3b
4:
    call main
5:  j    5b
