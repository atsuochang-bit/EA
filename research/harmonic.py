# Research copy of the HarmonicNavi logic (Python port) with spread-aware fills. Used by evaluate.py.
"""Line-by-line Python port of MQL5/Indicators/HarmonicNavi.mq5 for logic checks.
Not part of the deliverable. Mirrors ProcessBar / DetectPivot / AddSwing / OnSwingsChanged /
BuildSetup / HandlePending / OpenTrade / UpdateTrade / CloseTrade.
"""
from dataclasses import dataclass, field
import math

PAT = ["Gartley", "Bat", "Alt Bat", "Butterfly", "Crab", "Deep Crab", "Cypher"]
AB_MIN = [0.618, 0.382, 0.236, 0.786, 0.382, 0.886, 0.382]
AB_MAX = [0.618, 0.500, 0.382, 0.786, 0.618, 0.886, 0.618]
BC_MIN = [0.382, 0.382, 0.382, 0.382, 0.382, 0.382, 1.130]
BC_MAX = [0.886, 0.886, 0.886, 0.886, 0.886, 0.886, 1.414]
CD_MIN = [1.130, 1.618, 2.000, 1.618, 2.240, 2.000, 1.272]
CD_MAX = [1.618, 2.618, 3.618, 2.618, 3.618, 3.618, 2.000]
AD_XA = [0.786, 0.886, 1.130, 1.270, 1.618, 1.618, 0.786]
SL_XA = [1.000, 1.000, 1.270, 1.414, 2.000, 2.000, 1.000]
CYPHER = 6
OPEN, RES_SL, RES_T3, RES_TO = 0, 1, 2, 3


@dataclass
class Cfg:
    pivot_len: int = 5
    min_swing_atr: float = 1.0
    atr_period: int = 14
    pat_on: tuple = (True,) * 7
    tol: float = 0.05
    sl_mode: str = "atr"          # "atr" | "pattern"
    sl_atr: float = 1.0
    sl_buf_atr: float = 0.2
    tp_mode: str = "rr"           # "rr" | "fib"
    r: tuple = (2.618, 4.236, 6.854)
    f: tuple = (0.382, 0.618, 1.0)
    be_after_t1: bool = False
    pending_bars: int = 100
    trade_bars: int = 300
    digits: int = 5
    spread: float = 0.0


@dataclass
class Setup:
    dir: int; pat: int
    X: float; A: float; B: float; C: float
    tX: int; tA: int; tB: int; tC: int
    entry: float; sl: float; t1: float; t2: float; t3: float
    bars: int = 0
    created: int = 0


@dataclass
class Trade:
    id: int; dir: int; pat: int
    X: float; A: float; B: float; C: float
    tX: int; tA: int; tB: int; tC: int
    entry: float; sl: float; sl_init: float; t1: float; t2: float; t3: float
    t_entry: int
    t_hit: list = field(default_factory=lambda: [None, None, None])
    t_end: int = None
    stage: int = 0
    bars: int = 0
    result: int = OPEN
    mtm: float = 0.0


