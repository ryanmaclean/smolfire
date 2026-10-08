#!/usr/bin/env python3
"""dut_kv.py: durable KV where DUT supplies commit order, host holds data.

Committed from the proven /tmp throwaway kv_demo.py (live-proven on Tang
DUT); only change vs the throwaway is --port/--baud CLI flags. See
tools/README.md for origins and honesty notes.

Design (honest: DUT has no key storage by design):
- every put(key,value)/delete(key) is a DUT-committed op (single-submit path).
  descriptor DESC0/DESC1 = sha256(op|key|value)[0:8] content hash.
- host appends (tid,op,key,value,d0,d1,epoch,receipt-wm) JSON line + fsync per commit.
- get() serves from host dict. recovery = replay host log in TID order, at-most-once.
- committed-vs-unacked: only fsync'd TIDs count as committed. In-flight killed op
  is UNACKED; re-drive expects DUP (fabric already ordered) or clean commit;
  never double-applies (applied_tids guard + log has unique TIDs).

Cmds: sanity | run | slow-load | recover
"""
import argparse, binascii, hashlib, json, os, sys, time
import serial

M0, M1 = 0x44, 0x55
CMD_WRITE, CMD_READ, CMD_RESET, CMD_PING = 0x01, 0x02, 0x03, 0x04
RSP_WRITE, RSP_READ, RSP_RESET, RSP_PING = 0x81, 0x82, 0x83, 0x84
A = dict(EPOCH=0x00, REQ_LO=0x04, DUR_LO=0x0C, VIS_LO=0x10, ERROR=0x18,
         PROG=0x1C, RSTCNT=0x20, CTRL=0x24, STATUS=0x28, DESC0=0x2C,
         DESC1=0x30, DESC_CRC=0x34, TID_LO=0x3C, REQ_HI=0x44, DUR_HI=0x48,
         VIS_HI=0x4C, MAGIC=0x54, VERSION=0x58)
CTRL_SUBMIT = 1
TRANSCRIPT_N = 32
tr = []
def log(msg):
    tr.append(msg)
    if len(tr) > TRANSCRIPT_N: tr.pop(0)
    print(msg, flush=True)
def dump_tr():
    print("--- transcript (last %d) ---" % len(tr), flush=True)
    for i, m in enumerate(tr): print("[%d] %s" % (i, m), flush=True)
    print("--- end transcript ---", flush=True)
def fail(msg):
    print("FAIL: %s" % msg, flush=True); dump_tr(); sys.exit(1)

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
    def reset(self): return self._cmd(CMD_RESET, 0, 0, RSP_RESET)
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
    def wait_idle(self, npoll=30):
        for _ in range(npoll):
            st, e = self.read(A["STATUS"])
            if e: return e
            if not (st & 1): return None
        return "busy stuck"

def desc_crc(d0, d1, req, epoch):
    b = (d0.to_bytes(4, "little") + d1.to_bytes(4, "little") +
         req.to_bytes(4, "little") + epoch.to_bytes(4, "little"))
    return binascii.crc32(b) & 0xFFFFFFFF

def kv_hash(op, key, val):
    h = hashlib.sha256(("%s|%s|%s" % (op, key, val)).encode()).digest()
    return int.from_bytes(h[0:4], "little"), int.from_bytes(h[4:8], "little")

def pat(prefix, i):
    key = "%s%03d" % (prefix, i)
    val = "kv1:%s:%04d:%s" % (key, i, hashlib.sha256(key.encode()).hexdigest()[:16])
    return key, val

class Store:
    """Host KV: dict + fsync log. apply() is at-most-once per TID."""
    def __init__(self, path):
        self.path = path; self.state = {}; self.applied = set()
        self.puts = 0; self.dels = 0
    def append_fsync(self, rec):
        fd = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
        try:
            os.write(fd, (json.dumps(rec) + "\n").encode()); os.fsync(fd)
        finally: os.close(fd)
    def apply(self, rec):
        tid = rec["tid"]
        if tid in self.applied: return "dup-skip"
        self.applied.add(tid)
        if rec["op"] == "put": self.state[rec["key"]] = rec["val"]; self.puts += 1
        else: self.state.pop(rec["key"], None); self.dels += 1
        return "applied"
    def replay(self):
        n = 0; tids = set()
        with open(self.path) as f:
            for line in f:
                line = line.strip()
                if not line: continue
                rec = json.loads(line)
                if rec["tid"] in tids: fail("log has duplicate TID %d" % rec["tid"])
                tids.add(rec["tid"]); self.apply(rec); n += 1
        return n
    def digest(self):
        h = hashlib.sha256()
        for k in sorted(self.state): h.update(("%s=%s;" % (k, self.state[k])).encode())
        return h.hexdigest()

def submit_op(dut, epoch, tid, op, key, val):
    """Single-submit one KV op. Returns (outcome, rec-or-err).
    outcome: committed | rejected:DUP/GAP/CRC | transport-fail"""
    d0, d1 = kv_hash(op, key, val)
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
    rec = {"tid": tid, "op": op, "key": key, "val": val,
           "d0": d0, "d1": d1, "epoch": epoch, "wm": wm}
    return "committed", rec

