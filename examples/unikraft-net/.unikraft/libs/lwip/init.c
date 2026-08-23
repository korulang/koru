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
#include <string.h>
#include "lwip/opt.h"
#include "lwip/tcpip.h"
#include "lwip/init.h"
#include "lwip/dns.h"
#include "lwip/dhcp.h"
#include "lwip/inet.h"
#if CONFIG_LWIP_NOTHREADS
#include "lwip/timeouts.h"
#endif /* CONFIG_LWIP_NOTHREADS */
#if !CONFIG_LWIP_NOTHREADS || CONFIG_LWIP_WAITIFACE
#include <uk/semaphore.h>
#endif /* !CONFIG_LWIP_NOTHREADS || CONFIG_LWIP_WAITIFACE */
#if CONFIG_LWIP_WAITIFACE
#include <uk/arch/time.h>
#endif /* CONFIG_LWIP_WAITIFACE */
#include <errno.h>
#include <uk/netdev_core.h>
#include "netif/uknetdev.h"
#include <uk/init.h>

#if LWIP_NETIF_EXT_STATUS_CALLBACK && CONFIG_LWIP_NETIF_STATUS_PRINT
#include <stdio.h>

static void _netif_status_print(struct netif *nf, netif_nsc_reason_t reason,
				const netif_ext_callback_args_t *args)
{
	if (reason & LWIP_NSC_NETIF_ADDED)
		printf("%c%c%u: Added\n",
		       nf->name[0], nf->name[1], nf->num);
	if (reason & LWIP_NSC_NETIF_REMOVED)
		printf("%c%c%u: Removed\n",
		       nf->name[0], nf->name[1], nf->num);
	if (reason & LWIP_NSC_LINK_CHANGED)
		printf("%c%c%u: Link is %s\n",
		       nf->name[0], nf->name[1], nf->num,
		       args->link_changed.state ? "up" : "down");
	if (reason & LWIP_NSC_STATUS_CHANGED)
		printf("%c%c%u: Interface is %s\n",
		       nf->name[0], nf->name[1], nf->num,
		       args->status_changed.state ? "up" : "down");

#if LWIP_IPV4
	if ((reason & LWIP_NSC_IPV4_SETTINGS_CHANGED)
	    || (reason & LWIP_NSC_IPV4_ADDRESS_CHANGED)
	    || (reason & LWIP_NSC_IPV4_NETMASK_CHANGED)
	    || (reason & LWIP_NSC_IPV4_GATEWAY_CHANGED)) {
		char str_ip4_addr[17];
		char str_ip4_mask[17];
		char str_ip4_gw[17];

		ipaddr_ntoa_r(&nf->ip_addr, str_ip4_addr, sizeof(str_ip4_addr));
		ipaddr_ntoa_r(&nf->netmask, str_ip4_mask, sizeof(str_ip4_mask));
		ipaddr_ntoa_r(&nf->gw,      str_ip4_gw,   sizeof(str_ip4_gw));

		printf("%c%c%u: Set IPv4 address %s mask %s gw %s\n",
		       nf->name[0], nf->name[1], nf->num,
		       str_ip4_addr, str_ip4_mask, str_ip4_gw);
	}
#endif /* LWIP_IPV4 */

#if LWIP_IPV6
	if (reason & LWIP_NSC_IPV6_SET)
		printf("%c%c%u: Set IPv6 address %"__PRIs8": %s (state %"__PRIu8")\n",
		       nf->name[0], nf->name[1], nf->num,
		       args->ipv6_set.addr_index,
		       ipaddr_ntoa(&nf->ip6_addr[args->ipv6_set.addr_index]),
		       nf->ip6_addr_state[args->ipv6_set.addr_index]);
	if (reason & LWIP_NSC_IPV6_ADDR_STATE_CHANGED)
		printf("%c%c%u: Set IPv6 address %"__PRIs8": %s (state %"__PRIu8")\n",
		       nf->name[0], nf->name[1], nf->num,
		       args->ipv6_set.addr_index,
		       ipaddr_ntoa(&nf->ip6_addr[
				     args->ipv6_addr_state_changed.addr_index]),
		       nf->ip6_addr_state[
				     args->ipv6_addr_state_changed.addr_index]);
#endif /* LWIP_IPV6 */
}

