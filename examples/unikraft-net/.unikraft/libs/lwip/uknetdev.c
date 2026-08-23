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

#include <uk/config.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include <uk/alloc.h>
#include <uk/print.h>
#include "netif/uknetdev.h"
#include "netbuf.h"

#include "lwip/opt.h"
#include "lwip/def.h"
#include "lwip/pbuf.h"
#include "lwip/stats.h"
#include "lwip/snmp.h"
#include "lwip/sys.h"
#include "lwip/tcpip.h"
#include "lwip/ethip6.h"
#include "netif/etharp.h"
#include "netif/ethernet.h"
#include <uk/atomic.h>

#include <uk/essentials.h>

/*
 * NOTE: We do not support ETH_PAD_SIZE with uknetdev.
 *       According to https://lwn.net/Articles/89597/, the gain of doing padding
 *       seems to be negligible on the CPU architectures that we currently
 *       support and may hurt DMA engine performances that may get involved with
 *       the driver and/or hypervisor. Additionally, it will cause difficulties
 *       with the current netfront driver because the protocol does not support
 *       setting an offset for page-aligned receive buffers. Aligning the frame
 *       could then only be achieved by moving the packet bytes in memory which
 *       is obviously ways too costly. Because of this, we disable this feature
 *       completely.
 */
#if ETH_PAD_SIZE
#error ETH_PAD_SIZE is not '0'. This is not supported.
#endif

#define UKNETDEV_BPS 1000000000u
#define UKNETDEV_BUFLEN 2048

#define UKNETDEV_NETIF_NAME0 'e'
#define UKNETDEV_NETIF_NAME1 'n'

struct lwip_netdev_data {
	/*
	 * NOTE: For now we use the same allocator for RX and TX packets.
	 *       However, the uknetdev API enables us to use individual ones
	 *       per queue. The idea could be to avoid competition on
	 *       allocations which are potentially expensive. In such a case,
	 *       this lwip setup can be reconsidered.
	 */
	struct uk_alloc *pkt_a;
	struct uk_netdev_info dev_info;
#ifdef CONFIG_HAVE_SCHED
	struct uk_thread *poll_thread; /* Thread per device */
	char *_name; /* Thread name */
	struct uk_sched *sched; /* Scheduler information */
#endif /* CONFIG_HAVE_SCHED */
};

/*
 * Compile-time assertion that ensures that the uknetdev scratch pad can fit
 * `struct lwip_netdev_data`. In case this is not fulfilled, please adopt
 * LWIP_UKNETDEV_SCRATCH in `Config.uk`. The purpose of using the
 * scratch pad is performance: `struct lwip_netdev_data` is on the same
 * allocation as `struct uknetdev`. Cache-locality can be utilized better.
 */
UK_CTASSERT((sizeof(struct lwip_netdev_data)) <= CONFIG_UK_NETDEV_SCRATCH_SIZE);

#define netif_to_uknetdev(nf) \
	((struct uk_netdev *) (nf)->state)

static uint16_t netif_alloc_rxpkts(void *argp, struct uk_netbuf *nb[],
				   uint16_t count)
{
	struct lwip_netdev_data *lwip_data;
	uint16_t i;

	UK_ASSERT(argp);

	lwip_data = (struct lwip_netdev_data *) argp;

	for (i = 0; i < count; ++i) {
		nb[i] = lwip_alloc_netbuf(lwip_data->pkt_a,
					  UKNETDEV_BUFLEN,
					  lwip_data->dev_info.ioalign,
					  lwip_data->dev_info.nb_encap_rx);
		if (!nb[i]) {
			/* we run out of memory */
			break;
		}
	}

	return i;
}

