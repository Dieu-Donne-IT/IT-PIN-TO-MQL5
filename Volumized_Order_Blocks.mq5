//+------------------------------------------------------------------+
//|  Volumized Order Blocks | Flux Charts  (MQL5 Port)              |
//|  Original Pine Script © fluxchart                               |
//|  https://mozilla.org/MPL/2.0/                                   |
//+------------------------------------------------------------------+
#property copyright   "© fluxchart"
#property link        "https://mozilla.org/MPL/2.0/"
#property version     "1.00"
#property description "Volumized Order Blocks – ported from Pine Script v5 by fluxchart"
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

//--------------------------------------------------------------------
//  Constants  (mirror Pine Script consts)
//--------------------------------------------------------------------
#define MAX_BOXES_COUNT       500
#define OVERLAP_THRESHOLD_PCT 0.0
#define MAX_DIST_LAST_BAR     1750
#define MAX_ORDER_BLOCKS      30
#define MAX_ATR_MULT          3.5

//--------------------------------------------------------------------
//  Inputs  – General Configuration
//--------------------------------------------------------------------
input bool   InpShowInvalidated          = true;          // Show Historic Zones
input bool   InpOrderBlockVolumetricInfo = true;          // Volumetric Info
input string InpOBEndMethod              = "Wick";        // Zone Invalidation  (Wick / Close)
input int    InpSwingLength              = 10;            // Swing Length  (min 3)
input string InpZoneCount               = "Low";         // Zone Count  (High / Medium / Low / One)
input color  InpBullOrderBlockColor      = C'8,153,129';  // Bullish  (#089981)
input color  InpBearOrderBlockColor      = C'242,54,70';  // Bearish  (#f23646)

//--------------------------------------------------------------------
//  Inputs  – Style
//--------------------------------------------------------------------
input color  InpTextColor                = C'255,255,255'; // Text Color
input int    InpExtendZonesBy            = 15;             // Extend Zones  (1-30)
input bool   InpExtendZonesDynamic       = true;           // Dynamic Zones
input bool   InpMirrorVolumeBars         = true;           // Mirror Volume Bars
input bool   InpVolumeBarsLeft           = true;           // Volume Bars on Left Side

//--------------------------------------------------------------------
//  Data structures
//--------------------------------------------------------------------

// Equivalent of Pine "type orderBlockInfo"
struct OrderBlockInfo
{
   double   top;
   double   bottom;
   double   obVolume;
   string   obType;                // "Bull" | "Bear"
   datetime startTime;
   double   bbVolume;
   double   obLowVolume;
   double   obHighVolume;
   bool     breaker;
   datetime breakTime;             // 0  ≡  na  (zone not yet broken)
   string   timeframeStr;          // period in seconds, as a string
   bool     disabled;              // default false
   string   combinedTimeframesStr; // default "" ≡ na
   bool     combined;              // default false
};

// Equivalent of Pine "type obSwing"
struct OBSwing
{
   int    barIdx;       // absolute bar index in OnCalculate arrays (0 = oldest)
   double price;
   double swingVolume;
   bool   crossed;
};

// Equivalent of Pine "type orderBlock"  – stores visual object names instead of handles
struct OrderBlock
{
   OrderBlockInfo info;
   bool           isRendered;
   // Chart-object names (empty string ≡ na)
   string         orderBoxName;
   string         orderBoxTextName;
   string         orderBoxPositiveName;
   string         orderBoxNegativeName;
   string         orderSeparatorName;
   string         orderTextSeparatorName;
};

//--------------------------------------------------------------------
//  Global state  (equivalent of Pine "var" declarations)
//--------------------------------------------------------------------
int        g_bullishOBMax  = 3;
int        g_bearishOBMax  = 3;
long       g_objCounter    = 0;

OrderBlockInfo g_bullOBList[];  // var bullishOrderBlocksList
OrderBlockInfo g_bearOBList[];  // var bearishOrderBlocksList
OrderBlock     g_allOBList[];   // var allOrderBlocksList

OBSwing    g_swingTop;          // var obSwing top
OBSwing    g_swingBottom;       // var obSwing bottom
int        g_swingType = 0;     // var swingType  (0 = looking for top, 1 = looking for bottom)

double     g_atrBuf[];          // per-bar Wilder ATR(10)
double     g_volBuf[];          // tick_volume cast to double (avoids per-call allocation)

//====================================================================
//  Helper utilities
//====================================================================

//--------------------------------------------------------------------
// Initialise an OrderBlockInfo to safe defaults
//--------------------------------------------------------------------
void InitOBInfo(OrderBlockInfo &info)
{
   info.top                  = 0.0;
   info.bottom               = 0.0;
   info.obVolume             = 0.0;
   info.obType               = "";
   info.startTime            = 0;
   info.bbVolume             = 0.0;
   info.obLowVolume          = 0.0;
   info.obHighVolume         = 0.0;
   info.breaker              = false;
   info.breakTime            = 0;
   info.timeframeStr         = "";
   info.disabled             = false;
   info.combinedTimeframesStr= "";
   info.combined             = false;
}

//--------------------------------------------------------------------
// Unique chart-object name
//--------------------------------------------------------------------
string GetObjName(string prefix)
{
   return prefix + "_VOB_" + IntegerToString(g_objCounter++);
}

