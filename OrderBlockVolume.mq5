//+------------------------------------------------------------------+
//|                                          OrderBlockVolume.mq5    |
//|         Volumized Order Blocks — MQL5 port of Pine Script        |
//|         Original Pine Script © fluxchart (Mozilla PL 2.0)       |
//+------------------------------------------------------------------+
#property copyright "Based on Pine Script by fluxchart"
#property link      "https://mozilla.org/MPL/2.0/"
#property version   "1.00"
#property indicator_chart_window
#property indicator_plots 0

//--- Input parameters
input bool   InpShowHistoric     = true;           // Show Historic Zones
input bool   InpVolumetricInfo   = true;           // Volumetric Info
input string InpZoneInvalidation = "Wick";         // Zone Invalidation: Wick or Close
input int    InpSwingLength      = 10;             // Swing Length (min 3)
input string InpZoneCount        = "Low";          // Zone Count: One / Low / Medium / High
input color  InpBullColor        = C'8,153,129';   // Bullish color  (teal)
input color  InpBearColor        = C'242,54,70';   // Bearish color  (red)
input color  InpTextColor        = clrWhite;       // Text color
input int    InpExtendBars       = 15;             // Extend zones by (bars)
input double InpMaxATRMult       = 3.5;            // Max ATR multiplier

//--- Constants
#define MAX_OBS              30
#define OBV_PFX              "OBV_"
// Matches Pine Script's maxDistanceToLastBar = 1750 which limits the look-back
// window to keep runtime reasonable on large histories.
#define MAX_LOOKBACK_BARS    1750
// ATR period used for the candle-size filter (same value Pine Script hardcodes)
#define ATR_FILTER_PERIOD    10

//--- Order Block data record
struct SOBInfo
{
   double   top;
   double   bottom;
   double   obVolume;
   string   obType;        // "Bull" or "Bear"
   datetime startTime;
   double   bbVolume;
   double   obLowVolume;   // sell-side volume
   double   obHighVolume;  // buy-side volume
   bool     breaker;
   datetime breakTime;
   bool     disabled;
};

//--- Global state
SOBInfo  g_bullOBs[];
SOBInfo  g_bearOBs[];
int      g_bullCount = 0;
int      g_bearCount = 0;
int      g_maxBull   = 3;
int      g_maxBear   = 3;

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpSwingLength < 3)
   {
      Print("ERROR: SwingLength must be >= 3");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpZoneCount == "One")          { g_maxBull = 1;  g_maxBear = 1;  }
   else if(InpZoneCount == "Low")     { g_maxBull = 3;  g_maxBear = 3;  }
   else if(InpZoneCount == "Medium")  { g_maxBull = 5;  g_maxBear = 5;  }
   else                               { g_maxBull = 10; g_maxBear = 10; }

   ArrayResize(g_bullOBs, MAX_OBS);
   ArrayResize(g_bearOBs, MAX_OBS);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   DeleteAllOBVObjects();
}

