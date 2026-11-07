"""Run every pre-registered candidate on every available pair; report in-sample (2010-2019)
and out-of-sample (2020-2026.10) separately.  usage: python -I evaluate.py <research_dir> <data_dir>"""
import sys, os, glob
sys.path.insert(0, sys.argv[1]); D = sys.argv[2]
import numpy as np, pandas as pd
import bt, strategies as S
from harmonic import Sim, Cfg, RES_SL, RES_TO

SPLIT = pd.Timestamp("2020-01-01")
pairs = sorted(os.path.basename(p).split("_")[0] for p in glob.glob(f"{D}/*_H1.parquet"))
print("pairs:", pairs)


def harmonic_trades(df, pair, r1=None, sl_mode="atr", tp_mode="rr"):
    digits = 3 if pair.endswith("JPY") else 5
    cfg = Cfg(digits=digits, spread=bt.SPREAD[pair], sl_mode=sl_mode, tp_mode=tp_mode)
    if r1 is not None:
        cfg.r = (r1, r1 * 1.618, r1 * 2.618)
    o, h, l, c = (df[k].to_numpy() for k in "ohlc")
    s = Sim(cfg, o, h, l, c).run()
    rows = []
    for t in s.tr:
        if t.result == 0:
            continue
        risk = abs(t.entry - t.sl_init)
        if t.stage >= 1:
            R = abs(t.t1 - t.entry) / risk          # exit everything at T1
        elif t.result == RES_SL:
            R = -abs(t.entry - t.sl) / risk
        else:
            R = t.mtm
        end = t.t_hit[0] if t.stage >= 1 else t.t_end
        rows.append((pair, df.index[t.t_entry], df.index[end], t.dir, R))
    return pd.DataFrame(rows, columns=["pair", "t_in", "t_out", "dir", "R"])


CANDIDATES = {
    "A1 harmonic H1 exit@T1=2.618R": ("H1", lambda df, p: harmonic_trades(df, p)),
    "A2 harmonic H1 exit@T1=1R":     ("H1", lambda df, p: harmonic_trades(df, p, r1=1.0)),
    "A3 harmonic H1 exit@T1=2R":     ("H1", lambda df, p: harmonic_trades(df, p, r1=2.0)),
    "A4 harmonic H1 patternSL fib.382": ("H1", lambda df, p: harmonic_trades(df, p, sl_mode="pattern", tp_mode="fib")),
    "B1 donchian D1 20/10":          ("D1", lambda df, p: S.run(df, p, S.donchian(df, 20, 10))),
    "B2 donchian D1 55/20":          ("D1", lambda df, p: S.run(df, p, S.donchian(df, 55, 20))),
    "C1 trend pullback H4":          ("H4", lambda df, p: S.run(df, p, S.trend_pullback(df))),
    "D1 range reversion H1":         ("H1", lambda df, p: S.run(df, p, S.range_reversion(df))),
    "E1 TS momentum D1 60d":         ("D1", lambda df, p: S.run(df, p, S.ts_momentum(df))),
}

frames = {}
for pair in pairs:
    h1 = bt.load(pair, "H1", D)
    tf = {"H1": h1, "H4": S.resample(h1, "4h"), "D1": S.resample(h1, "1D")}
    for name, (k, fn) in CANDIDATES.items():
        frames.setdefault(name, []).append(fn(tf[k], pair))

all_tr = {k: pd.concat(v, ignore_index=True) for k, v in frames.items()}
os.makedirs(f"{sys.argv[1]}/out", exist_ok=True)
pd.to_pickle(all_tr, f"{sys.argv[1]}/out/trades.pkl")

rows = []
for name, tr in all_tr.items():
    for part, sub in (("IS 2010-19", tr[tr.t_in < SPLIT]), ("OOS 2020-26", tr[tr.t_in >= SPLIT])):
        st = bt.stats(sub)
        pos_pairs = sum(sub[sub.pair == p].R.sum() > 0 for p in pairs)
        rows.append({"strategy": name, "part": part, **st, "pairs+": f"{pos_pairs}/{len(pairs)}"})
pd.set_option("display.width", 200)
print(pd.DataFrame(rows).to_string(index=False))
