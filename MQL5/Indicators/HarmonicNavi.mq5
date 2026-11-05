//+------------------------------------------------------------------+
//|                                                 HarmonicNavi.mq5 |
//|  XABCD harmonic pattern "navigator" for MetaTrader 5.            |
//|  - Detects X-A-B-C on confirmed swings and projects the D point  |
//|    (entry), stop loss and targets T1-T3 BEFORE price gets there. |
//|  - When price reaches D, the setup becomes a signal and its      |
//|    outcome (T1/T2/T3/SL/timeout) is tracked and counted.         |
//|  - Everything is evaluated on closed bars only (no repaint).     |
//+------------------------------------------------------------------+
#property copyright   "atsuochang-bit"
#property version     "1.00"
#property description "XABCD harmonic pattern navigator."
#property description "Shows Entry / SL / T1-T3 in advance and tracks hit statistics."
#property description "Closed bars only - signals never repaint."
#property indicator_chart_window
#property indicator_buffers 6
#property indicator_plots   6

#property indicator_label1  "Buy entry"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  C'38,166,154'
#property indicator_width1  2
#property indicator_label2  "Sell entry"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  C'239,83,80'
#property indicator_width2  2
#property indicator_label3  "Stop loss"
#property indicator_type3   DRAW_NONE
#property indicator_label4  "Target 1"
#property indicator_type4   DRAW_NONE
#property indicator_label5  "Target 2"
#property indicator_type5   DRAW_NONE
#property indicator_label6  "Target 3"
#property indicator_type6   DRAW_NONE

//--- enums ----------------------------------------------------------
enum ENUM_HN_SL_MODE
  {
   HN_SL_ATR     = 0, // ATR distance from D
   HN_SL_PATTERN = 1  // Pattern structure (beyond X / extension)
  };

enum ENUM_HN_TP_MODE
  {
   HN_TP_RR     = 0, // Multiples of risk R
   HN_TP_FIB_AD = 1  // Fibonacci retracement of the A(C)-D leg
  };

//--- inputs ---------------------------------------------------------
input group "=== Swing detection ==="
input int    InpPivotLen     = 5;     // Pivot strength (bars on each side)
input double InpMinSwingATR  = 1.0;   // Min swing size (x ATR, 0 = off)
input int    InpATRPeriod    = 14;    // ATR period

input group "=== Patterns ==="
input bool   InpGartley      = true;  // Gartley
input bool   InpBat          = true;  // Bat
input bool   InpAltBat       = true;  // Alternate Bat
input bool   InpButterfly    = true;  // Butterfly
input bool   InpCrab         = true;  // Crab
input bool   InpDeepCrab     = true;  // Deep Crab
input bool   InpCypher       = true;  // Cypher
input double InpTolerance    = 0.05;  // Ratio tolerance (0.05 = 5%)

input group "=== Entry / Stop / Targets ==="
input ENUM_HN_SL_MODE InpSLMode      = HN_SL_ATR; // Stop loss mode
input double          InpSLATR       = 1.0;       // [ATR mode] SL distance from D (x ATR)
input double          InpSLBufferATR = 0.2;       // [Pattern mode] buffer beyond structure (x ATR)
input ENUM_HN_TP_MODE InpTPMode      = HN_TP_RR;  // Target mode
input double          InpR1          = 2.618;     // [R mode] T1 (x R)
input double          InpR2          = 4.236;     // [R mode] T2 (x R)
input double          InpR3          = 6.854;     // [R mode] T3 (x R)
input double          InpF1          = 0.382;     // [Fib mode] T1 (of A-D leg)
input double          InpF2          = 0.618;     // [Fib mode] T2 (of A-D leg)
input double          InpF3          = 1.000;     // [Fib mode] T3 (of A-D leg)
input bool            InpBEAfterT1   = false;     // Move SL to entry after T1
input int             InpPendingBars = 100;       // Pending setup expiry (bars, 0 = never)
input int             InpTradeBars   = 300;       // Signal timeout (bars, 0 = never)

input group "=== Display ==="
input int              InpMaxBars        = 5000;               // Bars to calculate
input int              InpMaxDrawnTrades = 30;                 // Signals kept on chart
input bool             InpShowPattern    = true;               // Draw XABCD legs
input bool             InpShowPending    = true;               // Draw pending setups (advance notice)
input bool             InpShowNavArrow   = true;               // Draw route arrow Entry -> T1
input bool             InpShowStats      = true;               // Show statistics panel
input ENUM_BASE_CORNER InpStatsCorner    = CORNER_LEFT_LOWER;  // Statistics panel corner
input int              InpProjectBars    = 30;                 // Level line length to the right (bars)
input color            InpBuyColor       = C'38,166,154';      // Buy color
input color            InpSellColor      = C'239,83,80';       // Sell color
input color            InpTargetColor    = C'38,166,154';      // Target lines
input color            InpSLColor        = C'239,83,80';       // Stop loss line
input color            InpEntryColor     = clrSilver;          // Entry line
input color            InpPatternColor   = clrDarkGray;        // Pattern legs
input int              InpFontSize       = 8;                  // Font size

input group "=== Alerts ==="
input bool InpAlertPopup = true;   // Popup alert
input bool InpAlertPush  = false;  // Push notification
input bool InpAlertSetup = true;   // Alert on new pending setup
input bool InpAlertEntry = true;   // Alert on entry (D reached)
input bool InpAlertHits  = true;   // Alert on T1/T2/T3/SL

//--- pattern table --------------------------------------------------
// AB = AB/XA, BC = BC/AB, CD = CD/BC, AD = D as retracement of XA
// (Cypher: D = 0.786 retracement of XC, stop reference = X)
#define PAT_COUNT  7
#define PAT_CYPHER 6
string g_patName[PAT_COUNT] = {"Gartley", "Bat", "Alt Bat", "Butterfly", "Crab", "Deep Crab", "Cypher"};
double g_abMin[PAT_COUNT]   = {0.618, 0.382, 0.236, 0.786, 0.382, 0.886, 0.382};
double g_abMax[PAT_COUNT]   = {0.618, 0.500, 0.382, 0.786, 0.618, 0.886, 0.618};
double g_bcMin[PAT_COUNT]   = {0.382, 0.382, 0.382, 0.382, 0.382, 0.382, 1.130};
double g_bcMax[PAT_COUNT]   = {0.886, 0.886, 0.886, 0.886, 0.886, 0.886, 1.414};
double g_cdMin[PAT_COUNT]   = {1.130, 1.618, 2.000, 1.618, 2.240, 2.000, 1.272};
double g_cdMax[PAT_COUNT]   = {1.618, 2.618, 3.618, 2.618, 3.618, 3.618, 2.000};
double g_adXA[PAT_COUNT]    = {0.786, 0.886, 1.130, 1.270, 1.618, 1.618, 0.786};
double g_slXA[PAT_COUNT]    = {1.000, 1.000, 1.270, 1.414, 2.000, 2.000, 1.000};
bool   g_patOn[PAT_COUNT];

//--- structures -----------------------------------------------------
#define HN_OPEN        0
#define HN_RES_SL      1
#define HN_RES_T3      2
#define HN_RES_TIMEOUT 3

struct HNSwing
  {
   double            price;
   datetime          time;
   int               type;      // +1 swing high, -1 swing low
  };

struct HNSetup
  {
   bool              active;
   int               dir;       // +1 buy (bullish pattern), -1 sell (bearish pattern)
   int               pat;
   double            X, A, B, C;
   datetime          tX, tA, tB, tC;
   double            entry, sl, t1, t2, t3;
   int               bars;
  };

struct HNTrade
  {
   int               id;
   int               dir;
   int               pat;
   double            X, A, B, C;
   datetime          tX, tA, tB, tC;
   double            entry, sl, slInit, t1, t2, t3;
   datetime          tEntry, tHit1, tHit2, tHit3, tEnd;
   int               stage;     // highest target reached (0..3)
   int               bars;
   int               result;    // HN_OPEN / HN_RES_SL / HN_RES_T3 / HN_RES_TIMEOUT
   bool              finalDrawn;
  };

//--- buffers & state ------------------------------------------------
double   g_buyBuf[], g_sellBuf[], g_slBuf[], g_t1Buf[], g_t2Buf[], g_t3Buf[];

HNSwing  g_sw[];
HNSetup  g_pend[2];             // [0] = buy setup, [1] = sell setup
HNTrade  g_tr[];

string   g_prefix   = "HNV_";
int      g_start    = 0;
int      g_lastIdx  = -1;
datetime g_lastTime = 0;
bool     g_live     = false;

double   g_atr = 0.0, g_atrSum = 0.0;
int      g_atrCnt = 0;

int      g_nextId = 0, g_firstOpen = 0, g_firstDrawn = 0;
int      g_signals = 0, g_resolved = 0, g_hit1 = 0, g_hit2 = 0, g_hit3 = 0;
int      g_slNoT1 = 0, g_slAfterT1 = 0, g_timeouts = 0, g_late = 0;

//+------------------------------------------------------------------+
//| Initialization                                                    |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpPivotLen < 1 || InpATRPeriod < 1)
     {
      Print("HarmonicNavi: Pivot strength and ATR period must be >= 1");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpSLMode == HN_SL_ATR && InpSLATR <= 0.0)
     {
      Print("HarmonicNavi: SL distance (x ATR) must be > 0 in ATR stop mode");
      return INIT_PARAMETERS_INCORRECT;
     }

   SetIndexBuffer(0, g_buyBuf,  INDICATOR_DATA);
   SetIndexBuffer(1, g_sellBuf, INDICATOR_DATA);
   SetIndexBuffer(2, g_slBuf,   INDICATOR_DATA);
   SetIndexBuffer(3, g_t1Buf,   INDICATOR_DATA);
   SetIndexBuffer(4, g_t2Buf,   INDICATOR_DATA);
   SetIndexBuffer(5, g_t3Buf,   INDICATOR_DATA);
   for(int p = 0; p < 6; p++)
      PlotIndexSetDouble(p, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetInteger(0, PLOT_ARROW, 233);
   PlotIndexSetInteger(1, PLOT_ARROW, 234);
   PlotIndexSetInteger(0, PLOT_ARROW_SHIFT, 12);
   PlotIndexSetInteger(1, PLOT_ARROW_SHIFT, -12);
   PlotIndexSetInteger(0, PLOT_LINE_COLOR, InpBuyColor);
   PlotIndexSetInteger(1, PLOT_LINE_COLOR, InpSellColor);

   IndicatorSetString(INDICATOR_SHORTNAME, "HarmonicNavi");
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);

   g_patOn[0] = InpGartley;
   g_patOn[1] = InpBat;
   g_patOn[2] = InpAltBat;
   g_patOn[3] = InpButterfly;
   g_patOn[4] = InpCrab;
   g_patOn[5] = InpDeepCrab;
   g_patOn[6] = InpCypher;

   g_lastIdx  = -1;
   g_lastTime = 0;
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, g_prefix);
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| Main calculation                                                  |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   int minBars = 2 * InpPivotLen + InpATRPeriod + 5;
   if(rates_total < minBars)
      return 0;

   ArraySetAsSeries(time, false);
   ArraySetAsSeries(open, false);
   ArraySetAsSeries(high, false);
   ArraySetAsSeries(low, false);
   ArraySetAsSeries(close, false);

   bool full = (prev_calculated <= 0 || g_lastIdx < 0 || g_lastIdx >= rates_total ||
                time[g_lastIdx] != g_lastTime);

   if(full)
     {
      ResetState();
      ArrayInitialize(g_buyBuf,  EMPTY_VALUE);
      ArrayInitialize(g_sellBuf, EMPTY_VALUE);
      ArrayInitialize(g_slBuf,   EMPTY_VALUE);
      ArrayInitialize(g_t1Buf,   EMPTY_VALUE);
      ArrayInitialize(g_t2Buf,   EMPTY_VALUE);
      ArrayInitialize(g_t3Buf,   EMPTY_VALUE);
      g_start    = MathMax(InpPivotLen + 1, rates_total - MathMax(InpMaxBars, minBars));
      g_lastIdx  = g_start - 1;
      g_lastTime = time[g_lastIdx];
     }
   else
     {
      for(int k = g_lastIdx + 1; k < rates_total; k++)
        {
         g_buyBuf[k]  = EMPTY_VALUE;
         g_sellBuf[k] = EMPTY_VALUE;
         g_slBuf[k]   = EMPTY_VALUE;
         g_t1Buf[k]   = EMPTY_VALUE;
         g_t2Buf[k]   = EMPTY_VALUE;
         g_t3Buf[k]   = EMPTY_VALUE;
        }
     }

   int  lastClosed = rates_total - 2;   // the forming bar is never evaluated
   bool processed  = false;
   for(int i = g_lastIdx + 1; i <= lastClosed; i++)
     {
      g_live = (!full && i == lastClosed);   // alerts only for the bar that just closed
      ProcessBar(i, time, high, low, close);
      g_lastIdx  = i;
      g_lastTime = time[i];
      processed  = true;
     }
   g_live = false;

   if(processed || full)
      RefreshDrawings(time[rates_total - 1]);

   return rates_total;
  }