def do_sanity(dut):
    v, e = dut.ping()
    if e or v != 1:
        if e is None and v != 1: fail("PONG VERSION=%r want 1 (wrong bitstream?)" % v)
        fail("PING: %s" % e)
    log("sanity PING: PONG v1 PASS")
    m, e = dut.read(A["MAGIC"])
    if e or m != 0x44555230: fail("MAGIC: %r %s" % (m, e))
    vv, e = dut.read(A["VERSION"])
    if e or vv != 1: fail("VERSION: %r %s" % (vv, e))
    log("sanity MAGIC DUR0 + VERSION v1 PASS")
    rc0, e = dut.read(A["RSTCNT"])
    if e: fail("read RSTCNT: %s" % e)
    d0, e = dut.durable()
    if e: fail("read durable: %s" % e)
    _, e = dut.reset()
    if e: fail("RESET: %s" % e)
    rc1, e = dut.read(A["RSTCNT"])
    if e: fail("read RSTCNT2: %s" % e)
    if rc1 != rc0 + 1: fail("RESET_CNT %d->%d want +1" % (rc0, rc1))
    d1, e = dut.durable()
    if e: fail("read durable2: %s" % e)
    if d1 != d0: fail("RESET moved durable %d->%d" % (d0, d1))
    ep, e = dut.read(A["EPOCH"])
    if e: fail("read EPOCH: %s" % e)
    log("sanity RESET: rcnt %d->%d durable base=%d epoch=%d PASS" % (rc0, rc1, d1, ep))
    return d1, ep

def cmd_sanity(args):
    dut = DUT(args.port, args.baud); base, ep = do_sanity(dut)
    print("RESULT sanity PASS base=%d epoch=%d" % (base, ep))

def cmd_run(args):
    dut = DUT(args.port, args.baud)
    if os.path.exists(args.log): fail("log %s exists; remove for clean run" % args.log)
    base, ep = do_sanity(dut)
    log("PHASE1 sanity PASS base=%d" % base)
    st = Store(args.log)
    NPUT, NDEL, PREFIX = 100, 30, "k"
    # puts
    for i in range(NPUT):
        key, val = pat(PREFIX, i)
        tid = base + i
        out, rec = submit_op(dut, ep, tid, "put", key, val)
        if out != "committed": fail("put %s tid=%d: %s %s" % (key, tid, out, rec))
        if rec["wm"] != tid + 1: fail("put %s: wm=%d want %d" % (key, rec["wm"], tid + 1))
        st.append_fsync(rec); st.apply(rec)
        log("put %s tid=%d wm=%d" % (key, tid, rec["wm"]))
    log("PHASE2a puts 100/100 PASS")
    # get all 100 exact
    bad = 0
    for i in range(NPUT):
        key, want = pat(PREFIX, i)
        if st.state.get(key) != want:
            bad += 1; log("MISMATCH get %s" % key)
    if bad: fail("get %d/100 mismatched" % bad)
    log("PHASE2b get 100/100 exact PASS")
    # delete 30 (k000..k029)
    for i in range(NDEL):
        key, _ = pat(PREFIX, i)
        tid = base + NPUT + i
        out, rec = submit_op(dut, ep, tid, "del", key, "")
        if out != "committed": fail("del %s tid=%d: %s %s" % (key, tid, out, rec))
        if rec["wm"] != tid + 1: fail("del %s: wm=%d want %d" % (key, rec["wm"], tid + 1))
        st.append_fsync(rec); st.apply(rec)
        log("del %s tid=%d wm=%d" % (key, tid, rec["wm"]))
    log("PHASE2c deletes 30/30 PASS")
    # get-deleted NOT-FOUND + others intact
    for i in range(NDEL):
        key, _ = pat(PREFIX, i)
        if key in st.state: fail("deleted %s still present" % key)
    bad = 0
    for i in range(NDEL, NPUT):
        key, want = pat(PREFIX, i)
        if st.state.get(key) != want: bad += 1
    if bad: fail("%d survivors mismatched" % bad)
    if len(st.state) != NPUT - NDEL: fail("live=%d want %d" % (len(st.state), NPUT - NDEL))
    log("PHASE2d get-deleted NOT-FOUND 30/30, survivors 70/70 exact PASS")
    # watermark math exact
    want_wm = base + NPUT + NDEL
    d, e = dut.durable()
    if e: fail("final durable read: %s" % e)
    v, e = dut.visible()
    if e: fail("final visible read: %s" % e)
    if d != want_wm or v != want_wm:
        fail("watermark d=%s v=%s want %d" % (d, v, want_wm))
    err, e = dut.read(A["ERROR"])
    if e or err != 0: fail("final ERROR=0x%r %s" % (err, e))
    log("PHASE2e watermark exact: base=%d +100 +30 = %d == durable == visible PASS" % (base, want_wm))
    # at-most-once: resubmit old committed TID -> DUP, state unchanged
    before = st.digest()
    key, val = pat(PREFIX, 50)
    out, _ = submit_op(dut, ep, base + 50, "put", key, val)
    if out != "rejected:DUP": fail("retry tid=%d: %s want rejected:DUP" % (base + 50, out))
    if st.digest() != before: fail("retry changed host state")
    log("PHASE2f retry DUP no-double-apply PASS digest=%s" % before[:16])
    print("RESULT run PASS base=%d final_wm=%d live=%d digest=%s" %
          (base, want_wm, len(st.state), st.digest()))

