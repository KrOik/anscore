/* PicoRV32 eval firmware: code/ROM at 0x80000000, data at 0x90000000. */
OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    IMEM (rx)  : ORIGIN = 0x80000000, LENGTH = 16K
    DMEM (rwx) : ORIGIN = 0x90000000, LENGTH = 8K
}

SECTIONS
{
    .text : {
        *(.text.start)
        *(.text*)
        *(.rodata*)
        *(.srodata*)
    } > IMEM

    . = ALIGN(4);
    _data_lma = .;

    .data : AT(_data_lma) {
        _data_vma = .;
        *(.data*)
        *(.sdata*)
        _edata = .;
    } > DMEM

    .bss : {
        _sbss = .;
        *(.bss*)
        *(.sbss*)
        *(COMMON)
        _ebss = .;
    } > DMEM
}
