#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# No diagnostic license exception exists. This entry point deliberately cannot
# compile, simulate, invoke a shell, or produce PASS until the exact-head remote
# tool graph and separate RTL/media authority gates have admitted evidence.
def main [] {
    error make {msg: "PR124 HOLD: published C/Nu logical observer has no admitted exact-head CI route; RTL/media W/G and physical acceptance remain unproved. See docs/MEDIA-LOG-V2-SOURCE-GATES.md"}
}
