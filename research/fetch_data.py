"""Download HistData.com M1 (EST, no DST, BID) and build UTC-indexed M15 / H1 parquet files.
Sequential and throttled on purpose (one request at a time, pause between files).
usage: python -I fetch_data.py <out_dir> PAIR [PAIR ...]
"""
import io, os, sys, time, zipfile, datetime as dt
import pandas as pd
from histdata.api import download_hist_data, Platform, TimeFrame

OUT = sys.argv[1]
PAIRS = [p.upper() for p in sys.argv[2:]]
FIRST_YEAR, LAST_FULL_YEAR = 2010, 2025
CUR_YEAR, LAST_MONTH = 2026, 10
RAW = os.path.join(OUT, "raw")
os.makedirs(RAW, exist_ok=True)


def fetch(pair, year, month=None):
    for attempt in range(4):
        try:
            return download_hist_data(year=str(year), month=month, pair=pair.lower(),
                                      platform=Platform.GENERIC_ASCII, time_frame=TimeFrame.ONE_MINUTE,
                                      output_directory=RAW, verbose=False)
        except Exception as e:  # network hiccup or missing period
            print(f"  {pair} {year}-{month}: attempt {attempt+1} failed: {e}", flush=True)
            time.sleep(5 * (attempt + 1))
    return None


def read_zip(path):
    with zipfile.ZipFile(path) as z:
        name = [n for n in z.namelist() if n.endswith(".csv")][0]
        raw = z.read(name)
    df = pd.read_csv(io.BytesIO(raw), sep=";", header=None,
                     names=["t", "o", "h", "l", "c", "v"], dtype={"t": str})
    t = pd.to_datetime(df["t"], format="%Y%m%d %H%M%S") + pd.Timedelta(hours=5)  # EST(no DST) -> UTC
    df.index = t
    return df[["o", "h", "l", "c"]].astype("float64")


def resample(m1, rule):
    agg = m1.resample(rule, label="left", closed="left").agg({"o": "first", "h": "max", "l": "min", "c": "last"})
    agg["n"] = m1["c"].resample(rule, label="left", closed="left").count()
    return agg.dropna(subset=["o"])


for pair in PAIRS:
    target = os.path.join(OUT, f"{pair}_H1.parquet")
    if os.path.exists(target):
        print(pair, "already done", flush=True)
        continue
    parts = []
    jobs = [(y, None) for y in range(FIRST_YEAR, LAST_FULL_YEAR + 1)] + [(CUR_YEAR, m) for m in range(1, LAST_MONTH + 1)]
    for y, m in jobs:
        z = fetch(pair, y, m)
        if z is None:
            print(f"  {pair} {y}-{m}: SKIPPED", flush=True)
            continue
        try:
            parts.append(read_zip(z))
        finally:
            os.remove(z)
        time.sleep(1.5)
    m1 = pd.concat(parts).sort_index()
    m1 = m1[~m1.index.duplicated(keep="last")]
    resample(m1, "15min").to_parquet(os.path.join(OUT, f"{pair}_M15.parquet"))
    resample(m1, "1h").to_parquet(target)
    print(f"{pair}: {len(m1):,} M1 rows  {m1.index[0]} .. {m1.index[-1]}", flush=True)
print("ALL DONE", flush=True)
