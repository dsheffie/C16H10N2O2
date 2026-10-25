/* start.S -- bare-metal entry + general exception handler for tests/memprobe */
    .set noreorder
    .globl _start
    .text
_start:
    lui   $sp, 0x8870          /* stack top = kseg0 0x88700000 (phys 0x08700000) */
    jal   main
    nop
1:  b     1b
    nop

/* General exception handler, copied by main() to the vector at 0x80000180.
 * Records {cause, epc, badvaddr} and a count at kseg1 0xa0000300.., then skips
 * the faulting instruction: EPC+4, or EPC+8 (branch + delay slot) when Cause.BD. */
    .globl exc_handler, exc_handler_end
exc_handler:
    mfc0  $26, $13
    lui   $27, 0xa000
    sw    $26, 0x300($27)
    mfc0  $26, $14
    sw    $26, 0x304($27)
    mfc0  $26, $8
    sw    $26, 0x308($27)
    lw    $26, 0x30c($27)
    addiu $26, $26, 1
    sw    $26, 0x30c($27)
    mfc0  $26, $13
    bltz  $26, 1f              /* Cause.BD */
    mfc0  $27, $14
    b     2f
    addiu $27, $27, 4
1:  addiu $27, $27, 8
2:  mtc0  $27, $14
    nop
    nop
    eret
    nop
exc_handler_end:
