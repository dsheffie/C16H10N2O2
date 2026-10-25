/* start.S -- bare-metal entry for tests/uncsdl */
    .set noreorder
    .globl _start
    .text
_start:
    lui   $sp, 0x8870          /* stack top = kseg0 0x88700000 (phys 0x08700000) */
    jal   main
    nop
1:  b     1b
    nop
