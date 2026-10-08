#!/usr/bin/env python3
"""dispatch_journal.py: coordinator dispatch/harvest journal.

Committed from the proven /tmp throwaway of the same name (live-proven on
Tang DUT); only change vs the throwaway is --port/--baud CLI flags. See
tools/README.md for origins and honesty notes.

Coordinator dispatch/harvest journal: every dispatch + harvest is a durable
DUT op (single-submit path). Content-hash(descriptor) -> DESC0/DESC1, host
holds the journal (fsync'd JSONL mirror + dispatch_id->[TIDs] index), DUT
supplies commit order. Same durability-v1 pattern as kv_demo.py.

Ops: 20 dispatches + 20 harvests, 4 waves of 5D+5H modeled on the live
5-task fan-out (dispatch->harvest latency per wave, logical S-003 retries
as fresh dispatch_ids). Telemetry field names mirror bin/coord-tick.nu:
task_id / message_id(dispatch_id) / executor / attempt / verdict.

Cmds: sanity | stream | recover | history | audit
"""
import argparse, binascii, hashlib, json, os, sys, time
import serial
from datetime import datetime, timezone

M0, M1 = 0x44, 0x55
CMD_WRITE, CMD_READ, CMD_RESET, CMD_PING = 0x01, 0x02, 0x03, 0x04
RSP_WRITE, RSP_READ, RSP_RESET, RSP_PING = 0x81, 0x82, 0x83, 0x84
A = dict(EPOCH=0x00, REQ_LO=0x04, DUR_LO=0x0C, VIS_LO=0x10, ERROR=0x18,
         PROG=0x1C, RSTCNT=0x20, CTRL=0x24, STATUS=0x28, DESC0=0x2C,
         DESC1=0x30, DESC_CRC=0x34, TID_LO=0x3C, REQ_HI=0x44, DUR_HI=0x48,
         VIS_HI=0x4C, MAGIC=0x54, VERSION=0x58)
CTRL_SUBMIT = 1
TR_N = 40
tr = []
def log(msg):
    tr.append(msg)
    if len(tr) > TR_N: tr.pop(0)
    print(msg, flush=True)
def dump_tr():
    print("--- transcript (last %d) ---" % len(tr), flush=True)
    for i, m in enumerate(tr): print("[%d] %s" % (i, m), flush=True)
    print("--- end transcript ---", flush=True)
def fail(msg):
    print("FAIL: %s" % msg, flush=True); dump_tr(); sys.exit(1)

def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

# ---------------- DUT driver (single-submit, copied pattern from kv_demo) ----
class DUT:
    def __init__(self, port, baud=115200):
        self.s = serial.Serial(port, baud, timeout=1)
        time.sleep(0.05); self.s.reset_input_buffer()
    def _cmd(self, cmd, addr, data, want):
        f = bytes([M0, M1, cmd, addr, data & 0xFF, (data >> 8) & 0xFF,
                   (data >> 16) & 0xFF, (data >> 24) & 0xFF,
                   (cmd + addr + (data & 0xFF) + ((data >> 8) & 0xFF) +
                    ((data >> 16) & 0xFF) + ((data >> 24) & 0xFF)) & 0xFF])
        self.s.reset_input_buffer(); self.s.write(f)
        r = self.s.read(8)
        if len(r) != 8: return None, "timeout cmd=0x%02x" % cmd
        if r[0] != M0 or r[1] != M1: return None, "bad magic %s" % r.hex()
        if (r[2] + r[3] + r[4] + r[5] + r[6]) & 0xFF != r[7]:
            return None, "bad chksum %s" % r.hex()
        if r[2] != want: return None, "want rsp 0x%02x got 0x%02x" % (want, r[2])
        return r[3] | r[4] << 8 | r[5] << 16 | r[6] << 24, None
    def write(self, addr, val):
        v, e = self._cmd(CMD_WRITE, addr, val & 0xFFFFFFFF, RSP_WRITE)
        if e: return e
        return None if v == (val & 0xFFFFFFFF) else "echo mismatch"
    def read(self, addr):
        return self._cmd(CMD_READ, addr, 0, RSP_READ)
    def ping(self): return self._cmd(CMD_PING, 0, 0, RSP_PING)
    def durable(self):
        lo, e1 = self.read(A["DUR_LO"])
        if e1: return None, e1
        hi, e2 = self.read(A["DUR_HI"])
        if e2: return None, e2
        return (hi << 32) | lo, None
    def visible(self):
        lo, e1 = self.read(A["VIS_LO"])
        if e1: return None, e1
        hi, e2 = self.read(A["VIS_HI"])
        if e2: return None, e2
        return (hi << 32) | lo, None
    def wait_idle(self, npoll=40):
        for _ in range(npoll):
            st, e = self.read(A["STATUS"])
            if e: return e
            if not (st & 1): return None
        return "busy stuck"

