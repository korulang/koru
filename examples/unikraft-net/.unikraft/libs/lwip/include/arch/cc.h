/*
 * lwip/arch/cc.h
 *
 * Compiler-specific types and macros for lwIP running on mini-os
 *
 * Tim Deegan <Tim.Deegan@eu.citrix.net>, July 2007
 * Simon Kuenzer <Simon.Kuenzer@neclab.eu>, October 2014
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY AUTHOR AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL AUTHOR OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

#ifndef __LWIP_ARCH_CC_H__
#define __LWIP_ARCH_CC_H__

#include <uk/arch/types.h>
#include <uk/print.h>
#include <uk/lcpu.h>
#include <uk/assert.h>
#include <uk/random.h>
#include <errno.h>
#include <stdarg.h>

#define S16_F __PRIs16
#define U16_F __PRIu16
#define X16_F __PRIx16
#define S32_F __PRIs32
#define U32_F __PRIu32
#define X32_F __PRIx32
#define SZT_F __PRIsz

#define BUG() UK_BUG()

/* 32 bit checksum calculation */
#define LWIP_CHKSUM_ALGORITHM 3

/*
 * Disable padding on Ethernet frames
 * (not supported by uknetdev driver)
 */
#define ETH_PAD_SIZE 0

/* rand */
#define LWIP_RAND() ({						\
	int res;						\
	__u32 x;						\
	res = uk_random_fill_buffer(&x, sizeof(x));		\
	if (unlikely(res))					\
		UK_CRASH("Could not obtain randomness (%d)",	\
			 res);					\
	x;							\
})

/* compiler hints for packing lwip's structures */
#define PACK_STRUCT_FIELD(_x)  _x
#define PACK_STRUCT_STRUCT     __attribute__ ((packed))
#define PACK_STRUCT_BEGIN
#define PACK_STRUCT_END

#define LWIP_PLATFORM_DIAG(_x) \
	({ uk_pr_debug _x; })

#if CONFIG_LIBUKDEBUG_ENABLE_ASSERT
#define LWIP_PLATFORM_ASSERT(_x) \
	do { uk_pr_crit(_x); UK_BUG(); } while (0)
#else
#define LWIP_PLATFORM_ASSERT(_x) \
	do { } while (0)
#endif /* CONFIG_LIBUKDEBUG_ENABLE_ASSERT */

/* lightweight synchronization mechanisms */
#define SYS_ARCH_DECL_PROTECT(_x) \
	unsigned long (_x)

#define SYS_ARCH_PROTECT(_x) \
	({ (_x) = uk_lcpu_save_irqf(); })

#define SYS_ARCH_UNPROTECT(_x) \
	uk_lcpu_restore_irqf((_x))

#endif /* __LWIP_ARCH_CC_H__ */
