/**
 * @file
 * Socket API (to be used from non-TCPIP threads)
 */

/*
 * Copyright (c) 2001-2004 Swedish Institute of Computer Science.
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification,
 * are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 *    this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 * 3. The name of the author may not be used to endorse or promote products
 *    derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR IMPLIED
 * WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT
 * SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT
 * OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
 * IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY
 * OF SUCH DAMAGE.
 *
 * This file is part of the lwIP TCP/IP stack.
 *
 * Author: Adam Dunkels <adam@sics.se>
 *
 */


#ifndef LWIP_HDR_SOCKETS_H
#define LWIP_HDR_SOCKETS_H

#include <uk/config.h>

#include <sys/socket.h>
#include <netinet/in.h>
#include <net/if.h>
#include <poll.h>

#include "lwip/opt.h"

#if LWIP_SOCKET /* don't build if not configured for use in lwipopts.h */

#ifdef __cplusplus
extern "C" {
#endif

#if LWIP_TCP
/*
 * Options for level IPPROTO_TCP
 */
#define TCP_NODELAY    0x01    /* don't delay send to coalesce packets */
#define TCP_KEEPALIVE  0x02    /* send KEEPALIVE probes when idle for pcb->keep_idle milliseconds */
#define TCP_KEEPIDLE   0x04    /* set pcb->keep_idle  - Same as TCP_KEEPALIVE, but use seconds for get/setsockopt */
#define TCP_KEEPINTVL  0x05    /* set pcb->keep_intvl - Use seconds for get/setsockopt */
#define TCP_KEEPCNT    0x06    /* set pcb->keep_cnt   - Use number of probes sent for get/setsockopt */
#endif /* LWIP_TCP */

/* FD_SET used for lwip_select */
#ifndef FD_SET
#undef  FD_SETSIZE
/* Make FD_SETSIZE match NUM_SOCKETS in socket.c */
#define FD_SETSIZE    MEMP_NUM_NETCONN
#define LWIP_SELECT_MAXNFDS (FD_SETSIZE + LWIP_SOCKET_OFFSET)
#define FDSETSAFESET(n, code) do { \
  if (((n) - LWIP_SOCKET_OFFSET < MEMP_NUM_NETCONN) && (((int)(n) - LWIP_SOCKET_OFFSET) >= 0)) { \
  code; }} while(0)
#define FDSETSAFEGET(n, code) (((n) - LWIP_SOCKET_OFFSET < MEMP_NUM_NETCONN) && (((int)(n) - LWIP_SOCKET_OFFSET) >= 0) ?\
  (code) : 0)
#define FD_SET(n, p)  FDSETSAFESET(n, (p)->fd_bits[((n)-LWIP_SOCKET_OFFSET)/8] = (u8_t)((p)->fd_bits[((n)-LWIP_SOCKET_OFFSET)/8] |  (1 << (((n)-LWIP_SOCKET_OFFSET) & 7))))
#define FD_CLR(n, p)  FDSETSAFESET(n, (p)->fd_bits[((n)-LWIP_SOCKET_OFFSET)/8] = (u8_t)((p)->fd_bits[((n)-LWIP_SOCKET_OFFSET)/8] & ~(1 << (((n)-LWIP_SOCKET_OFFSET) & 7))))
#define FD_ISSET(n,p) FDSETSAFEGET(n, (p)->fd_bits[((n)-LWIP_SOCKET_OFFSET)/8] &   (1 << (((n)-LWIP_SOCKET_OFFSET) & 7)))
#define FD_ZERO(p)    memset((void*)(p), 0, sizeof(*(p)))

typedef struct fd_set
{
  unsigned char fd_bits [(FD_SETSIZE+7)/8];
} fd_set;

#elif FD_SETSIZE < (LWIP_SOCKET_OFFSET + MEMP_NUM_NETCONN)
#error "external FD_SETSIZE too small for number of sockets"
#else
#define LWIP_SELECT_MAXNFDS FD_SETSIZE
#endif /* FD_SET */

