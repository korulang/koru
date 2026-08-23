/* SPDX-License-Identifier: BSD-3-Clause */
/* Copyright (c) 2025, Unikraft GmbH and The Unikraft Authors.
 * Licensed under the BSD-3-Clause License (the "License").
 * You may not use this file except in compliance with the License.
 */

#include "lwip/opt.h"

#include <inttypes.h>
#include <stdbool.h>
#include <netinet/in.h>

#include <uk/bitops/bitscan.h>
#include <uk/netlink/driver.h>
#include <uk/print.h>
#include <uk/streambuf.h>

#include <linux/rtnetlink.h>
#include <linux/if_link.h>
#include <linux/if_arp.h> /* ARPHRD_ETHER */
#include <lwip/tcp.h>

static void uk_pr_debug_nlh(const struct nlmsghdr *nlh)
{
	uk_pr_debug("nlh->len: %"PRIu32"\n", nlh->nlmsg_len);
	uk_pr_debug("nlh->type: %"PRIu16"\n", nlh->nlmsg_type);
	uk_pr_debug("nlh->flags: 0x%"PRIx16"\n", nlh->nlmsg_flags);
	uk_pr_debug("nlh->seq: %"PRIu32"\n", nlh->nlmsg_seq);
	uk_pr_debug("nlh->pid: %"PRIu32"\n", nlh->nlmsg_pid);
}

static size_t netif_name_len(const struct netif *ni)
{
	size_t len;

	len = sizeof(ni->name);
	if (ni->num >= 100)
		len += 3;
	else if (ni->num >= 10)
		len += 2;
	else
		len += 1;
	len += 1; /* `\0` termination */
	return len;
}

static void netif_name_dump(char *dest, const struct netif *ni)
{
	char *pos = dest;
	unsigned int num;
	unsigned int i;

	for (i = 0; i < sizeof(ni->name); i++)
		*(pos++) = ni->name[i];

	num = ni->num;
	if (num >= 100)
		goto hundreds;
	else if (num >= 10)
		goto tens;
	goto ones;

hundreds:
	i = num / 100;
	num %= 100;
	*(pos++) = '0' + i;
tens:
	i = num / 10;
	num %= 10;
	*(pos++) = '0' + i;
ones:
	*(pos++) = '0' + num;

	/* Add zero termination */
	*pos = '\0';
}

/**
 * Append an rtattr to a netlink reply.
 *
 * @return pointer to payload to be filled, NULL if there is no space left
 */
static void *nlbuf_rtattr(struct uk_streambuf *rep,
			  unsigned short rta_type,
			  unsigned short data_len)
{
	struct rtattr *attr;

	/* place rtattr * structure */
	attr = nlbuf_reserve(rep, RTA_SPACE(data_len));
	if (unlikely(!attr))
		return NULL;

	attr->rta_type = rta_type;
	attr->rta_len = RTA_LENGTH(data_len);
	return RTA_DATA(attr);
}

#if MIB2_STATS
static inline bool netif_is_loopback(const struct netif *netif)
{
	return netif->type == snmp_ifType_softwareLoopback;
}
#else /* !MIB2_STATS */
static inline bool netif_is_loopback(const struct netif *netif)
{
	bool ret = false;

#if LWIP_HAVE_LOOPIF
	/* Unfortunately, for loopback interfaces we have to guess
	 * and check for a parameter setup that is a result of
	 * `netif_loopif_init()`
	 */
	ret = netif->name[0] == 'l' && netif->name[1] == 'o';
#if LWIP_CHECKSUM_CTRL_PER_NETIF
	ret = ret && netif->chksum_flags == NETIF_CHECKSUM_DISABLE_ALL;
#endif /* LWIP_CHECKSUM_CTRL_PER_NETIF */
#endif /* LWIP_HAVE_LOOPIF */
	return ret;
}
#endif /* !MIB2_STATS */

#define NLMSG_ERR_LEN NLMSG_LENGTH(sizeof(struct nlmsgerr))

/* Only prepares msg; does not send msg, does not assume streambuf is empty */
static void prep_reply_err(struct nl_ctx *ctx, struct uk_streambuf *sb,
			   int err, uint16_t flags, const struct nlmsghdr *req)
{
	struct nlmsghdr *nlh;
	struct nlmsgerr *nlerr;

	uk_pr_debug("Reply with error msg: %d\n", err);

	nlh = nlbuf_reserve(sb, NLMSG_HDRLEN);
	UK_ASSERT(nlh);
	nlh->nlmsg_type = NLMSG_ERROR;
	nlh->nlmsg_flags = flags;
	nlh->nlmsg_pid = nl_ctx_pid(ctx);
	nlh->nlmsg_seq = req->nlmsg_seq;
	nlh->nlmsg_len = NLMSG_ERR_LEN;
	uk_pr_debug_nlh(nlh);

	nlerr = nlbuf_reserve(sb, NLMSG_ALIGN(sizeof(*nlerr)));
	UK_ASSERT(nlerr);
	nlerr->error = err;
	nlerr->msg = *req;
}