//--------------------------------------------------------------------
// Format period-seconds to human-readable string
//   Mirrors Pine formatTimeframeString()
//--------------------------------------------------------------------
string FormatPeriodSeconds(int seconds)
{
   if(seconds >= 2592000) return "M";     // Monthly (~30 d)
   if(seconds >= 604800)  return "W";     // Weekly
   if(seconds >= 86400)   return "D";     // Daily
   if(seconds >= 3600)
   {
      int h = seconds / 3600;
      return IntegerToString(h) + " Hour" + (h > 1 ? "s" : "");
   }
   return IntegerToString(seconds / 60) + " Min";
}

// Convert stored timeframeStr (seconds as string) to label
string FormatTFString(const string &tfStr)
{
   if(tfStr == "" || tfStr == "0")
      return FormatPeriodSeconds((int)PeriodSeconds(Period()));
   return FormatPeriodSeconds((int)StringToInteger(tfStr));
}

//--------------------------------------------------------------------
// Format volume number  (mirrors Pine format.volume)
//--------------------------------------------------------------------
string FormatVolume(double vol)
{
   if(vol >= 1000000000.0) return DoubleToString(vol / 1000000000.0, 2) + "B";
   if(vol >= 1000000.0)    return DoubleToString(vol / 1000000.0,    2) + "M";
   if(vol >= 1000.0)       return DoubleToString(vol / 1000.0,       2) + "K";
   return DoubleToString(vol, 0);
}

//====================================================================
//  Chart-object factory functions
//====================================================================

//--------------------------------------------------------------------
// Create filled rectangle  (mirrors Pine box.new with bgcolor)
//--------------------------------------------------------------------
string CreateOBBox(color clr)
{
   string name = GetObjName("Box");
   if(ObjectCreate(0, name, OBJ_RECTANGLE, 0, 0, 0, 0, 0))
   {
      ObjectSetInteger(0, name, OBJPROP_COLOR,      clr);
      ObjectSetInteger(0, name, OBJPROP_FILL,       true);
      ObjectSetInteger(0, name, OBJPROP_BACK,       true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTED,   false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
      ObjectSetInteger(0, name, OBJPROP_WIDTH,      1);
   }
   return name;
}

//--------------------------------------------------------------------
// Create text label  (mirrors Pine box.set_text)
//--------------------------------------------------------------------
string CreateTextObj(color clr)
{
   string name = GetObjName("Txt");
   if(ObjectCreate(0, name, OBJ_TEXT, 0, 0, 0))
   {
      ObjectSetInteger(0, name, OBJPROP_COLOR,      clr);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTED,   false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE,   8);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR,     ANCHOR_CENTER);
   }
   return name;
}

//--------------------------------------------------------------------
// Create trend-line  (mirrors Pine line.new with xloc.bar_time)
//--------------------------------------------------------------------
string CreateLineObj(color clr, ENUM_LINE_STYLE style = STYLE_SOLID, int width = 1)
{
   string name = GetObjName("Ln");
   if(ObjectCreate(0, name, OBJ_TREND, 0, 0, 0, 0, 0))
   {
      ObjectSetInteger(0, name, OBJPROP_COLOR,      clr);
      ObjectSetInteger(0, name, OBJPROP_STYLE,      style);
      ObjectSetInteger(0, name, OBJPROP_WIDTH,      width);
      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT,  false);
      ObjectSetInteger(0, name, OBJPROP_RAY_LEFT,   false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTED,   false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
   }
   return name;
}

//--------------------------------------------------------------------
// Reposition a rectangle  (mirrors Pine moveBox)
//--------------------------------------------------------------------
void MoveBox(const string &name, datetime x1, double y1, datetime x2, double y2)
{
   if(name == "") return;
   ObjectSetInteger(0, name, OBJPROP_TIME,  0, x1);
   ObjectSetDouble (0, name, OBJPROP_PRICE, 0, y1);
   ObjectSetInteger(0, name, OBJPROP_TIME,  1, x2);
   ObjectSetDouble (0, name, OBJPROP_PRICE, 1, y2);
}

//--------------------------------------------------------------------
// Reposition a trend line  (mirrors Pine moveLine / line.set_xy1/2)
//--------------------------------------------------------------------
void MoveLineObj(const string &name, datetime x1, double y1, datetime x2, double y2)
{
   if(name == "") return;
   ObjectSetInteger(0, name, OBJPROP_TIME,  0, x1);
   ObjectSetDouble (0, name, OBJPROP_PRICE, 0, y1);
   ObjectSetInteger(0, name, OBJPROP_TIME,  1, x2);
   ObjectSetDouble (0, name, OBJPROP_PRICE, 1, y2);
}

//--------------------------------------------------------------------
// Delete one named object and clear the name string
//--------------------------------------------------------------------
void SafeDeleteObj(string &name)
{
   if(name != "")
   {
      ObjectDelete(0, name);
      name = "";
   }
}

//--------------------------------------------------------------------
// Delete all visual objects that belong to one OrderBlock
//   Mirrors Pine safeDeleteOrderBlock()
//--------------------------------------------------------------------
void SafeDeleteOrderBlock(OrderBlock &ob)
{
   ob.isRendered = false;
   SafeDeleteObj(ob.orderBoxName);
   SafeDeleteObj(ob.orderBoxTextName);
   SafeDeleteObj(ob.orderBoxPositiveName);
   SafeDeleteObj(ob.orderBoxNegativeName);
   SafeDeleteObj(ob.orderSeparatorName);
   SafeDeleteObj(ob.orderTextSeparatorName);
}

