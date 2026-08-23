#ifndef _LWIP_GLUE_NETDB_H_
#define _LWIP_GLUE_NETDB_H_
#include <compat/posix/netdb.h>

#ifdef __cplusplus
extern "C" {
#endif

#if LWIP_DNS && LWIP_SOCKET

#if !(LWIP_COMPAT_SOCKETS)
struct hostent *gethostbyname(const char *name);
int gethostbyname_r(const char *name,
		struct hostent *ret, char *buf, size_t buflen,
		struct hostent **result, int *h_errnop);
#endif

struct hostent *gethostbyaddr(const void *addr __unused,
		socklen_t len __unused, int type __unused);

int getaddrinfo(const char *node, const char *service,
		const struct addrinfo *hints,
		struct addrinfo **res);
void freeaddrinfo(struct addrinfo *res);

int getnameinfo(const struct sockaddr *addr, socklen_t addrlen,
		char *host, socklen_t hostlen,
		char *serv, socklen_t servlen, int flags);

#endif /* LWIP_DNS && LWIP_SOCKET && !(LWIP_COMPAT_SOCKETS) */

const char *gai_strerror(int errcode);


struct servent {
	char    *s_name;        /* official service name */
	char    **s_aliases;    /* alias list */
	int     s_port;         /* port # */
	char    *s_proto;       /* protocol to use */
};

struct protoent {
	char    *p_name;        /* official protocol name */
	char    **p_aliases;    /* alias list */
	int     p_proto;        /* protocol # */
};

struct protoent *getprotoent(void);
struct protoent *getprotobyname(const char *name);
struct protoent *getprotobynumber(int num);
void endprotoent(void);
void setprotoent(int stayopen);

/*
 * Constants for getnameinfo()
 */
#define NI_MAXHOST      1025
#define NI_MAXSERV      32

/*
 * Flag values for getnameinfo()
 */
#define NI_NUMERICHOST  0x01
#define NI_NUMERICSERV  0x02
#define NI_NOFQDN       0x04
#define NI_NAMEREQD     0x08
#define NI_DGRAM        0x10
#define NI_NUMERICSCOPE 0x20

/* Error values for getaddrinfo() and getservbyport_r not defined */
/* by lwip/netdb.h */
#define EAI_BADFLAGS   -1
#define EAI_AGAIN      -3
#define EAI_NODATA     -5
#define EAI_SOCKTYPE   -7
#define EAI_ADDRFAMILY -9
#define EAI_SYSTEM     -11
#define EAI_OVERFLOW   -12

struct servent *getservbyname(const char *name, const char *proto);
struct servent *getservbyport(int port, const char *proto);
int getservbyport_r(int port, const char *prots, struct servent *se,
		    char *buf, size_t buflen, struct servent **res);

#ifdef __cplusplus
}
#endif

#endif