static err_t uknetdev_output(struct netif *nf, struct pbuf *p)
{
	struct uk_netdev *dev;
	struct lwip_netdev_data *lwip_data;
	struct pbuf *q;
	struct uk_netbuf *nb;
	char *wpos;
	int ret;

	UK_ASSERT(nf);
	dev = netif_to_uknetdev(nf);
	UK_ASSERT(dev);
	lwip_data = (struct lwip_netdev_data *) dev->scratch_pad;
	UK_ASSERT(lwip_data);

	nb = uk_netbuf_alloc_buf(lwip_data->pkt_a,
				 UKNETDEV_BUFLEN,
				 lwip_data->dev_info.ioalign,
				 lwip_data->dev_info.nb_encap_tx,
				 0, NULL);
	if (!nb)
		return ERR_MEM;

	if (unlikely(p->tot_len > uk_netbuf_tailroom(nb))) {
		LWIP_DEBUGF(NETIF_DEBUG,
			    ("%s: %c%c%u: Cannot send %"PRIu16" bytes, too big (> %"__PRIsz")\n",
			     __func__, nf->name[0], nf->name[1], nf->num,
			     p->tot_len, uk_netbuf_tailroom(nb)));
		uk_netbuf_free_single(nb);
		return ERR_MEM;
	}

	/*
	 * Copy pbuf to netbuf
	 * NOTE: Unfortunately, lwIP seems not to support zero-copy transmit,
	 *       yet. As long as we do not have this, we have to copy.
	 */
	wpos = nb->data;
	for (q = p; q != NULL; q = q->next) {
		memcpy(wpos, q->payload, q->len);
		wpos += q->len;
	}
	nb->len = p->tot_len;

	/* Transmit packet */
	do {
		ret = uk_netdev_tx_one(dev, 0, nb);
	} while (uk_netdev_status_notready(ret));
	if (unlikely(ret < 0)) {
		LWIP_DEBUGF(NETIF_DEBUG,
			    ("%s: %c%c%u: Failed to send %"PRIu16" bytes\n",
			     __func__, nf->name[0], nf->name[1], nf->num,
			     p->tot_len));
		/*
		 * Decrease refcount again because in
		 * the error case the netdev did not consume the pbuf
		 */
		uk_netbuf_free_single(nb);
		return ERR_IF;
	}
	LWIP_DEBUGF(NETIF_DEBUG, ("%s: %c%c%u: Sent %"PRIu16" bytes\n",
				  __func__, nf->name[0], nf->name[1], nf->num,
				  p->tot_len));

	return ERR_OK;
}