//+------------------------------------------------------------------+
//| Remove every chart object whose name starts with OBV_PFX         |
//+------------------------------------------------------------------+
void DeleteAllOBVObjects()
{
   int total = ObjectsTotal(0, 0, -1);
   for(int i = total - 1; i >= 0; i--)
   {
      string nm = ObjectName(0, i, 0, -1);
      if(StringFind(nm, OBV_PFX) == 0)
         ObjectDelete(0, nm);
   }
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Insert newItem at index 0, shifting everything right             |
//+------------------------------------------------------------------+
void UnshiftOB(SOBInfo &arr[], int &count, const SOBInfo &newItem)
{
   if(count >= MAX_OBS) count = MAX_OBS - 1;
   for(int k = count; k > 0; k--)
      arr[k] = arr[k - 1];
   arr[0] = newItem;
   count++;
   if(count > MAX_OBS) count = MAX_OBS;
}

//+------------------------------------------------------------------+
//| ATR(period) at bar position `bar` in an AS_SERIES array          |
//+------------------------------------------------------------------+
double CalcATR(const double &high[], const double &low[],
               const double &close[], int bar, int period, int total)
{
   if(bar + period >= total) return 0.0;
   double sum = 0.0;
   for(int i = bar; i < bar + period; i++)
   {
      double tr = high[i] - low[i];
      if(i + 1 < total)
      {
         double hc = MathAbs(high[i] - close[i + 1]);
         double lc = MathAbs(low[i]  - close[i + 1]);
         tr = MathMax(tr, MathMax(hc, lc));
      }
      sum += tr;
   }
   return sum / period;
}

//+------------------------------------------------------------------+
//| Format a tick-volume value as "1.234K" / "1.234M" / "1234"       |
//+------------------------------------------------------------------+
string FormatVolume(double vol)
{
   if(vol >= 1000000.0) return StringFormat("%.3fM", vol / 1000000.0);
   if(vol >= 1000.0)    return StringFormat("%.3fK", vol / 1000.0);
   return StringFormat("%.0f", vol);
}

//+------------------------------------------------------------------+
//| Human-readable timeframe label matching Pine Script output       |
//+------------------------------------------------------------------+
string FormatTFStr()
{
   int sec = PeriodSeconds();
   if(sec >= 86400)
   {
      int d = sec / 86400;
      return IntegerToString(d) + " Day" + (d > 1 ? "s" : "");
   }
   if(sec >= 3600)
   {
      int h = sec / 3600;
      return IntegerToString(h) + " Hour" + (h > 1 ? "s" : "");
   }
   int m = sec / 60;
   return IntegerToString(m) + " Min";
}

//+------------------------------------------------------------------+
//| Create (or recreate) a filled rectangle                          |
//+------------------------------------------------------------------+
bool CreateFilledRect(const string name,
                      datetime t1, double p1,
                      datetime t2, double p2,
                      color clr, bool back)
{
   if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
   if(!ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, p1, t2, p2))
   {
      Print("CreateFilledRect failed: ", name, "  err=", GetLastError());
      return false;
   }
   ObjectSetInteger(0, name, OBJPROP_COLOR,      clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE,      STYLE_SOLID);
   ObjectSetInteger(0, name, OBJPROP_WIDTH,      1);
   ObjectSetInteger(0, name, OBJPROP_FILL,       true);
   ObjectSetInteger(0, name, OBJPROP_BACK,       back);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTED,   false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
   return true;
}

//+------------------------------------------------------------------+
//| Create (or recreate) a text label                                |
//+------------------------------------------------------------------+
bool CreateTextObj(const string name,
                   datetime t, double p,
                   const string txt, color clr,
                   ENUM_ANCHOR_POINT anchor = ANCHOR_CENTER)
{
   if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
   if(!ObjectCreate(0, name, OBJ_TEXT, 0, t, p))
   {
      Print("CreateTextObj failed: ", name, "  err=", GetLastError());
      return false;
   }
   ObjectSetString(0,  name, OBJPROP_TEXT,      txt);
   ObjectSetInteger(0, name, OBJPROP_COLOR,     clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,  8);
   ObjectSetString(0,  name, OBJPROP_FONT,      "Arial");
   ObjectSetInteger(0, name, OBJPROP_ANCHOR,    anchor);
   ObjectSetInteger(0, name, OBJPROP_BACK,      false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN,    true);
   return true;
}

//+------------------------------------------------------------------+
//| Create (or recreate) a two-point trend line (no ray extension)   |
//+------------------------------------------------------------------+
bool CreateLineObj(const string name,
                   datetime t1, double p1,
                   datetime t2, double p2,
                   color clr,
                   ENUM_LINE_STYLE style = STYLE_SOLID)
{
   if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
   if(!ObjectCreate(0, name, OBJ_TREND, 0, t1, p1, t2, p2))
   {
      Print("CreateLineObj failed: ", name, "  err=", GetLastError());
      return false;
   }
   ObjectSetInteger(0, name, OBJPROP_COLOR,      clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE,      style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH,      1);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT,  false);
   ObjectSetInteger(0, name, OBJPROP_RAY_LEFT,   false);
   ObjectSetInteger(0, name, OBJPROP_BACK,       false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
   return true;
}

