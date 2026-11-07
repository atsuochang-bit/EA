"""Pre-registered candidate strategies (defined before looking at any result).
Each function returns arrays for bt.run(): sig, sl_dist, tp_dist, trail_dist, exit_sig, max_hold
"""
import numpy as np
import pandas as pd
import bt


def resample(df, rule):
    # day / H4 boundaries at 22:00 UTC (= 17:00 New York, the usual broker server midnight)
    agg = df.resample(rule, offset="22h", label="left", closed="left").agg(
        {"o": "first", "h": "max", "l": "min", "c": "last", "n": "sum"})
    return agg.dropna(subset=["o"])


def none_like(n, v=0.0):
    return np.full(n, v)


# --- sanity check: random direction, SL = TP = 1 ATR -> expectancy should be about -cost
def random_entries(df, seed=1, p=0.02):
    h, l, c = df.h.to_numpy(), df.l.to_numpy(), df.c.to_numpy()
    a = bt.atr(h, l, c, 14)
    rng = np.random.default_rng(seed)
    sig = np.where(rng.random(len(c)) < p, rng.choice([-1, 1], len(c)), 0)
    return sig, a, a.copy(), none_like(len(c)), np.zeros(len(c), np.int64), 0


# --- B: Donchian breakout (turtle style) on D1
def donchian(df, n_entry=20, n_exit=10, sl_atr=2.0):
    h, l, c = df.h.to_numpy(), df.l.to_numpy(), df.c.to_numpy()
    a = bt.atr(h, l, c, 20)
    hi = np.r_[np.nan, bt.rolling_max(h, n_entry)[:-1]]
    lo = np.r_[np.nan, bt.rolling_min(l, n_entry)[:-1]]
    xhi = np.r_[np.nan, bt.rolling_max(h, n_exit)[:-1]]
    xlo = np.r_[np.nan, bt.rolling_min(l, n_exit)[:-1]]
    sig = np.where(c > hi, 1, np.where(c < lo, -1, 0))
    ex = np.where(c < xlo, -1, np.where(c > xhi, 1, 0))     # -1 closes longs, +1 closes shorts
    return sig, sl_atr * a, none_like(len(c)), none_like(len(c)), ex.astype(np.int64), 0


# --- C: trend pullback on H4
def trend_pullback(df, sl_atr=2.0, trail_atr=3.0, adx_min=20):
    h, l, c = df.h.to_numpy(), df.l.to_numpy(), df.c.to_numpy()
    a = bt.atr(h, l, c, 14)
    e50, e200 = bt.ema(c, 50), bt.ema(c, 200)
    ad, _, _ = bt.adx(h, l, c, 14)
    r = bt.rsi(c, 14)
    rp = np.r_[np.nan, r[:-1]]
    up = (e50 > e200) & (c > e200) & (ad > adx_min)
    dn = (e50 < e200) & (c < e200) & (ad > adx_min)
    sig = np.where(up & (rp < 40) & (r >= 40), 1, np.where(dn & (rp > 60) & (r <= 60), -1, 0))
    return sig, sl_atr * a, none_like(len(c)), trail_atr * a, np.zeros(len(c), np.int64), 0


# --- D: range mean reversion on H1
def range_reversion(df, adx_max=20, sl_atr=1.5, max_hold=24):
    h, l, c = df.h.to_numpy(), df.l.to_numpy(), df.c.to_numpy()
    a = bt.atr(h, l, c, 14)
    ad, _, _ = bt.adx(h, l, c, 14)
    m = bt.sma(c, 20)
    sd = pd.Series(c).rolling(20).std().to_numpy()
    lo, hi = m - 2 * sd, m + 2 * sd
    rng = ad < adx_max
    sig = np.where(rng & (c < lo), 1, np.where(rng & (c > hi), -1, 0))
    tp = np.abs(m - c)
    return sig, sl_atr * a, tp, none_like(len(c)), np.zeros(len(c), np.int64), max_hold


# --- E: time-series momentum on D1 (sign of the N-day return), ATR stop + trailing, exit on sign flip
def ts_momentum(df, lookback=60, sl_atr=3.0, trail_atr=3.0):
    h, l, c = df.h.to_numpy(), df.l.to_numpy(), df.c.to_numpy()
    a = bt.atr(h, l, c, 20)
    ret = c / np.r_[np.full(lookback, np.nan), c[:-lookback]] - 1
    s = np.sign(np.nan_to_num(ret))
    sp = np.r_[0, s[:-1]]
    sig = np.where(s != sp, s, 0)               # enter when the sign changes
    ex = (-s).astype(np.int64)                   # a long closes when the sign turns negative
    return sig, sl_atr * a, none_like(len(c)), trail_atr * a, ex, 0


def run(df, pair, arrays):
    sig, sl, tp, tr, ex, mh = arrays
    o, h, l, c = (df[k].to_numpy() for k in "ohlc")
    res = bt.run(o, h, l, c, sig.astype(np.int64), np.nan_to_num(sl, nan=-1.0),
                 np.nan_to_num(tp, nan=-1.0), np.nan_to_num(tr, nan=-1.0), ex, mh, bt.SPREAD[pair])
    return bt.trades_df(df, res, pair)
