/* SPDX-License-Identifier: BSD-3-Clause */
/*
 * Authors: Alexander Jung <alexander.jung@neclab.eu>
 *          Marc Rittinghaus <marc.rittinghaus@kit.edu>
 *
 * Copyright (c) 2020, NEC Laboratories Europe GmbH, NEC Corporation.
 *                     All rights reserved.
 * Copyright (c) 2021, Karlsruhe Institute of Technology (KIT).
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
#include <uk/assert.h>
#include <uk/print.h>
#include <uk/essentials.h>
#include <uk/socket_driver.h>

#include <lwip/sockets.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <lwip/priv/sockets_priv.h>
#include <lwip/api.h>
#include <lwip/sys.h>
#include <lwip/tcp.h>
#include <lwip/tcpbase.h>

static inline
int _lwip_ignore_noncrit_msgflags(int flags)
{
	return flags & ~(MSG_NOSIGNAL);
}

static inline
int _lwip_getfd(posix_sock *sock)
{
	return (intptr_t)posix_sock_get_data(sock);
}

static int
lwip_socket_apply_flags(int lwip_fd, int flags)
{
	int val = 1;

	/* Set FIONBIO unconditionally, as posix-socket handles blocking
	 * internally and expects lwip sockets to be always non-blocking.
	 */
	val = lwip_ioctl(lwip_fd, FIONBIO, &val);
	if (unlikely(val < 0)) {
		return -errno;
	}

	/* Ignore SOCK_CLOEXEC */

	return 0;
}

static void *
lwip_posix_socket_create(struct posix_socket_driver *d, int family, int type,
			 int protocol)
{
	int lwip_fd;
	int flags, rc;

	flags = type & SOCK_FLAGS;
	type = type & ~SOCK_FLAGS;

	lwip_fd = lwip_socket(family, type, protocol);
	if (unlikely(lwip_fd < 0))
		return ERR2PTR(-errno);

	rc = lwip_socket_apply_flags(lwip_fd, flags);
	if (unlikely(rc)) {
		(void)lwip_close(lwip_fd);
		return ERR2PTR(rc);
	}

	return (void *)(intptr_t)lwip_fd;
}

static void *
lwip_posix_socket_accept4(posix_sock *file,
			  struct sockaddr *restrict addr,
			  socklen_t *restrict addr_len, int flags)
{
	int listen_fd, new_fd;
	int rc;

	listen_fd = _lwip_getfd(file);
	UK_ASSERT(listen_fd >= 0);

	new_fd = lwip_accept(listen_fd, addr, addr_len);
	if (unlikely(new_fd < 0))
		return ERR2PTR(-errno);

	rc = lwip_socket_apply_flags(new_fd, flags);
	if (unlikely(rc)) {
		(void)lwip_close(new_fd);
		return ERR2PTR(rc);
	}

	return (void *)(intptr_t)new_fd;
}

static int
lwip_posix_socket_bind(posix_sock *file,
		       const struct sockaddr *addr,
		       socklen_t addr_len)
{
	int lwip_fd;
	int ret;

	lwip_fd = _lwip_getfd(file);
	UK_ASSERT(lwip_fd >= 0);

	ret = lwip_bind(lwip_fd, addr, addr_len);
	if (unlikely(ret < 0))
		ret = -errno;

	return ret;
}

static int
lwip_posix_socket_shutdown(posix_sock *file, int how)
{
	int lwip_fd;
	int ret;

	lwip_fd = _lwip_getfd(file);
	UK_ASSERT(lwip_fd >= 0);

	ret = lwip_shutdown(lwip_fd, how);
	if (unlikely(ret < 0))
		ret = -errno;

	return ret;
}

static int
lwip_posix_socket_getpeername(posix_sock *file,
			      struct sockaddr *restrict addr,
			      socklen_t *restrict addr_len)
{
	int lwip_fd;
	int ret;

	lwip_fd = _lwip_getfd(file);
	UK_ASSERT(lwip_fd >= 0);

	ret = lwip_getpeername(lwip_fd, addr, addr_len);
	if (unlikely(ret < 0))
		ret = -errno;

	return ret;
}

static int
lwip_posix_socket_getsockname(posix_sock *file,
			      struct sockaddr *restrict addr,
			      socklen_t *restrict addr_len)
{
	int lwip_fd;
	int ret;

	lwip_fd = _lwip_getfd(file);
	UK_ASSERT(lwip_fd >= 0);

	ret = lwip_getsockname(lwip_fd, addr, addr_len);
	if (unlikely(ret < 0))
		ret = -errno;

	return ret;
}

static int
lwip_posix_socket_getsockopt(posix_sock *file, int level,
			     int optname, void *restrict optval,
			     socklen_t *restrict optlen)
{
	int lwip_fd;
	int ret;

	lwip_fd = _lwip_getfd(file);
	UK_ASSERT(lwip_fd >= 0);

	ret = lwip_getsockopt(lwip_fd, level, optname, optval, optlen);
	if (unlikely(ret < 0))
		ret = -errno;

	return ret;
}

#define LINUX_SOL_TCP 6
#define LINUX_TCP_FASTOPEN 23