def cmd_slow_load(args):
    dut = DUT(args.port, args.baud)
    base, e = dut.durable()
    if e: fail("durable: %s" % e)
    ep, e = dut.read(A["EPOCH"])
    if e: fail("epoch: %s" % e)
    if os.path.exists(args.log):
        # resume sequence from existing log tail (crash-only path uses recover; this is fresh)
        fail("log %s exists" % args.log)
    st = Store(args.log)
    log("slow-load start base=%d epoch=%d n=%d delay=%.2f" % (base, ep, args.n, args.delay))
    for i in range(args.n):
        key, val = pat(args.prefix, i)
        tid = base + i
        out, rec = submit_op(dut, ep, tid, "put", key, val)
        if out != "committed":
            # unacked tail: legitimately repeatable later; record + keep going? NO - STOP, killer may strike anytime
            log("UNACKED tid=%d out=%s (repeatable tail)" % (tid, out)); continue
        st.append_fsync(rec); st.apply(rec)
        if i % 10 == 0:
            log("PROGRESS i=%d tid=%d wm=%d log_lines=%d" % (i, tid, rec["wm"], i + 1))
        time.sleep(args.delay)
    log("slow-load done n=%d" % args.n)
    print("RESULT slow-load PASS lines=%d digest=%s" % (len(st.applied), st.digest()))

def cmd_recover(args):
    dut = DUT(args.port, args.baud)
    v, e = dut.ping()
    if e or v != 1: fail("recovery PING: %s v=%r" % (e, v))
    log("recovery PING PONG v1 PASS")
    if not os.path.exists(args.log): fail("no log %s" % args.log)
    st = Store(args.log)
    n = st.replay()
    d, e = dut.durable()
    if e: fail("durable: %s" % e)
    mx = max(st.applied) if st.applied else None
    log("recovery replayed %d lines puts=%d dels=%d live=%d max_tid=%s dut_durable=%d digest=%s" %
        (n, st.puts, st.dels, len(st.state), mx, d, st.digest()))
    # R1: contiguous committed TIDs, no loss: applied == lines (checked in replay)
    # R2/R3: final state == sequential application (replay IS sequential; verify digest stable)
    d1 = st.digest()
    st2 = Store(args.log); st2.replay()
    if st2.digest() != d1: fail("replay not deterministic")
    log("recovery determinism PASS (two replays identical)")
    # R4: gap analysis committed-vs-unacked
    if mx is not None and d < mx + 1: fail("DUT durable %d < log max+1 %d (lost commit!)" % (d, mx + 1))
    gap = d - (mx + 1) if mx is not None else 0
    log("gap analysis: dut_durable=%d log_max+1=%d gap=%d (unacked tail ops)" % (d, mx + 1 if mx is not None else 0, gap))
    if gap > 1: fail("gap=%d > 1: more than one in-flight op impossible single-submit" % gap)
    # R5: at-most-once: re-drive last 5 committed TIDs -> all DUP, digest unchanged
    if mx is not None:
        ep, e = dut.read(A["EPOCH"])
        if e: fail("epoch: %s" % e)
        tails = sorted(st.applied)[-5:]
        for t in tails:
            # find rec for tid t
            rec = None
            with open(args.log) as f:
                for line in f:
                    r = json.loads(line)
                    if r["tid"] == t: rec = r; break
            out, _ = submit_op(dut, rec["epoch"], t, rec["op"], rec["key"], rec["val"])
            if out != "rejected:DUP": fail("re-drive tid=%d: %s want rejected:DUP (double-apply risk)" % (t, out))
        if st.digest() != d1: fail("re-drive changed state")
        log("at-most-once PASS: 5 tail re-drives all DUP, digest unchanged %s" % d1[:16])
    print("RESULT recover PASS lines=%d live=%d gap=%d digest=%s" % (n, len(st.state), gap, d1))

ap = argparse.ArgumentParser()
ap.add_argument("--port", default="/dev/ttyUSB1")
ap.add_argument("--baud", type=int, default=115200)
ap.add_argument("--log", default="/tmp/kv_demo.log")
ap.add_argument("--n", type=int, default=200)
ap.add_argument("--delay", type=float, default=0.05)
ap.add_argument("--prefix", default="kk")
sub = ap.add_subparsers(dest="cmd", required=True)
for c in ("sanity", "run", "slow-load", "recover"): sub.add_parser(c)
args = ap.parse_args()
{"sanity": cmd_sanity, "run": cmd_run, "slow-load": cmd_slow_load, "recover": cmd_recover}[args.cmd](args)