def desc_crc(d0, d1, req, epoch):
    b = (d0.to_bytes(4, "little") + d1.to_bytes(4, "little") +
         req.to_bytes(4, "little") + epoch.to_bytes(4, "little"))
    return binascii.crc32(b) & 0xFFFFFFFF

def content_hash(descriptor):
    h = hashlib.sha256(descriptor.encode()).digest()
    return int.from_bytes(h[0:4], "little"), int.from_bytes(h[4:8], "little")

# ---------------- plan: 20 dispatches + 20 harvests, 4 waves ------------------
# (dispatch_id, task_id, executor, attempt) per wave; harvest verdicts mixed.
WAVES = [
    ([("alpha", "vm", 1), ("bravo", "vm", 1), ("charlie", "jail", 1),
      ("delta", "vm", 1), ("echo", "vm", 1)],
     ["pass", "fail", "pass", "fail", "pass"]),
    ([("bravo", "vm", 2), ("delta", "vm", 2), ("foxtrot", "vm", 1),
      ("golf", "jail", 1), ("hotel", "vm", 1)],
     ["pass", "fail", "pass", "fail", "pass"]),
    ([("delta", "vm", 3), ("golf", "jail", 2), ("india", "vm", 1),
      ("juliet", "vm", 1), ("kilo", "vm", 1)],
     ["pass", "pass", "fail", "pass", "pass"]),
    ([("india", "vm", 2), ("lima", "vm", 1), ("mike", "jail", 1),
      ("november", "vm", 1), ("oscar", "vm", 1)],
     ["pass", "pass", "pass", "pass", "pass"]),
]

def build_plan():
    """40 ops in execution order: per wave 5 dispatches then 5 harvests."""
    ops = []
    dc = 0
    for disps, verdicts in WAVES:
        dids = []
        for (task, ex, att) in disps:
            did = "d%03d-%s-a%d" % (dc, task, att)
            ops.append({"op_seq": len(ops), "kind": "dispatch",
                        "dispatch_id": did, "task_id": task,
                        "executor": ex, "attempt": att, "verdict": ""})
            dids.append(did); dc += 1
        for did, v in zip(dids, verdicts):
            task = [o for o in ops if o["dispatch_id"] == did][0]["task_id"]
            ops.append({"op_seq": len(ops), "kind": "harvest",
                        "dispatch_id": did, "task_id": task,
                        "executor": "", "attempt": 0, "verdict": v})
    return ops

def descriptor_of(op, ts):
    if op["kind"] == "dispatch":
        return "dispatch|%s|%s|%s|%d|%s" % (
            op["dispatch_id"], op["task_id"], op["executor"],
            op["attempt"], ts)
    return "harvest|%s|%s|%s|%s" % (
        op["dispatch_id"], op["task_id"], op["verdict"], ts)

# ---------------- journal: fsync JSONL + index -------------------------------
class Journal:
    def __init__(self, path):
        self.path = path
        self.by_dispatch = {}   # dispatch_id -> [tids]
        self.by_task = {}       # task_id -> [recs]
        self.tids = set()
        self.lines = 0
    def append_fsync(self, rec):
        fd = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
        try:
            os.write(fd, (json.dumps(rec) + "\n").encode()); os.fsync(fd)
        finally: os.close(fd)
        self._index(rec)
    def _index(self, rec):
        if rec["tid"] in self.tids:
            fail("journal duplicate TID %d (double-apply!)" % rec["tid"])
        self.tids.add(rec["tid"])
        self.by_dispatch.setdefault(rec["dispatch_id"], []).append(rec["tid"])
        self.by_task.setdefault(rec["task_id"], []).append(rec)
        self.lines += 1
    def replay(self):
        n = 0
        with open(self.path) as f:
            for line in f:
                line = line.strip()
                if not line: continue
                self._index(json.loads(line)); n += 1
        # op_seq contiguity
        seqs = []
        with open(self.path) as f:
            for line in f:
                if line.strip(): seqs.append(json.loads(line)["op_seq"])
        if seqs != list(range(len(seqs))):
            fail("log op_seq not contiguous 0..n-1: %s" % seqs[:50])
        return n