//+------------------------------------------------------------------+
void ResetState()
  {
   ObjectsDeleteAll(0, g_prefix);
   ArrayFree(g_sw);
   ArrayFree(g_tr);
   for(int s = 0; s < 2; s++)
     {
      ZeroMemory(g_pend[s]);
      g_pend[s].active = false;
     }
   g_atr = 0.0;
   g_atrSum = 0.0;
   g_atrCnt = 0;
   g_nextId = 0;
   g_firstOpen = 0;
   g_firstDrawn = 0;
   g_signals = 0;
   g_resolved = 0;
   g_hit1 = 0;
   g_hit2 = 0;
   g_hit3 = 0;
   g_slNoT1 = 0;
   g_slAfterT1 = 0;
   g_timeouts = 0;
   g_late = 0;
   g_live = false;
  }

//+------------------------------------------------------------------+
//| One closed bar, processed in chronological order                  |
//+------------------------------------------------------------------+
void ProcessBar(const int i, const datetime &time[], const double &high[],
                const double &low[], const double &close[])
  {
//--- ATR (Wilder)
   double tr = MathMax(high[i], close[i - 1]) - MathMin(low[i], close[i - 1]);
   if(g_atrCnt < InpATRPeriod)
     {
      g_atrSum += tr;
      g_atrCnt++;
      g_atr = g_atrSum / g_atrCnt;
     }
   else
      g_atr = (g_atr * (InpATRPeriod - 1) + tr) / InpATRPeriod;

//--- 1) running signals
   ManageTrades(i, time, high, low);

//--- 2) pending setups (waiting for D)
   for(int s = 0; s < 2; s++)
      if(g_pend[s].active)
         HandlePending(s, i, time, high, low);

//--- 3) new swing -> new setup
   DetectPivot(i, time, high, low);
  }

//+------------------------------------------------------------------+
void ManageTrades(const int i, const datetime &time[], const double &high[], const double &low[])
  {
   int n = ArraySize(g_tr);
   while(g_firstOpen < n && g_tr[g_firstOpen].result != HN_OPEN)
      g_firstOpen++;
   for(int k = g_firstOpen; k < n; k++)
     {
      if(g_tr[k].result != HN_OPEN || g_tr[k].tEntry >= time[i])
         continue;
      UpdateTrade(g_tr[k], i, time, high, low);
     }
  }

//+------------------------------------------------------------------+
void UpdateTrade(HNTrade &t, const int i, const datetime &time[], const double &high[], const double &low[])
  {
   t.bars++;
//--- conservative: if SL and a target are inside the same bar, SL counts first
   bool slHit = (t.dir > 0) ? (low[i] <= t.sl) : (high[i] >= t.sl);
   if(slHit)
     {
      CloseTrade(t, HN_RES_SL, time[i]);
      return;
     }
   while(t.stage < 3)
     {
      double lvl = (t.stage == 0) ? t.t1 : ((t.stage == 1) ? t.t2 : t.t3);
      bool hit = (t.dir > 0) ? (high[i] >= lvl) : (low[i] <= lvl);
      if(!hit)
         break;
      t.stage++;
      if(t.stage == 1)
         t.tHit1 = time[i];
      else
         if(t.stage == 2)
            t.tHit2 = time[i];
         else
            t.tHit3 = time[i];
      if(InpAlertHits)
         Notify(SideName(t.dir) + " " + g_patName[t.pat] + ": Target " + IntegerToString(t.stage) +
                " hit at " + DoubleToString(lvl, _Digits));
      if(t.stage == 1 && InpBEAfterT1)
         t.sl = t.entry;
     }
   if(t.stage >= 3)
     {
      CloseTrade(t, HN_RES_T3, time[i]);
      return;
     }
   if(InpTradeBars > 0 && t.bars >= InpTradeBars)
      CloseTrade(t, HN_RES_TIMEOUT, time[i]);
  }

