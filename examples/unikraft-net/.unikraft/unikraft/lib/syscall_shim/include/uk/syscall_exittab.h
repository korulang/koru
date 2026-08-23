/* SPDX-License-Identifier: BSD-3-Clause */
/* Copyright (c) 2024, Unikraft GmbH and The Unikraft Authors.
 * Licensed under the BSD-3-Clause License (the "License").
 * You may not use this file except in compliance with the License.
 */

#ifndef __UK_SYSCALL_EXITTAB_H__
#define __UK_SYSCALL_EXITTAB_H__

#include <uk/assert.h>
#include <uk/arch/ctx.h>

struct uk_syscall_exit_ctx {
	struct ukarch_execenv *execenv;
	unsigned long nested_depth;
#define UK_SYSCALL_EXIT_CTX_BINARY_SYSCALL		(1 << 0)
	__u32 flags;
};

#if CONFIG_LIBSYSCALL_SHIM
/*
 * Initialize a system call exit context.
 *
 * @param exit_ctx
 *   Pointer to the exit context to initialize
 * @param execenv
 *   Pointer to the execution environment to be used on exit context
 *   initialization
 * @param nested_depth
 *   How many system calls have been called (native or binary) on this
 *   current context before this system call on whose exit we are going
 *   to run the system call exit table, plus one, the system call itself.
 *   This helps us tell whether we are in a nested system call or not.
 *   E.g., if this is the first system call called, then this should be 1;
 *   if this is a system call called by another system call then this should
 *   be previous system call's nested_depth + 1.
 * @param flags
 *   System call exit context flags:
 *   UK_SYSCALL_EXIT_CTX_BINARY_SYSCALL		We are in a binary system
 *						call's context
 */
static inline
void uk_syscall_exit_ctx_init(struct uk_syscall_exit_ctx *exit_ctx,
			      struct ukarch_execenv *execenv,
			      unsigned long nested_depth,
			      __u32 flags)
{
	UK_ASSERT(exit_ctx);
	exit_ctx->execenv = execenv;
	exit_ctx->nested_depth = nested_depth;
	exit_ctx->flags = flags;
}
#else /* !CONFIG_LIBSYSCALL_SHIM */
static inline
void uk_syscall_exit_ctx_init(struct uk_syscall_exit_ctx *exit_ctx __unused,
			      struct ukarch_execenv *execenv __unused,
			      unsigned long nested_depth __unused,
			      __u32 flags __unused)
{ }
#endif /* !CONFIG_LIBSYSCALL_SHIM */

typedef void (*uk_syscall_exittab_func_t)(struct uk_syscall_exit_ctx *);

struct uk_syscall_exittab_entry {
	uk_syscall_exittab_func_t func;
};

extern const struct uk_syscall_exittab_entry uk_syscall_exittab_start[];
extern const struct uk_syscall_exittab_entry uk_syscall_exittab_end;

extern __thread unsigned long uk_syscall_nested_depth;

/**
 * Helper macro for iterating over system call exit functions.
 * Please note that the table may contain NULL pointer entries.
 *
 * @param itr
 *   Iterator variable (struct uk_syscall_exittab_entry *) which points to the
 *   individual table entries during iteration
 * @param syscall_exittab_start
 *   Start address of table (type: const struct uk_syscall_exittab_entry[])
 * @param syscall_exittab_end
 *   End address of table (type: const struct uk_syscall_exittab_entry)
 */
#define uk_syscall_exittab_foreach(itr, tab_start, tab_end)		\
	for ((itr) = DECONST(struct uk_syscall_exittab_entry *, tab_start);\
	     (itr) < &(tab_end);					\
	     (itr)++)

/**
 * Register a Unikraft system call exit function.
 *
 * @param fn
 *   System call exit function to be called
 * @param prio
 *   Priority level: (`UK_PRIO_ EARLIEST()` to `UK_PRIO_LATEST()`).
 *   Use the UK_PRIO_AFTER()/UK_PRIO_BEFORE() helper macro for computing
 *   priority dependencies.
 *   Note: Any other value for level will be ignored
 */
#define __UK_SYSCALL_EXITTAB_ENTRY(fn, prio)				\
	static const struct uk_syscall_exittab_entry			\
	__used __section(".uk_syscall_exittab" #prio) __align(8)	\
		__uk_syscall_exittab ## prio ## _ ## fn = {		\
		.func = (fn),						\
	}

#define _UK_SYSCALL_EXITTAB(fn, prio)					\
	__UK_SYSCALL_EXITTAB_ENTRY(fn, prio)

#define uk_syscall_exittab_prio(fn, prio)				\
	_UK_SYSCALL_EXITTAB(fn, prio)

#if CONFIG_LIBSYSCALL_SHIM
/*
 * Run the routines registered into the hooked system call exit table routines.
 * If any of those routines fails, then system will crash as there is no sane
 * error value to be returned to the system call caller.
 *
 * @param exit_ctx
 *   Pointer to the system call exit context
 */
static inline
void uk_syscall_exittab_run(struct uk_syscall_exit_ctx *exit_ctx)
{
	struct uk_syscall_exittab_entry *entry;

	UK_ASSERT(exit_ctx);

	uk_pr_debug("Syscall exit table @ %p - %p\n",
		    &uk_syscall_exittab_start[0], &uk_syscall_exittab_end);

	uk_syscall_exittab_foreach(entry,
				   uk_syscall_exittab_start,
				   uk_syscall_exittab_end) {
		UK_ASSERT(entry);

		if (!entry->func)
			continue;

		uk_pr_debug("Call syscall exit table entry: %p(%p)...\n",
			    entry->func, exit_ctx);
		(*entry->func)(exit_ctx);
	}
}
#else /* !CONFIG_LIBSYSCALL_SHIM */
static inline
void uk_syscall_exittab_run(struct uk_syscall_exit_ctx *exit_ctx __unused)
{ }
#endif /* !CONFIG_LIBSYSCALL_SHIM */
#endif /* __UK_SYSCALL_EXITTAB_H__ */
