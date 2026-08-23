/* SPDX-License-Identifier: BSD-3-Clause */
/* Copyright (c) 2024, Unikraft GmbH and The Unikraft Authors.
 * Licensed under the BSD-3-Clause License (the "License").
 * You may not use this file except in compliance with the License.
 */

SECTIONS
{
	. = ALIGN(8);

	.uk_syscall_exittab :
	{
		PROVIDE(uk_syscall_exittab_start = .);
		KEEP(*(SORT_BY_NAME(.uk_syscall_exittab[0-9])))
		PROVIDE(uk_syscall_exittab_end = .);
	}
}
INSERT AFTER .rodata;