//+------------------------------------------------------------------+
void CloseTrade(HNTrade &t, const int res, const datetime when)
  {
   t.result = res;
   t.tEnd   = when;
   g_resolved++;
   if(t.stage >= 1)
      g_hit1++;
   if(t.stage >= 2)
      g_hit2++;
   if(t.stage >= 3)
      g_hit3++;
   if(res == HN_RES_SL)
     {
      if(t.stage == 0)
         g_slNoT1++;
      else
         g_slAfterT1++;
      if(InpAlertHits)
         Notify(SideName(t.dir) + " " + g_patName[t.pat] + ": Stop " + DoubleToString(t.sl, _Digits) +
                ((t.stage == 0) ? " hit before T1" : " hit after T" + IntegerToString(t.stage)));
     }
   if(res == HN_RES_TIMEOUT)
      g_timeouts++;
  }

//+------------------------------------------------------------------+
void HandlePending(const int s, const int i, const datetime &time[], const double &high[], const double &low[])
  {
   g_pend[s].bars++;
   int dir = g_pend[s].dir;
//--- price went beyond C: the pattern geometry is broken
   bool cBroken = (dir > 0) ? (high[i] > g_pend[s].C) : (low[i] < g_pend[s].C);
   if(cBroken)
     {
      g_pend[s].active = false;
      return;
     }
//--- D reached: limit entry at D
   bool touched = (dir > 0) ? (low[i] <= g_pend[s].entry) : (high[i] >= g_pend[s].entry);
   if(touched)
     {
      OpenTrade(g_pend[s], i, time, high, low);
      g_pend[s].active = false;
      return;
     }
   if(InpPendingBars > 0 && g_pend[s].bars >= InpPendingBars)
      g_pend[s].active = false;
  }

//+------------------------------------------------------------------+
void OpenTrade(const HNSetup &p, const int i, const datetime &time[], const double &high[], const double &low[])
  {
   HNTrade t;
   ZeroMemory(t);
   t.id     = g_nextId++;
   t.dir    = p.dir;
   t.pat    = p.pat;
   t.X      = p.X;
   t.A      = p.A;
   t.B      = p.B;
   t.C      = p.C;
   t.tX     = p.tX;
   t.tA     = p.tA;
   t.tB     = p.tB;
   t.tC     = p.tC;
   t.entry  = p.entry;
   t.sl     = p.sl;
   t.slInit = p.sl;
   t.t1     = p.t1;
   t.t2     = p.t2;
   t.t3     = p.t3;
   t.tEntry = time[i];
   t.stage  = 0;
   t.bars   = 0;
   t.result = HN_OPEN;
   t.finalDrawn = false;

   if(p.dir > 0)
      g_buyBuf[i] = p.entry;
   else
      g_sellBuf[i] = p.entry;
   g_slBuf[i] = p.sl;
   g_t1Buf[i] = p.t1;
   g_t2Buf[i] = p.t2;
   g_t3Buf[i] = p.t3;
   g_signals++;

   int n = ArraySize(g_tr);
   ArrayResize(g_tr, n + 1, 256);
   g_tr[n] = t;

   if(InpAlertEntry)
      Notify(SideName(p.dir) + " " + g_patName[p.pat] + " ENTRY " + DoubleToString(p.entry, _Digits) +
             "  SL " + DoubleToString(p.sl, _Digits) + "  T1 " + DoubleToString(p.t1, _Digits) +
             "  T2 " + DoubleToString(p.t2, _Digits) + "  T3 " + DoubleToString(p.t3, _Digits));

//--- conservative: stop inside the entry bar counts as a loss
   bool slHit = (p.dir > 0) ? (low[i] <= p.sl) : (high[i] >= p.sl);
   if(slHit)
      CloseTrade(g_tr[n], HN_RES_SL, time[i]);
  }

//+------------------------------------------------------------------+
//| Fractal pivot confirmed InpPivotLen bars after it formed          |
//+------------------------------------------------------------------+
void DetectPivot(const int i, const datetime &time[], const double &high[], const double &low[])
  {
   int L = InpPivotLen;
   int j = i - L;
   if(j < g_start || j - L < 0)
      return;

   bool ph = true, pl = true;
   for(int k = 1; k <= L && (ph || pl); k++)
     {
      if(ph && !(high[j] > high[j - k] && high[j] >= high[j + k]))
         ph = false;
      if(pl && !(low[j] < low[j - k] && low[j] <= low[j + k]))
         pl = false;
     }
   if(ph && pl)   // outside bar: keep the alternating one
     {
      int n = ArraySize(g_sw);
      if(n > 0 && g_sw[n - 1].type > 0)
         ph = false;
      else
         pl = false;
     }

   bool changed = false;
   if(ph)
      changed = AddSwing(1, high[j], time[j]);
   else
      if(pl)
         changed = AddSwing(-1, low[j], time[j]);

   if(changed)
      OnSwingsChanged(i, j, time, high, low);
  }

//+------------------------------------------------------------------+
//| Alternating swing list (zigzag)                                   |
//+------------------------------------------------------------------+
bool AddSwing(const int type, const double price, const datetime t)
  {
   int n = ArraySize(g_sw);
   if(n > 0)
     {
      if(g_sw[n - 1].type == type)
        {
         bool more = (type > 0) ? (price > g_sw[n - 1].price) : (price < g_sw[n - 1].price);
         if(!more)
            return false;
         g_sw[n - 1].price = price;    // same direction continues: extend the swing
         g_sw[n - 1].time  = t;
         return true;
        }
      //--- a low must be below the last high and vice versa
      if(type > 0 && price <= g_sw[n - 1].price)
         return false;
      if(type < 0 && price >= g_sw[n - 1].price)
         return false;
      //--- ignore small swings
      if(InpMinSwingATR > 0.0 && g_atrCnt >= InpATRPeriod &&
         MathAbs(price - g_sw[n - 1].price) < InpMinSwingATR * g_atr)
         return false;
     }
   if(n >= 64)
     {
      for(int k = 0; k < 32; k++)
         g_sw[k] = g_sw[n - 32 + k];
      ArrayResize(g_sw, 32);
      n = 32;
     }
   ArrayResize(g_sw, n + 1, 64);
   g_sw[n].price = price;
   g_sw[n].time  = t;
   g_sw[n].type  = type;
   return true;
  }

