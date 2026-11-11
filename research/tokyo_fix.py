"""USDJPY Tokyo-fix (9:55 JST) anomaly check.
Primary hypothesis (fixed before looking at the data):
  sell USDJPY at 9:55:00 JST, buy back at 11:00:00 JST -> positive after costs,
  in-sample 2010-2019 (t >= 2) AND out-of-sample 2020-2026.10.
Secondary: gotobi (5/10/15/20/25/month-end, moved to the previous business day) vs other days,
other exit times, the pre-fix rise, year by year.
Prices are BID M1 opens at the exact minute; a short pays the spread once (sell bid, buy ask).
usage: python -I tokyo_fix.py <M1 parquet>"""
import sys
import numpy as np
import pandas as pd
import holidays

PIP = 0.01
COSTS = (0.5, 1.0)                       # round-trip cost in pips
SPLIT = pd.Timestamp("2020-01-01")

m1 = pd.read_parquet(sys.argv[1])
m1.index = m1.index + pd.Timedelta(hours=9)          # UTC -> JST
opens = m1["o"]

# --- Tokyo business days and gotobi days
years = range(2010, 2027)
jpx = holidays.JPX(years=years)
days = pd.bdate_range("2010-01-04", "2026-10-30")
bdays = pd.DatetimeIndex([d for d in days if d not in jpx])
bset = set(bdays)


def prev_bday(d):
    while d not in bset:
        d -= pd.Timedelta(days=1)
    return d


gotobi = set()
for y in years:
    for mth in range(1, 13):
        last = (pd.Timestamp(y, mth, 1) + pd.offsets.MonthEnd(0)).day
        for day in (5, 10, 15, 20, 25, last):
            d = pd.Timestamp(y, mth, day)
            if pd.Timestamp("2010-01-04") <= d <= pd.Timestamp("2026-10-30"):
                gotobi.add(prev_bday(d))


def price_at(hhmm):
    """BID open of the M1 bar starting at hh:mm JST on every business day (NaN if that minute is missing)."""
    h, m = map(int, hhmm.split(":"))
    ts = bdays + pd.Timedelta(hours=h, minutes=m)
    return pd.Series(opens.reindex(ts).to_numpy(), index=bdays)


P = {t: price_at(t) for t in ("09:00", "09:30", "09:55", "10:15", "10:30", "11:00", "12:00", "15:00")}
is_gotobi = pd.Series([d in gotobi for d in bdays], index=bdays)
period = pd.Series(np.where(bdays < SPLIT, "IS 2010-19", "OOS 2020-26"), index=bdays)


def summarize(pips, label):
    rows = []
    for per in ("IS 2010-19", "OOS 2020-26"):
        for grp, mask in (("all", slice(None)), ("gotobi", is_gotobi), ("other", ~is_gotobi)):
            x = pips[(period == per)][mask[period == per] if grp != "all" else slice(None)].dropna()
            n = len(x)
            t = x.mean() / (x.std(ddof=1) / np.sqrt(n)) if n > 2 else np.nan
            row = {"trade": label, "period": per, "days": grp, "n": n, "gross pips": round(x.mean(), 2),
                   "t": round(t, 1), "std": round(x.std(), 1)}
            for c in COSTS:
                row[f"net@{c}"] = round(x.mean() - c, 2)
                row[f"win@{c}%"] = round((x > c).mean() * 100, 1)
            rows.append(row)
    return rows


rows = []
# primary + exit grid: short from the fix
for ex in ("10:15", "10:30", "11:00", "12:00", "15:00"):
    rows += summarize((P["09:55"] - P[ex]) / PIP, f"SHORT 09:55->{ex}")
# pre-fix rise: long into the fix
for st in ("09:00", "09:30"):
    rows += summarize((P["09:55"] - P[st]) / PIP, f"LONG {st}->09:55")
pd.set_option("display.width", 220)
out = pd.DataFrame(rows)
print(out.to_string(index=False))

print("\nPrimary (SHORT 09:55->11:00) by year, gross pips per day:")
prim = (P["09:55"] - P["11:00"]) / PIP
yr = pd.DataFrame({"all": prim.groupby(prim.index.year).mean(),
                   "gotobi": prim[is_gotobi].groupby(prim[is_gotobi].index.year).mean(),
                   "other": prim[~is_gotobi].groupby(prim[~is_gotobi].index.year).mean(),
                   "n": prim.groupby(prim.index.year).count()}).round(2)
print(yr.to_string())
print("\nmissing exact minutes:", {k: int(v.isna().sum()) for k, v in P.items()}, "of", len(bdays), "business days")