static int
lwip_posix_socket_setsockopt(posix_sock *file, int level,
			     int optname, const void *optval, socklen_t optlen)
{
	int lwip_fd;
	int ret;

	lwip_fd = _lwip_getfd(file);
	UK_ASSERT(lwip_fd >= 0);

	if ((level == LINUX_SOL_TCP && optname == LINUX_TCP_FASTOPEN) ||
	    (level == SOL_IP && optname == IP_RECVERR)) {
		/* Ignore stuff that LWIP doesn't support */
		return 0;
	}
	ret = lwip_setsockopt(lwip_fd, level, optname, optval, optlen);
	if (unlikely(ret < 0))
		ret = -errno;

	return ret;
}

static int
lwip_posix_socket_connect(posix_sock *file,
			  const struct sockaddr *addr, socklen_t addr_len)
{
	int lwip_fd;
	int ret;

	lwip_fd = _lwip_getfd(file);
	UK_ASSERT(lwip_fd >= 0);

	ret = lwip_connect(lwip_fd, addr, addr_len);
	if (unlikely(ret < 0))
		ret = -errno;

	return ret;
}

static int
lwip_posix_socket_listen(posix_sock *file, int backlog)
{
	int lwip_fd;
	int ret;

	lwip_fd = _lwip_getfd(file);
	UK_ASSERT(lwip_fd >= 0);

	ret = lwip_listen(lwip_fd, backlog);
	if (unlikely(ret < 0))
		ret = -errno;

	return ret;
}

static ssize_t
lwip_posix_socket_recvfrom(posix_sock *file, void *restrict buf,
			   size_t len, int flags, struct sockaddr *from,
			   socklen_t *restrict fromlen)
{
	int lwip_fd;
	ssize_t ret;

	flags = _lwip_ignore_noncrit_msgflags(flags);

	lwip_fd = _lwip_getfd(file);
	UK_ASSERT(lwip_fd >= 0);

	ret = lwip_recvfrom(lwip_fd, buf, len, flags, from, fromlen);
	if (unlikely(ret < 0))
		ret = -errno;

	return ret;
}

static ssize_t
lwip_posix_socket_recvmsg(posix_sock *file, struct msghdr *msg,
			  int flags)
{
	int lwip_fd;
	ssize_t ret;

	flags = _lwip_ignore_noncrit_msgflags(flags);

	lwip_fd = _lwip_getfd(file);
	UK_ASSERT(lwip_fd >= 0);

	ret = lwip_recvmsg(lwip_fd, msg, flags);
	if (unlikely(ret < 0))
		ret = -errno;

	return ret;
}

static ssize_t
lwip_posix_socket_sendmsg(posix_sock *file,
			  const struct msghdr *msg, int flags)
{
	int lwip_fd;
	ssize_t ret;

	flags = _lwip_ignore_noncrit_msgflags(flags);

	lwip_fd = _lwip_getfd(file);
	UK_ASSERT(lwip_fd >= 0);
	ret = lwip_sendmsg(lwip_fd, msg, flags);
	if (unlikely(ret < 0))
		ret = -errno;

	return ret;
}

static ssize_t
lwip_posix_socket_sendto(posix_sock *file, const void *buf,
			 size_t len, int flags,
			 const struct sockaddr *dest_addr,
			 socklen_t addrlen)
{
	int lwip_fd;
	ssize_t ret;

	flags = _lwip_ignore_noncrit_msgflags(flags);

	lwip_fd = _lwip_getfd(file);
	UK_ASSERT(lwip_fd >= 0);

	ret = lwip_sendto(lwip_fd, buf, len, flags,
			  dest_addr, addrlen);
	if (unlikely(ret < 0))
		ret = -errno;

	return ret;
}

static ssize_t
lwip_posix_socket_read(posix_sock *file, const struct iovec *iov,
		       size_t iovcnt)
{
	int lwip_fd;
	ssize_t ret;

	lwip_fd = _lwip_getfd(file);
	UK_ASSERT(lwip_fd >= 0);

	ret = lwip_readv(lwip_fd, iov, iovcnt);
	if (unlikely(ret < 0))
		ret = -errno;

	return ret;
}

static ssize_t
lwip_posix_socket_write(posix_sock *file, const struct iovec *iov,
			size_t iovcnt)
{
	int lwip_fd;
	ssize_t ret;

	lwip_fd = _lwip_getfd(file);
	UK_ASSERT(lwip_fd >= 0);

	ret = lwip_writev(lwip_fd, iov, iovcnt);
	if (unlikely(ret < 0))
		ret = -errno;

	return ret;
}

static int
lwip_posix_socket_close(posix_sock *file)
{
	int lwip_fd;
	int ret;

	lwip_fd = _lwip_getfd(file);
	UK_ASSERT(lwip_fd >= 0);

	ret = lwip_close(lwip_fd);
	if (unlikely(ret < 0))
		ret = -errno;

	return ret;
}

