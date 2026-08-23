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

#include "netbuf.h"
#include <string.h>

/**
 * This function is called by lwip when our pbuf is free'd
 * At this point, lwip should have no reference to the pbuf
 * anymore, so we can just release the encapsulating netbuf
 */
static void _netbuf_free(struct pbuf *p)
{
	struct uk_netbuf *nb;

	nb = lwip_pbuf_to_netbuf(p);
	uk_netbuf_free_single(nb);
}

struct uk_netbuf *lwip_alloc_netbuf(struct uk_alloc *a, size_t alloc_size,
				    size_t alloc_align, uint16_t headroom)
{
	struct uk_netbuf *b;
	struct _netbuf_pbuf *np;

	b = uk_netbuf_alloc_buf(a, alloc_size, alloc_align,
				headroom, sizeof(struct _netbuf_pbuf), NULL);
	if (unlikely(!b)) {
		LWIP_DEBUGF(PBUF_DEBUG,
			    ("Failed to allocate netbuf with encapsulated pbuf: requested headroom: %"__PRIu16", size: %"__PRIsz", alignement: %"__PRIsz"\n",
			     headroom, alloc_size, alloc_align));
		goto err_out;
	}

	/* Fill-out meta data */
	np = (struct _netbuf_pbuf *) uk_netbuf_get_priv(b);
	memset(np, 0, sizeof(struct _netbuf_pbuf));
	np->pbuf_custom.pbuf.type_internal   = PBUF_ROM;
	np->pbuf_custom.pbuf.flags           = PBUF_FLAG_IS_CUSTOM;
	np->pbuf_custom.pbuf.payload         = b->data;
	np->pbuf_custom.pbuf.ref             = 1;
	np->pbuf_custom.custom_free_function = _netbuf_free;
	np->netbuf = b;

	/*
	 * Set length of netbuf to available space so that it
	 * can be used as receive buffer
	 */
	b->len = b->buflen - headroom;

	LWIP_DEBUGF(PBUF_DEBUG,
		    ("Allocated netbuf with encapsulated pbuf %p (buflen: %"__PRIsz", headroom: %"__PRIsz")\n",
		     b, b->buflen, uk_netbuf_headroom(b)));
	return b;

err_out:
	return NULL;
}