//+------------------------------------------------------------------+
//| Render one Order Block                                           |
//|                                                                  |
//| Visual layout (volume bars on the LEFT — mirrors Pine default):  |
//|  |<------ zoneSize ------->|                                     |
//|  |<- volW ->|<-- textW --->|                                     |
//|  [ bull bar|               ]   ← top                            |
//|  [---------| centered text ]   ← mid (horiz sep inside vol box) |
//|  [ bear bar|               ]   ← bottom                         |
//|  (vert sep at volEndT between vol box and text zone)             |
//+------------------------------------------------------------------+
void RenderOB(const SOBInfo &ob, const string pfx, int idx)
{
   bool  isBull  = (ob.obType == "Bull");
   color mainClr = isBull ? InpBullColor : InpBearColor;

   // ── time range ──────────────────────────────────────────────────
   datetime startT = ob.startTime;
   datetime endT;
   if(ob.breaker && ob.breakTime > 0)
      endT = ob.breakTime;
   else
      endT = (datetime)(TimeCurrent() + (long)PeriodSeconds() * InpExtendBars);

   if(endT <= startT)
      endT = (datetime)(startT + (long)PeriodSeconds() * InpExtendBars);

   long     zoneW   = (long)(endT - startT);
   long     volW    = zoneW / 3;                          // vol box = left 1/3
   datetime volEndT = (datetime)(startT + volW);

   double top = ob.top;
   double bot = ob.bottom;
   double mid = (top + bot) * 0.5;

   string base = pfx + IntegerToString(idx);

   // 1. Main background rectangle covering the entire zone
   CreateFilledRect(base + "_bg", startT, top, endT, bot, mainClr, false);

   // 2. Proportional vol bars inside the vol box (left 1/3)
   double totVol  = ob.obVolume;
   double highVol = (totVol > 0.0) ? ob.obHighVolume : 0.0;
   double lowVol  = (totVol > 0.0) ? ob.obLowVolume  : 0.0;

   // Prevent division by zero
   double highFrac = (totVol > 0.0) ? MathMin(highVol / totVol, 1.0) : 0.5;
   double lowFrac  = (totVol > 0.0) ? MathMin(lowVol  / totVol, 1.0) : 0.5;

   datetime bullBarEnd = (datetime)(startT + (long)(volW * highFrac));
   datetime bearBarEnd = (datetime)(startT + (long)(volW * lowFrac));

   // Clamp so bars never exceed the vol box boundary
   if(bullBarEnd > volEndT) bullBarEnd = volEndT;
   if(bearBarEnd > volEndT) bearBarEnd = volEndT;

   // Bull bar: top half of vol box
   CreateFilledRect(base + "_vbull", startT, top, bullBarEnd, mid, InpBullColor, false);
   // Bear bar: bottom half of vol box
   CreateFilledRect(base + "_vbear", startT, mid, bearBarEnd, bot, InpBearColor, false);

   // 3. Horizontal dashed separator at mid-price within the vol box
   if(volW > 0)
      CreateLineObj(base + "_hsep", startT, mid, volEndT, mid, InpTextColor, STYLE_DASH);

   // 4. Vertical solid separator between vol box and text zone
   if(top != bot)
      CreateLineObj(base + "_vsep", volEndT, top, volEndT, bot, InpTextColor, STYLE_SOLID);

   // 5. Text inside the text zone (right 2/3)
   //    Two labels simulate the two-line display Pine Script uses.
   datetime textT  = (datetime)(volEndT + (long)((endT - volEndT) / 2));
   double   height = top - bot;

   int pct = 0;
   if(ob.obHighVolume > 0.0 && ob.obLowVolume > 0.0)
   {
      double minV = MathMin(ob.obHighVolume, ob.obLowVolume);
      double maxV = MathMax(ob.obHighVolume, ob.obLowVolume);
      if(maxV > 0.0) pct = (int)MathRound((minV / maxV) * 100.0);
   }

   string tfLabel = FormatTFStr() + " OB";

   if(InpVolumetricInfo)
   {
      string volLine = FormatVolume(ob.obVolume) + " (" + IntegerToString(pct) + "%)";
      // Line 1: volume info (slightly above centre)
      CreateTextObj(base + "_txt1", textT, mid + height * 0.15, volLine, InpTextColor);
      // Line 2: timeframe label (slightly below centre)
      CreateTextObj(base + "_txt2", textT, mid - height * 0.15, tfLabel, InpTextColor);
   }
   else
   {
      CreateTextObj(base + "_txt1", textT, mid, tfLabel, InpTextColor);
   }
}

