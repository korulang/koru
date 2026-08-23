/* SPDX-License-Identifier: BSD-3-Clause */
/*
 * Authors: Simon Kuenzer <simon.kuenzer@neclab.eu>
 *
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

#ifndef _LWIP_NETBUF_
#define _LWIP_NETBUF_

#include <uk/config.h>
#include "lwip/opt.h"

#if CONFIG_LWIP_UKNETDEV /* do not define anything if not configured for use */

#include "lwip/pbuf.h"
#include <uk/netbuf.h>
#include <uk/alloc.h>
#include <uk/assert.h>
#include <uk/essentials.h>

struct _netbuf_pbuf {
	struct pbuf_custom pbuf_custom;
	struct uk_netbuf *netbuf;
};

/**
 * Allocates a netbuf that embeds a pbuf. Both will point
 * to the same packet data buffer.
 * Such buffers are used to implement zero-copy receive with the
 * uknetdev API.
 * NOTE: Make sure that netbuf and pbuf meta data are kept in sync
 * before handing over the embedded pbuf to the network stack.
 */
struct uk_netbuf *lwip_alloc_netbuf(struct uk_alloc *a, size_t alloc_size,
				    size_t alloc_align, uint16_t headroom);

/**
 * Returns the reference of the embedded pbuf of a netbuf
 */
static inline struct pbuf *lwip_netbuf_to_pbuf(struct uk_netbuf *b)
{
	struct _netbuf_pbuf *np;

	UK_ASSERT(b);
	np = (struct _netbuf_pbuf *) uk_netbuf_get_priv(b);
	UK_ASSERT(np);

	/*
	 * Sanity check: We use the PBUF_CUSTOM_FLAG as a way
	 * to identify lwip_alloc_netbuf() was allocating this pbuf.
	 * We know it may fail but it is still better than nothing.
	 */
	UK_ASSERT(np->pbuf_custom.pbuf.flags & PBUF_FLAG_IS_CUSTOM);

	return &np->pbuf_custom.pbuf;
}

/**
 * Returns the reference of the encapsulating netbuf of a pbuf
 */
static inline struct uk_netbuf *lwip_pbuf_to_netbuf(struct pbuf *p)
{
	struct pbuf_custom *pc;
	struct _netbuf_pbuf *np;

	UK_ASSERT(p);
	UK_ASSERT(p->flags & PBUF_FLAG_IS_CUSTOM);

	pc = (struct pbuf_custom *) __containerof(p,  struct pbuf_custom, pbuf);
	UK_ASSERT(pc);
	np = (struct _netbuf_pbuf *)  __containerof(pc, struct _netbuf_pbuf,
						    pbuf_custom);
	UK_ASSERT(np);
	return np->netbuf;
}

#endif /* CONFIG_LWIP_UKNETDEV */
#endif /* _LWIP_NETBUF_ */