# ---------------- DUT submit --------------------------------------------------
def submit_op(dut, epoch, tid, descriptor):
    d0, d1 = content_hash(descriptor)
    crc = desc_crc(d0, d1, tid & 0xFFFFFFFF, epoch)
    for a, v in ((A["DESC0"], d0), (A["DESC1"], d1),
                 (A["REQ_LO"], tid & 0xFFFFFFFF), (A["REQ_HI"], 0),
                 (A["DESC_CRC"], crc)):
        e = dut.write(a, v)
        if e: return "transport-fail", "write 0x%02x: %s" % (a, e)
    e = dut.write(A["CTRL"], CTRL_SUBMIT)
    if e: return "transport-fail", "submit: %s" % e
    e = dut.wait_idle()
    if e: return "transport-fail", "wait_idle: %s" % e
    err, ee = dut.read(A["ERROR"])
    if ee: return "transport-fail", "read ERROR: %s" % ee
    wm, we = dut.durable()
    if we: return "transport-fail", "read durable: %s" % we
    if err != 0:
        ce = dut.write(A["ERROR"], 0x3F)
        if ce: return "transport-fail", "clear errors: %s" % ce
        code = {1: "CRC", 2: "DUP", 4: "GAP"}.get(err & 0x07, "ERR=0x%x" % err)
        return "rejected:" + code, None
    return "committed", {"tid": tid, "d0": d0, "d1": d1,
                         "epoch": epoch, "wm": wm, "crc": crc}

def commit_one(dut, journal, base, op, ts=None, note=""):
    """Commit plan op as DUT TID base+op_seq; fsync journal line."""
    ts = ts or now_iso()
    tid = base + op["op_seq"]
    desc = descriptor_of(op, ts)
    out, res = submit_op(dut, EP[0], tid, desc)
    if out != "committed":
        return out, None
    if res["wm"] != tid + 1:
        fail("op_seq=%d tid=%d: wm=%d want %d" % (op["op_seq"], tid, res["wm"], tid + 1))
    rec = {"op_seq": op["op_seq"], "kind": op["kind"],
           "dispatch_id": op["dispatch_id"], "task_id": op["task_id"],
           "executor": op["executor"], "attempt": op["attempt"],
           "verdict": op["verdict"], "ts": ts, "descriptor": desc,
           "tid": tid, "d0": res["d0"], "d1": res["d1"],
           "crc": res["crc"], "epoch": EP[0], "wm": res["wm"]}
    if note: rec["note"] = note
    journal.append_fsync(rec)
    return "committed", rec

EP = [None]

def read_epoch(dut):
    ep, e = dut.read(A["EPOCH"])
    if e: fail("read EPOCH: %s" % e)
    return ep

# ---------------- commands ----------------------------------------------------
def cmd_sanity(args):
    dut = DUT(args.port, args.baud)
    v, e = dut.ping()
    if e or v != 1:
        if e is None and v != 1: fail("PONG VERSION=%r want 1" % v)
        fail("PING: %s" % e)
    log("sanity PING: PONG v1 PASS")
    d, e = dut.durable()
    if e: fail("durable: %s" % e)
    ep = read_epoch(dut)
    log("sanity durable=%d epoch=%d" % (d, ep))
    print("RESULT sanity PASS durable=%d epoch=%d" % (d, ep))

def cmd_stream(args):
    dut = DUT(args.port, args.baud)
    v, e = dut.ping()
    if e or v != 1: fail("PING: %s v=%r" % (e, v))
    base, e = dut.durable()
    if e: fail("durable: %s" % e)
    EP[0] = read_epoch(dut)
    err, e = dut.read(A["ERROR"])
    if e: fail("ERROR read: %s" % e)
    if err != 0: fail("pre-existing ERROR=0x%x (refuse to run dirty)" % err)
    if os.path.exists(args.log): fail("log %s exists" % args.log)
    j = Journal(args.log)
    plan = build_plan()
    log("stream start base=%d epoch=%d delay=%.2f" % (base, EP[0], args.delay))
    for op in plan:
        out, rec = commit_one(dut, j, base, op)
        if out != "committed": fail("op_seq=%d %s: %s" % (op["op_seq"], op["dispatch_id"], out))
        if op["op_seq"] % 5 == 0 or op["kind"] == "harvest" and op["op_seq"] % 5 == 4:
            log("PROGRESS op_seq=%d/%d tid=%d %s %s wm=%d log_lines=%d" % (
                op["op_seq"], len(plan) - 1, rec["tid"], op["kind"],
                op["dispatch_id"], rec["wm"], j.lines))
        time.sleep(args.delay)
    d, e = dut.durable()
    if e: fail("final durable: %s" % e)
    log("stream done base=%d final_wm=%d lines=%d" % (base, d, j.lines))
    print("RESULT stream PASS base=%d final_wm=%d lines=%d" % (base, d, j.lines))