/* Only prepares msg; does not send msg, does not assume streambuf is empty */
static void prep_reply_done(struct nl_ctx *ctx, struct uk_streambuf *sb,
			    const struct nlmsghdr *req)
{
	struct nlmsghdr *nlh;

	uk_pr_debug("Reply with DONE message\n");

	nlh = nlbuf_reserve(sb, NLMSG_HDRLEN);
	UK_ASSERT(nlh);

	nlh->nlmsg_type = NLMSG_DONE;
	nlh->nlmsg_flags = NLM_F_MULTI;
	nlh->nlmsg_pid = nl_ctx_pid(ctx);
	nlh->nlmsg_seq = req->nlmsg_seq;
	nlh->nlmsg_len = NLMSG_HDRLEN;
	uk_pr_debug_nlh(nlh);
}

static int reply_getlink_if(struct nl_ctx *ctx, struct netif *netif,
			    const struct nlmsghdr *req)
{
	struct uk_streambuf *rep;
	struct nlmsghdr *nlh;
	struct ifinfomsg *ifi;
	char *ifname;
	uint32_t *ifmtu;
	char *ifaddr;

	rep = nlbuf_alloc(ctx, 512);
	if (unlikely(!rep))
		return -ENOMEM;

	uk_pr_debug("Generate getlink for %c%c%d\n",
		    netif->name[0], netif->name[1], netif->num);
	nlh = nlbuf_reserve(rep, NLMSG_HDRLEN);
	UK_ASSERT(nlh);
	nlh->nlmsg_type = RTM_NEWLINK;
	nlh->nlmsg_flags = NLM_F_MULTI;
	nlh->nlmsg_pid = nl_ctx_pid(ctx);
	nlh->nlmsg_seq = req->nlmsg_seq;

	/* IFINFO */
	ifi = nlbuf_reserve(rep, NLMSG_ALIGN(sizeof(*ifi)));
	UK_ASSERT(ifi);
#if MIB2_STATS
	switch (netif->type) {
	case snmp_ifType_softwareLoopback:
		ifi->ifi_type = ARPHRD_LOOPBACK;
		break;
	case snmp_ifType_ppp:
		ifi->ifi_type = ARPHRD_PPP;
		break;
	case snmp_ifType_slip:
		ifi->ifi_type = ARPHRD_SLIP;
		break;
	default:
		ifi->ifi_type = ARPHRD_ETHER;
		break;
	}
#else /* !MIB2_STATS */
	if (netif_is_loopback(netif)) {
		ifi->ifi_type = ARPHRD_LOOPBACK;
	} else if (netif->flags & NETIF_FLAG_ETHERNET) {
		ifi->ifi_type = ARPHRD_ETHER;
	} else {
		ifi->ifi_type = ARPHRD_VOID;
	}
#endif /* !MIB2_STATS */
	ifi->ifi_index = netif->num;
	ifi->ifi_family = AF_UNSPEC;
	ifi->ifi_flags = IFF_RUNNING | IFF_LOWER_UP;
	ifi->ifi_change = 0xffffffff;
	if (netif->flags & NETIF_FLAG_UP)
		ifi->ifi_flags |= IFF_UP;
	if (netif->flags & NETIF_FLAG_BROADCAST)
		ifi->ifi_flags |= IFF_BROADCAST | IFF_MULTICAST;

	/* IFLA_IFNAME (C-string) */
	uk_pr_debug("Append IFLA_IFNAME\n");
	ifname = nlbuf_rtattr(rep, IFLA_IFNAME, netif_name_len(netif));
	UK_ASSERT(ifname);
	netif_name_dump(ifname, netif);

	/* IFLA_MTU (u32) */
	uk_pr_debug("Append IFLA_MTU\n");
	ifmtu = nlbuf_rtattr(rep, IFLA_MTU, sizeof(*ifmtu));
	UK_ASSERT(ifmtu);
	*ifmtu = netif->mtu;

	/* IFLA_ADDRESS (hwaddr) */
	if (netif->hwaddr_len && (ifi->ifi_type != ARPHRD_LOOPBACK)) {
		uk_pr_debug("Append IFLA_ADDRESS\n");
		ifaddr = nlbuf_rtattr(rep, IFLA_ADDRESS, netif->hwaddr_len);
		UK_ASSERT(ifaddr);
		for (unsigned int i = 0; i < netif->hwaddr_len; i++)
			ifaddr[i] = netif->hwaddr[i];
	}

	nlh->nlmsg_len = nlbuf_len(rep);

	uk_pr_debug("Put getlink message for %c%c%d\n",
		    netif->name[0], netif->name[1], netif->num);
	uk_pr_debug_nlh(nlh);

	nlbuf_send(ctx, rep);
	return 0;
}