//--------------------------------------------------------------------
// Delete ALL indicator objects from the chart  (used on full reset)
//--------------------------------------------------------------------
void DeleteAllIndicatorObjects()
{
   int total = ObjectsTotal(0, 0, -1);
   for(int i = total - 1; i >= 0; i--)
   {
      string n = ObjectName(0, i);
      if(StringFind(n, "_VOB_") >= 0)
         ObjectDelete(0, n);
   }
}

//====================================================================
//  Array helpers  (Pine: unshift / pop / remove)
//====================================================================

void ArrayUnshiftOBInfo(OrderBlockInfo &arr[], const OrderBlockInfo &item)
{
   int n = ArraySize(arr);
   ArrayResize(arr, n + 1);
   for(int i = n; i > 0; i--)
      arr[i] = arr[i - 1];
   arr[0] = item;
}

void ArrayPopOBInfo(OrderBlockInfo &arr[])
{
   int n = ArraySize(arr);
   if(n > 0) ArrayResize(arr, n - 1);
}

void ArrayRemoveOBInfo(OrderBlockInfo &arr[], int idx)
{
   int n = ArraySize(arr);
   if(idx < 0 || idx >= n) return;
   for(int i = idx; i < n - 1; i++)
      arr[i] = arr[i + 1];
   ArrayResize(arr, n - 1);
}

void ArrayUnshiftOrderBlock(OrderBlock &arr[], const OrderBlock &item)
{
   int n = ArraySize(arr);
   ArrayResize(arr, n + 1);
   for(int i = n; i > 0; i--)
      arr[i] = arr[i - 1];
   arr[0] = item;
}

//====================================================================
//  Geometry helpers  (mirrors Pine areaOfOB / doOBsTouch)
//====================================================================

double AreaOfOB(const OrderBlockInfo &ob, datetime curTime)
{
   // Pine: edge1 = sqrt((XA2-XA1)^2 + 0)  = |XA2 - XA1|
   //       edge2 = sqrt(0 + (YA2-YA1)^2)  = |YA2 - YA1|
   double xa1 = (double)(long)ob.startTime;
   double xa2 = (ob.breakTime == 0) ? (double)(long)(curTime + 1) : (double)(long)ob.breakTime;
   double ya1 = ob.top;
   double ya2 = ob.bottom;
   return MathAbs(xa2 - xa1) * MathAbs(ya1 - ya2);
}

bool DoOBsTouch(const OrderBlockInfo &ob1, const OrderBlockInfo &ob2, datetime curTime)
{
   double xa1 = (double)(long)ob1.startTime;
   double xa2 = (ob1.breakTime == 0) ? (double)(long)(curTime + 1) : (double)(long)ob1.breakTime;
   double ya1 = ob1.top,  ya2 = ob1.bottom;

   double xb1 = (double)(long)ob2.startTime;
   double xb2 = (ob2.breakTime == 0) ? (double)(long)(curTime + 1) : (double)(long)ob2.breakTime;
   double yb1 = ob2.top,  yb2 = ob2.bottom;

   double xOvlp = MathMax(0.0, MathMin(xa2, xb2) - MathMax(xa1, xb1));
   double yOvlp = MathMax(0.0, MathMin(ya1, yb1) - MathMax(ya2, yb2));
   double intersect = xOvlp * yOvlp;
   double unionArea = AreaOfOB(ob1, curTime) + AreaOfOB(ob2, curTime) - intersect;

   if(unionArea <= 0.0) return false;
   double pct = (intersect / unionArea) * 100.0;
   return pct > OVERLAP_THRESHOLD_PCT;
}

bool IsOBValid(const OrderBlockInfo &ob) { return !ob.disabled; }

//====================================================================
//  Wilder ATR(10)  –  mirrors Pine ta.atr(10)
//====================================================================

// Compute one ATR value at position pos.
// Requires atrBuf[pos-1] to already be computed (except on first calls).
double CalcATRStep(int pos,
                   const double &high_[], const double &low_[], const double &close_[],
                   double prevATR, int len = 10)
{
   if(pos < 1) return 0.0;
   double h  = high_[pos];
   double l  = low_[pos];
   double cp = close_[pos - 1];
   double tr = MathMax(h - l, MathMax(MathAbs(h - cp), MathAbs(l - cp)));
   if(pos < len)
      return tr;                          // not enough data yet
   if(pos == len)
   {
      // Seed: simple average of first 'len' TRs
      double sum = 0.0;
      for(int k = 1; k <= len; k++)
      {
         double hk = high_[k], lk = low_[k], cpk = close_[k - 1];
         sum += MathMax(hk - lk, MathMax(MathAbs(hk - cpk), MathAbs(lk - cpk)));
      }
      return sum / len;
   }
   // Wilder smoothing: RMA = (prev*(len-1) + tr) / len
   return (prevATR * (len - 1) + tr) / len;
}

//====================================================================
//  Swing detection  –  mirrors Pine findOBSwings(len)
//====================================================================