#define lwip_socket_init() /* Compatibility define, no init needed. */
void lwip_socket_thread_init(void); /* LWIP_NETCONN_SEM_PER_THREAD==1: initialize thread-local semaphore */
void lwip_socket_thread_cleanup(void); /* LWIP_NETCONN_SEM_PER_THREAD==1: destroy thread-local semaphore */

#if LWIP_COMPAT_SOCKETS == 2
/* This helps code parsers/code completion by not having the COMPAT functions as defines */
#define lwip_accept       accept
#define lwip_bind         bind
#define lwip_shutdown     shutdown
#define lwip_getpeername  getpeername
#define lwip_getsockname  getsockname
#define lwip_setsockopt   setsockopt
#define lwip_getsockopt   getsockopt
#define lwip_close        closesocket
#define lwip_connect      connect
#define lwip_listen       listen
#define lwip_recv         recv
#define lwip_recvmsg      recvmsg
#define lwip_recvfrom     recvfrom
#define lwip_send         send
#define lwip_sendmsg      sendmsg
#define lwip_sendto       sendto
#define lwip_socket       socket
#if LWIP_SOCKET_SELECT
#define lwip_select       select
#endif
#if LWIP_SOCKET_POLL
#define lwip_poll         poll
#endif
#define lwip_ioctl        ioctlsocket
#define lwip_inet_ntop    inet_ntop
#define lwip_inet_pton    inet_pton

#if LWIP_POSIX_SOCKETS_IO_NAMES
#define lwip_read         read
#define lwip_readv        readv
#define lwip_write        write
#define lwip_writev       writev
#undef lwip_close
#define lwip_close        close
#define closesocket(s)    close(s)
int fcntl(int s, int cmd, ...);
#undef lwip_ioctl
#define lwip_ioctl        ioctl
#define ioctlsocket       ioctl
#endif /* LWIP_POSIX_SOCKETS_IO_NAMES */
#endif /* LWIP_COMPAT_SOCKETS == 2 */

int lwip_accept(int s, struct sockaddr *addr, socklen_t *addrlen);
int lwip_bind(int s, const struct sockaddr *name, socklen_t namelen);
int lwip_shutdown(int s, int how);
int lwip_getpeername (int s, struct sockaddr *name, socklen_t *namelen);
int lwip_getsockname (int s, struct sockaddr *name, socklen_t *namelen);
int lwip_getsockopt (int s, int level, int optname, void *optval, socklen_t *optlen);
int lwip_setsockopt (int s, int level, int optname, const void *optval, socklen_t optlen);
 int lwip_close(int s);
int lwip_connect(int s, const struct sockaddr *name, socklen_t namelen);
int lwip_listen(int s, int backlog);
ssize_t lwip_recv(int s, void *mem, size_t len, int flags);
ssize_t lwip_read(int s, void *mem, size_t len);
ssize_t lwip_readv(int s, const struct iovec *iov, int iovcnt);
ssize_t lwip_recvfrom(int s, void *mem, size_t len, int flags,
      struct sockaddr *from, socklen_t *fromlen);
ssize_t lwip_recvmsg(int s, struct msghdr *message, int flags);
ssize_t lwip_send(int s, const void *dataptr, size_t size, int flags);
ssize_t lwip_sendmsg(int s, const struct msghdr *message, int flags);
ssize_t lwip_sendto(int s, const void *dataptr, size_t size, int flags,
    const struct sockaddr *to, socklen_t tolen);
int lwip_socket(int domain, int type, int protocol);
ssize_t lwip_write(int s, const void *dataptr, size_t size);
ssize_t lwip_writev(int s, const struct iovec *iov, int iovcnt);
#if LWIP_SOCKET_SELECT
int lwip_select(int maxfdp1, fd_set *readset, fd_set *writeset, fd_set *exceptset,
                struct timeval *timeout);
#endif
#if LWIP_SOCKET_POLL
int lwip_poll(struct pollfd *fds, nfds_t nfds, int timeout);
#endif
int lwip_ioctl(int s, long cmd, void *argp);
int lwip_fcntl(int s, int cmd, int val);
const char *lwip_inet_ntop(int af, const void *src, char *dst, socklen_t size);
int lwip_inet_pton(int af, const char *src, void *dst);