static int reply_getlink(struct nl_ctx *ctx, const struct nlmsghdr *req)
{
	struct uk_streambuf *eor; /* end-of-reply */
	struct netif *netif;
	int err = 0;

	/* Reserve space ahead of time for DONE msg + optional ERROR msg */
	eor = nlbuf_alloc(ctx, NLMSG_HDRLEN + NLMSG_ERR_LEN);
	if (unlikely(!eor))
		return -ENOMEM;

	uk_pr_debug("Handle GETLINK request\n");
	uk_pr_debug_nlh(req);
	if (unlikely((req->nlmsg_flags & (NLM_F_REQUEST | NLM_F_DUMP)) !=
		     (NLM_F_REQUEST | NLM_F_DUMP))) {
		uk_pr_debug("Unsupported message flags for GETLINK\n");
		err = -EINVAL;
		goto done;
	}

	for (netif = netif_list; netif != NULL; netif = netif->next)
		if ((err = reply_getlink_if(ctx, netif, req)))
			break;

done:
	if (err) {
		UK_ASSERT(err < 0);
		prep_reply_err(ctx, eor, err, NLM_F_MULTI, req);
	}
	prep_reply_done(ctx, eor, req);
	nlbuf_send(ctx, eor);
	return 0;
}

#if LWIP_IPV4
/* The following code assumes that long is at least a 32 bit number */
UK_CTASSERT(sizeof(long) >= sizeof(uint32_t));

static inline uint8_t netmask_2_suffixlen(ip4_addr_t *netmask)
{
	long hmask;

	UK_ASSERT(netmask);

	/* Corner cases */
	if ((unsigned long)netmask->addr == 0x0UL)
		return 32;
	if ((unsigned long)netmask->addr == 0xFFFFFFFFUL)
		return 0;

	/* Suffix length is equal to the least significant bit that is `1` */
	hmask = (long)PP_NTOHL(netmask->addr);
	return (uint8_t)uk_lssbl(hmask);
}

#define netmask_2_prefixlen(netmask) \
	(32 - netmask_2_suffixlen(netmask))

static inline void ip4_addr_2_in_addr(ip4_addr_t *in, in_addr_t *out)
{
	UK_ASSERT(in);
	UK_ASSERT(out);

	/* Both data structures are in network byte order */
	/* Both data structures consists of a __u32 value */
	*((uint32_t *)out) = (uint32_t)in->addr;
}

static inline in_addr_t in_addr_netmask(uint8_t prefixlen)
{
	in_addr_t mask = 0xFFFFFFFFUL;

	return (mask ^ ((1UL << (32 - prefixlen)) - 1));
}

