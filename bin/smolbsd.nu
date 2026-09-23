#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# DEPRECATED shim — smolbsd.nu was renamed to smolfire.nu (issue #41).
# This wrapper forwards all arguments and will be removed after one release.
def --wrapped main [...args] {
    print -e "smolbsd.nu is deprecated; use bin/smolfire.nu (project renamed smolBSD -> smolfire)"
    ^nu $"($env.FILE_PWD)/smolfire.nu" ...$args
    exit $env.LAST_EXIT_CODE
}