// Called once per bar (pos) to update g_swingTop / g_swingBottom / g_swingType.
// Equivalent of Pine findOBSwings(swingLength) executed bar-by-bar.
void FindOBSwings(int pos, int swingLen,
                  const double &high_[], const double &low_[], const double &volume_[])
{
   if(pos < swingLen) return;

   // ta.highest(swingLen) = max of high[pos .. pos-swingLen+1]
   // (the pivot candidate at pos-swingLen is excluded from 'upper' and 'lower')
   // Pine: upper = ta.highest(len)  where len bars means high[0]..high[len-1]
   double upper = high_[pos];
   double lower = low_[pos];
   for(int k = 1; k < swingLen; k++)
   {
      if(high_[pos - k] > upper) upper = high_[pos - k];
      if(low_ [pos - k] < lower) lower = low_ [pos - k];
   }

   int refPos = pos - swingLen;   // Pine's high[len] / low[len]
   if(refPos < 0) return;

   int prevSwingType = g_swingType;

   // Pine: swingType := high[len] > upper ? 0 : low[len] < lower ? 1 : swingType
   if     (high_[refPos] > upper) g_swingType = 0;
   else if(low_ [refPos] < lower) g_swingType = 1;

   // Pine: if swingType == 0 and swingType[1] != 0  →  new swing high
   if(g_swingType == 0 && prevSwingType != 0)
   {
      g_swingTop.barIdx      = refPos;
      g_swingTop.price       = high_[refPos];
      g_swingTop.swingVolume = volume_[refPos];
      g_swingTop.crossed     = false;
   }

   // Pine: if swingType == 1 and swingType[1] != 1  →  new swing low
   if(g_swingType == 1 && prevSwingType != 1)
   {
      g_swingBottom.barIdx      = refPos;
      g_swingBottom.price       = low_[refPos];
      g_swingBottom.swingVolume = volume_[refPos];
      g_swingBottom.crossed     = false;
   }
}

//====================================================================
//  Order Block detection  –  mirrors Pine findOrderBlocks()
//====================================================================

void FindOrderBlocks(int pos, int total,
                     const double &high_[],   const double &low_[],
                     const double &open_[],   const double &close_[],
                     const double &volume_[], const datetime &time_[],
                     double atr)
{
   // Performance gate: only process bars near the last bar
   // Pine: bar_index > last_bar_index - maxDistanceToLastBar
   if(pos <= (total - 1) - MAX_DIST_LAST_BAR) return;
   if(pos < 2) return;

   FindOBSwings(pos, InpSwingLength, high_, low_, volume_);

   // ---- Bullish Order Block logic ----------------------------------------

   // Update breaker status of existing bullish OBs
   int bullSz = ArraySize(g_bullOBList);
   for(int i = bullSz - 1; i >= 0; i--)
   {
      if(!g_bullOBList[i].breaker)
      {
         // Pine: (obEndMethod=="Wick" ? low : min(open,close)) < bottom
         double chk = (InpOBEndMethod == "Wick")
                      ? low_[pos]
                      : MathMin(open_[pos], close_[pos]);
         if(chk < g_bullOBList[i].bottom)
         {
            g_bullOBList[i].breaker   = true;
            g_bullOBList[i].breakTime = time_[pos];
            g_bullOBList[i].bbVolume  = volume_[pos];
         }
      }
      else
      {
         // Already a breaker: remove if price goes above its top
         if(high_[pos] > g_bullOBList[i].top)
            ArrayRemoveOBInfo(g_bullOBList, i);
      }
   }

   // Detect new bullish OB: close crosses above swing high
   // Pine: if close > top.y and not top.crossed
   if(g_swingTop.barIdx >= 0 && !g_swingTop.crossed && close_[pos] > g_swingTop.price)
   {
      g_swingTop.crossed = true;

      // Pine initialises: boxBtm = max[1]=high[1],  boxTop = min[1]=low[1]
      // Then loop finds bar with lowest low (min[i]) in the range [1 .. bar_index-top.x-1]
      double   boxBtm  = high_[pos - 1];   // max[1]
      double   boxTop  = low_ [pos - 1];   // min[1]
      datetime boxLoc  = time_[pos - 1];

      int lookback = pos - g_swingTop.barIdx - 1;
      for(int i = 1; i <= lookback; i++)
      {
         int k = pos - i;
         if(k < 0) break;
         double minI = low_ [k];  // Pine: min[i]
         double maxI = high_[k];  // Pine: max[i]
         // Pine: boxBtm := math.min(min[i], boxBtm)
         //        boxTop := boxBtm == min[i] ? max[i] : boxTop
         if(minI <= boxBtm)
         {
            boxBtm = minI;
            boxTop = maxI;
            boxLoc = time_[k];
         }
      }

      // Pine: orderBlockInfo.new(boxTop, boxBtm, vol0+vol1+vol2, "Bull", boxLoc)
      OrderBlockInfo newOB;
      InitOBInfo(newOB);
      newOB.top          = boxTop;                               // high of lowest-low bar
      newOB.bottom       = boxBtm;                              // lowest low
      newOB.obVolume     = volume_[pos] + volume_[pos-1] + volume_[pos-2];
      newOB.obType       = "Bull";
      newOB.startTime    = boxLoc;
      newOB.obLowVolume  = volume_[pos-2];                      // Pine: volume[2]
      newOB.obHighVolume = volume_[pos] + volume_[pos-1];       // Pine: volume+volume[1]
      newOB.timeframeStr = IntegerToString((int)PeriodSeconds(Period()));

      double obSize = MathAbs(newOB.top - newOB.bottom);
      if(obSize <= atr * MAX_ATR_MULT && obSize > 0.0)
      {
         ArrayUnshiftOBInfo(g_bullOBList, newOB);
         if(ArraySize(g_bullOBList) > MAX_ORDER_BLOCKS)
            ArrayPopOBInfo(g_bullOBList);
      }
   }

   // ---- Bearish Order Block logic ----------------------------------------

   // Update breaker status of existing bearish OBs
   int bearSz = ArraySize(g_bearOBList);
   for(int i = bearSz - 1; i >= 0; i--)
   {
      if(!g_bearOBList[i].breaker)
      {
         // Pine: (obEndMethod=="Wick" ? high : max(open,close)) > top
         double chk = (InpOBEndMethod == "Wick")
                      ? high_[pos]
                      : MathMax(open_[pos], close_[pos]);
         if(chk > g_bearOBList[i].top)
         {
            g_bearOBList[i].breaker   = true;
            g_bearOBList[i].breakTime = time_[pos];
            g_bearOBList[i].bbVolume  = volume_[pos];
         }
      }
      else
      {
         // Already a breaker: remove if price goes below its bottom
         if(low_[pos] < g_bearOBList[i].bottom)
            ArrayRemoveOBInfo(g_bearOBList, i);
      }
   }

   // Detect new bearish OB: close crosses below swing low
   // Pine: if close < btm.y and not btm.crossed
   if(g_swingBottom.barIdx >= 0 && !g_swingBottom.crossed && close_[pos] < g_swingBottom.price)
   {
      g_swingBottom.crossed = true;

      // Pine initialises: boxBtm=min[1]=low[1],  boxTop=max[1]=high[1]
      // Loop finds bar with highest high (max[i]) in range [1 .. bar_index-btm.x-1]
      double   boxBtm  = low_ [pos - 1];   // min[1]
      double   boxTop  = high_[pos - 1];   // max[1]
      datetime boxLoc  = time_[pos - 1];

      int lookback = pos - g_swingBottom.barIdx - 1;
      for(int i = 1; i <= lookback; i++)
      {
         int k = pos - i;
         if(k < 0) break;
         double maxI = high_[k];   // Pine: max[i]
         double minI = low_ [k];   // Pine: min[i]
         // Pine: boxTop := math.max(max[i], boxTop)
         //        boxBtm := boxTop == max[i] ? min[i] : boxBtm
         if(maxI >= boxTop)
         {
            boxTop = maxI;
            boxBtm = minI;
            boxLoc = time_[k];
         }
      }

      // Pine: orderBlockInfo.new(boxTop, boxBtm, vol0+vol1+vol2, "Bear", boxLoc)
      OrderBlockInfo newOB;
      InitOBInfo(newOB);
      newOB.top          = boxTop;
      newOB.bottom       = boxBtm;
      newOB.obVolume     = volume_[pos] + volume_[pos-1] + volume_[pos-2];
      newOB.obType       = "Bear";
      newOB.startTime    = boxLoc;
      newOB.obLowVolume  = volume_[pos] + volume_[pos-1];   // Pine: volume+volume[1]
      newOB.obHighVolume = volume_[pos-2];                   // Pine: volume[2]
      newOB.timeframeStr = IntegerToString((int)PeriodSeconds(Period()));

      double obSize = MathAbs(newOB.top - newOB.bottom);
      if(obSize <= atr * MAX_ATR_MULT && obSize > 0.0)
      {
         ArrayUnshiftOBInfo(g_bearOBList, newOB);
         if(ArraySize(g_bearOBList) > MAX_ORDER_BLOCKS)
            ArrayPopOBInfo(g_bearOBList);
      }
   }
}