def cmd_recover(args):
    dut = DUT(args.port, args.baud)
    v, e = dut.ping()
    if e or v != 1: fail("recovery PING: %s v=%r" % (e, v))
    log("recovery PING PONG v1 PASS")
    if not os.path.exists(args.log): fail("no log %s" % args.log)
    j = Journal(args.log)
    n = j.replay()
    log("recovery replayed %d fsync'd lines, tids=%d unique" % (n, len(j.tids)))
    with open(args.log) as f:
        recs = [json.loads(l) for l in f if l.strip()]
    base = recs[0]["tid"] - recs[0]["op_seq"]
    bep = recs[0]["epoch"]
    EP[0] = read_epoch(dut)
    if EP[0] != bep: fail("epoch moved %d->%d (concurrent reset?)" % (bep, EP[0]))
    if sorted(j.tids) != list(range(base, base + n)):
        fail("log tids not contiguous base=%d n=%d" % (base, n))
    d, e = dut.durable()
    if e: fail("durable: %s" % e)
    log("recovery base=%d logged=%d dut_durable=%d" % (base, n, d))
    if d < base + n: fail("DUT durable %d < log max+1 %d (LOST COMMIT)" % (d, base + n))
    if d > base + n + 1: fail("DUT durable %d > log+1 %d (concurrent use?)" % (d, base + n + 1))
    plan = build_plan()
    k = n
    if d == base + n + 1:
        # unacked tail: TID ordered on DUT, killed before fsync. Re-drive
        # same TID -> must come back DUP (side-effect-free); then journal it.
        op = plan[n]
        tid = base + n
        desc = descriptor_of(op, now_iso())
        out, res = submit_op(dut, EP[0], tid, desc)
        if out != "rejected:DUP":
            fail("unacked-tail re-drive tid=%d: %s want rejected:DUP" % (tid, out))
        d0, d1 = content_hash(desc)
        rec = {"op_seq": op["op_seq"], "kind": op["kind"],
               "dispatch_id": op["dispatch_id"], "task_id": op["task_id"],
               "executor": op["executor"], "attempt": op["attempt"],
               "verdict": op["verdict"], "ts": now_iso(), "descriptor": desc,
               "tid": tid, "d0": d0, "d1": d1,
               "crc": desc_crc(d0, d1, tid & 0xFFFFFFFF, EP[0]),
               "epoch": EP[0], "wm": d, "note": "recovered:dup-tail"}
        j.append_fsync(rec)
        log("recovery unacked tail op_seq=%d tid=%d DUP-confirm journaled (zero loss)" % (n, tid))
        k = n + 1
    else:
        log("recovery clean kill: no unacked tail (durable == log max+1)")
    for op in plan[k:]:
        out, rec = commit_one(dut, j, base, op)
        if out != "committed": fail("resume op_seq=%d: %s" % (op["op_seq"], out))
        log("resume op_seq=%d tid=%d %s %s wm=%d" % (
            op["op_seq"], rec["tid"], op["kind"], op["dispatch_id"], rec["wm"]))
        time.sleep(args.delay)
    d2, e = dut.durable()
    if e: fail("final durable: %s" % e)
    if d2 != base + 40: fail("final durable=%d want base+40=%d" % (d2, base + 40))
    if len(j.tids) != 40: fail("journal tids=%d want 40" % len(j.tids))
    log("recovery complete: 40/40 tids, durable=%d, zero lost + zero double-applied" % d2)
    print("RESULT recover PASS base=%d resumed_from=%d final_wm=%d lines=%d" % (base, k, d2, j.lines))

def history_recs(logpath, task_id):
    out = []
    with open(logpath) as f:
        for line in f:
            if not line.strip(): continue
            r = json.loads(line)
            if r["task_id"] == task_id: out.append(r)
    return sorted(out, key=lambda r: r["tid"])

def cmd_history(args):
    recs = history_recs(args.log, args.task_id)
    if not recs: fail("no chain for task %s" % args.task_id)
    print("history(task_id=%s): %d commits in TID order" % (args.task_id, len(recs)))
    for r in recs:
        what = ("dispatch %s via %s attempt %d" % (r["dispatch_id"], r["executor"], r["attempt"])
                if r["kind"] == "dispatch" else
                ("harvest %s verdict=%s" % (r["dispatch_id"], r["verdict"])))
        print("  tid=%d op_seq=%d %-9s %s ts=%s d0=%08x d1=%08x wm=%d" % (
            r["tid"], r["op_seq"], r["kind"], what, r["ts"], r["d0"], r["d1"], r["wm"]))
    print("RESULT history PASS task=%s commits=%d tids=%d..%d" % (
        args.task_id, len(recs), recs[0]["tid"], recs[-1]["tid"]))