//+------------------------------------------------------------------+
//| Render every active Order Block                                  |
//+------------------------------------------------------------------+
void RenderAllOBs()
{
   int nBull = MathMin(g_bullCount, g_maxBull);
   int nBear = MathMin(g_bearCount, g_maxBear);

   for(int i = 0; i < nBull; i++)
      if(!g_bullOBs[i].disabled)
         RenderOB(g_bullOBs[i], OBV_PFX "Bull_", i);

   for(int i = 0; i < nBear; i++)
      if(!g_bearOBs[i].disabled)
         RenderOB(g_bearOBs[i], OBV_PFX "Bear_", i);

   Print("BullCount=", g_bullCount, "  BearCount=", g_bearCount,
         "  rendered Bull=", nBull, "  Bear=", nBear);
}

//+------------------------------------------------------------------+
//| Mark OBs as breakers when price invalidates them                 |
//+------------------------------------------------------------------+
void CheckInvalidations(const double   &high[],
                        const double   &low[],
                        const double   &open[],
                        const double   &close[],
                        const datetime &time[],
                        const long     &tvol[],
                        int             total)
{
   // Bull OBs: breaker when price drops BELOW the OB bottom
   for(int i = 0; i < g_bullCount; i++)
   {
      if(g_bullOBs[i].breaker) continue;
      for(int b = 0; b < total; b++)
      {
         if(time[b] <= g_bullOBs[i].startTime) break;
         double chk = (InpZoneInvalidation == "Wick")
                      ? low[b]
                      : MathMin(open[b], close[b]);
         if(chk < g_bullOBs[i].bottom)
         {
            g_bullOBs[i].breaker   = true;
            g_bullOBs[i].breakTime = time[b];
            g_bullOBs[i].bbVolume  = (double)tvol[b];
            break;
         }
      }
   }

   // Bear OBs: breaker when price rises ABOVE the OB top
   for(int i = 0; i < g_bearCount; i++)
   {
      if(g_bearOBs[i].breaker) continue;
      for(int b = 0; b < total; b++)
      {
         if(time[b] <= g_bearOBs[i].startTime) break;
         double chk = (InpZoneInvalidation == "Wick")
                      ? high[b]
                      : MathMax(open[b], close[b]);
         if(chk > g_bearOBs[i].top)
         {
            g_bearOBs[i].breaker   = true;
            g_bearOBs[i].breakTime = time[b];
            g_bearOBs[i].bbVolume  = (double)tvol[b];
            break;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Core detection — simulates Pine Script bar-by-bar execution      |
//|                                                                  |
//| Arrays are AS_SERIES=true: index 0 = current bar (newest),      |
//| higher index = older bar.                                        |
//|                                                                  |
//| We iterate k from maxLB (oldest) down to len (newest),          |
//| mirroring Pine Script's sequential per-bar execution.           |
//|                                                                  |
//| Pine Script swing logic (at each bar execution):                |
//|   upper = ta.highest(len)  ← max of high[0..len-1]             |
//|   lower = ta.lowest(len)   ← min of  low[0..len-1]             |
//|   swingType = high[len]>upper ? 0 : low[len]<lower ? 1 : prev  |
//|   On 1→0 transition: record swing high at bar_index[len]        |
//|   On 0→1 transition: record swing low  at bar_index[len]        |
//|                                                                  |
//| In AS_SERIES, at position k:                                    |
//|   upper = max(high[k..k+len-1])                                 |
//|   pivot  high = high[k+len]                                     |
//|   pivot  low  =  low[k+len]                                     |
//+------------------------------------------------------------------+
void DetectOrderBlocks(const datetime &time[],
                       const double   &open[],
                       const double   &high[],
                       const double   &low[],
                       const double   &close[],
                       const long     &tvol[],
                       int             total)
{
   int len   = InpSwingLength;
   int maxLB = MathMin(total - len - 1, MAX_LOOKBACK_BARS + len);

   // State variables — mirror Pine Script `var` declarations
   int      swingType  = 0;
   int      topBar     = -1;
   double   topY       = 0.0;
   bool     topCrossed = false;
   int      btmBar     = -1;
   double   btmY       = 0.0;
   bool     btmCrossed = false;

   // Scan from oldest bar (high AS_SERIES index) to newest (low index)
   for(int k = maxLB; k >= len; k--)
   {
      // Safety: pivot index must be within bounds
      if(k + len >= total) continue;

      // ── compute upper/lower for bars [k .. k+len-1] ──────────────
      double upper = high[k];
      double lower =  low[k];
      for(int j = 1; j < len; j++)
      {
         if(k + j >= total) break;
         if(high[k + j] > upper) upper = high[k + j];
         if( low[k + j] < lower) lower =  low[k + j];
      }

      // ── update swingType ─────────────────────────────────────────
      int prevSwingType = swingType;
      if     (high[k + len] > upper) swingType = 0;   // swing high at k+len
      else if( low[k + len] < lower) swingType = 1;   // swing low  at k+len
      // else: unchanged

      // ── record new swing reference on TRANSITION ─────────────────
      if(swingType == 0 && prevSwingType != 0)
      {
         topBar     = k + len;
         topY       = high[k + len];
         topCrossed = false;
      }
      if(swingType == 1 && prevSwingType != 1)
      {
         btmBar     = k + len;
         btmY       =  low[k + len];
         btmCrossed = false;
      }

      // ── check for BULLISH OB ──────────────────────────────────────
      // Condition: close[k] crosses above the last recorded swing high
      if(topBar >= 0 && !topCrossed && close[k] > topY)
      {
         topCrossed = true;

         // The OB candle is the bar with the LOWEST LOW between
         // bar k+1 and bar topBar-1  (Pine: for i=1 to bar_index-top.x-1)
         if(topBar > k + 1)
         {
            double   boxBtm = low [k + 1];
            double   boxTop = high[k + 1];
            datetime boxLoc = time[k + 1];

            for(int i = k + 2; i <= topBar - 1 && i < total; i++)
            {
               if(low[i] < boxBtm)
               {
                  boxBtm = low [i];
                  boxTop = high[i];
                  boxLoc = time[i];
               }
            }

            // ATR size filter
            double atrVal = CalcATR(high, low, close, k, ATR_FILTER_PERIOD, total);
            double obSize = boxTop - boxBtm;

            if(atrVal <= 0.0 || obSize <= atrVal * InpMaxATRMult)
            {
               // Duplicate guard: same startTime already registered?
               bool exists = false;
               for(int x = 0; x < g_bullCount; x++)
                  if(g_bullOBs[x].startTime == boxLoc) { exists = true; break; }

               if(!exists)
               {
                  // Volume: Pine Script uses volume[0]+volume[1]+volume[2]
                  // where [0]=crossing bar(k), [1]=k+1, [2]=k+2
                  double v0 = (k     < total) ? (double)tvol[k]     : 0.0;
                  double v1 = (k + 1 < total) ? (double)tvol[k + 1] : 0.0;
                  double v2 = (k + 2 < total) ? (double)tvol[k + 2] : 0.0;

                  SOBInfo nb;
                  nb.top         = boxTop;
                  nb.bottom      = boxBtm;
                  nb.obVolume    = v0 + v1 + v2;
                  nb.obType      = "Bull";
                  nb.startTime   = boxLoc;
                  nb.bbVolume    = 0.0;
                  nb.obLowVolume = v2;           // Pine: obLowVolume  = volume[2]
                  nb.obHighVolume= v0 + v1;      // Pine: obHighVolume = volume + volume[1]
                  nb.breaker     = false;
                  nb.breakTime   = 0;
                  nb.disabled    = false;

                  UnshiftOB(g_bullOBs, g_bullCount, nb);
               }
            }
         }
      }

      // ── check for BEARISH OB ──────────────────────────────────────
      // Condition: close[k] crosses below the last recorded swing low
      if(btmBar >= 0 && !btmCrossed && close[k] < btmY)
      {
         btmCrossed = true;

         if(btmBar > k + 1)
         {
            double   boxTop = high[k + 1];
            double   boxBtm =  low[k + 1];
            datetime boxLoc = time[k + 1];

            for(int i = k + 2; i <= btmBar - 1 && i < total; i++)
            {
               if(high[i] > boxTop)
               {
                  boxTop = high[i];
                  boxBtm =  low[i];
                  boxLoc = time[i];
               }
            }

            double atrVal = CalcATR(high, low, close, k, ATR_FILTER_PERIOD, total);
            double obSize = boxTop - boxBtm;

            if(atrVal <= 0.0 || obSize <= atrVal * InpMaxATRMult)
            {
               bool exists = false;
               for(int x = 0; x < g_bearCount; x++)
                  if(g_bearOBs[x].startTime == boxLoc) { exists = true; break; }

               if(!exists)
               {
                  double v0 = (k     < total) ? (double)tvol[k]     : 0.0;
                  double v1 = (k + 1 < total) ? (double)tvol[k + 1] : 0.0;
                  double v2 = (k + 2 < total) ? (double)tvol[k + 2] : 0.0;

                  SOBInfo nb;
                  nb.top         = boxTop;
                  nb.bottom      = boxBtm;
                  nb.obVolume    = v0 + v1 + v2;
                  nb.obType      = "Bear";
                  nb.startTime   = boxLoc;
                  nb.bbVolume    = 0.0;
                  nb.obLowVolume = v0 + v1;      // Pine: obLowVolume  = volume + volume[1]
                  nb.obHighVolume= v2;            // Pine: obHighVolume = volume[2]
                  nb.breaker     = false;
                  nb.breakTime   = 0;
                  nb.disabled    = false;

                  UnshiftOB(g_bearOBs, g_bearCount, nb);
               }
            }
         }
      }
   } // end main loop
}

//+------------------------------------------------------------------+
//| Remove all breaker (invalidated) OBs from an array in-place     |
//+------------------------------------------------------------------+
void RemoveBreakerOBs(SOBInfo &arr[], int &count)
{
   for(int i = count - 1; i >= 0; i--)
   {
      if(arr[i].breaker)
      {
         for(int j = i; j < count - 1; j++)
            arr[j] = arr[j + 1];
         count--;
      }
   }
}

//+------------------------------------------------------------------+
//| Indicator main function                                          |
//+------------------------------------------------------------------+
int OnCalculate(const int      rates_total,
                const int      prev_calculated,
                const datetime &time[],
                const double   &open[],
                const double   &high[],
                const double   &low[],
                const double   &close[],
                const long     &tick_volume[],
                const long     &volume[],
                const int      &spread[])
{
   if(rates_total < InpSwingLength * 2 + 10)
      return 0;

   // Force AS_SERIES on every array we use
   ArraySetAsSeries(time,        true);
   ArraySetAsSeries(open,        true);
   ArraySetAsSeries(high,        true);
   ArraySetAsSeries(low,         true);
   ArraySetAsSeries(close,       true);
   ArraySetAsSeries(tick_volume, true);
   ArraySetAsSeries(volume,      true);
   ArraySetAsSeries(spread,      true);

   // Full recalculation — triggered on first call or chart reload
   if(prev_calculated == 0)
   {
      DeleteAllOBVObjects();
      g_bullCount = 0;
      g_bearCount = 0;
      DetectOrderBlocks(time, open, high, low, close, tick_volume, rates_total);
   }
   else if(rates_total != prev_calculated)
   {
      // New bar confirmed — redo detection from scratch to stay consistent
      DeleteAllOBVObjects();
      g_bullCount = 0;
      g_bearCount = 0;
      DetectOrderBlocks(time, open, high, low, close, tick_volume, rates_total);
   }

   // Mark invalidated (breaker) OBs
   CheckInvalidations(high, low, open, close, time, tick_volume, rates_total);

   // Optionally hide historic (invalidated) zones
   if(!InpShowHistoric)
   {
      RemoveBreakerOBs(g_bullOBs, g_bullCount);
      RemoveBreakerOBs(g_bearOBs, g_bearCount);
   }

   // Draw all order blocks
   RenderAllOBs();
   ChartRedraw(0);

   return rates_total;
}
//+------------------------------------------------------------------+
