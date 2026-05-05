// Bare-metal STM32F401RE blinky in C
//
// No HAL, no FreeRTOS, no startup code from CubeMX — just a vector
// table, a reset handler, and direct MMIO. This is the smallest
// "running on metal" C implementation; it is the most generous
// reference C comparison for the binary-size shootout.
//
// Build:
//   arm-none-eabi-gcc -mcpu=cortex-m4 -mthumb -mfloat-abi=hard \
//     -mfpu=fpv4-sp-d16 -nostdlib -ffreestanding -Os -fno-unwind-tables \
//     -fno-asynchronous-unwind-tables -ffunction-sections -fdata-sections \
//     -Wl,--gc-sections -T linker.ld -o blinky.elf blinky.c

#include <stdint.h>

#define RCC_AHB1ENR  (*(volatile uint32_t *)0x40023830U)
#define GPIOA_MODER  (*(volatile uint32_t *)0x40020000U)
#define GPIOA_BSRR   (*(volatile uint32_t *)0x40020018U)

extern uint32_t _stack_top;     // defined by linker.ld

void Reset_Handler(void);
void Default_Handler(void);

// Cortex-M4 vector table — at minimum, initial SP and reset handler.
// Other entries default to Default_Handler so spurious IRQs don't crash
// silently. We weak-alias them to keep the table dense.
__attribute__((section(".isr_vector"), used))
const void *vector_table[] = {
    (const void *)&_stack_top,
    Reset_Handler,
    Default_Handler, /* NMI */
    Default_Handler, /* HardFault */
    Default_Handler, /* MemManage */
    Default_Handler, /* BusFault */
    Default_Handler, /* UsageFault */
};

void Reset_Handler(void) {
    // Enable GPIOA clock
    RCC_AHB1ENR |= (1U << 0);

    // PA5 -> general-purpose output (mode = 01)
    GPIOA_MODER = (GPIOA_MODER & ~(0x3U << 10)) | (0x1U << 10);

    for (;;) {
        GPIOA_BSRR = (1U << 5);                            // set
        for (volatile uint32_t i = 0; i < 400000; i++) { __asm__("nop"); }
        GPIOA_BSRR = (1U << (5 + 16));                     // reset
        for (volatile uint32_t i = 0; i < 400000; i++) { __asm__("nop"); }
    }
}

void Default_Handler(void) {
    for (;;) { }
}