static int reply_getaddr_if(struct nl_ctx *ctx, struct netif *netif,
			    const struct nlmsghdr *req)
{
	struct uk_streambuf *rep;
	struct nlmsghdr *nlh;
	struct ifaddrmsg *ifa;
	in_addr_t *inaddr;
	in_addr_t *inbc;
	char *ifname;

#if LWIP_IPV6
	/* With dual-stack, addresses get a type */
	if (netif->address.type != IPADDR_TYPE_V4)
		return 0; /* no IPv4 address */
#endif /* LWIP_IPV6 */

	rep = nlbuf_alloc(ctx, 256);
	if (unlikely(!rep))
		return -ENOMEM;

	uk_pr_debug("Generate getaddr for %c%c%d\n",
		    netif->name[0], netif->name[1], netif->num);
	nlh = nlbuf_reserve(rep, NLMSG_HDRLEN);
	UK_ASSERT(nlh);
	nlh->nlmsg_type = RTM_NEWADDR;
	nlh->nlmsg_flags = NLM_F_MULTI;
	nlh->nlmsg_pid = nl_ctx_pid(ctx);
	nlh->nlmsg_seq = req->nlmsg_seq;

	ifa = nlbuf_reserve(rep, NLMSG_ALIGN(sizeof(*ifa)));
	UK_ASSERT(ifa);
	ifa->ifa_index = netif->num;
	ifa->ifa_family = AF_INET;
	if (netif_is_loopback(netif)) {
		ifa->ifa_flags = IFA_F_PERMANENT;
		ifa->ifa_scope = RT_SCOPE_HOST;
	} else {
		ifa->ifa_flags = 0x0;
		ifa->ifa_scope = RT_SCOPE_UNIVERSE;
	}
#if LWIP_IPV6
	ifa->ifa_prefixlen = netmask_2_prefixlen(&netif->netmask.u_addr.ip4);
#else /* !LWIP_IPV6*/
	ifa->ifa_prefixlen = netmask_2_prefixlen(&netif->netmask);
#endif /* !LWIP_IPV6 */

	/* IFA_ADDRESS */
	uk_pr_debug("Append IFA_ADDRESS\n");
	inaddr = nlbuf_rtattr(rep, IFA_ADDRESS, sizeof(*inaddr));
	UK_ASSERT(inaddr);
#if LWIP_IPV6
	ip4_addr_2_in_addr(&netif->ip_addr.u_addr.ip4, inaddr);
#else /* !LWIP_IPV6*/
	ip4_addr_2_in_addr(&netif->ip_addr, inaddr);
#endif /* !LWIP_IPV6 */

	/* IFA_BROADCAST */
	uk_pr_debug("Append IFA_BROADCAST\n");
	inbc = nlbuf_rtattr(rep, IFA_BROADCAST, sizeof(*inbc));
	UK_ASSERT(inbc);
#if LWIP_IPV6
	ip4_addr_2_in_addr(&netif->ip_addr.u_addr.ip4, inbc);
#else /* !LWIP_IPV6*/
	ip4_addr_2_in_addr(&netif->ip_addr, inbc);
#endif /* !LWIP_IPV6 */
	*inbc |= ~in_addr_netmask(ifa->ifa_prefixlen);

	/* IFA_LABEL (C-string) */
	uk_pr_debug("Append IFA_LABEL\n");
	ifname = nlbuf_rtattr(rep, IFA_LABEL, netif_name_len(netif));
	UK_ASSERT(ifname);
	netif_name_dump(ifname, netif);

	nlh->nlmsg_len = nlbuf_len(rep);

	uk_pr_debug("Put getaddr message for %c%c%d\n",
		    netif->name[0], netif->name[1], netif->num);
	uk_pr_debug_nlh(nlh);

	nlbuf_send(ctx, rep);
	return 0;
}

#endif /* LWIP_IPV4 */

static int reply_getaddr(struct nl_ctx *ctx, const struct nlmsghdr *req)
{
	struct uk_streambuf *eor; /* end-of-reply */
	struct netif *netif;
	int err = 0;

	/* Reserve space ahead of time for DONE msg + optional ERROR msg */
	eor = nlbuf_alloc(ctx, NLMSG_HDRLEN + NLMSG_ERR_LEN);
	if (unlikely(!eor))
		return -ENOMEM;

	uk_pr_debug("Handle GETADDR request\n");
	uk_pr_debug_nlh(req);
	if (unlikely((req->nlmsg_flags & (NLM_F_REQUEST | NLM_F_DUMP)) !=
		     (NLM_F_REQUEST | NLM_F_DUMP))) {
		uk_pr_debug("Unsupported message flags for GETADDR\n");
		err = -EINVAL;
		goto done;
	}

#if LWIP_IPV4
	for (netif = netif_list; netif != NULL; netif = netif->next)
		if ((err = reply_getaddr_if(ctx, netif, req)))
			break;
#endif /* LWIP_IPV4 */

#if LWIP_IPV6
	uk_pr_warn_once("IPv6 getaddr not supported\n");
#endif /* LWIP_IPV6 */

done:
	if (err) {
		UK_ASSERT(err < 0);
		prep_reply_err(ctx, eor, err, NLM_F_MULTI, req);
	}
	prep_reply_done(ctx, eor, req);
	nlbuf_send(ctx, eor);
	return 0;
}

static int reply_enotsup(struct nl_ctx *ctx, const struct nlmsghdr *req)
{
	struct uk_streambuf *rep;

	rep = nlbuf_alloc(ctx, NLMSG_ERR_LEN);
	if (unlikely(!rep))
		return -ENOMEM;

	prep_reply_err(ctx, rep, -ENOTSUP, 0, req);
	nlbuf_send(ctx, rep);
	return 0;
}

static int lwip_nl_route_handle(struct nl_ctx *ctx,
				const struct nlmsghdr *req)
{
	/* Switch to target handler routine */
	switch(req->nlmsg_type) {
		case RTM_GETLINK:
			return reply_getlink(ctx, req);
		case RTM_GETADDR:
			return reply_getaddr(ctx, req);
		default:
			uk_pr_warn("Unsupported netlink message %d, flags 0x%x.\n",
				   req->nlmsg_type, req->nlmsg_flags);
			return reply_enotsup(ctx, req);
	}
}

static const struct posix_netlink_protocol_ops lwip_nl_route_ops = {
	.handle = lwip_nl_route_handle
};

POSIX_NETLINK_PROTOCOL_REGISTER(NETLINK_ROUTE, &lwip_nl_route_ops);