static void uknetdev_input(struct uk_netdev *dev,
			   uint16_t queue_id __unused, void *argp)
{
	struct netif *nf = (struct netif *) argp;
	struct uk_netbuf *nb, *nbi;
	struct pbuf *p, *pi;
	err_t err;
	int ret;

	UK_ASSERT(dev);
	UK_ASSERT(nf);
	UK_ASSERT(nf->input);

	LWIP_DEBUGF(NETIF_DEBUG, ("%s: %c%c%u: Poll receive queue...\n",
				  __func__, nf->name[0], nf->name[1], nf->num));
	do {
		ret = uk_netdev_rx_one(dev, 0, &nb);
		LWIP_DEBUGF(NETIF_DEBUG,
			    ("%s: %c%c%u: Input status %d (%c%c%c)\n",
			     __func__, nf->name[0], nf->name[1], nf->num, ret,
			     uk_netdev_status_test_set(ret,
						       UK_NETDEV_STATUS_SUCCESS)
			     ? 'S' : '-',
			     uk_netdev_status_test_set(ret,
						       UK_NETDEV_STATUS_MORE)
			     ? 'M' : '-',
			     uk_netdev_status_test_set(ret,
						      UK_NETDEV_STATUS_UNDERRUN)
			     ? 'U' : '-'));
		if (unlikely(ret < 0)) {
			/*
			 * Ouch, an error happened. We cannot recover from it
			 * currently, so we will throw an error message, bring
			 * the interface down, and leave our loop.
			 */
			uk_pr_crit("%c%c%u: Receive error %d. Stopping interface...\n",
				   nf->name[0], nf->name[1], nf->num, ret);
			netif_set_down(nf);
			break;
		}
		if (uk_netdev_status_notready(ret)) {
			/* No (more) packets received */
			break;
		}

		LWIP_DEBUGF(NETIF_DEBUG,
			    ("%s: %c%c%u: Received %"PRIu16" bytes\n",
			     __func__, nf->name[0], nf->name[1], nf->num,
			     nb->len));

		/* Send packet to lwip */
		p = lwip_netbuf_to_pbuf(nb);
		p->payload = nb->data;
		p->tot_len = p->len = nb->len;
		/* Also chain further netbuf segments */
		nbi = nb->next;
		while (nbi) {
			pi = lwip_netbuf_to_pbuf(nbi);
			pi->payload = nbi->data;
			pi->tot_len = pi->len = nbi->len;
			pbuf_cat(p, pi);
			nbi = nbi->next;
		}
		err = nf->input(p, nf);
		if (unlikely(err != ERR_OK)) {
#if CONFIG_LWIP_THREADS && CONFIG_LIBUKNETDEV_DISPATCHERTHREADS
			/* At this point it is possible that lwIP's input queue
			 * is full or we run out of memory. In this case, we
			 * return to the scheduler and hope that lwIP's main
			 * thread is able to process some packets.
			 * Afterwards, we try it once again.
			 */
			if (err == ERR_MEM) {
				LWIP_DEBUGF(NETIF_DEBUG,
					    ("%s: %c%c%u: lwIP's input queue full: yielding and trying once again...\n",
					     __func__, nf->name[0], nf->name[1],
					     nf->num));
				uk_sched_yield();
				err = nf->input(p, nf);
				if (likely(err == ERR_OK))
					continue;
			}
#endif

			/*
			 * Drop the packet that we could not send to the stack
			 */
			uk_pr_err("%c%c%u: Failed to forward packet to lwIP: %d\n",
				  nf->name[0], nf->name[1], nf->num, err);
			uk_netbuf_free_single(nb);
		}
	} while (uk_netdev_status_more(ret));
}

/*
 * TODO: We are not exporting any error states to the user. This is inline
 * with what lwip provides for loopback and slipif interfaces. However, this
 * does not give the user any chance to react on an receive errors in their
 * mainloop. Maybe we should revisit this interface when we add support for
 * netif removal in order to let API users re-initialize interfaces.
 */
void uknetdev_poll(struct netif *nf)
{
	struct uk_netdev *dev;

	UK_ASSERT(nf);
	/*
	 * TODO: Unfortunately, checking the interface name is a weak sanity
	 * check that uknetdev_poll() is called on a netif that is driven by
	 * this driver...
	 */
	UK_ASSERT(nf->name[0] == UKNETDEV_NETIF_NAME0);
	UK_ASSERT(nf->name[1] == UKNETDEV_NETIF_NAME1);

	dev = netif_to_uknetdev(nf);
	UK_ASSERT(dev);

	uknetdev_input(dev, 0, nf);
}

#ifdef CONFIG_LWIP_NOTHREADS
void uknetdev_poll_all(void)
{
	struct netif *nf;

	/*
	 * TODO: We are going through all netifs and check the interface name.
	 * This way we are figuring out that the netif is provided by our
	 * driver. Probably we should find a better and more stable solution at
	 * some point...
	 */
	NETIF_FOREACH(nf) {
		if (nf->name[0] == UKNETDEV_NETIF_NAME0
		    && nf->name[1] == UKNETDEV_NETIF_NAME1)
			uknetdev_poll(nf);
	}
}

#else /* CONFIG_LWIP_NOTHREADS */

static __noreturn void _poll_netif(void *arg)
{
	struct netif *nf = (struct netif *) arg;

	while (1) {
		uknetdev_poll(nf);
		uk_sched_yield();
	}
}