#if LWIP_COMPAT_SOCKETS
#if LWIP_COMPAT_SOCKETS != 2
/** @ingroup socket */
#define accept(s,addr,addrlen)                    lwip_accept(s,addr,addrlen)
/** @ingroup socket */
#define bind(s,name,namelen)                      lwip_bind(s,name,namelen)
/** @ingroup socket */
#define shutdown(s,how)                           lwip_shutdown(s,how)
/** @ingroup socket */
#define getpeername(s,name,namelen)               lwip_getpeername(s,name,namelen)
/** @ingroup socket */
#define getsockname(s,name,namelen)               lwip_getsockname(s,name,namelen)
/** @ingroup socket */
#define setsockopt(s,level,optname,opval,optlen)  lwip_setsockopt(s,level,optname,opval,optlen)
/** @ingroup socket */
#define getsockopt(s,level,optname,opval,optlen)  lwip_getsockopt(s,level,optname,opval,optlen)
/** @ingroup socket */
#define closesocket(s)                            lwip_close(s)
/** @ingroup socket */
#define connect(s,name,namelen)                   lwip_connect(s,name,namelen)
/** @ingroup socket */
#define listen(s,backlog)                         lwip_listen(s,backlog)
/** @ingroup socket */
#define recv(s,mem,len,flags)                     lwip_recv(s,mem,len,flags)
/** @ingroup socket */
#define recvmsg(s,message,flags)                  lwip_recvmsg(s,message,flags)
/** @ingroup socket */
#define recvfrom(s,mem,len,flags,from,fromlen)    lwip_recvfrom(s,mem,len,flags,from,fromlen)
/** @ingroup socket */
#define send(s,dataptr,size,flags)                lwip_send(s,dataptr,size,flags)
/** @ingroup socket */
#define sendmsg(s,message,flags)                  lwip_sendmsg(s,message,flags)
/** @ingroup socket */
#define sendto(s,dataptr,size,flags,to,tolen)     lwip_sendto(s,dataptr,size,flags,to,tolen)
/** @ingroup socket */
#define socket(domain,type,protocol)              lwip_socket(domain,type,protocol)
#if LWIP_SOCKET_SELECT
/** @ingroup socket */
#define select(maxfdp1,readset,writeset,exceptset,timeout)     lwip_select(maxfdp1,readset,writeset,exceptset,timeout)
#endif
#if LWIP_SOCKET_POLL
/** @ingroup socket */
#define poll(fds,nfds,timeout)                    lwip_poll(fds,nfds,timeout)
#endif
/** @ingroup socket */
#define ioctlsocket(s,cmd,argp)                   lwip_ioctl(s,cmd,argp)
/** @ingroup socket */
#define inet_ntop(af,src,dst,size)                lwip_inet_ntop(af,src,dst,size)
/** @ingroup socket */
#define inet_pton(af,src,dst)                     lwip_inet_pton(af,src,dst)

#if LWIP_POSIX_SOCKETS_IO_NAMES
/** @ingroup socket */
#define read(s,mem,len)                           lwip_read(s,mem,len)
/** @ingroup socket */
#define readv(s,iov,iovcnt)                       lwip_readv(s,iov,iovcnt)
/** @ingroup socket */
#define write(s,dataptr,len)                      lwip_write(s,dataptr,len)
/** @ingroup socket */
#define writev(s,iov,iovcnt)                      lwip_writev(s,iov,iovcnt)
/** @ingroup socket */
#define close(s)                                  lwip_close(s)
/** @ingroup socket */
#define fcntl(s,cmd,val)                          lwip_fcntl(s,cmd,val)
/** @ingroup socket */
#define ioctl(s,cmd,argp)                         lwip_ioctl(s,cmd,argp)
#endif /* LWIP_POSIX_SOCKETS_IO_NAMES */
#endif /* LWIP_COMPAT_SOCKETS != 2 */

#endif /* LWIP_COMPAT_SOCKETS */

#ifdef __cplusplus
}
#endif

#endif /* LWIP_SOCKET */

#endif /* LWIP_HDR_SOCKETS_H */
