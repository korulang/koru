/* SPDX-License-Identifier: BSD-3-Clause */
/*
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

#ifndef _UK_LWIP_SOCKET_H_

#ifdef __cplusplus
extern "C" {
#endif

#include <uk/config.h>
#if CONFIG_LWIP_SOCKET
#if CONFIG_HAVE_LIBC
#include <fcntl.h>
#include <poll.h>
#endif /* CONFIG_HAVE_LIBC */
#include <lwip/sockets.h>

#ifndef SOCK_CLOEXEC
#define SOCK_CLOEXEC    0x10000000
#endif

#ifndef SOCK_NONBLOCK
#define SOCK_NONBLOCK   0x20000000
#endif

#ifndef SOCK_SEQPACKET
#define SOCK_SEQPACKET 5
#endif

#ifndef SOMAXCONN
#define SOMAXCONN 128
#endif

#ifndef PF_LOCAL
#define PF_LOCAL 1
#endif

#ifndef PF_UNIX
#define PF_UNIX PF_LOCAL
#endif

#ifndef AF_LOCAL
#define AF_LOCAL PF_LOCAL /* Not supported/stub */
#endif

#ifndef AF_UNIX
#define AF_UNIX AF_LOCAL /* Not supported/stub */
#endif

#ifndef SCM_RIGHTS
#define SCM_RIGHTS 1 /* Not supported/stub */
#endif

int socket(int domain, int type, int protocol);
int accept(int s, struct sockaddr *addr, socklen_t *addrlen);
int bind(int s, const struct sockaddr *name, socklen_t namelen);
int shutdown(int s, int how);
int getpeername(int s, struct sockaddr *name, socklen_t *namelen);
int getsockname(int s, struct sockaddr *name, socklen_t *namelen);
int getsockopt(int s, int level, int optname, void *optval, socklen_t *optlen);
int setsockopt(int s, int level, int optname, const void *optval,
	       socklen_t optlen);
int connect(int s, const struct sockaddr *name, socklen_t namelen);
int listen(int s, int backlog);
ssize_t recv(int s, void *mem, size_t len, int flags);
ssize_t recvfrom(int s, void *mem, size_t len, int flags,
	     struct sockaddr *from, socklen_t *fromlen);
ssize_t recvmsg(int s, struct msghdr *msg, int flags);
ssize_t send(int s, const void *dataptr, size_t size, int flags);
ssize_t sendmsg(int s, const struct msghdr *message, int flags);
ssize_t sendto(int s, const void *dataptr, size_t size, int flags,
	   const struct sockaddr *to, socklen_t tolen);
int socketpair(int domain, int type, int protocol, int sv[2]);

#endif /* CONFIG_LWIP_SOCKET */

#ifdef __cplusplus
}
#endif

#endif /* _UK_LWIP_SOCKET_H_ */