//====================================================================
//  Combine overlapping OBs  –  mirrors Pine combineOBsFunc()
//====================================================================

void CombineOBsFunc(datetime curTime)
{
   if(ArraySize(g_allOBList) == 0) return;

   // Pine: while lastCombinations > 0 { scan all pairs; combine touching same-type OBs }
   // We restart the scan after each combination to maintain correct array indices.
   bool combinedAny = true;
   while(combinedAny)
   {
      combinedAny = false;
      int n = ArraySize(g_allOBList);
      for(int i = 0; i < n && !combinedAny; i++)
      {
         for(int j = 0; j < n && !combinedAny; j++)
         {
            if(i == j) continue;
            if(!IsOBValid(g_allOBList[i].info) || !IsOBValid(g_allOBList[j].info)) continue;
            if(g_allOBList[i].info.obType != g_allOBList[j].info.obType) continue;
            if(!DoOBsTouch(g_allOBList[i].info, g_allOBList[j].info, curTime)) continue;

            // Mark both as disabled
            g_allOBList[i].info.disabled = true;
            g_allOBList[j].info.disabled = true;

            // Build merged OB  (mirrors Pine's createOrderBlock + field assignments)
            OrderBlockInfo merged;
            InitOBInfo(merged);
            merged.top      = MathMax(g_allOBList[i].info.top,    g_allOBList[j].info.top);
            merged.bottom   = MathMin(g_allOBList[i].info.bottom, g_allOBList[j].info.bottom);
            merged.obType   = g_allOBList[i].info.obType;
            merged.startTime= (datetime)MathMin((double)(long)g_allOBList[i].info.startTime,
                                                (double)(long)g_allOBList[j].info.startTime);

            // Pine: math.max(nz(bt1), nz(bt2)), then if 0 → na
            long bt1 = (long)(g_allOBList[i].info.breakTime);
            long bt2 = (long)(g_allOBList[j].info.breakTime);
            long maxBT = MathMax(bt1, bt2);
            merged.breakTime = (maxBT == 0) ? 0 : (datetime)maxBT;

            merged.timeframeStr  = g_allOBList[i].info.timeframeStr;
            merged.obVolume      = g_allOBList[i].info.obVolume     + g_allOBList[j].info.obVolume;
            merged.obLowVolume   = g_allOBList[i].info.obLowVolume  + g_allOBList[j].info.obLowVolume;
            merged.obHighVolume  = g_allOBList[i].info.obHighVolume + g_allOBList[j].info.obHighVolume;
            merged.bbVolume      = g_allOBList[i].info.bbVolume     + g_allOBList[j].info.bbVolume;
            merged.breaker       = g_allOBList[i].info.breaker || g_allOBList[j].info.breaker;
            merged.combined      = true;

            // Combined timeframe label (only different when OBs come from different TFs)
            if(g_allOBList[i].info.timeframeStr != g_allOBList[j].info.timeframeStr)
            {
               string tf1 = (g_allOBList[i].info.combinedTimeframesStr != "")
                              ? g_allOBList[i].info.combinedTimeframesStr
                              : FormatTFString(g_allOBList[i].info.timeframeStr);
               string tf2 = (g_allOBList[j].info.combinedTimeframesStr != "")
                              ? g_allOBList[j].info.combinedTimeframesStr
                              : FormatTFString(g_allOBList[j].info.timeframeStr);
               merged.combinedTimeframesStr = tf1 + " & " + tf2;
            }

            // Pine: allOrderBlocksList.unshift(newOB)
            OrderBlock newOBEntry;
            newOBEntry.info                  = merged;
            newOBEntry.isRendered            = false;
            newOBEntry.orderBoxName          = "";
            newOBEntry.orderBoxTextName      = "";
            newOBEntry.orderBoxPositiveName  = "";
            newOBEntry.orderBoxNegativeName  = "";
            newOBEntry.orderSeparatorName    = "";
            newOBEntry.orderTextSeparatorName= "";
            ArrayUnshiftOrderBlock(g_allOBList, newOBEntry);
            combinedAny = true;
         }
      }
   }
}