//+------------------------------------------------------------------+
//| Called when the last swing was added or extended                  |
//| i = current closed bar, j = bar of that swing                     |
//+------------------------------------------------------------------+
void OnSwingsChanged(const int i, const int j, const datetime &time[], const double &high[], const double &low[])
  {
   int n = ArraySize(g_sw);
   HNSwing last = g_sw[n - 1];

//--- a new C-type swing after C means the D leg ended without reaching D
   for(int s = 0; s < 2; s++)
      if(g_pend[s].active && last.time > g_pend[s].tC && last.type == g_pend[s].dir)
         g_pend[s].active = false;

   if(n < 4 || g_atrCnt < InpATRPeriod)
      return;

   int dir  = last.type;          // C is a high -> bullish pattern (D will be a low)
   int slot = (dir > 0) ? 0 : 1;
   if(g_pend[slot].active)
      return;

   HNSetup su;
   ZeroMemory(su);
   if(!BuildSetup(g_sw[n - 4], g_sw[n - 3], g_sw[n - 2], g_sw[n - 1], su))
      return;

//--- D already reached while C was being confirmed -> too late, skip
   for(int k = j + 1; k <= i; k++)
     {
      if((dir > 0 && low[k] <= su.entry) || (dir < 0 && high[k] >= su.entry))
        {
         g_late++;
         return;
        }
     }

   su.active = true;
   su.bars   = 0;
   g_pend[slot] = su;

   if(InpAlertSetup)
      Notify("New " + SideName(dir) + " setup (" + g_patName[su.pat] + ")  LIMIT " +
             DoubleToString(su.entry, _Digits) + "  SL " + DoubleToString(su.sl, _Digits) +
             "  T1 " + DoubleToString(su.t1, _Digits) + "  T2 " + DoubleToString(su.t2, _Digits) +
             "  T3 " + DoubleToString(su.t3, _Digits));
  }

//+------------------------------------------------------------------+
bool InRatio(const double r, const double lo, const double hi)
  {
   return (r >= lo * (1.0 - InpTolerance) && r <= hi * (1.0 + InpTolerance));
  }

//+------------------------------------------------------------------+
//| Match X-A-B-C against the pattern table and project D / SL / T    |
//| If several patterns fit, the one with the nearest D is used.      |
//+------------------------------------------------------------------+
bool BuildSetup(const HNSwing &x, const HNSwing &a, const HNSwing &b, const HNSwing &c, HNSetup &out)
  {
   int dir = c.type;
   if(x.type != -dir || a.type != dir || b.type != -dir)
      return false;

   double XA = MathAbs(a.price - x.price);
   double AB = MathAbs(a.price - b.price);
   double BC = MathAbs(c.price - b.price);
   if(XA <= 0.0 || AB <= 0.0 || BC <= 0.0)
      return false;
//--- B must lie inside the XA leg
   if(dir * (a.price - x.price) <= 0.0 || dir * (b.price - x.price) <= 0.0 || dir * (a.price - b.price) <= 0.0)
      return false;

   double rAB = AB / XA;
   double rBC = BC / AB;
   double best = DBL_MAX;
   bool   found = false;

   for(int p = 0; p < PAT_COUNT; p++)
     {
      if(!g_patOn[p])
         continue;
      if(!InRatio(rAB, g_abMin[p], g_abMax[p]) || !InRatio(rBC, g_bcMin[p], g_bcMax[p]))
         continue;

      double d, slRef;
      if(p == PAT_CYPHER)
        {
         d     = c.price - dir * g_adXA[p] * MathAbs(c.price - x.price);
         slRef = x.price;
        }
      else
        {
         d     = a.price - dir * g_adXA[p] * XA;
         slRef = a.price - dir * g_slXA[p] * XA;
        }
      if(dir * (b.price - d) <= 0.0)          // D must go beyond B
         continue;
      double CD = MathAbs(c.price - d);
      if(!InRatio(CD / BC, g_cdMin[p], g_cdMax[p]))
         continue;

      double sl = (InpSLMode == HN_SL_ATR) ? d - dir * InpSLATR * g_atr
                                           : slRef - dir * InpSLBufferATR * g_atr;
      if(dir * (d - sl) <= 0.0)
         continue;
      if(CD >= best)
         continue;

      //--- targets are computed from the rounded (displayed) entry and stop
      double en   = NormalizeDouble(d, _Digits);
      double sn   = NormalizeDouble(sl, _Digits);
      double risk = MathAbs(en - sn);
      if(risk < _Point * 0.5)
         continue;

      best  = CD;
      found = true;
      double top  = (dir > 0) ? MathMax(a.price, c.price) : MathMin(a.price, c.price);
      double leg  = MathAbs(top - en);
      double m1, m2, m3, unit;
      if(InpTPMode == HN_TP_RR)
        {
         m1 = InpR1;
         m2 = InpR2;
         m3 = InpR3;
         unit = risk;
        }
      else
        {
         m1 = InpF1;
         m2 = InpF2;
         m3 = InpF3;
         unit = leg;
        }

      out.dir   = dir;
      out.pat   = p;
      out.X     = x.price;
      out.A     = a.price;
      out.B     = b.price;
      out.C     = c.price;
      out.tX    = x.time;
      out.tA    = a.time;
      out.tB    = b.time;
      out.tC    = c.time;
      out.entry = en;
      out.sl    = sn;
      out.t1    = NormalizeDouble(en + dir * m1 * unit, _Digits);
      out.t2    = NormalizeDouble(en + dir * m2 * unit, _Digits);
      out.t3    = NormalizeDouble(en + dir * m3 * unit, _Digits);
     }
   return found;
  }

