"""Hour-of-day / session drift check (Ranaldo-style), in-sample 2010-2019 vs out-of-sample 2020-2026.
usage: python -I seasonality.py <research_dir> <data_dir>"""
import sys; sys.path.insert(0, sys.argv[1]); D = sys.argv[2]
import numpy as np, pandas as pd, bt
SPLIT = pd.Timestamp("2020-01-01")
PAIRS = ["EURUSD", "USDJPY", "GBPUSD", "AUDUSD", "USDCHF", "EURJPY"]
for pair in PAIRS:
    df = bt.load(pair, "H1", D); pip = 0.01 if pair.endswith("JPY") else 0.0001
    r = (df.c - df.o) / pip
    line = [pair]
    for name, hrs in (("Asia 23-07", [23] + list(range(0, 7))), ("Europe 07-12", range(7, 12)), ("US 12-20", range(12, 20))):
        msk = np.isin(df.index.hour, list(hrs))
        vals = []
        for part in (df.index < SPLIT, df.index >= SPLIT):
            m = msk & part
            vals.append(r[m].groupby(df.index[m].date).sum().mean())
        line.append(f"{name}: IS {vals[0]:+.2f} / OOS {vals[1]:+.2f}")
    print(" | ".join(line), f"| cost {bt.SPREAD[pair] / pip:.1f} pips")