NETIF_DECLARE_EXT_CALLBACK(netif_status_print)
#endif /* LWIP_NETIF_EXT_STATUS_CALLBACK && CONFIG_LWIP_NETIF_STATUS_PRINT */

void sys_init(void)
{
	/*
	 * This function is called before the any other sys_arch-function is
	 * called and is meant to be used to initialize anything that has to
	 * be up and running for the rest of the functions to work. for
	 * example to set up a pool of semaphores.
	 */
}

#if !CONFIG_LWIP_NOTHREADS
static struct uk_semaphore _lwip_init_sem;

static void _lwip_init_done(void *arg __unused)
{
	uk_semaphore_up(&_lwip_init_sem);
}
#endif /* !CONFIG_LWIP_NOTHREADS */

static unsigned int lwip_netif_attached = 0;

#if CONFIG_LWIP_WAITIFACE
static struct uk_semaphore _lwip_waitif_sem;
NETIF_DECLARE_EXT_CALLBACK(lwip_netif_waitif);

static void _lwip_netif_waitif(struct netif *nf, netif_nsc_reason_t reason,
			       const netif_ext_callback_args_t *args);
#endif /* CONFIG_LWIP_WAITIFACE */

/*
 * This function initializing the lwip network stack
 */
static int liblwip_init(struct uk_init_ctx *ictx __unused)
{
#if CONFIG_LWIP_UKNETDEV && CONFIG_LWIP_AUTOIFACE
	unsigned int devid;
	struct uk_netdev *dev;
	struct netif *nf;
	const char  __maybe_unused *strcfg;
	uint16_t  __maybe_unused int16cfg;
	int is_first_nf;
	int ret;
#if LWIP_IPV4
	ip4_addr_t ip4;
	ip4_addr_t *ip4_arg;
	ip4_addr_t mask4;
	ip4_addr_t *mask4_arg;
	ip4_addr_t gw4;
	ip4_addr_t *gw4_arg;
	const char *hostname_arg;
#if LWIP_DNS
	ip_addr_t dns;
	unsigned int nb_dns4 = 0;
#endif /* LWIP_DNS */
#endif /* LWIP_IPV4 */
#endif /* CONFIG_LWIP_UKNETDEV && CONFIG_LWIP_AUTOIFACE */

	uk_pr_info("Initializing lwip\n");
#if !CONFIG_LWIP_NOTHREADS
	uk_semaphore_init(&_lwip_init_sem, 0);
#endif /* !CONFIG_LWIP_NOTHREADS */
#if CONFIG_LWIP_WAITIFACE
	uk_semaphore_init(&_lwip_waitif_sem, 0);
#endif /* CONFIG_LWIP_WAITIFACE */

#if CONFIG_LWIP_NOTHREADS
	lwip_init();
#else /* CONFIG_LWIP_NOTHREADS */
	tcpip_init(_lwip_init_done, NULL);

	/* Wait until stack is booted */
	uk_semaphore_down(&_lwip_init_sem);
#endif /* CONFIG_LWIP_NOTHREADS */

#if LWIP_NETIF_EXT_STATUS_CALLBACK && CONFIG_LWIP_NETIF_STATUS_PRINT
	/* Add print callback for netif state changes */
	netif_add_ext_callback(&netif_status_print, _netif_status_print);
#endif /* LWIP_NETIF_EXT_STATUS_CALLBACK && CONFIG_LWIP_NETIF_STATUS_PRINT */
#if CONFIG_LWIP_WAITIFACE
	netif_add_ext_callback(&lwip_netif_waitif, _lwip_netif_waitif);
#endif /* CONFIG_LWIP_WAITIFACE */

#if CONFIG_LWIP_UKNETDEV && CONFIG_LWIP_AUTOIFACE
	is_first_nf = 1;

	for (devid = 0; devid < uk_netdev_count(); ++devid) {
		dev = uk_netdev_get(devid);
		if (!dev)
			continue;
		if (uk_netdev_state_get(dev) != UK_NETDEV_UNCONFIGURED
		    && uk_netdev_state_get(dev) != UK_NETDEV_UNPROBED) {
			uk_pr_info("Skipping to add network device %u to lwIP: Not in unconfigured state\n",
				    devid);
			continue;
		}

		if (uk_netdev_state_get(dev) == UK_NETDEV_UNPROBED) {
			ret = uk_netdev_probe(dev);
			if (ret < 0) {
				uk_pr_err("Failed to probe features of network device %u: %d; skipping device...\n",
					  devid, ret);
				continue;
			}
		}

		/* Here, the device has to be in unconfigured state */
		UK_ASSERT(uk_netdev_state_get(dev) == UK_NETDEV_UNCONFIGURED);

		uk_pr_info("Attach network device %u to lwIP...\n",
			   devid);

#if LWIP_IPV4
		ip4_arg      = NULL;
		mask4_arg    = NULL;
		gw4_arg      = NULL;
		hostname_arg = NULL;

		/* CIDR (IP and mask) */
		strcfg = uk_netdev_einfo_get(dev, UK_NETDEV_IPV4_CIDR);
		if (strcfg) {
			long maskbits;
			char str_ipaddr[16]; /* Can hold "255.255.255.255\0" */
			size_t strlen_ipaddr;
			const char *str_maskbits;

			str_maskbits = strchr(strcfg, '/');
			if (!str_maskbits) {
				uk_pr_err("Failed to find maskbits separator of CIDR IP address: %s\n",
					  strcfg);
				goto ipv4_legacy;
			}
			strlen_ipaddr = (size_t) str_maskbits - (size_t) strcfg;
			if (strlen_ipaddr > ARRAY_SIZE(str_ipaddr)) {
				uk_pr_err("IP address length out of range: %s\n",
					  str_ipaddr);
				goto ipv4_legacy;
			}
			strncpy(str_ipaddr, strcfg, strlen_ipaddr);
			str_ipaddr[strlen_ipaddr] = '\0';
			str_maskbits++; /* skip '/' */

			if (ip4addr_aton(str_ipaddr, &ip4) != 1) {
				uk_pr_err("Error converting IP address: %s\n",
					  str_ipaddr);
				goto ipv4_legacy;
			}
			maskbits = strtol(str_maskbits, NULL, 10);
			if (maskbits < 0 || maskbits > 32) {
				uk_pr_err("Mask bits out of range: %s\n",
					  str_ipaddr);
				goto ipv4_legacy;
			}
			ip4_addr_set_u32(&mask4,
					 lwip_htonl(~(__u32)((1LL <<
							(32 - maskbits)) - 1)));

			uk_pr_debug("Detected IP from IPv4 CIDR: %s\n",
				    str_ipaddr);
			uk_pr_debug("Detected mask bits from IPv4 CIDR: %ld\n",
				    maskbits);
			ip4_arg = &ip4;
			mask4_arg = &mask4;
			goto ipv4_gw;
		}

ipv4_legacy:
		/* IP */
		strcfg = uk_netdev_einfo_get(dev, UK_NETDEV_IPV4_ADDR);
		if (strcfg) {
			if (ip4addr_aton(strcfg, &ip4) != 1) {
				uk_pr_err("Error converting IP address: %s\n",
						strcfg);
				goto no_conf;
			}
		} else
			goto no_conf;
		ip4_arg = &ip4;

		/* mask */
		strcfg = uk_netdev_einfo_get(dev, UK_NETDEV_IPV4_MASK);
		if (strcfg) {
			if (ip4addr_aton(strcfg, &mask4) != 1) {
				uk_pr_err("Error converting net mask: %s\n",
						strcfg);
				goto no_conf;
			}
		} else
			/* default mask */
			ip4_addr_set_u32(&mask4, lwip_htonl(IP_CLASSC_NET));
		mask4_arg = &mask4;

ipv4_gw:
		/* gateway */
		strcfg = uk_netdev_einfo_get(dev, UK_NETDEV_IPV4_GW);
		if (strcfg) {
			if (ip4addr_aton(strcfg, &gw4) != 1) {
				uk_pr_err("Error converting gateway: %s\n",
						strcfg);
				goto no_conf;
			}
			gw4_arg = &gw4;
		}

no_conf:
		/* hostname */
		strcfg = uk_netdev_einfo_get(dev, UK_NETDEV_IPV4_HOSTNAME);
		if (strcfg)
			hostname_arg = strcfg;

		nf = uknetdev_addif(dev, ip4_arg, mask4_arg, gw4_arg,
				    hostname_arg);
#else /* LWIP_IPV4 */
		/*
		 * TODO: Add support for IPv6 device configuration from
		 * netdev's econf interface
		 */

		nf = uknetdev_addif(dev, NULL);
#endif /* LWIP_IPV4 */
		if (!nf) {
			uk_pr_err("Failed to attach network device %u to lwIP\n",
				  devid);
			continue;
		}
		lwip_netif_attached += 1;

		/* Print hardware address */
		if (nf->hwaddr_len == 6) {
			uk_pr_info("%c%c%u: Hardware address: %02"PRIx8":%02"PRIx8":%02"PRIx8":%02"PRIx8":%02"PRIx8":%02"PRIx8"\n",
				   nf->name[0], nf->name[1], nf->num,
				   nf->hwaddr[0], nf->hwaddr[1], nf->hwaddr[2],
				   nf->hwaddr[3], nf->hwaddr[4], nf->hwaddr[5]);
		}

#if LWIP_CHECKSUM_CTRL_PER_NETIF
		uk_pr_info("%c%c%u: Check checksums:",
			   nf->name[0], nf->name[1], nf->num);
		IF__NETIF_CHECKSUM_ENABLED(nf, NETIF_CHECKSUM_CHECK_IP) {
			uk_pr_info(" IP");
		}
		IF__NETIF_CHECKSUM_ENABLED(nf, NETIF_CHECKSUM_CHECK_UDP) {
			uk_pr_info(" UDP");
		}
		IF__NETIF_CHECKSUM_ENABLED(nf, NETIF_CHECKSUM_CHECK_TCP) {
			uk_pr_info(" TCP");
		}
		IF__NETIF_CHECKSUM_ENABLED(nf, NETIF_CHECKSUM_CHECK_ICMP) {
			uk_pr_info(" ICMP");
		}
		IF__NETIF_CHECKSUM_ENABLED(nf, NETIF_CHECKSUM_CHECK_ICMP6) {
			uk_pr_info(" ICMP6");
		}
		uk_pr_info("\n");

		uk_pr_info("%c%c%u: Generate checksums:",
			   nf->name[0], nf->name[1], nf->num);
		IF__NETIF_CHECKSUM_ENABLED(nf, NETIF_CHECKSUM_GEN_IP) {
			uk_pr_info(" IP");
		}
		IF__NETIF_CHECKSUM_ENABLED(nf, NETIF_CHECKSUM_GEN_UDP) {
			uk_pr_info(" UDP");
		}
		IF__NETIF_CHECKSUM_ENABLED(nf, NETIF_CHECKSUM_GEN_TCP) {
			uk_pr_info(" TCP");
		}
		IF__NETIF_CHECKSUM_ENABLED(nf, NETIF_CHECKSUM_GEN_ICMP) {
			uk_pr_info(" ICMP");
		}
		IF__NETIF_CHECKSUM_ENABLED(nf, NETIF_CHECKSUM_GEN_ICMP6) {
			uk_pr_info(" ICMP6");
		}
		uk_pr_info("\n");
#endif /* LWIP_CHECKSUM_CTRL_PER_NETIF */

#if LWIP_IPV4 && LWIP_DNS
		/* Primary DNS */
		if (nb_dns4 < DNS_MAX_SERVERS) {
			strcfg = uk_netdev_einfo_get(dev, UK_NETDEV_IPV4_DNS0);
			if (strcfg) {
#if LWIP_IPV6
				dns.type = IPADDR_TYPE_V4;
				if (ip4addr_aton(strcfg, &dns.u_addr.ip4) != 1) {
#else /* LWIP_IPV6 */
				if (ip4addr_aton(strcfg, &dns) != 1) {
#endif /* LWIP_IPV6 */
					uk_pr_err("Failed to parse DNS server address: %s\n",
						  strcfg);
					goto dns_secondary;
				}

				dns_setserver(nb_dns4++, &dns);
				uk_pr_info("%c%c%u: Primary DNS server: %s\n",
					   nf->name[0], nf->name[1], nf->num,
					   strcfg);
			}
		}

dns_secondary:
		/* Secondary DNS */
		if (nb_dns4 < DNS_MAX_SERVERS) {
			strcfg = uk_netdev_einfo_get(dev, UK_NETDEV_IPV4_DNS1);
			if (strcfg) {
#if LWIP_IPV6
				dns.type = IPADDR_TYPE_V4;
				if (ip4addr_aton(strcfg, &dns.u_addr.ip4) != 1) {
#else /* LWIP_IPV6 */
				if (ip4addr_aton(strcfg, &dns) != 1) {
#endif /* LWIP_IPV6 */
					uk_pr_err("Failed to parse DNS server address: %s\n",
						  strcfg);
					goto dns_done;
				}

				dns_setserver(nb_dns4++, &dns);
				uk_pr_info("%c%c%u: Secondary DNS server: %s\n",
					   nf->name[0], nf->name[1], nf->num,
					   strcfg);
			}
		}

dns_done:
#endif /* LWIP_IPV4 && LWIP_DNS */

		/* Declare the first network device as default interface */
		if (is_first_nf) {
			uk_pr_info("%c%c%u: Set as default interface\n",
				   nf->name[0], nf->name[1], nf->num);
			netif_set_default(nf);
			is_first_nf = 0;
		}
		netif_set_up(nf);

#if LWIP_IPV4 && LWIP_DHCP
		if (!ip4_arg) {
			uk_pr_info("%c%c%u: DHCP configuration (background)...\n",
				   nf->name[0], nf->name[1], nf->num);
			dhcp_start(nf);
		}
#endif /* LWIP_IPV4 && LWIP_DHCP */
	}

	if (lwip_netif_attached == 0) {
#if !CONFIG_LWIP_FAILNOIFACE
		uk_pr_warn("No network interface attached!\n");
#else /* CONFIG_LWIP_FAILNOIFACE */
		uk_pr_crit("No network interface attached!\n");
		return -ETIMEDOUT;
#endif  /* CONFIG_LWIP_FAILNOIFACE */
	}
#endif /* CONFIG_LWIP_UKNETDEV && CONFIG_LWIP_AUTOIFACE */
	return 0;
}

uk_lib_initcall(liblwip_init, 0);

#if CONFIG_LWIP_WAITIFACE
static void _lwip_netif_waitif(struct netif *nf, netif_nsc_reason_t reason,
			       const netif_ext_callback_args_t *args)
{
	if (0x0
#if LWIP_IPV4
	    || (reason & LWIP_NSC_IPV4_SETTINGS_CHANGED)
	    || (reason & LWIP_NSC_IPV4_ADDRESS_CHANGED)
#endif /* LWIP_IPV4 */
#if LWIP_IPV6
	    || (reason & LWIP_NSC_IPV6_SET)
	    || (reason & LWIP_NSC_IPV6_ADDR_STATE_CHANGED)
#endif /* LWIP_IPV6 */
	    ) {
		uk_semaphore_up(&_lwip_waitif_sem);
	}
}

static int liblwip_waitif(struct uk_init_ctx *ictx __unused)
{
#if CONFIG_LWIP_WAITIFACE_TO
	int lefttime = CONFIG_LWIP_WAITIFACE_TO;
#endif /* CONFIG_LWIP_WAITIFACE_TO */

	if (lwip_netif_attached == 0)
		return 0; /* No interface to wait for */
	if (uk_semaphore_down_try(&_lwip_waitif_sem) > 0)
		return 0; /* Fast path: at least one netif is already
			   * configured (probably a static IP) -->
			   * Do not print, continue booting.
			   */

	uk_pr_info("Wait for networking...");
	while (uk_semaphore_down_to(&_lwip_waitif_sem,
				    ukarch_time_sec_to_nsec(1)) == __NSEC_MAX) {
#if CONFIG_LWIP_WAITIFACE_TO
		lefttime--;
		if (lefttime == 0) {
#if !LWIP_FAILNOIFACE
			uk_pr_info("Timed out\n");
			return 0;
#else /* LWIP_FAILNOIFACE */
			uk_pr_crit("Network setup timed out\n");
			return -ETIMEDOUT;
#endif  /* LWIP_FAILNOIFACE */
		}
#endif /* CONFIG_LWIP_WAITIFACE_TO */
		uk_pr_info(".");
	}
	uk_pr_info("\n");
	return 0;
}

uk_late_initcall_prio(liblwip_waitif, 0x0, UK_PRIO_LATEST);
#endif /* CONFIG_LWIP_WAITIFACE */
