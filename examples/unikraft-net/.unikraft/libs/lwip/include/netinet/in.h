#ifndef _NETINET_IN_H_
#define _NETINET_IN_H_

#include <uk/config.h>
#ifdef CONFIG_LWIP_SOCKET
#include <lwip/sockets.h>
/* Taken from musl's netinet/in.h */
#ifdef CONFIG_LWIP_IPV6
#define IN6_IS_ADDR_MULTICAST(a) (((uint8_t *) (a))[0] == 0xff)
#define IN6_IS_ADDR_LINKLOCAL(a) \
  ((((uint8_t *) (a))[0]) == 0xfe && (((uint8_t *) (a))[1] & 0xc0) == 0x80)
#define IN6_IS_ADDR_MC_LINKLOCAL(a) \
  (IN6_IS_ADDR_MULTICAST(a) && ((((uint8_t *) (a))[1] & 0xf) == 0x2))
#endif /* LWIP_IPV6 */
#else /* CONFIG_LWIP_SOCKET */
#include_next <netinet/in.h>
#endif

#define IP_ADD_SOURCE_MEMBERSHIP  39 
#define IP_DROP_SOURCE_MEMBERSHIP 40

#define MCAST_JOIN_GROUP   42
#define MCAST_BLOCK_SOURCE 43
#define MCAST_UNBLOCK_SOURCE      44
#define MCAST_LEAVE_GROUP  45
#define MCAST_JOIN_SOURCE_GROUP   46
#define MCAST_LEAVE_SOURCE_GROUP  47
#define MCAST_MSFILTER     48

struct ip_mreq_source {
       struct in_addr imr_multiaddr;
       struct in_addr imr_interface;
       struct in_addr imr_sourceaddr;
};

struct group_source_req {
       uint32_t gsr_interface;
       struct sockaddr_storage gsr_group;
       struct sockaddr_storage gsr_source;
};


#ifdef CONFIG_LWIP_IPV6
extern const struct in6_addr in6addr_any, in6addr_loopback;

#define IPV6_ADDRFORM           1
#define IPV6_2292PKTINFO        2
#define IPV6_2292HOPOPTS        3
#define IPV6_2292DSTOPTS        4
#define IPV6_2292RTHDR          5
#define IPV6_2292PKTOPTIONS     6
#define IPV6_CHECKSUM           7
#define IPV6_2292HOPLIMIT       8
#define IPV6_NEXTHOP            9
#define IPV6_AUTHHDR            10
#define IPV6_UNICAST_HOPS       16
#define IPV6_MULTICAST_IF       17
#define IPV6_MULTICAST_HOPS     18
#define IPV6_MULTICAST_LOOP     19
#define IPV6_ROUTER_ALERT       22
#define IPV6_MTU_DISCOVER       23
#define IPV6_MTU                24
#define IPV6_RECVERR            25
#define IPV6_JOIN_ANYCAST       27
#define IPV6_LEAVE_ANYCAST      28
#define IPV6_MULTICAST_ALL      29
#define IPV6_ROUTER_ALERT_ISOLATE 30
#define IPV6_IPSEC_POLICY       34
#define IPV6_XFRM_POLICY        35
#define IPV6_HDRINCL            36

#define IPV6_RECVPKTINFO        49
#define IPV6_PKTINFO            50
#define IPV6_RECVHOPLIMIT       51
#define IPV6_HOPLIMIT           52
#define IPV6_RECVHOPOPTS        53
#define IPV6_HOPOPTS            54
#define IPV6_RTHDRDSTOPTS       55
#define IPV6_RECVRTHDR          56
#define IPV6_RTHDR              57
#define IPV6_RECVDSTOPTS        58
#define IPV6_DSTOPTS            59
#define IPV6_RECVPATHMTU        60
#define IPV6_PATHMTU            61
#define IPV6_DONTFRAG           62
#define IPV6_RECVTCLASS         66
#define IPV6_TCLASS             67
#define IPV6_AUTOFLOWLABEL      70
#define IPV6_ADDR_PREFERENCES   72
#define IPV6_MINHOPCOUNT        73
#define IPV6_ORIGDSTADDR        74
#define IPV6_RECVORIGDSTADDR    IPV6_ORIGDSTADDR
#define IPV6_TRANSPARENT        75
#define IPV6_UNICAST_IF         76
#define IPV6_RECVFRAGSIZE       77
#define IPV6_FREEBIND           78

