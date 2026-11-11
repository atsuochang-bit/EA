"""Download HistData.com M1 (EST without DST, BID) for one pair and save it UTC-indexed as parquet.
Sequential and throttled (one request at a time).  usage: python -I fetch_m1.py <out_dir> PAIR"""
import io, os, sys, time, zipfile
import pandas as pd
from histdata.api import download_hist_data, Platform, TimeFrame

OUT, PAIR = sys.argv[1], sys.argv[2].upper()
RAW = os.path.join(OUT, "raw")
os.makedirs(RAW, exist_ok=True)
JOBS = [(y, None) for y in range(2010, 2026)] + [(2026, m) for m in range(1, 11)]


def fetch(year, month):
    for attempt in range(4):
        try:
            return download_hist_data(year=str(year), month=month, pair=PAIR.lower(), platform=Platform.GENERIC_ASCII,
                                      time_frame=TimeFrame.ONE_MINUTE, output_directory=RAW, verbose=False)
        except Exception as e:
            print(f"  {year}-{month}: attempt {attempt + 1} failed: {e}", flush=True)
            time.sleep(5 * (attempt + 1))
    return None


parts = []
for y, m in JOBS:
    z = fetch(y, m)
    if z is None:
        print(f"  {y}-{m}: SKIPPED", flush=True)
        continue
    with zipfile.ZipFile(z) as zf:
        raw = zf.read([n for n in zf.namelist() if n.endswith(".csv")][0])
    os.remove(z)
    df = pd.read_csv(io.BytesIO(raw), sep=";", header=None, names=["t", "o", "h", "l", "c", "v"], dtype={"t": str})
    df.index = pd.to_datetime(df["t"], format="%Y%m%d %H%M%S") + pd.Timedelta(hours=5)   # EST(no DST) -> UTC
    parts.append(df[["o", "h", "l", "c"]].astype("float64"))
    time.sleep(1.5)
m1 = pd.concat(parts).sort_index()
m1 = m1[~m1.index.duplicated(keep="last")]
m1.to_parquet(os.path.join(OUT, f"{PAIR}_M1.parquet"))
print(f"{PAIR}: {len(m1):,} M1 rows  {m1.index[0]} .. {m1.index[-1]}", flush=True)