static void uknetdev_updown(struct netif *nf)
{
	struct uk_netdev *dev;
	int ret;
	struct lwip_netdev_data  *lwip_data;

	UK_ASSERT(nf);
	dev = netif_to_uknetdev(nf);
	UK_ASSERT(dev);
	lwip_data = (struct lwip_netdev_data *)dev->scratch_pad;

	/* Enable and disable interrupts according to netif's up/down status */

	if (nf->flags & NETIF_FLAG_UP) {
		if (uk_netdev_rxintr_supported(lwip_data->dev_info.features)) {
			ret = uk_netdev_rxq_intr_enable(dev, 0);
			if (ret < 0) {
				LWIP_DEBUGF(NETIF_DEBUG,
						("%s: %c%c%u: Failed to enable rx interrupt mode on netdev %u\n",
						 __func__, nf->name[0],
						 nf->name[1],
						 nf->num,
						 uk_netdev_id_get(dev)));
			} else {
				LWIP_DEBUGF(NETIF_DEBUG,
					("%s: %c%c%u: Enabled rx interrupt mode on netdev %u\n",
						 __func__, nf->name[0],
						 nf->name[1],
						 nf->num,
						 uk_netdev_id_get(dev)));
			}

			if (ret == 1) {
				/*
				 * uk_netdev_rxq_intr_enable() told us that we
				 * need to flush the receive queue before
				 * interrupts are enabled. For this purpose
				 * we do an initial poll.
				 */
				uknetdev_poll(nf);
			}
		} else {
#ifdef CONFIG_HAVE_SCHED
			LWIP_DEBUGF(NETIF_DEBUG,
					("%s: Poll receive enabled\n",
					 __func__));
			/* Create a thread */
			lwip_data->sched = uk_sched_current();
			UK_ASSERT(lwip_data->sched);
			lwip_data->poll_thread =
				uk_sched_thread_create(lwip_data->sched,
						       _poll_netif, nf, NULL);
#else /* CONFIG_HAVE_SCHED */
			uk_pr_warn("The netdevice does not support interrupt. Ensure the netdevice is polled to receive packets");
#endif /* CONFIG_HAVE_SCHED */
		}
	} else {
		/**
		 * TODO:
		 * Cleanup the thread on stopping the network interface.
		 */
		if (uk_netdev_rxintr_supported(lwip_data->dev_info.features)) {
			uk_netdev_rxq_intr_disable(dev, 0);
			LWIP_DEBUGF(NETIF_DEBUG,
					("%s: %c%c%u: Disabled rx interrupts on netdev %u\n",
					 __func__, nf->name[0], nf->name[1],
					 nf->num, uk_netdev_id_get(dev)));
		}

	}
}
#endif /* CONFIG_LWIP_NOTHREADS */

#if CONFIG_UK_NETDEV_SCRATCH_SIZE < CONFIG_LWIP_UKNETDEV_SCRATCH
/**
 * CONFIG_UK_NETDEV_SCRATCH_SIZE is configured as the max of all scratch pad
 * requirements by the Makefile.uk macro uknetdev_scratch_mem. This value
 * should atleast be greater CONFIG_LWIP_UKNETDEV_SCRATCH
 */
#error "Insufficient Scratch memory"
#endif

/**
 * Make sure the CONFIG_LWIP_UKNETDEV_SCRATCH is still sufficient to
 * store lwip_data.
 */
UK_CTASSERT(sizeof(struct lwip_netdev_data) <= CONFIG_LWIP_UKNETDEV_SCRATCH);