//+------------------------------------------------------------------+
//| Helpers                                                           |
//+------------------------------------------------------------------+
string SideName(const int dir)
  {
   return (dir > 0) ? "BUY" : "SELL";
  }

string TfName()
  {
   string s = EnumToString((ENUM_TIMEFRAMES)_Period);
   return StringSubstr(s, 7);
  }

string Pct(const int a, const int b)
  {
   if(b <= 0)
      return "    -";
   return StringFormat("%5.1f%%", 100.0 * a / b);
  }

void Notify(const string msg)
  {
   if(!g_live)
      return;
   string full = "HarmonicNavi " + _Symbol + " " + TfName() + ": " + msg;
   if(InpAlertPopup)
      Alert(full);
   if(InpAlertPush)
      SendNotification(full);
  }

string TradePrefix(const int id)
  {
   return g_prefix + "T" + IntegerToString(id) + "_";
  }

//+------------------------------------------------------------------+
//| Object helpers (create once, then update)                         |
//+------------------------------------------------------------------+
void TrendObj(const string name, const datetime t1, const double p1, const datetime t2, const double p2,
              const color clr, const ENUM_LINE_STYLE style, const int width)
  {
   if(ObjectFind(0, name) < 0)
     {
      if(!ObjectCreate(0, name, OBJ_TREND, 0, t1, p1, t2, p2))
         return;
      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, name, OBJPROP_RAY_LEFT, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
     }
   else
     {
      ObjectMove(0, name, 0, t1, p1);
      ObjectMove(0, name, 1, t2, p2);
     }
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
  }

void TextObj(const string name, const datetime t, const double p, const string text,
             const color clr, const int size, const ENUM_ANCHOR_POINT anchor)
  {
   if(ObjectFind(0, name) < 0)
     {
      if(!ObjectCreate(0, name, OBJ_TEXT, 0, t, p))
         return;
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }
   else
      ObjectMove(0, name, 0, t, p);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, anchor);
  }

void ArrowObj(const string name, const ENUM_OBJECT type, const datetime t, const double p,
              const color clr, const int code, const ENUM_ARROW_ANCHOR anchor)
  {
   if(ObjectFind(0, name) < 0)
     {
      if(!ObjectCreate(0, name, type, 0, t, p))
         return;
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }
   else
      ObjectMove(0, name, 0, t, p);
   if(code >= 0)
      ObjectSetInteger(0, name, OBJPROP_ARROWCODE, code);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, anchor);
  }

void RectObj(const string name, const ENUM_BASE_CORNER corner, const int x, const int y,
             const int w, const int h, const color bg, const color border)
  {
   if(ObjectFind(0, name) < 0)
     {
      if(!ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0))
         return;
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
     }
   ObjectSetInteger(0, name, OBJPROP_CORNER, corner);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, name, OBJPROP_COLOR, border);
  }

void LabelObj(const string name, const ENUM_BASE_CORNER corner, const int x, const int y,
              const string text, const color clr, const int size)
  {
   if(ObjectFind(0, name) < 0)
     {
      if(!ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0))
         return;
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }
   ObjectSetInteger(0, name, OBJPROP_CORNER, corner);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
  }

//--- anchor of a pattern point label: lows below, highs above
ENUM_ANCHOR_POINT PointAnchor(const bool isHigh)
  {
   return isHigh ? ANCHOR_LOWER : ANCHOR_UPPER;
  }