//====================================================================
//  Render one order block  –  mirrors Pine renderOrderBlock()
//====================================================================

void RenderOrderBlock(OrderBlock &ob, datetime curTime)
{
   OrderBlockInfo &info = ob.info;
   ob.isRendered = true;

   // Pine: not (not showInvalidated and info.breaker)
   if(!InpShowInvalidated && info.breaker) return;

   color orderColor = (info.obType == "Bull") ? InpBullOrderBlockColor : InpBearOrderBlockColor;

   // Pine: ob.orderBox := createOBBox(orderColor, 1.5)
   ob.orderBoxName = CreateOBBox(orderColor);

   // Pine: ob.orderBoxText := createOBBox(color.new(color.white, 100))  [fully transparent = text only]
   ob.orderBoxTextName = CreateTextObj(InpTextColor);

   if(InpOrderBlockVolumetricInfo)
   {
      ob.orderBoxPositiveName   = CreateOBBox(InpBullOrderBlockColor);
      ob.orderBoxNegativeName   = CreateOBBox(InpBearOrderBlockColor);
      // Pine: line.new(..., line.style_dashed, 1)
      ob.orderSeparatorName     = CreateLineObj(InpTextColor, STYLE_DASH,  1);
      // Pine: line.new(..., line.style_solid,  1)
      ob.orderTextSeparatorName = CreateLineObj(InpTextColor, STYLE_SOLID, 1);
   }

   // ---- Zone size calculation -------------------------------------------
   // Pine: extendZonesByTime = extendZonesBy * timeframe.in_seconds(period) * 1000
   //       (Pine time is in ms; MQL5 datetime is in seconds – no ×1000 needed)
   long extZoneTime = (long)InpExtendZonesBy * (long)PeriodSeconds(Period());
   long zoneSize;

   // Pine:
   //   zoneSize = extendZonesDynamic ? na(breakTime) ? extendZonesByTime
   //                                                 : (breakTime - startTime)
   //                                 : extendZonesByTime
   //   if na(breakTime)
   //       zoneSize := (time + 1) - startTime
   if(info.breakTime == 0)           // na(breakTime)  → extend to current bar
   {
      zoneSize = (long)(curTime - info.startTime);
      if(zoneSize <= 0) zoneSize = extZoneTime;
   }
   else if(InpExtendZonesDynamic)    // broken zone: span from start to break
   {
      zoneSize = (long)(info.breakTime - info.startTime);
   }
   else
   {
      zoneSize = extZoneTime;        // fixed extension
   }
   if(zoneSize <= 0) zoneSize = extZoneTime;

   datetime endTime = info.startTime + (datetime)zoneSize;

   // ---- Volume-bar split (left third vs right two-thirds) ---------------
   // Pine: startX  = volumeBarsLeftSide ? startTime             : startTime + zoneSize - zoneSize/3
   //        maxEndX = volumeBarsLeftSide ? startTime + zoneSize/3 : startTime + zoneSize
   datetime startX, maxEndX;
   if(InpVolumeBarsLeft)
   {
      startX  = info.startTime;
      maxEndX = info.startTime + (datetime)(zoneSize / 3);
   }
   else
   {
      startX  = info.startTime + (datetime)(zoneSize - zoneSize / 3);
      maxEndX = endTime;
   }

   // ---- Main box --------------------------------------------------------
   // Pine: moveBox(ob.orderBox, startTime, top, startTime + zoneSize, bottom)
   MoveBox(ob.orderBoxName, info.startTime, info.top, endTime, info.bottom);

   // ---- Text label ------------------------------------------------------
   // Pine: box.set_text(orderBoxText, ..., text_halign=text.align_center)
   // Text area spans: [textAreaLeft .. endTime] (left side) or [startTime .. startX] (right side).
   // We place OBJ_TEXT with ANCHOR_CENTER at the midpoint of that area / zone height.
   datetime textAreaLeft  = InpVolumeBarsLeft ? maxEndX      : info.startTime;
   datetime textAreaRight = InpVolumeBarsLeft ? endTime      : startX;
   datetime textX = (datetime)(((long)textAreaLeft + (long)textAreaRight) / 2);

   // Pine: percentage = int((min(obHighVolume,obLowVolume) / max(obHighVolume,obLowVolume)) * 100)
   int pct = 0;
   if(info.obHighVolume > 0.0 && info.obLowVolume > 0.0)
   {
      double mn = MathMin(info.obHighVolume, info.obLowVolume);
      double mx = MathMax(info.obHighVolume, info.obLowVolume);
      if(mx > 0.0) pct = (int)((mn / mx) * 100.0);
   }

   // Pine: OBText = (na(combinedTimeframesStr) ? formatTF(TFStr) : combinedTFStr) + " OB"
   string tfLabel = (info.combinedTimeframesStr != "")
                    ? info.combinedTimeframesStr
                    : FormatTFString(info.timeframeStr);

   // Pine: box.set_text(orderBoxText,
   //         (volumetric ? volume+"(pct%)\n" : "") + OBText )
   string obText = "";
   if(InpOrderBlockVolumetricInfo)
      obText = FormatVolume(info.obVolume) + " (" + IntegerToString(pct) + "%)\n";
   obText += tfLabel + " OB";

   ObjectSetInteger(0, ob.orderBoxTextName, OBJPROP_TIME,   0, textX);
   ObjectSetDouble (0, ob.orderBoxTextName, OBJPROP_PRICE,  0, (info.top + info.bottom) / 2.0);
   ObjectSetString (0, ob.orderBoxTextName, OBJPROP_TEXT,      obText);
   ObjectSetInteger(0, ob.orderBoxTextName, OBJPROP_ANCHOR,    ANCHOR_CENTER);

   // ---- Volume bars (only when volumetric info enabled) -----------------
   if(InpOrderBlockVolumetricInfo && info.obVolume > 0.0)
   {
      long barWidth = (long)(maxEndX - startX);
      if(barWidth <= 0) barWidth = 1;

      // Pine:
      //   curEndXHigh = int(ceil((obHighVolume / obVolume) * (maxEndX - startX) + startX))
      //   curEndXLow  = int(ceil((obLowVolume  / obVolume) * (maxEndX - startX) + startX))
      datetime curEndXHigh = startX + (datetime)(long)MathCeil((info.obHighVolume / info.obVolume) * barWidth);
      datetime curEndXLow  = startX + (datetime)(long)MathCeil((info.obLowVolume  / info.obVolume) * barWidth);

      double midY = (info.bottom + info.top) / 2.0;

      // Pine: mirrorVolumeBars ? startX : curEndXLow,  top,  mirrorVolumeBars ? curEndXHigh : maxEndX,  mid
      if(InpMirrorVolumeBars)
      {
         MoveBox(ob.orderBoxPositiveName, startX,       info.top,    curEndXHigh, midY);
         MoveBox(ob.orderBoxNegativeName, startX,       info.bottom, curEndXLow,  midY);
      }
      else
      {
         MoveBox(ob.orderBoxPositiveName, curEndXLow,   info.top,    maxEndX,     midY);
         MoveBox(ob.orderBoxNegativeName, curEndXHigh,  info.bottom, maxEndX,     midY);
      }

      // Pine: moveLine(ob.orderSeparator,
      //          volumeBarsLeftSide ? startX : maxEndX,  midY,
      //          volumeBarsLeftSide ? maxEndX : startX)
      datetime sepX1 = InpVolumeBarsLeft ? startX  : maxEndX;
      datetime sepX2 = InpVolumeBarsLeft ? maxEndX : startX;
      MoveLineObj(ob.orderSeparatorName, sepX1, midY, sepX2, midY);

      // Pine: line.set_xy1(ob.orderTextSeparator,
      //          volumeBarsLeftSide ? maxEndX : startX,  top)
      //        line.set_xy2(ob.orderTextSeparator,
      //          volumeBarsLeftSide ? maxEndX : startX,  bottom)
      datetime sepVX = InpVolumeBarsLeft ? maxEndX : startX;
      MoveLineObj(ob.orderTextSeparatorName, sepVX, info.top, sepVX, info.bottom);
   }
}