def cmd_audit(args):
    dut = DUT(args.port, args.baud)
    v, e = dut.ping()
    if e or v != 1: fail("audit PING: %s v=%r" % (e, v))
    with open(args.log) as f:
        recs = [json.loads(l) for l in f if l.strip()]
    n = len(recs)
    log("audit replaying %d lines" % n)
    # 1. op_seq + TID contiguity, no dupes
    if [r["op_seq"] for r in recs] != list(range(n)):
        fail("op_seq not 0..n-1")
    tids = [r["tid"] for r in recs]
    if len(set(tids)) != n: fail("duplicate TIDs in log (double-apply!)")
    base = tids[0]
    if tids != list(range(base, base + n)): fail("TIDs not contiguous from base=%d" % base)
    log("audit tids contiguous %d..%d (40 ops)" % (tids[0], tids[-1]))
    # 2. hash-chain integrity: recompute content-hash + CRC per line
    for r in recs:
        d0, d1 = content_hash(r["descriptor"])
        if d0 != r["d0"] or d1 != r["d1"]:
            fail("op_seq=%d tid=%d content-hash mismatch" % (r["op_seq"], r["tid"]))
        if desc_crc(d0, d1, r["tid"] & 0xFFFFFFFF, r["epoch"]) != r["crc"]:
            fail("op_seq=%d tid=%d CRC mismatch" % (r["op_seq"], r["tid"]))
        if r["wm"] != r["tid"] + 1:
            fail("op_seq=%d wm=%d != tid+1" % (r["op_seq"], r["wm"]))
    log("audit hash chain PASS: %d/%d descriptors + CRCs + wm==tid+1 verified" % (n, n))
    # 3. dispatch<->harvest pairing per dispatch_id
    kinds = {}
    for r in recs:
        kinds.setdefault(r["dispatch_id"], []).append(r["kind"])
    bad = {k: v for k, v in kinds.items() if sorted(v) != ["dispatch", "harvest"]}
    if bad: fail("unpaired dispatch_ids: %s" % bad)
    log("audit pairing PASS: 20 dispatch_ids each exactly {dispatch, harvest}")
    # 4. verdict mix + retry shape
    hv = [r["verdict"] for r in recs if r["kind"] == "harvest"]
    from collections import Counter
    log("audit verdicts: %s" % dict(Counter(hv)))
    # 5. DUT watermarks
    d, e = dut.durable()
    if e: fail("durable: %s" % e)
    vis, e = dut.visible()
    if e: fail("visible: %s" % e)
    err, e = dut.read(A["ERROR"])
    if e: fail("ERROR: %s" % e)
    if d != base + n: fail("DUT durable=%d != base+n=%d" % (d, base + n))
    if vis != d: fail("visible=%d != durable=%d" % (vis, d))
    if err != 0: fail("ERROR sticky=0x%x" % err)
    log("audit watermarks PASS: durable==visible==%d == base+%d, ERROR=0" % (d, n))
    # 6. at-most-once: re-drive 3 committed TIDs -> all DUP
    ep = read_epoch(dut)
    for r in recs[-3:]:
        out, _ = submit_op(dut, ep, r["tid"], r["descriptor"])
        if out != "rejected:DUP":
            fail("re-drive tid=%d: %s want rejected:DUP" % (r["tid"], out))
    log("audit at-most-once PASS: 3 tail re-drives all DUP")
    print("RESULT audit PASS ops=%d base=%d durable=%d verdicts=%s" % (n, base, d, dict(Counter(hv))))

ap = argparse.ArgumentParser()
ap.add_argument("--port", default="/dev/ttyUSB1")
ap.add_argument("--baud", type=int, default=115200)
ap.add_argument("--log", default="/tmp/dispatch_journal.log")
ap.add_argument("--delay", type=float, default=0.05)
ap.add_argument("--task-id", default="")
sub = ap.add_subparsers(dest="cmd", required=True)
for c in ("sanity", "stream", "recover", "history", "audit"):
    sub.add_parser(c)
args = ap.parse_args()
{"sanity": cmd_sanity, "stream": cmd_stream, "recover": cmd_recover,
 "history": cmd_history, "audit": cmd_audit}[args.cmd](args)