err_t uknetdev_init(struct netif *nf)
{
	struct uk_alloc *a = NULL;
	struct uk_netdev *dev;
	struct uk_netdev_conf dev_conf;
	struct uk_netdev_rxqueue_conf rxq_conf;
	struct uk_netdev_txqueue_conf txq_conf = {0};
	struct lwip_netdev_data *lwip_data;
	const struct uk_hwaddr *hwaddr;
	unsigned int i;
	int ret;

	UK_ASSERT(nf);
	dev = netif_to_uknetdev(nf);
	UK_ASSERT(dev);

	lwip_data = (struct lwip_netdev_data *)dev->scratch_pad;

	LWIP_ASSERT("uknetdev needs an input callback (netif_input or tcpip_input)",
		    nf->input != NULL);

	/* Netdev has to be in unconfigured state */
	if (uk_netdev_state_get(dev) != UK_NETDEV_UNCONFIGURED) {
		LWIP_DEBUGF(NETIF_DEBUG,
			    ("%s: Netdev %u not in uncofigured state\n",
			     __func__, uk_netdev_id_get(dev)));
		return ERR_ISCONN;
	}

	/* Interface name, the interface number (nf->num) is assigned by lwip */
	nf->name[0] = UKNETDEV_NETIF_NAME0;
	nf->name[1] = UKNETDEV_NETIF_NAME1;

	/*
	 * Bring up uknetdev
	 * Note: We use the default allocator for setting up the rx/tx queues
	 */
	/* TODO: In case the device initialization should happen manually before
	 *       attaching to lwip, we require another init function that skips
	 *       this initialization steps.
	 */
	a = uk_alloc_get_default();
	if (!a)
		return ERR_MEM;

	/* Get device information */
	uk_netdev_info_get(dev, &lwip_data->dev_info);
	if (!lwip_data->dev_info.max_rx_queues
	    || !lwip_data->dev_info.max_tx_queues)
		return ERR_IF;
#if CONFIG_LWIP_UKNETDEV_POLLONLY
	/* Unset receive interrupt support: We force polling mode */
	lwip_data->dev_info.features &= ~UK_NETDEV_F_RXQ_INTR;
#endif /* CONFIG_LWIP_UKNETDEV_POLLONLY */
	lwip_data->pkt_a = a;

	LWIP_DEBUGF(NETIF_DEBUG,
		    ("%s: %c%c%u: Headroom rx:%"PRIu16", tx:%"PRIu16"; I/O align: 0x%"PRIx16"\n",
		     __func__, nf->name[0], nf->name[1], nf->num,
		     lwip_data->dev_info.nb_encap_rx,
		     lwip_data->dev_info.nb_encap_tx,
		     lwip_data->dev_info.ioalign));

	/*
	 * Device configuration,
	 * we want to use just one queue for each direction
	 */
	dev_conf.nb_rx_queues = 1;
	dev_conf.nb_tx_queues = 1;
	dev_conf.lro = !!(lwip_data->dev_info.features & UK_NETDEV_F_LRO);
	ret = uk_netdev_configure(dev, &dev_conf);
	if (ret < 0) {
		LWIP_DEBUGF(NETIF_DEBUG,
			    ("%s: %c%c%u: Failed to configure netdev %u\n",
			     __func__, nf->name[0], nf->name[1], nf->num,
			     uk_netdev_id_get(dev)));
		return ERR_IF;
	}

	/*
	 * Receive queue,
	 * use driver default descriptors
	 */
	rxq_conf.a = a;
	rxq_conf.alloc_rxpkts = netif_alloc_rxpkts;
	rxq_conf.alloc_rxpkts_argp = lwip_data;
#ifdef CONFIG_LWIP_NOTHREADS
	/*
	 * In mainloop mode, we will not use interrupts.
	 */
	rxq_conf.callback = NULL;
	rxq_conf.callback_cookie = NULL;
#else  /* CONFIG_LWIP_NOTHREADS */
	rxq_conf.callback = uknetdev_input;
	rxq_conf.callback_cookie = nf;
#ifdef CONFIG_LIBUKNETDEV_DISPATCHERTHREADS
	rxq_conf.s = uk_sched_current();
	if (!rxq_conf.s)
		return ERR_IF;

#endif /* CONFIG_LIBUKNETDEV_DISPATCHERTHREADS */
#endif /* CONFIG_LWIP_NOTHREADS */
	ret = uk_netdev_rxq_configure(dev, 0, 0, &rxq_conf);
	if (ret < 0) {
		LWIP_DEBUGF(NETIF_DEBUG,
			    ("%s: %c%c%u: Failed to configure rx queue of netdev %u\n",
			     __func__, nf->name[0], nf->name[1], nf->num,
			     uk_netdev_id_get(dev)));
		return ERR_IF;
	}

	/*
	 * Transmit queue,
	 * use driver default descriptors
	 */
	txq_conf.a = a;
	ret = uk_netdev_txq_configure(dev, 0, 0, &txq_conf);
	if (ret < 0) {
		LWIP_DEBUGF(NETIF_DEBUG,
			    ("%s: %c%c%u: Failed to configure tx queue of netdev %u\n",
			     __func__, nf->name[0], nf->name[1], nf->num,
			     uk_netdev_id_get(dev)));
		return ERR_IF;
	}

	/* Start interface */
	ret = uk_netdev_start(dev);
	if (ret < 0) {
		LWIP_DEBUGF(NETIF_DEBUG,
			    ("%s: %c%c%u: Failed to start netdev %u\n",
			     __func__, nf->name[0], nf->name[1], nf->num,
			     uk_netdev_id_get(dev)));
		return ERR_IF;
	}

	/* Driver callbacks */
#if LWIP_IPV4
	nf->output = etharp_output;
#endif /* LWIP_IPV4 */
#if LWIP_IPV6
	nf->output_ip6 = ethip6_output;
#endif /* LWIP_IPV6 */
	nf->linkoutput = uknetdev_output;

	/* TODO: Set remove callback */

	/* Device capabilities */
	netif_set_flags(nf, (NETIF_FLAG_BROADCAST
			     | NETIF_FLAG_ETHARP
			     | NETIF_FLAG_LINK_UP));
	LWIP_DEBUGF(NETIF_DEBUG,
		    ("%s: %c%c%u: flags: %"PRIx8"\n",
		     __func__, nf->name[0], nf->name[1], nf->num, nf->flags));

#if LWIP_CHECKSUM_CTRL_PER_NETIF
	/*
	 * Checksum settings
	 * TODO: libuknetdev does not support checksum capabilities yet.
	 *       Because of this, we need to calculate the checksum for every
	 *       outgoing packet in software. We assume that we receive packets
	 *       from a virtual interface, so the host was doing a check for us
	 *       already. In case of guest-to-guest communication, the checksum
	 *       field may be incorrect because the other guest expects that the
	 *       host is offloading the calculation to hardware as soon as a
	 *       packet leaves the physical host machine. At this point, the
	 *       best we can do is not to check any checksums on incoming
	 *       traffic and assume everything is fine.
	 */
	NETIF_SET_CHECKSUM_CTRL(nf, (NETIF_CHECKSUM_GEN_IP
				     | NETIF_CHECKSUM_GEN_UDP
				     | NETIF_CHECKSUM_GEN_TCP
				     | NETIF_CHECKSUM_GEN_ICMP
				     | NETIF_CHECKSUM_GEN_ICMP6));
	LWIP_DEBUGF(NETIF_DEBUG,
		    ("%s: %c%c%u: chksum_flags: %"PRIx16"\n",
		     __func__, nf->name[0], nf->name[1], nf->num,
		     nf->chksum_flags));
#endif /* LWIP_CHECKSUM_CTRL_PER_NETIF */

	/* MAC address */
	UK_ASSERT(NETIF_MAX_HWADDR_LEN >= UK_NETDEV_HWADDR_LEN);
	hwaddr = uk_netdev_hwaddr_get(dev);
	UK_ASSERT(hwaddr);
	nf->hwaddr_len = UK_NETDEV_HWADDR_LEN;
	for (i = 0; i < UK_NETDEV_HWADDR_LEN; ++i)
		nf->hwaddr[i] = hwaddr->addr_bytes[i];
#if UK_NETDEV_HWADDR_LEN == 6
	LWIP_DEBUGF(NETIF_DEBUG,
		    ("%s: %c%c%u: Hardware address: %02"PRIx8":%02"PRIx8":%02"PRIx8":%02"PRIx8":%02"PRIx8":%02"PRIx8"\n",
		     __func__, nf->name[0], nf->name[1], nf->num,
		     nf->hwaddr[0], nf->hwaddr[1], nf->hwaddr[2],
		     nf->hwaddr[3], nf->hwaddr[4], nf->hwaddr[5]));
#else /* UK_NETDEV_HWADDR_LEN */
	LWIP_DEBUGF(NETIF_DEBUG,
		    ("%s: %c%c%u: Hardware address set\n",
		     __func__, nf->name[0], nf->name[1], nf->num));
#endif /* UK_NETDEV_HWADDR_LEN */

	/* Maximum transfer unit */
	nf->mtu = uk_netdev_mtu_get(dev);
	UK_ASSERT(nf->mtu);
	LWIP_DEBUGF(NETIF_DEBUG,
		    ("%s: %c%c%u: MTU: %u\n",
		     __func__, nf->name[0], nf->name[1], nf->num,
		     nf->mtu));

#ifndef CONFIG_LWIP_NOTHREADS
	/*
	 * We will use the status update callback to enable and disabled
	 * receive queue interrupts
	 */
	netif_set_status_callback(nf, uknetdev_updown);
#endif /* !CONFIG_LWIP_NOTHREADS */

	/*
	 * Initialize the snmp variables and counters inside the struct netif.
	 * The last argument is the link speed, in units of bits per second.
	 */
	NETIF_INIT_SNMP(nf, snmp_ifType_ethernet_csmacd, UKNETDEV_BPS);
	LWIP_DEBUGF(NETIF_DEBUG,
		    ("%s: %c%c%u: Link speed: %"PRIu32" bps\n",
		     __func__, nf->name[0], nf->name[1], nf->num,
		     UKNETDEV_BPS));

	return ERR_OK;
}

