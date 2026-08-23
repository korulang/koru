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

#ifndef _LWIP_UKNETDEV_
#define _LWIP_UKNETDEV_

#include <uk/config.h>
#include "lwip/opt.h"

#if CONFIG_LWIP_UKNETDEV /* do not define anything if not configured for use */

#include "lwip/netif.h"
#include "lwip/ip_addr.h"
#include "netif/ethernet.h"
#include <uk/netdev.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Configures and brings up net device */
err_t uknetdev_init(struct netif *nf);

/*
 * Note: When threading mode is enabled, only uknetdev netifs that do not
 * support receive interrupts should be polled for packets.
 */
void uknetdev_poll(struct netif *nf);

#ifdef CONFIG_LWIP_NOTHREADS
void uknetdev_poll_all(void);
#endif /* CONFIG_LWIP_NOTHREADS */

struct netif *uknetdev_addif(struct uk_netdev *n
#if LWIP_IPV4
			     ,
			     const ip4_addr_t *ipaddr,
			     const ip4_addr_t *netmask,
			     const ip4_addr_t *gw,
#endif /* LWIP_IPV4 */
			     const char *hostname
	);

#ifdef __cplusplus
}
#endif

#endif /* CONFIG_LWIP_UKNETDEV */
#endif /* _LWIP_NETDEV_ */
