#![no_std]
#![no_main]

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    loop {}
}

#[no_mangle]
pub extern "C" fn _start() -> ! {
    let msg = b"Hello, World!\n";
    unsafe {
        core::arch::asm!(
            "syscall",
            in("rax") 1_u64,
            in("rdi") 1_u64,
            in("rsi") msg.as_ptr(),
            in("rdx") msg.len(),
            lateout("rax") _,
            options(nostack)
        );
        core::arch::asm!(
            "syscall",
            in("rax") 60_u64,
            in("rdi") 0_u64,
            options(noreturn)
        );
    }
}
