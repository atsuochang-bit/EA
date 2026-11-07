"""Small bar-by-bar backtest engine for strategy research (BID bars + fixed spread).

Rules shared by every strategy:
- a signal is evaluated on the CLOSE of bar i and filled at the OPEN of bar i+1 (market order)
- long: fills at ask (= bid + spread), exits on bid; short: fills at bid, exits on ask
- SL is checked before TP inside a bar (conservative); a gap through SL fills at the open
- results are in R = pnl / initial risk (risk measured from the actual fill incl. spread)
- one position at a time per instrument
"""
import numpy as np
import pandas as pd
from numba import njit

SPREAD = {  # round-trip cost proxy in price units (typical retail ECN spread + commission)
    "EURUSD": 0.00012, "GBPUSD": 0.00018, "AUDUSD": 0.00015, "USDCHF": 0.00018,
    "USDJPY": 0.014, "EURJPY": 0.020,
}


# ---------------------------------------------------------------- indicators
def wilder(x, n):
    out = np.full(len(x), np.nan)
    if len(x) <= n:
        return out
    out[n - 1] = np.nanmean(x[:n])
    a = 1.0 / n
    for i in range(n, len(x)):
        out[i] = out[i - 1] + a * (x[i] - out[i - 1])
    return out


def atr(h, l, c, n=14):
    pc = np.r_[c[0], c[:-1]]
    tr = np.maximum(h, pc) - np.minimum(l, pc)
    return wilder(tr, n)


def ema(x, n):
    return pd.Series(x).ewm(span=n, adjust=False).mean().to_numpy()


def sma(x, n):
    return pd.Series(x).rolling(n).mean().to_numpy()


def rsi(c, n=14):
    d = np.diff(c, prepend=c[0])
    up, dn = wilder(np.maximum(d, 0), n), wilder(np.maximum(-d, 0), n)
    rs = up / np.where(dn == 0, np.nan, dn)
    return 100 - 100 / (1 + rs)


def adx(h, l, c, n=14):
    up = np.diff(h, prepend=h[0])
    dn = -np.diff(l, prepend=l[0])
    pdm = np.where((up > dn) & (up > 0), up, 0.0)
    mdm = np.where((dn > up) & (dn > 0), dn, 0.0)
    a = atr(h, l, c, n)
    pdi = 100 * wilder(pdm, n) / a
    mdi = 100 * wilder(mdm, n) / a
    dx = 100 * np.abs(pdi - mdi) / np.where(pdi + mdi == 0, np.nan, pdi + mdi)
    return wilder(np.nan_to_num(dx), n), pdi, mdi


def rolling_max(x, n):
    return pd.Series(x).rolling(n).max().to_numpy()


def rolling_min(x, n):
    return pd.Series(x).rolling(n).min().to_numpy()


def efficiency_ratio(c, n):
    change = np.abs(c - np.r_[np.full(n, np.nan), c[:-n]])
    vol = pd.Series(np.abs(np.diff(c, prepend=c[0]))).rolling(n).sum().to_numpy()
    return change / np.where(vol == 0, np.nan, vol)


# ---------------------------------------------------------------- engine
@njit(cache=True)
def run(o, h, l, c, sig, sl_dist, tp_dist, trail_dist, exit_sig, max_hold, spread):
    """sig[i] in {-1,0,1}; sl_dist/tp_dist/trail_dist in price (tp/trail <= 0 = off);
    exit_sig[i] in {-1,0,1}: close a position of the opposite sign... (=-dir) at next open."""
    n = len(c)
    ent_i = np.empty(n, np.int64); ex_i = np.empty(n, np.int64)
    dirs = np.empty(n, np.int64); rr = np.empty(n, np.float64)
    k = 0
    pos = 0; entry = 0.0; sl = 0.0; tp = 0.0; risk = 0.0; trail = 0.0; ei = 0
    i = 0
    while i < n - 1:
        if pos == 0:
            s = sig[i]
            if s != 0 and sl_dist[i] > 0 and not np.isnan(sl_dist[i]):
                j = i + 1
                pos = s
                ei = j
                if s > 0:
                    entry = o[j] + spread
                    sl = entry - sl_dist[i]
                    tp = entry + tp_dist[i] if tp_dist[i] > 0 else 1e18
                else:
                    entry = o[j]
                    sl = entry + sl_dist[i]
                    tp = entry - tp_dist[i] if tp_dist[i] > 0 else -1e18
                risk = sl_dist[i]
                trail = trail_dist[i]
                i = j
                continue
            i += 1
            continue
        # manage open position on bar i (entry bar included)
        exit_px = np.nan
        if pos > 0:
            if l[i] <= sl:
                exit_px = min(o[i], sl) if i > ei else sl
            elif h[i] >= tp:
                exit_px = max(o[i], tp) if i > ei else tp
        else:
            if h[i] + spread >= sl:
                exit_px = max(o[i] + spread, sl) if i > ei else sl
            elif l[i] + spread <= tp:
                exit_px = min(o[i] + spread, tp) if i > ei else tp
        if np.isnan(exit_px):
            # bar-close management
            if trail > 0:
                if pos > 0:
                    sl = max(sl, c[i] - trail)
                else:
                    sl = min(sl, c[i] + spread + trail)
            if exit_sig[i] == -pos or (max_hold > 0 and i - ei + 1 >= max_hold):
                j = i + 1
                exit_px = o[j] if pos > 0 else o[j] + spread
                ent_i[k] = ei; ex_i[k] = j; dirs[k] = pos
                rr[k] = (exit_px - entry) / risk if pos > 0 else (entry - exit_px) / risk
                k += 1
                pos = 0
                i = j
                continue
            i += 1
            continue
        ent_i[k] = ei; ex_i[k] = i; dirs[k] = pos
        rr[k] = (exit_px - entry) / risk if pos > 0 else (entry - exit_px) / risk
        k += 1
        pos = 0
        # stay on bar i: a signal at its close may open the next trade at i+1
    return ent_i[:k], ex_i[:k], dirs[:k], rr[:k]


def trades_df(df, res, pair):
    ei, xi, d, r = res
    return pd.DataFrame({"pair": pair, "t_in": df.index[ei], "t_out": df.index[np.minimum(xi, len(df) - 1)],
                         "dir": d, "R": r})


# ---------------------------------------------------------------- metrics
def stats(tr, risk_pct=1.0):
    if len(tr) == 0:
        return dict(n=0)
    r = tr["R"].to_numpy()
    eq = np.cumsum(r)
    dd = (np.maximum.accumulate(np.r_[0, eq]) - np.r_[0, eq]).max()
    gp, gl = r[r > 0].sum(), -r[r < 0].sum()
    years = max((tr["t_out"].max() - tr["t_in"].min()).days / 365.25, 1e-9)
    return dict(n=len(r), win=round((r > 0).mean() * 100, 1), avgR=round(r.mean(), 3),
                PF=round(gp / gl, 2) if gl > 0 else np.inf, totR=round(r.sum(), 1),
                maxDD_R=round(dd, 1), R_per_yr=round(r.sum() / years, 1),
                t_per_yr=round(len(r) / years, 1))


def by_year(tr):
    g = tr.groupby(tr["t_out"].dt.year)["R"]
    return pd.DataFrame({"n": g.size(), "sumR": g.sum().round(1)})


def load(pair, tf, data_dir):
    df = pd.read_parquet(f"{data_dir}/{pair}_{tf}.parquet")
    return df[df["n"] >= (3 if tf == "M15" else 10)]  # drop near-empty bars (holidays)