class Sim:
    def __init__(self, cfg, o, h, l, c):
        self.cfg, self.o, self.h, self.l, self.c = cfg, o, h, l, c
        self.sw = []            # [price, bar, type]
        self.pend = [None, None]
        self.tr = []
        self.atr = 0.0; self.atr_sum = 0.0; self.atr_cnt = 0
        self.start = cfg.pivot_len + 1
        self.st = dict(signals=0, resolved=0, hit1=0, hit2=0, hit3=0, sl_no_t1=0, sl_after_t1=0, timeouts=0, late=0)
        self.setups_created = 0
        self.cancel = dict(c_broken=0, expired=0, new_swing=0)

    def nd(self, x):
        return round(x, self.cfg.digits)

    def run(self):
        for i in range(self.start, len(self.c) - 1):   # last bar = forming bar, skipped
            self.process_bar(i)
        return self

    def process_bar(self, i):
        cfg, h, l, c = self.cfg, self.h, self.l, self.c
        tr = max(h[i], c[i - 1]) - min(l[i], c[i - 1])
        if self.atr_cnt < cfg.atr_period:
            self.atr_sum += tr; self.atr_cnt += 1; self.atr = self.atr_sum / self.atr_cnt
        else:
            self.atr = (self.atr * (cfg.atr_period - 1) + tr) / cfg.atr_period
        for t in self.tr:
            if t.result == OPEN and t.t_entry < i:
                self.update_trade(t, i)
        for s in range(2):
            if self.pend[s] is not None:
                self.handle_pending(s, i)
        self.detect_pivot(i)

    def update_trade(self, t, i):
        cfg, h, l = self.cfg, self.h, self.l
        t.bars += 1
        sp = cfg.spread
        sl_hit = l[i] <= t.sl if t.dir > 0 else h[i] + sp >= t.sl
        if sl_hit:
            self.close_trade(t, RES_SL, i); return
        while t.stage < 3:
            lvl = (t.t1, t.t2, t.t3)[t.stage]
            hit = h[i] >= lvl if t.dir > 0 else l[i] + sp <= lvl
            if not hit:
                break
            t.stage += 1
            t.t_hit[t.stage - 1] = i
            if t.stage == 1 and cfg.be_after_t1:
                t.sl = t.entry
        if t.stage >= 3:
            self.close_trade(t, RES_T3, i); return
        if cfg.trade_bars > 0 and t.bars >= cfg.trade_bars:
            t.mtm = ((self.c[i] - t.entry) if t.dir > 0 else (t.entry - self.c[i] - sp)) / abs(t.entry - t.sl_init)
            self.close_trade(t, RES_TO, i)

    def close_trade(self, t, res, i):
        st = self.st
        t.result, t.t_end = res, i
        st["resolved"] += 1
        if t.stage >= 1: st["hit1"] += 1
        if t.stage >= 2: st["hit2"] += 1
        if t.stage >= 3: st["hit3"] += 1
        if res == RES_SL:
            st["sl_no_t1" if t.stage == 0 else "sl_after_t1"] += 1
        if res == RES_TO:
            st["timeouts"] += 1

    def handle_pending(self, s, i):
        p = self.pend[s]
        p.bars += 1
        if (self.h[i] > p.C) if p.dir > 0 else (self.l[i] < p.C):
            self.pend[s] = None; self.cancel["c_broken"] += 1; return
        sp = self.cfg.spread
        if (self.l[i] + sp <= p.entry) if p.dir > 0 else (self.h[i] >= p.entry):
            self.open_trade(p, i); self.pend[s] = None; return
        if self.cfg.pending_bars > 0 and p.bars >= self.cfg.pending_bars:
            self.pend[s] = None; self.cancel["expired"] += 1

    def open_trade(self, p, i):
        t = Trade(len(self.tr), p.dir, p.pat, p.X, p.A, p.B, p.C, p.tX, p.tA, p.tB, p.tC,
                  p.entry, p.sl, p.sl, p.t1, p.t2, p.t3, i)
        self.st["signals"] += 1
        self.tr.append(t)
        sl_hit = self.l[i] <= p.sl if p.dir > 0 else self.h[i] + self.cfg.spread >= p.sl
        if sl_hit:
            self.close_trade(t, RES_SL, i)

    def detect_pivot(self, i):
        L, h, l = self.cfg.pivot_len, self.h, self.l
        j = i - L
        if j < self.start or j - L < 0:
            return
        ph = pl = True
        for k in range(1, L + 1):
            if not (ph or pl):
                break
            if ph and not (h[j] > h[j - k] and h[j] >= h[j + k]): ph = False
            if pl and not (l[j] < l[j - k] and l[j] <= l[j + k]): pl = False
        if ph and pl:
            if self.sw and self.sw[-1][2] > 0: ph = False
            else: pl = False
        changed = False
        if ph: changed = self.add_swing(1, h[j], j)
        elif pl: changed = self.add_swing(-1, l[j], j)
        if changed:
            self.on_swings_changed(i, j)

    def add_swing(self, typ, price, t):
        cfg, sw = self.cfg, self.sw
        if sw:
            last = sw[-1]
            if last[2] == typ:
                more = price > last[0] if typ > 0 else price < last[0]
                if not more: return False
                last[0], last[1] = price, t
                return True
            if typ > 0 and price <= last[0]: return False
            if typ < 0 and price >= last[0]: return False
            if cfg.min_swing_atr > 0 and self.atr_cnt >= cfg.atr_period and abs(price - last[0]) < cfg.min_swing_atr * self.atr:
                return False
        sw.append([price, t, typ])
        if len(sw) > 64: del sw[:32]
        return True

    def on_swings_changed(self, i, j):
        last = self.sw[-1]
        for s in range(2):
            p = self.pend[s]
            if p is not None and last[1] > p.tC and last[2] == p.dir:
                self.pend[s] = None; self.cancel["new_swing"] += 1
        if len(self.sw) < 4 or self.atr_cnt < self.cfg.atr_period:
            return
        d = last[2]
        slot = 0 if d > 0 else 1
        if self.pend[slot] is not None:
            return
        su = self.build_setup(*self.sw[-4:])
        if su is None:
            return
        for k in range(j + 1, i + 1):
            if (d > 0 and self.l[k] <= su.entry) or (d < 0 and self.h[k] >= su.entry):
                self.st["late"] += 1
                return
        su.created = i
        self.pend[slot] = su
        self.setups_created += 1

    def in_ratio(self, r, lo, hi):
        return lo * (1 - self.cfg.tol) <= r <= hi * (1 + self.cfg.tol)

    def build_setup(self, x, a, b, c):
        cfg = self.cfg
        d_ = c[2]
        if x[2] != -d_ or a[2] != d_ or b[2] != -d_:
            return None
        XA, AB, BC = abs(a[0] - x[0]), abs(a[0] - b[0]), abs(c[0] - b[0])
        if XA <= 0 or AB <= 0 or BC <= 0:
            return None
        if d_ * (a[0] - x[0]) <= 0 or d_ * (b[0] - x[0]) <= 0 or d_ * (a[0] - b[0]) <= 0:
            return None
        rAB, rBC = AB / XA, BC / AB
        best, out = math.inf, None
        for p in range(7):
            if not cfg.pat_on[p]: continue
            if not self.in_ratio(rAB, AB_MIN[p], AB_MAX[p]) or not self.in_ratio(rBC, BC_MIN[p], BC_MAX[p]):
                continue
            if p == CYPHER:
                D = c[0] - d_ * AD_XA[p] * abs(c[0] - x[0]); sl_ref = x[0]
            else:
                D = a[0] - d_ * AD_XA[p] * XA; sl_ref = a[0] - d_ * SL_XA[p] * XA
            if d_ * (b[0] - D) <= 0: continue
            CD = abs(c[0] - D)
            if not self.in_ratio(CD / BC, CD_MIN[p], CD_MAX[p]): continue
            sl = D - d_ * cfg.sl_atr * self.atr if cfg.sl_mode == "atr" else sl_ref - d_ * cfg.sl_buf_atr * self.atr
            if d_ * (D - sl) <= 0: continue
            if CD >= best: continue
            en, sn = self.nd(D), self.nd(sl)
            risk = abs(en - sn)
            if risk < 0.5 * 10 ** -cfg.digits: continue
            best = CD
            top = max(a[0], c[0]) if d_ > 0 else min(a[0], c[0])
            leg = abs(top - en)
            m, unit = (cfg.r, risk) if cfg.tp_mode == "rr" else (cfg.f, leg)
            out = Setup(d_, p, x[0], a[0], b[0], c[0], x[1], a[1], b[1], c[1],
                        en, sn, self.nd(en + d_ * m[0] * unit),
                        self.nd(en + d_ * m[1] * unit), self.nd(en + d_ * m[2] * unit))
        return out

    def report(self):
        st = self.st
        pct = lambda a, b: f"{100*a/b:5.1f}%" if b else "    -"
        n_open = sum(1 for t in self.tr if t.result == OPEN)
        return "\n".join([
            f"Signals        {st['signals']:6d}",
            f"Resolved       {st['resolved']:6d}",
            f"Target 1 hit   {st['hit1']:6d}  {pct(st['hit1'], st['resolved'])}",
            f"Target 2 hit   {st['hit2']:6d}  {pct(st['hit2'], st['hit1'])} of T1",
            f"Target 3 hit   {st['hit3']:6d}  {pct(st['hit3'], st['hit2'])} of T2",
            f"SL before T1   {st['sl_no_t1']:6d}  {pct(st['sl_no_t1'], st['resolved'])}",
            f"SL after T1    {st['sl_after_t1']:6d}",
            f"Timed out      {st['timeouts']:6d}",
            f"Open           {n_open:6d}   skipped(late) {st['late']}",
            f"setups created {self.setups_created}  cancels {self.cancel}",
        ])
