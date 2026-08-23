/* SPDX-License-Identifier: BSD-3-Clause */
/* Copyright (c) 2024, Unikraft GmbH and The Unikraft Authors.
 * Licensed under the BSD-3-Clause License (the "License").
 * You may not use this file except in compliance with the License.
 */

#include <uk/errptr.h>
#include <uk/random/driver.h>

#include <uk/boot/earlytab.h>

struct uk_random_driver_ops *device_init(void);

struct uk_random_driver driver = {
	.name = "CPU"
};

static int uk_random_lcpu_init(struct ukplat_bootinfo __unused *bi)
{
	int rc;

	/* Initialize the device. Issue a warning if the device is not
	 * available, to allow boot to proceed in case the application
	 * does not require randomness.
	 */
	driver.ops = device_init();
	if (unlikely(PTRISERR(driver.ops))) {
		uk_pr_warn("Could not initialize the HWRNG (%d)\n",
			   PTR2ERR(driver.ops));
		return 0;
	}

	/* Register with libukrandom. Return an error upon failure, as
	 * it's critical that the internal state of the CSPRNG has been
	 * correctly initialized before it's being requested to generate
	 * entropy.
	 */
	rc = uk_random_init(&driver);
	if (unlikely(rc)) {
		uk_pr_err("Could not register with libukrandom (%d)\n", rc);
		return rc;
	}

	return 0;
}

UK_BOOT_EARLYTAB_ENTRY(uk_random_lcpu_init, UK_RANDOM_EARLY_DRIVER_PRIO);
