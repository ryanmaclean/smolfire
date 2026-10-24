<!-- SPDX-License-Identifier: Apache-2.0 -->
# tools/ — DUT serial drivers (Python exception)

Owner-granted Python exception (2026-10-07, recorded in `AGENTS.md` language
policy + `tests/no-new-python-test.nu` allow-list): Nushell cannot do
serial-port I/O, so the DUT drivers are Python. Everything else new stays
Nushell.

## Files

| File | What it does |
|------|--------------|
| `tools/dut_kv.py` | Durable KV demo: DUT supplies commit order (single-submit path), host holds data in dict + fsync'd JSONL log. Cmds: `sanity`, `run`, `slow-load`, `recover`. |
| `tools/dispatch_journal.py` | Coordinator dispatch/harvest journal: every dispatch + harvest is a durable DUT op; host holds fsync'd JSONL mirror + dispatch_id→[TIDs] index. Cmds: `sanity`, `stream`, `recover`, `history`, `audit`. |

## Usage

```sh
python3 tools/dut_kv.py --port /dev/ttyUSB1 --baud 115200 sanity
python3 tools/dut_kv.py --port /dev/ttyUSB1 run          # 100 puts + 30 deletes, DUP-retry check
python3 tools/dut_kv.py --port /dev/ttyUSB1 slow-load --n 200 --delay 0.05
python3 tools/dut_kv.py --port /dev/ttyUSB1 recover      # replay log, gap analysis, tail re-drive

python3 tools/dispatch_journal.py --port /dev/ttyUSB1 sanity
python3 tools/dispatch_journal.py --port /dev/ttyUSB1 stream    # 20 dispatches + 20 harvests, 4 waves
python3 tools/dispatch_journal.py --port /dev/ttyUSB1 recover   # resume from kill point, unacked-tail DUP confirm
python3 tools/dispatch_journal.py --port /dev/ttyUSB1 audit     # hash-chain + pairing + watermark + at-most-once
python3 tools/dispatch_journal.py --port /dev/ttyUSB1 history --task-id bravo
python3 tools/dut_kv.py --help   # same for dispatch_journal.py
```

Defaults: `--port /dev/ttyUSB1 --baud 115200` (Tang debugger UART). Logs
default to `/tmp/kv_demo.log` / `/tmp/dispatch_journal.log`. `run`/`stream`
refuse to start if the log already exists (delete for a clean run).

## Host requirements

- Python 3.10+, `pyserial` (`pip install pyserial`).
- Tang board debugger UART presenting as a USB tty; 115200 8-N-1.
- No hardware writes beyond the script's own protocol ops; `sanity` is
  PING + READs plus one RESET (reset-count +1 asserted, durable unchanged).

## Protocol pointer

Wire protocol (8-byte frame `44 55 cmd addr data[4] checksum`, register map,
DURABLE/VISIBLE/ERROR semantics, UART divisor): `rtl/README.md` — UART
front-end section (`rtl/dut_uart.v`, `rtl/dut_top_uart.v`).

## Honesty notes

- Origins: both files are the `/tmp` throwaways `kv_demo.py` (331 lines) and
  `dispatch_journal.py` (419 lines) from the build host (`7950x4090pop`),
  fetched 2026-10-07 and verified present with the expected logic before
  committing. Only deliberate change vs the throwaways: `--baud` CLI flag
  added (`--port` already existed); behavior otherwise byte-identical logic.
- Live-proven counts are what the scripts themselves assert on a PASS run:
  KV `run` = 100/100 puts exact, 30/30 deletes, 70/70 survivors, retry→DUP;
  journal `stream`/`recover` = 40/40 TIDs (20 dispatch + 20 harvest),
  `audit` = hash-chain + 20/20 pairing + watermarks + DUP re-drives. Those
  PASS lines were produced against the live Tang DUT from the build host,
  not from this checkout — no hardware was touched by this commit
  (compile + `--help` + repo test suite only).