//====================================================================
//  Rebuild & render all OBs  –  mirrors Pine handleOrderBlocksFinal()
//====================================================================

void HandleOrderBlocksFinal(datetime curTime)
{
   // Pine: clear allOrderBlocksList (deleting every box/line first)
   int n = ArraySize(g_allOBList);
   for(int i = 0; i < n; i++)
      SafeDeleteOrderBlock(g_allOBList[i]);
   ArrayResize(g_allOBList, 0);

   // Populate from bullish list (up to g_bullishOBMax entries)
   // Pine: for j = 0 to min(bullList.size()-1, bullishOrderBlocks-1)
   int bullCnt = MathMin(ArraySize(g_bullOBList), g_bullishOBMax);
   for(int j = 0; j < bullCnt; j++)
   {
      OrderBlock entry;
      entry.info                   = g_bullOBList[j];
      entry.isRendered             = false;
      entry.orderBoxName           = "";
      entry.orderBoxTextName       = "";
      entry.orderBoxPositiveName   = "";
      entry.orderBoxNegativeName   = "";
      entry.orderSeparatorName     = "";
      entry.orderTextSeparatorName = "";
      entry.info.timeframeStr = IntegerToString((int)PeriodSeconds(Period()));
      ArrayUnshiftOrderBlock(g_allOBList, entry);
   }

   // Populate from bearish list
   int bearCnt = MathMin(ArraySize(g_bearOBList), g_bearishOBMax);
   for(int j = 0; j < bearCnt; j++)
   {
      OrderBlock entry;
      entry.info                   = g_bearOBList[j];
      entry.isRendered             = false;
      entry.orderBoxName           = "";
      entry.orderBoxTextName       = "";
      entry.orderBoxPositiveName   = "";
      entry.orderBoxNegativeName   = "";
      entry.orderSeparatorName     = "";
      entry.orderTextSeparatorName = "";
      entry.info.timeframeStr = IntegerToString((int)PeriodSeconds(Period()));
      ArrayUnshiftOrderBlock(g_allOBList, entry);
   }

   // Pine: if combineOBs  (always true when DEBUG=false)
   CombineOBsFunc(curTime);

   // Pine: for each valid OB → renderOrderBlock
   n = ArraySize(g_allOBList);
   for(int i = 0; i < n; i++)
   {
      if(IsOBValid(g_allOBList[i].info))
         RenderOrderBlock(g_allOBList[i], curTime);
   }

   ChartRedraw(0);
}

