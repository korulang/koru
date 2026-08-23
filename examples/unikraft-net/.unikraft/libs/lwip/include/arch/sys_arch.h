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
/*
 * lwip/arch/sys_arch.h
 *
 * Arch-specific semaphores and mailboxes for lwIP running on mini-os
 *
 * Tim Deegan <Tim.Deegan@eu.citrix.net>, July 2007
 * Simon Kuenzer <Simon.Kuenzer@neclab.eu>, October 2014
 */

#ifndef __LWIP_ARCH_SYS_ARCH_H__
#define __LWIP_ARCH_SYS_ARCH_H__

#include <uk/config.h>

#include <stdlib.h>
#include <uk/mutex.h>
#include <uk/semaphore.h>
#include <uk/mbox.h>

#if CONFIG_LWIP_THREADS
#include <uk/thread.h>
#endif /* CONFIG_LWIP_THREADS */

#if CONFIG_LWIP_SOCKET && CONFIG_HAVE_LIBC
#include <fcntl.h>
#endif /* CONFIG_LWIP_SOCKET && CONFIG_HAVE_LIBC */

#define SYS_SEM_NULL   NULL
#define SYS_MUTEX_NULL NULL
#define SYS_MBOX_NULL  NULL

typedef struct {
	struct uk_mutex mtx;
	int valid;
} sys_mutex_t;

typedef struct {
	struct uk_semaphore sem;
	int valid;
} sys_sem_t;

typedef struct {
	struct uk_alloc *a;
	struct uk_mbox *mbox;
	int valid;
} sys_mbox_t;

#if CONFIG_LWIP_THREADS
typedef struct uk_thread *sys_thread_t;
#endif /* CONFIG_LWIP_THREADS */

typedef unsigned long sys_prot_t;

#endif /*__LWIP_ARCH_SYS_ARCH_H__ */