//+------------------------------------------------------------------+
//| Drawing                                                           |
//+------------------------------------------------------------------+
void RefreshDrawings(const datetime tNow)
  {
   datetime tFut = (datetime)((long)tNow + (long)InpProjectBars * PeriodSeconds());

   int n     = ArraySize(g_tr);
   int first = MathMax(0, n - MathMax(InpMaxDrawnTrades, 0));
   for(int k = g_firstDrawn; k < first; k++)
      ObjectsDeleteAll(0, TradePrefix(g_tr[k].id));
   if(first > g_firstDrawn)
      g_firstDrawn = first;

   for(int k = first; k < n; k++)
     {
      if(g_tr[k].finalDrawn)
         continue;
      DrawTrade(g_tr[k], tNow, tFut);
      if(g_tr[k].result != HN_OPEN)
         g_tr[k].finalDrawn = true;
     }

   for(int s = 0; s < 2; s++)
     {
      string pf = g_prefix + "P" + IntegerToString(s) + "_";
      if(g_pend[s].active && InpShowPending)
         DrawPending(g_pend[s], pf, tNow, tFut);
      else
         ObjectsDeleteAll(0, pf);
     }

//--- the panel is rebuilt last so it stays on top of the chart objects
   ObjectsDeleteAll(0, g_prefix + "S_");
   if(InpShowStats)
      DrawStats();

   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
void DrawTrade(const HNTrade &t, const datetime tNow, const datetime tFut)
  {
   string   pf     = TradePrefix(t.id);
   bool     isOpen = (t.result == HN_OPEN);
   int      ps     = PeriodSeconds();
   datetime tEnd   = isOpen ? tFut : t.tEnd;
   datetime tMin   = (datetime)((long)t.tEntry + (long)2 * ps);
   if(tEnd < tMin)
      tEnd = tMin;
   color dc   = (t.dir > 0) ? InpBuyColor : InpSellColor;
   bool  bull = (t.dir > 0);

//--- pattern legs
   if(InpShowPattern)
     {
      TrendObj(pf + "XA", t.tX, t.X, t.tA, t.A, InpPatternColor, STYLE_DOT, 1);
      TrendObj(pf + "AB", t.tA, t.A, t.tB, t.B, InpPatternColor, STYLE_DOT, 1);
      TrendObj(pf + "BC", t.tB, t.B, t.tC, t.C, InpPatternColor, STYLE_DOT, 1);
      TrendObj(pf + "CD", t.tC, t.C, t.tEntry, t.entry, InpPatternColor, STYLE_DOT, 1);
      TextObj(pf + "pX", t.tX, t.X, "X", InpPatternColor, InpFontSize, PointAnchor(!bull));
      TextObj(pf + "pA", t.tA, t.A, "A", InpPatternColor, InpFontSize, PointAnchor(bull));
      TextObj(pf + "pB", t.tB, t.B, "B", InpPatternColor, InpFontSize, PointAnchor(!bull));
      TextObj(pf + "pC", t.tC, t.C, "C", InpPatternColor, InpFontSize, PointAnchor(bull));
     }

//--- signal label
   string txt = SideName(t.dir) + " " + DoubleToString(t.entry, _Digits) + "  " + g_patName[t.pat];
   TextObj(pf + "lbl", t.tEntry, t.entry, txt, dc, InpFontSize + 1,
           bull ? ANCHOR_RIGHT_UPPER : ANCHOR_RIGHT_LOWER);

//--- level lines
   TrendObj(pf + "en", t.tEntry, t.entry,  tEnd, t.entry,  InpEntryColor,  STYLE_DOT,   1);
   TrendObj(pf + "sl", t.tEntry, t.slInit, tEnd, t.slInit, InpSLColor,     STYLE_SOLID, 2);
   TrendObj(pf + "t1", t.tEntry, t.t1,     tEnd, t.t1,     InpTargetColor, STYLE_SOLID, 1);
   TrendObj(pf + "t2", t.tEntry, t.t2,     tEnd, t.t2,     InpTargetColor, STYLE_SOLID, 1);
   TrendObj(pf + "t3", t.tEntry, t.t3,     tEnd, t.t3,     InpTargetColor, STYLE_SOLID, 1);
   TextObj(pf + "lsl", tEnd, t.slInit, " SL " + DoubleToString(t.slInit, _Digits), InpSLColor,     InpFontSize, ANCHOR_LEFT);
   TextObj(pf + "lt1", tEnd, t.t1,     " T1 " + DoubleToString(t.t1, _Digits),     InpTargetColor, InpFontSize, ANCHOR_LEFT);
   TextObj(pf + "lt2", tEnd, t.t2,     " T2 " + DoubleToString(t.t2, _Digits),     InpTargetColor, InpFontSize, ANCHOR_LEFT);
   TextObj(pf + "lt3", tEnd, t.t3,     " T3 " + DoubleToString(t.t3, _Digits),     InpTargetColor, InpFontSize, ANCHOR_LEFT);

//--- route arrow Entry -> T1 (dashed towards the current bar until T1 is reached, then solid)
   if(InpShowNavArrow && (isOpen || t.stage >= 1))
     {
      datetime ta = (t.stage >= 1) ? t.tHit1 : tNow;
      if(ta <= t.tEntry)
         ta = (datetime)((long)t.tEntry + (long)ps);
      TrendObj(pf + "nav", t.tEntry, t.entry, ta, t.t1, dc,
               (t.stage >= 1) ? STYLE_SOLID : STYLE_DASH, (t.stage >= 1) ? 2 : 1);
      ArrowObj(pf + "nvh", OBJ_ARROW, ta, t.t1, dc, bull ? 233 : 234, bull ? ANCHOR_BOTTOM : ANCHOR_TOP);
     }
   else
     {
      ObjectDelete(0, pf + "nav");
      ObjectDelete(0, pf + "nvh");
     }

//--- hit markers
   if(t.stage >= 1)
      ArrowObj(pf + "h1", OBJ_ARROW_CHECK, t.tHit1, t.t1, InpTargetColor, -1, bull ? ANCHOR_TOP : ANCHOR_BOTTOM);
   if(t.stage >= 2)
      ArrowObj(pf + "h2", OBJ_ARROW_CHECK, t.tHit2, t.t2, InpTargetColor, -1, bull ? ANCHOR_TOP : ANCHOR_BOTTOM);
   if(t.stage >= 3)
      ArrowObj(pf + "h3", OBJ_ARROW_CHECK, t.tHit3, t.t3, InpTargetColor, -1, bull ? ANCHOR_TOP : ANCHOR_BOTTOM);
   if(t.result == HN_RES_SL)
      ArrowObj(pf + "hs", OBJ_ARROW_STOP, t.tEnd, t.sl, InpSLColor, -1, bull ? ANCHOR_TOP : ANCHOR_BOTTOM);
   if(t.result == HN_RES_TIMEOUT)
      TextObj(pf + "to", t.tEnd, t.entry, "timeout", InpEntryColor, InpFontSize, ANCHOR_LEFT);
  }

//+------------------------------------------------------------------+
//| Pending setup = the "advance notice" before price reaches D       |
//+------------------------------------------------------------------+
void DrawPending(const HNSetup &p, const string pf, const datetime tNow, const datetime tFut)
  {
   color dc   = (p.dir > 0) ? InpBuyColor : InpSellColor;
   bool  bull = (p.dir > 0);

   if(InpShowPattern)
     {
      TrendObj(pf + "XA", p.tX, p.X, p.tA, p.A, InpPatternColor, STYLE_DOT, 1);
      TrendObj(pf + "AB", p.tA, p.A, p.tB, p.B, InpPatternColor, STYLE_DOT, 1);
      TrendObj(pf + "BC", p.tB, p.B, p.tC, p.C, InpPatternColor, STYLE_DOT, 1);
      TextObj(pf + "pX", p.tX, p.X, "X", InpPatternColor, InpFontSize, PointAnchor(!bull));
      TextObj(pf + "pA", p.tA, p.A, "A", InpPatternColor, InpFontSize, PointAnchor(bull));
      TextObj(pf + "pB", p.tB, p.B, "B", InpPatternColor, InpFontSize, PointAnchor(!bull));
      TextObj(pf + "pC", p.tC, p.C, "C", InpPatternColor, InpFontSize, PointAnchor(bull));
     }
//--- projected C -> D path
   TrendObj(pf + "CD", p.tC, p.C, tNow, p.entry, dc, STYLE_DASH, 1);

   TrendObj(pf + "en", tNow, p.entry, tFut, p.entry, dc,             STYLE_DASH, 1);
   TrendObj(pf + "sl", tNow, p.sl,    tFut, p.sl,    InpSLColor,     STYLE_DASH, 1);
   TrendObj(pf + "t1", tNow, p.t1,    tFut, p.t1,    InpTargetColor, STYLE_DASH, 1);
   TrendObj(pf + "t2", tNow, p.t2,    tFut, p.t2,    InpTargetColor, STYLE_DASH, 1);
   TrendObj(pf + "t3", tNow, p.t3,    tFut, p.t3,    InpTargetColor, STYLE_DASH, 1);

   string side = bull ? " BUY LIMIT " : " SELL LIMIT ";
   TextObj(pf + "len", tFut, p.entry, side + DoubleToString(p.entry, _Digits) + "  " + g_patName[p.pat] + " (waiting)",
           dc, InpFontSize, ANCHOR_LEFT);
   TextObj(pf + "lsl", tFut, p.sl, " SL " + DoubleToString(p.sl, _Digits), InpSLColor,     InpFontSize, ANCHOR_LEFT);
   TextObj(pf + "lt1", tFut, p.t1, " T1 " + DoubleToString(p.t1, _Digits), InpTargetColor, InpFontSize, ANCHOR_LEFT);
   TextObj(pf + "lt2", tFut, p.t2, " T2 " + DoubleToString(p.t2, _Digits), InpTargetColor, InpFontSize, ANCHOR_LEFT);
   TextObj(pf + "lt3", tFut, p.t3, " T3 " + DoubleToString(p.t3, _Digits), InpTargetColor, InpFontSize, ANCHOR_LEFT);
  }

//+------------------------------------------------------------------+
//| Statistics panel                                                  |
//+------------------------------------------------------------------+
void DrawStats()
  {
   int openCnt = 0;
   int n = ArraySize(g_tr);
   for(int k = g_firstOpen; k < n; k++)
      if(g_tr[k].result == HN_OPEN)
         openCnt++;

   string lines[12];
   lines[0]  = "HarmonicNavi  " + _Symbol + " " + TfName();
   lines[1]  = StringFormat("%-15s%6d", "Signals", g_signals);
   lines[2]  = StringFormat("%-15s%6d", "Resolved", g_resolved);
   lines[3]  = StringFormat("%-15s%6d  %s", "Target 1 hit", g_hit1, Pct(g_hit1, g_resolved));
   lines[4]  = StringFormat("%-15s%6d  %s of T1", "Target 2 hit", g_hit2, Pct(g_hit2, g_hit1));
   lines[5]  = StringFormat("%-15s%6d  %s of T2", "Target 3 hit", g_hit3, Pct(g_hit3, g_hit2));
   lines[6]  = StringFormat("%-15s%6d  %s", "SL before T1", g_slNoT1, Pct(g_slNoT1, g_resolved));
   lines[7]  = StringFormat("%-15s%6d", "SL after T1", g_slAfterT1);
   lines[8]  = StringFormat("%-15s%6d", "Timed out", g_timeouts);
   lines[9]  = StringFormat("%-15s%6d   skipped(late) %d", "Open", openCnt, g_late);
   lines[10] = g_pend[0].active ? StringFormat("Waiting BUY  %s @ %s", g_patName[g_pend[0].pat], DoubleToString(g_pend[0].entry, _Digits))
                                : "Waiting BUY  -";
   lines[11] = g_pend[1].active ? StringFormat("Waiting SELL %s @ %s", g_patName[g_pend[1].pat], DoubleToString(g_pend[1].entry, _Digits))
                                : "Waiting SELL -";

   int nl = ArraySize(lines);
   int maxLen = 0;
   for(int k = 0; k < nl; k++)
      maxLen = MathMax(maxLen, StringLen(lines[k]));

   int dpi = (int)TerminalInfoInteger(TERMINAL_SCREEN_DPI);
   if(dpi <= 0)
      dpi = 96;
   double px    = InpFontSize * dpi / 72.0;
   int    lineH = (int)MathRound(px * 1.6);
   int    charW = (int)MathCeil(px * 0.6);
   int    pad   = (int)MathRound(px * 0.8);
   int    w     = maxLen * charW + 2 * pad;
   int    h     = nl * lineH + 2 * pad;
   int    margin = 10;

   bool right = (InpStatsCorner == CORNER_RIGHT_UPPER || InpStatsCorner == CORNER_RIGHT_LOWER);
   bool lower = (InpStatsCorner == CORNER_LEFT_LOWER  || InpStatsCorner == CORNER_RIGHT_LOWER);
//--- every object is anchored at its upper-left point; distances are measured from the chosen corner
   int rx = right ? margin + w : margin;
   int ry = lower ? margin + h : margin;
   RectObj(g_prefix + "S_bg", InpStatsCorner, rx, ry, w, h, C'18,18,24', C'70,70,80');

   for(int k = 0; k < nl; k++)
     {
      int lx = right ? rx - pad : rx + pad;
      int ly = lower ? ry - pad - k * lineH : ry + pad + k * lineH;
      color c = (k == 0) ? clrWhite : ((k >= 3 && k <= 5) ? InpTargetColor : ((k == 6 || k == 7) ? InpSLColor : clrSilver));
      LabelObj(g_prefix + "S_L" + IntegerToString(k), InpStatsCorner, lx, ly, lines[k], c, InpFontSize);
     }
  }
//+------------------------------------------------------------------+
