/* SPDX-License-Identifier: BSD-3-Clause */
/* Copyright (c) 2024, Unikraft GmbH and The Unikraft Authors.
 * Licensed under the BSD-3-Clause License (the "License").
 * You may not use this file except in compliance with the License.
 */

#ifndef __UK_SYSCALL_ENTERTAB_H__
#define __UK_SYSCALL_ENTERTAB_H__

#include <uk/assert.h>
#include <uk/arch/ctx.h>

struct uk_syscall_enter_ctx {
	struct ukarch_execenv *execenv;
	unsigned long nested_depth;
#define UK_SYSCALL_ENTER_CTX_BINARY_SYSCALL		(1 << 0)
	__u32 flags;
};

#if CONFIG_LIBSYSCALL_SHIM
/*
 * Initialize a system call enter context.
 *
 * @param enter_ctx
 *   Pointer to the enter context to initialize
 * @param execenv
 *   Pointer to the execution environment to be used on enter context
 *   initialization
 * @param nested_depth
 *   How many system calls have been called (native or binary) on this
 *   current context before this system call on whose entry we are going
 *   to run the system call enter table, plus one, the system call itself.
 *   This helps us tell whether we are in a nested system call or not.
 *   E.g., if this is the first system call called, then this should be 1;
 *   if this is a system call called by another system call then this should
 *   be previous system call's nested_depth + 1.
 * @param flags
 *   System call enter context flags:
 *   UK_SYSCALL_ENTER_CTX_BINARY_SYSCALL	We are in a binary system
 *						call's context
 */
static inline
void uk_syscall_enter_ctx_init(struct uk_syscall_enter_ctx *enter_ctx,
			       struct ukarch_execenv *execenv,
			       unsigned long nested_depth,
			       __u32 flags)
{
	UK_ASSERT(enter_ctx);
	enter_ctx->execenv = execenv;
	enter_ctx->nested_depth = nested_depth;
	enter_ctx->flags = flags;
}
#else /* !CONFIG_LIBSYSCALL_SHIM */
static inline
void uk_syscall_enter_ctx_init(struct uk_syscall_enter_ctx *enter_ctx __unused,
			       struct ukarch_execenv *execenv __unused,
			       unsigned long nested_depth __unused,
			       __u32 flags __unused)
{ }
#endif /* !CONFIG_LIBSYSCALL_SHIM */

typedef void (*uk_syscall_entertab_func_t)(struct uk_syscall_enter_ctx *);

struct uk_syscall_entertab_entry {
	uk_syscall_entertab_func_t func;
};

extern const struct uk_syscall_entertab_entry uk_syscall_entertab_start[];
extern const struct uk_syscall_entertab_entry uk_syscall_entertab_end;

extern __thread unsigned long uk_syscall_nested_depth;

/**
 * Helper macro for iterating over system call enter functions.
 * Please note that the table may contain NULL pointer entries.
 *
 * @param itr
 *   Iterator variable (struct uk_syscall_entertab_entry *) which points to the
 *   individual table entries during iteration
 * @param tab_start
 *   Start address of table (type: const struct uk_syscall_entertab_entry[])
 * @param tab_end
 *   End address of table (type: const struct uk_syscall_entertab_entry)
 */
#define uk_syscall_entertab_foreach(itr, tab_start, tab_end)		\
	for ((itr) = DECONST(struct uk_syscall_entertab_entry *, tab_start);\
	     (itr) < &(tab_end);					\
	     (itr)++)

/**
 * Register a Unikraft system call enter function.
 *
 * @param fn
 *   System call enter function to be called
 * @param prio
 *   Priority level: (`UK_PRIO_ EARLIEST()` to `UK_PRIO_LATEST()`).
 *   Use the UK_PRIO_AFTER()/UK_PRIO_BEFORE() helper macro for computing
 *   priority dependencies.
 *   Note: Any other value for level will be ignored
 */
#define __UK_SYSCALL_ENTERTAB_ENTRY(fn, prio)				\
	static const struct uk_syscall_entertab_entry			\
	__used __section(".uk_syscall_entertab" #prio) __align(8)	\
		__uk_syscall_entertab ## prio ## _ ## fn = {		\
		.func = (fn),						\
	}

#define _UK_SYSCALL_ENTERTAB(fn, prio)					\
	__UK_SYSCALL_ENTERTAB_ENTRY(fn, prio)

#define uk_syscall_entertab_prio(fn, prio)				\
	_UK_SYSCALL_ENTERTAB(fn, prio)

#if CONFIG_LIBSYSCALL_SHIM
/*
 * Run the routines registered into the hooked system call enter table routines.
 * If any of those routines fails, then system will crash as there is no sane
 * error value to be returned to the system call caller.
 *
 * @param enter_ctx
 *   Pointer to the system call enter context
 */
static inline
void uk_syscall_entertab_run(struct uk_syscall_enter_ctx *enter_ctx)
{
	struct uk_syscall_entertab_entry *entry;

	UK_ASSERT(enter_ctx);

	uk_pr_debug("Syscall enter table @ %p - %p\n",
		    &uk_syscall_entertab_start[0], &uk_syscall_entertab_end);

	uk_syscall_entertab_foreach(entry,
				    uk_syscall_entertab_start,
				    uk_syscall_entertab_end) {
		UK_ASSERT(entry);

		if (!entry->func)
			continue;

		uk_pr_debug("Call syscall enter table entry: %p(%p)...\n",
			    entry->func, enter_ctx);
		(*entry->func)(enter_ctx);
	}
}
#else /* !CONFIG_LIBSYSCALL_SHIM */
static inline
void uk_syscall_entertab_run(struct uk_syscall_enter_ctx *enter_ctx __unused)
{ }
#endif /* !CONFIG_LIBSYSCALL_SHIM */
#endif /* __UK_SYSCALL_ENTERTAB_H__ */