static int
lwip_posix_socket_ioctl(posix_sock *file, int request, void *argp)
{
	int lwip_fd;
	int ret;

	lwip_fd = _lwip_getfd(file);
	UK_ASSERT(lwip_fd >= 0);

	ret = lwip_ioctl(lwip_fd, request, argp);
	if (unlikely(ret < 0))
		ret = -errno;

	return ret;
}

#if LWIP_NETCONN_FULLDUPLEX
#define NETCONN_RECVMBOX_WAITABLE(conn)					\
	(sys_mbox_valid(&(conn)->recvmbox) &&				\
	 (((conn)->flags & NETCONN_FLAG_MBOXINVALID) == 0))
#else /* LWIP_NETCONN_FULLDUPLEX */
#define NETCONN_RECVMBOX_WAITABLE(conn)					\
	sys_mbox_valid(&(conn)->recvmbox)
#endif /* LWIP_NETCONN_FULLDUPLEX */

static unsigned int
get_lwip_socket_events(struct lwip_sock *sock)
{
	unsigned int events = 0;

	UK_ASSERT(sock);

	if ((NETCONNTYPE_GROUP(sock->conn->type) == NETCONN_TCP)) {
		/* A TCP connection may be in not-connected state. Don't report it as
		 * readable or writeable.
		 */
		if ((sock->conn->state == NETCONN_NONE) &&
		    (!NETCONN_RECVMBOX_WAITABLE(sock->conn))) {
			if (sock->errevent != 0)
				events |= EPOLLERR;

			return events;
		}

                /* Check whether the TCP connection is in CLOSE_WAIT (= got a
                 * FIN packet). In that case the peer will not sent more data
                 * and we can tell the application that the receive buffer is
                 * everything we got until the EOF.
                 */
                if (sock->conn->pcb.tcp == NULL ||
		    sock->conn->pcb.tcp->state == CLOSE_WAIT)
			events |= EPOLLRDHUP;
	}

	if (sock->lastdata.pbuf || sock->rcvevent > 0)
		events |= EPOLLIN | EPOLLRDNORM;
	if (sock->sendevent != 0)
		events |= EPOLLOUT | EPOLLWRNORM;
	if (sock->errevent != 0)
		events |= EPOLLERR;

	return events;
}

void
lwip_posix_socket_event_callback(struct lwip_sock *sock,
				 enum netconn_evt evt __unused,
				 u16_t len __unused)
{
	posix_sock *sockobj;
	unsigned int events;

	UK_ASSERT(sock);
	if (unlikely(!sock->sock_data))
		return;

	sockobj = (posix_sock *)sock->sock_data;
	UK_ASSERT(_lwip_getfd(sockobj) == sock->conn->socket);

	events = get_lwip_socket_events(sock);
	posix_sock_event_assign(sockobj, events);
}

static void
lwip_posix_socket_poll_setup(posix_sock *file)
{
	int lwip_fd;
	unsigned revents;
	struct lwip_sock *sock;
	SYS_ARCH_DECL_PROTECT(lev);

	lwip_fd = _lwip_getfd(file);

	SYS_ARCH_PROTECT(lev);
	/* This is a bit hacky but lwip does not provide a different public
	 * interface to get a reference to the socket. Furthermore, this
	 * function does not increase the reference count which is good
	 * as we do not hold the reference longer than the lock anyways. Since
	 * we need to hold the lock for evaluating the socket state this fits
	 * in well.
	 */
	sock = lwip_socket_dbg_get_socket(lwip_fd);
	revents = get_lwip_socket_events(sock);
	sock->sock_data = (void *)file;
	SYS_ARCH_UNPROTECT(lev);
	posix_sock_event_assign(file, revents);
}

static struct posix_socket_ops lwip_posix_socket_ops = {
	/* POSIX interfaces */
	.create		= lwip_posix_socket_create,
	.accept4	= lwip_posix_socket_accept4,
	.bind		= lwip_posix_socket_bind,
	.shutdown	= lwip_posix_socket_shutdown,
	.getpeername	= lwip_posix_socket_getpeername,
	.getsockname	= lwip_posix_socket_getsockname,
	.getsockopt	= lwip_posix_socket_getsockopt,
	.setsockopt	= lwip_posix_socket_setsockopt,
	.connect	= lwip_posix_socket_connect,
	.listen		= lwip_posix_socket_listen,
	.recvfrom	= lwip_posix_socket_recvfrom,
	.recvmsg	= lwip_posix_socket_recvmsg,
	.sendmsg	= lwip_posix_socket_sendmsg,
	.sendto		= lwip_posix_socket_sendto,
	/* vfscore ops */
	.read		= lwip_posix_socket_read,
	.write		= lwip_posix_socket_write,
	.close		= lwip_posix_socket_close,
	.ioctl		= lwip_posix_socket_ioctl,
	.poll_setup	= lwip_posix_socket_poll_setup,
};

POSIX_SOCKET_FAMILY_REGISTER(AF_INET, &lwip_posix_socket_ops);

#ifdef CONFIG_LWIP_IPV6
POSIX_SOCKET_FAMILY_REGISTER(AF_INET6, &lwip_posix_socket_ops);
#endif /* CONFIG_LWIP_IPV6 */