//====================================================================
//  OnInit
//====================================================================

int OnInit()
{
   // Map ZoneCount input  (mirrors Pine bullishOrderBlocks / bearishOrderBlocks)
   if     (InpZoneCount == "One")    { g_bullishOBMax = 1;  g_bearishOBMax = 1;  }
   else if(InpZoneCount == "Low")    { g_bullishOBMax = 3;  g_bearishOBMax = 3;  }
   else if(InpZoneCount == "Medium") { g_bullishOBMax = 5;  g_bearishOBMax = 5;  }
   else                              { g_bullishOBMax = 10; g_bearishOBMax = 10; }

   // Initialise swing structs  (Pine: var obSwing top = obSwing.new(na,na))
   g_swingTop.barIdx      = -1;
   g_swingTop.price       = 0.0;
   g_swingTop.swingVolume = 0.0;
   g_swingTop.crossed     = false;

   g_swingBottom.barIdx      = -1;
   g_swingBottom.price       = 0.0;
   g_swingBottom.swingVolume = 0.0;
   g_swingBottom.crossed     = false;

   g_swingType  = 0;
   g_objCounter = 0;

   ArrayResize(g_bullOBList, 0);
   ArrayResize(g_bearOBList, 0);
   ArrayResize(g_allOBList,  0);
   ArrayResize(g_atrBuf,     0);
   ArrayResize(g_volBuf,     0);

   DeleteAllIndicatorObjects();
   return INIT_SUCCEEDED;
}

//====================================================================
//  OnDeinit
//====================================================================

void OnDeinit(const int reason)
{
   // Clean up all visual objects on removal
   int n = ArraySize(g_allOBList);
   for(int i = 0; i < n; i++)
      SafeDeleteOrderBlock(g_allOBList[i]);
   DeleteAllIndicatorObjects();
   ChartRedraw(0);
}

//====================================================================
//  OnCalculate  –  main bar-by-bar loop
//====================================================================

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
   if(rates_total < InpSwingLength + 3) return 0;

   // Full recalculation needed when indicator is first attached or chart is refreshed
   if(prev_calculated == 0)
   {
      // Reset all state  (mirrors Pine var initialisations executing fresh on each chart load)
      g_swingType           = 0;
      g_swingTop.barIdx     = -1;  g_swingTop.crossed     = false;
      g_swingBottom.barIdx  = -1;  g_swingBottom.crossed  = false;
      g_objCounter          = 0;

      ArrayResize(g_bullOBList, 0);
      ArrayResize(g_bearOBList, 0);

      // Clear rendered objects
      int nOB = ArraySize(g_allOBList);
      for(int i = 0; i < nOB; i++)
         SafeDeleteOrderBlock(g_allOBList[i]);
      ArrayResize(g_allOBList, 0);
      DeleteAllIndicatorObjects();

      // Pre-size buffers
      ArrayResize(g_atrBuf, rates_total);
      ArrayInitialize(g_atrBuf, 0.0);
      ArrayResize(g_volBuf, rates_total);
   }
   else
   {
      // Extend buffers for new bars
      if(ArraySize(g_atrBuf) < rates_total)
      {
         ArrayResize(g_atrBuf, rates_total);
         ArrayResize(g_volBuf, rates_total);
      }
   }

   // Populate volume buffer from tick_volume (Pine's 'volume' ≡ tick_volume in most brokers)
   int startPos = (prev_calculated <= 0) ? 1 : (prev_calculated - 1);
   for(int i = MathMax(0, startPos - 1); i < rates_total; i++)
      g_volBuf[i] = (double)tick_volume[i];

   // --- Pass 1: compute ATR(10) for all new bars ---
   for(int i = startPos; i < rates_total; i++)
      g_atrBuf[i] = CalcATRStep(i, high, low, close, g_atrBuf[i - 1], 10);

   // --- Pass 2: detect order blocks bar-by-bar ---
   // Pine executes findOrderBlocks() on every bar; we replay it here.
   for(int i = startPos; i < rates_total; i++)
      FindOrderBlocks(i, rates_total, high, low, open, close, g_volBuf, time, g_atrBuf[i]);

   // --- Pass 3: rebuild visuals on the last (confirmed) bar ---
   // Pine: if barstate.isconfirmed → handleOrderBlocksFinal()
   // We rebuild on every new closed bar for accuracy.
   if(rates_total > 0)
      HandleOrderBlocksFinal(time[rates_total - 1]);

   return rates_total;
}
//+------------------------------------------------------------------+
