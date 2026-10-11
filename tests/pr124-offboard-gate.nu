#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# No diagnostic license exception exists. This entry point deliberately cannot
# compile, simulate, invoke a shell, or produce PASS until its replacement has
# an admitted actual-native interface and complete remote tool graph.
def main [] {
    error make {msg: "PR124 HOLD: no admitted native decoder/RTL route; fixture proposal is not a native test. See docs/MEDIA-LOG-V2-SOURCE-GATES.md"}
}