#define IPV6_PMTUDISC_DONT      0
#define IPV6_PMTUDISC_WANT      1
#define IPV6_PMTUDISC_DO        2
#define IPV6_PMTUDISC_PROBE     3
#define IPV6_PMTUDISC_INTERFACE 4
#define IPV6_PMTUDISC_OMIT      5

#define IPV6_PREFER_SRC_TMP            0x0001
#define IPV6_PREFER_SRC_PUBLIC         0x0002
#define IPV6_PREFER_SRC_PUBTMP_DEFAULT 0x0100
#define IPV6_PREFER_SRC_COA            0x0004
#define IPV6_PREFER_SRC_HOME           0x0400
#define IPV6_PREFER_SRC_CGA            0x0008
#define IPV6_PREFER_SRC_NONCGA         0x0800

#define IPV6_RTHDR_LOOSE        0
#define IPV6_RTHDR_STRICT       1

#define IPV6_RTHDR_TYPE_0       0
#endif

#define IN6_IS_ADDR_UNSPECIFIED(a) \
        (((uint32_t *) (a))[0] == 0 && ((uint32_t *) (a))[1] == 0 && \
         ((uint32_t *) (a))[2] == 0 && ((uint32_t *) (a))[3] == 0)

#define IN6_IS_ADDR_LOOPBACK(a) \
        (((uint32_t *) (a))[0] == 0 && ((uint32_t *) (a))[1] == 0 && \
         ((uint32_t *) (a))[2] == 0 && \
         ((uint8_t *) (a))[12] == 0 && ((uint8_t *) (a))[13] == 0 && \
         ((uint8_t *) (a))[14] == 0 && ((uint8_t *) (a))[15] == 1 )

#define IN6_IS_ADDR_MULTICAST(a) (((uint8_t *) (a))[0] == 0xff)

#define IN6_IS_ADDR_LINKLOCAL(a) \
        ((((uint8_t *) (a))[0]) == 0xfe && (((uint8_t *) (a))[1] & 0xc0) == 0x80)

#define IN6_IS_ADDR_SITELOCAL(a) \
        ((((uint8_t *) (a))[0]) == 0xfe && (((uint8_t *) (a))[1] & 0xc0) == 0xc0)

#define IN6_IS_ADDR_V4MAPPED(a) \
        (((uint32_t *) (a))[0] == 0 && ((uint32_t *) (a))[1] == 0 && \
         ((uint8_t *) (a))[8] == 0 && ((uint8_t *) (a))[9] == 0 && \
         ((uint8_t *) (a))[10] == 0xff && ((uint8_t *) (a))[11] == 0xff)

#define IN6_IS_ADDR_V4COMPAT(a) \
        (((uint32_t *) (a))[0] == 0 && ((uint32_t *) (a))[1] == 0 && \
         ((uint32_t *) (a))[2] == 0 && ((uint8_t *) (a))[15] > 1)

#define IN6_IS_ADDR_MC_NODELOCAL(a) \
        (IN6_IS_ADDR_MULTICAST(a) && ((((uint8_t *) (a))[1] & 0xf) == 0x1))

#define IN6_IS_ADDR_MC_LINKLOCAL(a) \
        (IN6_IS_ADDR_MULTICAST(a) && ((((uint8_t *) (a))[1] & 0xf) == 0x2))

#define IN6_IS_ADDR_MC_SITELOCAL(a) \
        (IN6_IS_ADDR_MULTICAST(a) && ((((uint8_t *) (a))[1] & 0xf) == 0x5))

#define IN6_IS_ADDR_MC_ORGLOCAL(a) \
        (IN6_IS_ADDR_MULTICAST(a) && ((((uint8_t *) (a))[1] & 0xf) == 0x8))

#define IN6_IS_ADDR_MC_GLOBAL(a) \
        (IN6_IS_ADDR_MULTICAST(a) && ((((uint8_t *) (a))[1] & 0xf) == 0xe))

#if defined(_GNU_SOURCE) || defined(_BSD_SOURCE)

struct ip_mreqn {
	struct in_addr imr_multiaddr;
	struct in_addr imr_address;
	int imr_ifindex;
};
#endif /* defined(_GNU_SOURCE) || defined(_BSD_SOURCE) */


#ifdef CONFIG_LWIP_IPV6
struct in6_pktinfo {
	struct in6_addr ipi6_addr;
	unsigned ipi6_ifindex;
};

struct ip6_mtuinfo {
	struct sockaddr_in6 ip6m_addr;
	uint32_t ip6m_mtu;
};
#endif

#endif /* _NETINET_IN_H_ */
