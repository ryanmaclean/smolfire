<!-- SPDX-License-Identifier: Apache-2.0 -->
# #88 software fault injection — superstation1, Linux 6.18.38-MiSTer, 2026-09-25

| scenario | faults | SIGKILL (stop / external) | errno | violations | torn repaired | restart p50 / p99 ms |
|---|---|---|---|---|---|---|
| crash exFAT 64 B split 4 | 1200 | 727 / 418 | 55 | 0 | 407 | 5.5 / 26.9 |
| crash exFAT 4 KiB split 8 | 300 | 176 / 111 | 13 | 0 | 103 | 20.2 / 46.6 |
| fill tmpfs 256 KiB | 30 | - | ENOSPC 30 | 0 | 22 | 22.2 / 31.8 |
| fill FAT image on SD (loop) | 10 | - | ENOSPC 10 | 0 | 4 | 71.2 / 93.3 |
| fill FAT on full tmpfs (loop) | 30 | - | EIO 12, ENOSPC 18 | **25 acked_lost** | 0 | 16.3 / 31.6 |
| self-test mutant ack-early | 100 | 58 / 39 | 3 | 41 acked_lost (expected) | 36 | 5.2 / 13.6 |
| self-test mutant no-repair | 100 | 57 / 39 | 4 | 33 torn_exposed (expected) | 33 | 4.6 / 13.2 |

See docs/SUPERSTATION-FAULT-INJECTION-2026-09-25.md for method, the vfat-on-loop finding and the limits of software injection.
