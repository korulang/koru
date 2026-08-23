#ifndef __NET_IF_H__
#define __NET_IF_H__

#include <compat/posix/net/if.h>

#ifdef __cplusplus
extern "C" {
#endif

char *if_indextoname (unsigned int, char *);

#if defined(_GNU_SOURCE) || defined(_BSD_SOURCE)

#define IFF_UP	0x1
#define IFF_BROADCAST 0x2
#define IFF_DEBUG 0x4
#define IFF_LOOPBACK 0x8
#define IFF_POINTOPOINT 0x10
#define IFF_NOTRAILERS 0x20
#define IFF_RUNNING 0x40
#define IFF_NOARP 0x80
#define IFF_PROMISC 0x100
#define IFF_ALLMULTI 0x200
#define IFF_MASTER 0x400
#define IFF_SLAVE 0x800
#define IFF_MULTICAST 0x1000
#define IFF_PORTSEL 0x2000
#define IFF_AUTOMEDIA 0x4000
#define IFF_DYNAMIC 0x8000
#define IFF_LOWER_UP 0x10000
#define IFF_DORMANT 0x20000
#define IFF_ECHO 0x40000
#define IFF_VOLATILE (IFF_LOOPBACK|IFF_POINTOPOINT|IFF_BROADCAST| \
        IFF_ECHO|IFF_MASTER|IFF_SLAVE|IFF_RUNNING|IFF_LOWER_UP|IFF_DORMANT)

struct ifconf {
	int ifc_len;
	union {
		char *ifcu_buf;
		struct ifreq *ifcu_req;
	} ifc_ifcu;
};
#define ifc_buf         ifc_ifcu.ifcu_buf
#define ifc_req         ifc_ifcu.ifcu_req

#endif /* defined(_GNU_SOURCE) || defined(_BSD_SOURCE) */

#ifdef __cplusplus
}
#endif

#endif /* __NET_IF_H__ */
