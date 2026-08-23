/* SPDX-License-Identifier: BSD-3-Clause */
/*
 * Copyright (c) 2019, NEC Laboratories Europe GmbH, NEC Corporation.
 *                     All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 * 3. Neither the name of the copyright holder nor the names of its
 *    contributors may be used to endorse or promote products derived from
 *    this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */

#include <uk/mbox.h>
#include <uk/arch/time.h>
#include <lwip/sys.h>
#include <lwipopts.h>

#include <uk/essentials.h>

/* Creates an empty mailbox. */
err_t sys_mbox_new(sys_mbox_t *mbox, int size)
{
	if (size <= 0) {
		LWIP_DEBUGF(SOCKETS_DEBUG,
			    ("Mailbox created with default size.\n"));
		size = TCPIP_MBOX_SIZE;
	}

	UK_ASSERT(mbox);
	mbox->a = uk_alloc_get_default();
	UK_ASSERT(mbox->a);
	mbox->mbox = uk_mbox_create(mbox->a, size);
	if (!mbox->mbox)
		return ERR_MEM;
	mbox->valid = 1;
	return ERR_OK;
}

int sys_mbox_valid(sys_mbox_t *mbox)
{
	if (!mbox)
		return 0;
	return (mbox->valid == 1);
}

void sys_mbox_set_invalid(sys_mbox_t *mbox)
{
	UK_ASSERT(mbox);
	mbox->valid = 0;
}

/**
 * Deallocates a mailbox. If there are messages still present in the
 * mailbox when the mailbox is deallocated, it is an indication of a
 * programming error in lwIP and the developer should be notified.
 */
void sys_mbox_free(sys_mbox_t *mbox)
{
	UK_ASSERT(sys_mbox_valid(mbox));

	uk_mbox_free(mbox->a, mbox->mbox);
	sys_mbox_set_invalid(mbox);
}

/* Posts "msg" to the mailbox, NULL msg's are not supported */
void sys_mbox_post(sys_mbox_t *mbox, void *msg)
{
	UK_ASSERT(sys_mbox_valid(mbox));

	if (!msg) {
		uk_pr_debug("Ignored posting NULL message");
		return;
	}

	uk_mbox_post(mbox->mbox, msg);
}

/* Try to post "msg" to the mailbox. */
err_t sys_mbox_trypost(sys_mbox_t *mbox, void *msg)
{
	UK_ASSERT(sys_mbox_valid(mbox));

	if (uk_mbox_post_try(mbox->mbox, msg) < 0)
		return ERR_MEM;
	return ERR_OK;
}

/* Try to post the "msg" to the mailbox from ISR context. */
err_t sys_mbox_trypost_fromisr(sys_mbox_t *mbox, void *msg)
{
	UK_ASSERT(sys_mbox_valid(mbox));

	if (uk_mbox_post_try(mbox->mbox, msg) < 0)
		return ERR_MEM;
	return ERR_OK;
}

/**
 * Blocks the thread until a message arrives in the mailbox, but does
 * not block the thread longer than "timeout" milliseconds (similar to
 * the sys_arch_sem_wait() function). The "msg" argument is a result
 * parameter that is set by the function (i.e., by doing "*msg =
 * ptr"). The "msg" parameter maybe NULL to indicate that the message
 * should be dropped.
 *
 * The return values are the same as for the sys_arch_sem_wait() function:
 * Number of milliseconds spent waiting or SYS_ARCH_TIMEOUT if there was a
 * timeout.
 */
u32_t sys_arch_mbox_fetch(sys_mbox_t *mbox, void **msg, u32_t timeout)
{
	__nsec nsret;

	UK_ASSERT(sys_mbox_valid(mbox));

	if (timeout == 0) {
		nsret = ukplat_monotonic_clock();
		uk_mbox_recv(mbox->mbox, msg);
		nsret = ukplat_monotonic_clock() - nsret;
	} else {
		nsret = uk_mbox_recv_to(mbox->mbox, msg,
					ukarch_time_msec_to_nsec((__nsec)
								 timeout));
		if (unlikely(nsret == __NSEC_MAX))
			return SYS_ARCH_TIMEOUT;
	}
	return (u32_t) ukarch_time_nsec_to_msec(nsret);
}

/**
 * This is similar to sys_arch_mbox_fetch, however if a message is not
 * present in the mailbox, it immediately returns with the code
 * SYS_MBOX_EMPTY. On success 0 is returned.
 *
 * To allow for efficient implementations, this can be defined as a
 * function-like macro in sys_arch.h instead of a normal function. For
 * example, a naive implementation could be:
 *   #define sys_arch_mbox_tryfetch(mbox,msg) \
 *     sys_arch_mbox_fetch(mbox,msg,1)
 * although this would introduce unnecessary delays.
 */
u32_t sys_arch_mbox_tryfetch(sys_mbox_t *mbox, void **msg)
{
	void *rmsg;

	UK_ASSERT(sys_mbox_valid(mbox));

	if (uk_mbox_recv_try(mbox->mbox, &rmsg) < 0)
		return SYS_MBOX_EMPTY;

	if (msg)
		*msg = rmsg;
	return 0;
}