#if CONFIG_LWIP_NOTHREADS
#define NETIF_INPUT ethernet_input
#else /* CONFIG_LWIP_NOTHREADS */
#define NETIF_INPUT tcpip_input
#endif /*CONFIG_LWIP_NOTHREADS */

struct netif *uknetdev_addif(struct uk_netdev *n
#if LWIP_IPV4
			     ,
			     const ip4_addr_t *ipaddr,
			     const ip4_addr_t *netmask,
			     const ip4_addr_t *gw,
#endif /* LWIP_IPV4 */
			     const char *hostname
	)
{
	/*
	 * This pointer and UK_READ_ONCE on it is an ugly workaround
	 * against a pretty weird problem. Without it, the last
	 * parameter of netif_add passed as NULL. It seems to be a
	 * build time problem because:
	 *
	 * - Moving "input" parameter to the first positions helps
	 * - Removing one parameter helps. Seems does not matter which
	 * - An extra parameter added after "input" works well. And
	 *   input is still NULL in this case
	 * - Swapping "init" and "input" helps
	 */
	static const void *pethernet_input = NETIF_INPUT;
	struct netif *nf;
	struct netif *ret;

	nf = mem_calloc(1, sizeof(*nf));
	if (!nf)
		return NULL;

	ret = netif_add(nf,
#if LWIP_IPV4
			ipaddr, netmask, gw,
#endif /* LWIP_IPV4 */
			n, uknetdev_init, UK_READ_ONCE(pethernet_input));
	UK_ASSERT(nf->input);

	if (!ret) {
		mem_free(nf);
		return NULL;
	}

	if (hostname) {
		netif_set_hostname(nf, hostname);
#if CONFIG_LIBPOSIX_SYSINFO
		sethostname(hostname, strlen(hostname));
#endif /* CONFIG_LIBPOSIX_SYSINFO */
	}

	return ret;
}
