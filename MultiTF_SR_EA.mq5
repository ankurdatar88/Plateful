//+------------------------------------------------------------------+
//|                       MultiTF_SR_EA.mq5                          |
//|       Multi-Timeframe Support & Resistance Expert Advisor         |
//|                                                                  |
//|  OVERVIEW                                                        |
//|  ─────────────────────────────────────────────────────────────   |
//|  • Detects swing-high / swing-low S/R levels across D1, H4,     |
//|    H1, M15 timeframes.                                           |
//|  • Entry timeframe: user-selected. Must be ≤ M15 or alert fires. |
//|  • Volatility ATR: separate TF + period for market context.      |
//|  • SL ATR      : separate TF + period for per-trade risk sizing. |
//|  • Risk per trade: % of equity, user-defined.                    |
//|  • Partial close 50% at 1:2 RR → SL to breakeven.               |
//|  • Second target at 1:2 → SL moves to 1:1 profit.               |
//|  • One trade per direction per symbol at a time.                 |
//|  • News filter: scrapes user-supplied URL; suspends trading      |
//|    2 min before and after each detected major event.             |
//|    Profitable open trades are closed before the event window.    |
//|  • Recalculates all levels every bar.                            |
//+------------------------------------------------------------------+
#property copyright   "Plateful"
#property link        ""
#property version     "1.00"
#property description "Multi-TF Swing S/R EA with ATR risk, partial close and news filter."

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//+------------------------------------------------------------------+
//| Enumerations                                                     |
//+------------------------------------------------------------------+

// S/R timeframes available for analysis
enum ENUM_SR_TIMEFRAME
  {
   SR_TF_D1  = 0,  // Daily (D1)
   SR_TF_H4  = 1,  // 4-Hour (H4)
   SR_TF_H1  = 2,  // 1-Hour (H1)
   SR_TF_M15 = 3   // 15-Minute (M15)
  };

//+------------------------------------------------------------------+
//| Input parameters                                                 |
//+------------------------------------------------------------------+

input group "━━━━━  S/R – Swing Detection  ━━━━━"
input int              InpSwingLookback   = 5;            // Swing pivot lookback (bars each side)
input bool             InpUseSR_D1        = true;         // Use Daily S/R levels
input bool             InpUseSR_H4        = true;         // Use 4H    S/R levels
input bool             InpUseSR_H1        = true;         // Use 1H    S/R levels
input bool             InpUseSR_M15       = true;         // Use 15M   S/R levels
input int              InpSRMaxLevels     = 3;            // Max levels per TF to cache
input double           InpSRProximityATR  = 0.5;          // S/R proximity band (× Volatility ATR)

input group "━━━━━  Entry Timeframe  ━━━━━"
input ENUM_TIMEFRAMES  InpEntryTF         = PERIOD_M15;   // Entry Timeframe

input group "━━━━━  Volatility ATR (market context)  ━━━━━"
input ENUM_TIMEFRAMES  InpVolATR_TF       = PERIOD_H1;    // Volatility ATR – Timeframe
input int              InpVolATR_Period   = 14;           // Volatility ATR – Period

input group "━━━━━  Stop-Loss ATR (per-trade sizing)  ━━━━━"
input ENUM_TIMEFRAMES  InpSL_ATR_TF       = PERIOD_M15;   // SL ATR – Timeframe
input int              InpSL_ATR_Period   = 14;           // SL ATR – Period
input double           InpSL_ATR_Mult     = 1.5;          // SL ATR Multiplier

input group "━━━━━  Risk Management  ━━━━━"
input double           InpEquityRisk      = 1.0;          // Equity Risk Per Trade (%)
input double           InpRRTarget1       = 2.0;          // 1st RR target (partial close & BE)
input double           InpPartialClosePct = 50.0;         // % of position to close at Target 1

input group "━━━━━  News Filter  ━━━━━"
input bool             InpNewsEnable      = true;         // Enable News Filter
input string           InpNewsURL         = "https://nfs.faireconomy.media/ff_calendar_thisweek.json"; // News Source URL
input int              InpNewsBuffer      = 2;            // Trading suspend window (minutes)
input string           InpNewsCurrencies  = "USD,EUR,GBP,JPY";  // Currencies to monitor
input string           InpNewsImpact      = "High";       // Minimum impact level (High/Medium)

input group "━━━━━  Trade Direction Lock  ━━━━━"
input bool             InpLockDirection   = false;        // Lock trade direction
input bool             InpOnlyBuys        = true;         // If locked: true=BUY only, false=SELL only

input group "━━━━━  Pairs To Monitor  ━━━━━"
input string           InpPairList        = "EURUSD,GBPUSD,USDJPY,AUDUSD"; // Comma-separated pairs

input group "━━━━━  Correlation  ━━━━━"
input double           InpCorrThreshold   = 0.8;          // Correlation threshold (0-1)

input group "━━━━━  General  ━━━━━"
input int              InpMagicNumber     = 200001;       // Magic Number

//+------------------------------------------------------------------+
//| Constants                                                        |
//+------------------------------------------------------------------+
#define MAX_SR_LEVELS   20     // maximum total cached S/R levels
#define NEWS_CACHE_MIN  5      // minutes between news re-fetches
#define MAX_NEWS_EVENTS 50     // maximum news events to store

//+------------------------------------------------------------------+
//| Structures                                                       |
//+------------------------------------------------------------------+
struct SRLevel
  {
   double         price;
   ENUM_TIMEFRAMES tf;
   bool           isResistance;  // true = resistance, false = support
  };

struct NewsEvent
  {
   datetime       eventTime;
   string         currency;
   string         impact;
   string         title;
  };

//+------------------------------------------------------------------+
//| Global state                                                     |
//+------------------------------------------------------------------+
CTrade        Trade;
CPositionInfo PosInfo;

// ATR handles
int    hVolATR  = INVALID_HANDLE;  // volatility ATR
int    hSL_ATR  = INVALID_HANDLE;  // stop-loss ATR

// S/R level cache
SRLevel  gSRLevels[MAX_SR_LEVELS];
int      gSRCount   = 0;

// News cache
NewsEvent gNewsEvents[MAX_NEWS_EVENTS];
int       gNewsCount  = 0;
datetime  gLastNewsFetch = 0;

// Per-position management state
// We store flags for each position by ticket for partial-close tracking
struct PosState
  {
   ulong    ticket;
   bool     target1Hit;   // 50% closed, SL at BE
   bool     target2Hit;   // SL moved to 1:1 profit
   double   entryPrice;
   double   originalSL;
   double   originalTP;   // originally RR×SL
   double   slDistance;   // |entry - originalSL|
  };

PosState gPosStates[100];
int      gPosStateCount = 0;

//+------------------------------------------------------------------+
//| Utility: map ENUM_SR_TIMEFRAME → ENUM_TIMEFRAMES                 |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES SRTFtoMT5TF(int srIdx)
  {
   switch(srIdx)
     {
      case 0: return PERIOD_D1;
      case 1: return PERIOD_H4;
      case 2: return PERIOD_H1;
      case 3: return PERIOD_M15;
     }
   return PERIOD_H1;
  }

//+------------------------------------------------------------------+
//| Validate entry timeframe                                         |
//|  Returns true if valid (≤ M15). Sends alert if too high.         |
//+------------------------------------------------------------------+
bool ValidateEntryTF()
  {
   // Supported S/R TFs: D1, H4, H1, M15
   // Entry TF must be ≤ the highest S/R TF (M15) or equal to one of them.
   // "Higher than M15" means larger period TF (H1, H4, D1).
   if(InpEntryTF == PERIOD_D1 || InpEntryTF == PERIOD_H4 || InpEntryTF == PERIOD_H1)
     {
      Alert("MultiTF_SR EA: Entry Timeframe (", EnumToString(InpEntryTF),
            ") is higher than or equal to the S/R timeframes (H1/H4/D1). "
            "Please select M15 or lower as the entry timeframe.");
      Print("WARNING: Entry TF too high. EA will not trade until reconfigured.");
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Detect swing highs and lows for a given TF and populate gSRLevels|
//+------------------------------------------------------------------+
void ComputeSRLevels(ENUM_TIMEFRAMES tf, bool enabled)
  {
   if(!enabled) return;

   int lb = InpSwingLookback;
   int barsNeeded = lb * 2 + 1 + InpSRMaxLevels + 10;
   int resCount = 0, supCount = 0;

   for(int i = lb + 1; i < barsNeeded && (resCount < InpSRMaxLevels || supCount < InpSRMaxLevels); i++)
     {
      double high_i = iHigh(_Symbol, tf, i);
      double low_i  = iLow (_Symbol, tf, i);

      // Check swing high
      if(resCount < InpSRMaxLevels)
        {
         bool isSwingHigh = true;
         for(int j = i - lb; j <= i + lb; j++)
           {
            if(j == i) continue;
            if(iHigh(_Symbol, tf, j) >= high_i) { isSwingHigh = false; break; }
           }
         if(isSwingHigh && gSRCount < MAX_SR_LEVELS)
           {
            gSRLevels[gSRCount].price        = high_i;
            gSRLevels[gSRCount].tf           = tf;
            gSRLevels[gSRCount].isResistance = true;
            gSRCount++;
            resCount++;
           }
        }

      // Check swing low
      if(supCount < InpSRMaxLevels)
        {
         bool isSwingLow = true;
         for(int j = i - lb; j <= i + lb; j++)
           {
            if(j == i) continue;
            if(iLow(_Symbol, tf, j) <= low_i) { isSwingLow = false; break; }
           }
         if(isSwingLow && gSRCount < MAX_SR_LEVELS)
           {
            gSRLevels[gSRCount].price        = low_i;
            gSRLevels[gSRCount].tf           = tf;
            gSRLevels[gSRCount].isResistance = false;
            gSRCount++;
            supCount++;
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Recalculate all S/R levels (called each bar)                     |
//+------------------------------------------------------------------+
void RecalcSRLevels()
  {
   gSRCount = 0;
   ArrayInitialize(gSRLevels, 0);

   ComputeSRLevels(PERIOD_D1,  InpUseSR_D1);
   ComputeSRLevels(PERIOD_H4,  InpUseSR_H4);
   ComputeSRLevels(PERIOD_H1,  InpUseSR_H1);
   ComputeSRLevels(PERIOD_M15, InpUseSR_M15);
  }

//+------------------------------------------------------------------+
//| Get current volatility ATR value                                 |
//+------------------------------------------------------------------+
double GetVolatilityATR()
  {
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(hVolATR, 0, 1, 1, buf) <= 0) return 0.0;
   return buf[0];
  }

//+------------------------------------------------------------------+
//| Get current SL ATR value                                         |
//+------------------------------------------------------------------+
double GetSL_ATR()
  {
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(hSL_ATR, 0, 1, 1, buf) <= 0) return 0.0;
   return buf[0];
  }

//+------------------------------------------------------------------+
//| Check if current price is near an S/R level (within proximity)   |
//|  Returns true and outputs the nearest level price                |
//+------------------------------------------------------------------+
bool IsNearSRLevel(double price, double proximityBand, double &nearestLevel, bool &isResistance)
  {
   double bestDist = DBL_MAX;
   bool   found    = false;

   for(int i = 0; i < gSRCount; i++)
     {
      double dist = MathAbs(price - gSRLevels[i].price);
      if(dist <= proximityBand && dist < bestDist)
        {
         bestDist      = dist;
         nearestLevel  = gSRLevels[i].price;
         isResistance  = gSRLevels[i].isResistance;
         found         = true;
        }
     }
   return found;
  }

//+------------------------------------------------------------------+
//| Parse simple JSON array from news URL response                   |
//|  Expected format (Forex Factory JSON):                           |
//|  [{"date":"...", "time":"...", "currency":"...",                  |
//|    "impact":"High", "title":"..."}]                              |
//+------------------------------------------------------------------+
void ParseNewsJSON(const string &json)
  {
   gNewsCount = 0;

   string impactFilter = InpNewsImpact; // "High" or "Medium"

   int pos = 0;
   int len = StringLen(json);

   while(pos < len && gNewsCount < MAX_NEWS_EVENTS)
     {
      // Find next event object
      int objStart = StringFind(json, "{", pos);
      if(objStart < 0) break;
      int objEnd = StringFind(json, "}", objStart);
      if(objEnd < 0) break;

      string obj = StringSubstr(json, objStart, objEnd - objStart + 1);
      pos = objEnd + 1;

      // Extract fields
      string date     = ExtractJSONField(obj, "date");
      string time_str = ExtractJSONField(obj, "time");
      string currency = ExtractJSONField(obj, "currency");
      string impact   = ExtractJSONField(obj, "impact");
      string title    = ExtractJSONField(obj, "title");

      if(impact == "" || currency == "") continue;

      // Filter by impact
      bool impactMatch = false;
      if(impactFilter == "High"   && impact == "High")   impactMatch = true;
      if(impactFilter == "Medium" && (impact == "High" || impact == "Medium")) impactMatch = true;
      if(!impactMatch) continue;

      // Filter by monitored currencies
      if(StringFind(InpNewsCurrencies, currency) < 0) continue;

      // Parse datetime "MM-DD-YYYY" + "HH:MM" (Forex Factory format)
      datetime evTime = ParseFFDateTime(date, time_str);
      if(evTime == 0) continue;

      gNewsEvents[gNewsCount].eventTime = evTime;
      gNewsEvents[gNewsCount].currency  = currency;
      gNewsEvents[gNewsCount].impact    = impact;
      gNewsEvents[gNewsCount].title     = title;
      gNewsCount++;
     }

   PrintFormat("NewsFilter: parsed %d relevant events.", gNewsCount);
  }

//+------------------------------------------------------------------+
//| Extract a JSON string field value by key                         |
//+------------------------------------------------------------------+
string ExtractJSONField(const string &obj, const string &key)
  {
   string searchKey = "\"" + key + "\"";
   int keyPos = StringFind(obj, searchKey);
   if(keyPos < 0) return "";

   int colonPos = StringFind(obj, ":", keyPos + StringLen(searchKey));
   if(colonPos < 0) return "";

   int valStart = colonPos + 1;
   while(valStart < StringLen(obj) && StringGetCharacter(obj, valStart) == ' ') valStart++;

   if(StringGetCharacter(obj, valStart) == '"')
     {
      // String value
      int valEnd = StringFind(obj, "\"", valStart + 1);
      if(valEnd < 0) return "";
      return StringSubstr(obj, valStart + 1, valEnd - valStart - 1);
     }
   else
     {
      // Numeric / boolean – read until comma or brace
      int valEnd = valStart;
      while(valEnd < StringLen(obj))
        {
         ushort c = StringGetCharacter(obj, valEnd);
         if(c == ',' || c == '}' || c == ']') break;
         valEnd++;
        }
      return StringSubstr(obj, valStart, valEnd - valStart);
     }
  }

//+------------------------------------------------------------------+
//| Parse Forex Factory date "MM-DD-YYYY" + time "HH:MM am/pm"      |
//+------------------------------------------------------------------+
datetime ParseFFDateTime(const string &datePart, const string &timePart)
  {
   // Date: "01-31-2025" → month=1 day=31 year=2025
   if(StringLen(datePart) < 10) return 0;
   int month = (int)StringToInteger(StringSubstr(datePart, 0, 2));
   int day   = (int)StringToInteger(StringSubstr(datePart, 3, 2));
   int year  = (int)StringToInteger(StringSubstr(datePart, 6, 4));

   // Time: "8:30am" or "8:30pm" or "All Day"
   int hour = 0, minute = 0;
   if(StringLen(timePart) >= 4 && timePart != "All Day")
     {
      int colonPos = StringFind(timePart, ":");
      if(colonPos > 0)
        {
         hour   = (int)StringToInteger(StringSubstr(timePart, 0, colonPos));
         minute = (int)StringToInteger(StringSubstr(timePart, colonPos + 1, 2));
         if(StringFind(timePart, "pm") >= 0 && hour < 12) hour += 12;
         if(StringFind(timePart, "am") >= 0 && hour == 12) hour = 0;
        }
     }

   MqlDateTime dt;
   dt.year   = year;
   dt.mon    = month;
   dt.day    = day;
   dt.hour   = hour;
   dt.min    = minute;
   dt.sec    = 0;
   dt.day_of_week = 0;
   dt.day_of_year = 0;

   return StructToTime(dt);
  }

//+------------------------------------------------------------------+
//| Fetch news from URL (uses WebRequest)                            |
//+------------------------------------------------------------------+
void FetchNews()
  {
   if(!InpNewsEnable) return;

   datetime now = TimeCurrent();
   if(now - gLastNewsFetch < NEWS_CACHE_MIN * 60) return;
   gLastNewsFetch = now;

   char   postData[];
   char   resultData[];
   string headers    = "";
   string resHeaders = "";
   int    timeout    = 5000;

   int ret = WebRequest("GET", InpNewsURL, headers, timeout,
                        postData, resultData, resHeaders);
   if(ret < 0 || ArraySize(resultData) == 0)
     {
      int err = GetLastError();
      if(err == 4014) // WebRequest not allowed
         Print("NewsFilter: Enable WebRequest for '", InpNewsURL,
               "' in Tools → Options → Expert Advisors → Allow WebRequests.");
      else
         PrintFormat("NewsFilter: WebRequest failed. Error=%d", err);
      return;
     }

   string json = CharArrayToString(resultData, 0, ArraySize(resultData), CP_UTF8);
   ParseNewsJSON(json);
  }

//+------------------------------------------------------------------+
//| Check if trading is blocked by news                              |
//+------------------------------------------------------------------+
bool IsNewsBlocked()
  {
   if(!InpNewsEnable) return false;

   datetime now    = TimeCurrent();
   int      bufSec = InpNewsBuffer * 60;

   for(int i = 0; i < gNewsCount; i++)
     {
      datetime t = gNewsEvents[i].eventTime;
      if(now >= t - bufSec && now <= t + bufSec)
        {
         PrintFormat("NewsFilter: BLOCKED – '%s' (%s) at %s",
                     gNewsEvents[i].title,
                     gNewsEvents[i].currency,
                     TimeToString(t));
         return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Close profitable trades before an upcoming news event            |
//+------------------------------------------------------------------+
void CloseTradesBeforeNews()
  {
   if(!InpNewsEnable) return;

   datetime now    = TimeCurrent();
   int      bufSec = InpNewsBuffer * 60;

   bool newsImminent = false;
   for(int i = 0; i < gNewsCount; i++)
     {
      datetime t = gNewsEvents[i].eventTime;
      if(now >= t - bufSec && now < t)
        { newsImminent = true; break; }
     }
   if(!newsImminent) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!PosInfo.SelectByIndex(i)) continue;
      if(PosInfo.Symbol() != _Symbol || PosInfo.Magic() != (long)InpMagicNumber) continue;

      if(PosInfo.Profit() > 0.0)
        {
         PrintFormat("NewsFilter: Closing profitable trade #%llu before news event.", PosInfo.Ticket());
         Trade.PositionClose(PosInfo.Ticket());
        }
     }
  }

//+------------------------------------------------------------------+
//| Count open positions for this EA on this symbol (long or short)  |
//+------------------------------------------------------------------+
int CountPositionsByType(ENUM_POSITION_TYPE type)
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PosInfo.SelectByIndex(i) &&
         PosInfo.Symbol()       == _Symbol &&
         PosInfo.Magic()        == (long)InpMagicNumber &&
         PosInfo.PositionType() == type)
         count++;
   return count;
  }

//+------------------------------------------------------------------+
//| Lot size – risks InpEquityRisk% of equity on slDist              |
//+------------------------------------------------------------------+
double CalcLotSize(double slDist)
  {
   if(slDist <= 0.0) return 0.0;

   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmt   = equity * (InpEquityRisk / 100.0);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || tickValue <= 0.0) return 0.0;

   double lots    = riskAmt / ((slDist / tickSize) * tickValue);
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lots = MathFloor(lots / lotStep) * lotStep;
   return MathMax(minLot, MathMin(maxLot, lots));
  }

//+------------------------------------------------------------------+
//| Find or create a PosState for a ticket                           |
//+------------------------------------------------------------------+
PosState* GetPosState(ulong ticket)
  {
   for(int i = 0; i < gPosStateCount; i++)
      if(gPosStates[i].ticket == ticket)
         return &gPosStates[i];

   if(gPosStateCount < 100)
     {
      gPosStates[gPosStateCount].ticket     = ticket;
      gPosStates[gPosStateCount].target1Hit = false;
      gPosStates[gPosStateCount].target2Hit = false;
      return &gPosStates[gPosStateCount++];
     }
   return NULL;
  }

//+------------------------------------------------------------------+
//| Remove PosState for closed ticket                                |
//+------------------------------------------------------------------+
void RemovePosState(ulong ticket)
  {
   for(int i = 0; i < gPosStateCount; i++)
     {
      if(gPosStates[i].ticket == ticket)
        {
         for(int j = i; j < gPosStateCount - 1; j++)
            gPosStates[j] = gPosStates[j + 1];
         gPosStateCount--;
         return;
        }
     }
  }

//+------------------------------------------------------------------+
//| Partial close: close pctToClose% of position volume             |
//+------------------------------------------------------------------+
bool PartialClose(ulong ticket, double pctToClose)
  {
   if(!PosInfo.SelectByTicket(ticket)) return false;

   double fullLots    = PosInfo.Volume();
   double closeLots   = fullLots * (pctToClose / 100.0);
   double lotStep     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot      = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   closeLots = MathFloor(closeLots / lotStep) * lotStep;
   if(closeLots < minLot) closeLots = minLot;
   if(closeLots >= fullLots) closeLots = fullLots; // safety

   return Trade.PositionClosePartial(ticket, closeLots);
  }

//+------------------------------------------------------------------+
//| Trade management: partial closes and SL adjustments              |
//+------------------------------------------------------------------+
void ManageOpenTrades()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!PosInfo.SelectByIndex(i)) continue;
      if(PosInfo.Symbol() != _Symbol || PosInfo.Magic() != (long)InpMagicNumber) continue;

      ulong   ticket   = PosInfo.Ticket();
      PosState *state  = GetPosState(ticket);
      if(state == NULL) continue;

      // Initialise state for newly detected positions
      if(state->entryPrice == 0.0)
        {
         state->entryPrice  = PosInfo.PriceOpen();
         state->originalSL  = PosInfo.StopLoss();
         state->slDistance  = MathAbs(state->entryPrice - state->originalSL);
         // TP was set to slDist * InpRRTarget1 at entry; store it
         state->originalTP  = PosInfo.TakeProfit();
        }

      double bid      = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask      = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double curSL    = PosInfo.StopLoss();
      double curTP    = PosInfo.TakeProfit();
      double slDist   = state->slDistance;
      double entry    = state->entryPrice;

      // ─── BUY management ───────────────────────────────────────
      if(PosInfo.PositionType() == POSITION_TYPE_BUY)
        {
         double profit1R = entry + slDist;           // breakeven
         double profit2R = entry + slDist * InpRRTarget1; // 1st RR target

         // Target 1: partial close + move SL to breakeven
         if(!state->target1Hit && bid >= profit2R)
           {
            if(PartialClose(ticket, InpPartialClosePct))
              {
               double newSL = NormalizeDouble(entry, _Digits); // breakeven
               if(newSL > curSL)
                  Trade.PositionModify(ticket, newSL, curTP);
               state->target1Hit = true;
               PrintFormat("[BUY #%llu] Target1 hit – closed %.0f%%, SL → breakeven", ticket, InpPartialClosePct);
              }
           }

         // Target 2: move SL to 1:1 profit level (entry + slDist)
         if(state->target1Hit && !state->target2Hit && bid >= profit2R + slDist)
           {
            double newSL = NormalizeDouble(profit1R, _Digits);  // 1R profit
            if(newSL > curSL)
               Trade.PositionModify(ticket, newSL, curTP);
            state->target2Hit = true;
            PrintFormat("[BUY #%llu] Target2 hit – SL → 1R profit level %.5f", ticket, newSL);
           }
        }

      // ─── SELL management ──────────────────────────────────────
      else if(PosInfo.PositionType() == POSITION_TYPE_SELL)
        {
         double profit1R = entry - slDist;
         double profit2R = entry - slDist * InpRRTarget1;

         if(!state->target1Hit && ask <= profit2R)
           {
            if(PartialClose(ticket, InpPartialClosePct))
              {
               double newSL = NormalizeDouble(entry, _Digits);
               if(newSL < curSL)
                  Trade.PositionModify(ticket, newSL, curTP);
               state->target1Hit = true;
               PrintFormat("[SELL #%llu] Target1 hit – closed %.0f%%, SL → breakeven", ticket, InpPartialClosePct);
              }
           }

         if(state->target1Hit && !state->target2Hit && ask <= profit2R - slDist)
           {
            double newSL = NormalizeDouble(profit1R, _Digits);
            if(newSL < curSL)
               Trade.PositionModify(ticket, newSL, curTP);
            state->target2Hit = true;
            PrintFormat("[SELL #%llu] Target2 hit – SL → 1R profit level %.5f", ticket, newSL);
           }
        }
     }

   // Clean up state for tickets that are no longer open
   for(int i = gPosStateCount - 1; i >= 0; i--)
      if(!PositionSelectByTicket(gPosStates[i].ticket))
         RemovePosState(gPosStates[i].ticket);
  }

//+------------------------------------------------------------------+
//| Determine if entry price is near an S/R level                   |
//|  buySetup  = price approaching support from above               |
//|  sellSetup = price approaching resistance from below            |
//+------------------------------------------------------------------+
bool EvalEntrySignal(bool isBuyLookup, double currentPrice, double proximityBand)
  {
   for(int i = 0; i < gSRCount; i++)
     {
      double dist = MathAbs(currentPrice - gSRLevels[i].price);
      if(dist > proximityBand) continue;

      // Buy near support (S/R below price or at price)
      if(isBuyLookup && !gSRLevels[i].isResistance &&
         currentPrice >= gSRLevels[i].price - proximityBand &&
         currentPrice <= gSRLevels[i].price + proximityBand)
         return true;

      // Sell near resistance (S/R above price or at price)
      if(!isBuyLookup && gSRLevels[i].isResistance &&
         currentPrice >= gSRLevels[i].price - proximityBand &&
         currentPrice <= gSRLevels[i].price + proximityBand)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Init                                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   // Validate entry timeframe
   if(!ValidateEntryTF()) return INIT_FAILED;

   Trade.SetExpertMagicNumber(InpMagicNumber);
   Trade.SetDeviationInPoints(20);

   uint fillFlags = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_FLAGS);
   if((fillFlags & SYMBOL_FILLING_FOK) != 0)
      Trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((fillFlags & SYMBOL_FILLING_IOC) != 0)
      Trade.SetTypeFilling(ORDER_FILLING_IOC);
   else
      Trade.SetTypeFilling(ORDER_FILLING_RETURN);

   hVolATR = iATR(_Symbol, InpVolATR_TF, InpVolATR_Period);
   hSL_ATR = iATR(_Symbol, InpSL_ATR_TF, InpSL_ATR_Period);

   if(hVolATR == INVALID_HANDLE || hSL_ATR == INVALID_HANDLE)
     {
      Alert("MultiTF_SR EA: Failed to create ATR handles.");
      return INIT_FAILED;
     }

   // Initial news fetch
   FetchNews();

   PrintFormat("MultiTF_SR EA ready | %s | Magic=%d | EntryTF=%s",
               _Symbol, InpMagicNumber, EnumToString(InpEntryTF));
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Deinit                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(hVolATR != INVALID_HANDLE) { IndicatorRelease(hVolATR); hVolATR = INVALID_HANDLE; }
   if(hSL_ATR != INVALID_HANDLE) { IndicatorRelease(hSL_ATR); hSL_ATR = INVALID_HANDLE; }
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // ── Manage open trades on every tick ──────────────────────────
   ManageOpenTrades();

   // ── Close profitable trades before imminent news ───────────────
   CloseTradesBeforeNews();

   // ── New-bar gate: entry logic evaluated per bar open ──────────
   static datetime lastBarTime = 0;
   datetime curBarTime = iTime(_Symbol, InpEntryTF, 0);
   if(curBarTime == lastBarTime) return;
   lastBarTime = curBarTime;

   // ── Refresh news cache (throttled) ────────────────────────────
   FetchNews();

   // ── Check news block ──────────────────────────────────────────
   if(IsNewsBlocked()) return;

   // ── Recalculate S/R levels every bar ──────────────────────────
   RecalcSRLevels();

   // ── ATR values ────────────────────────────────────────────────
   double volATR = GetVolatilityATR();
   double slATR  = GetSL_ATR();
   if(volATR <= 0.0 || slATR <= 0.0) return;

   double proximityBand = volATR * InpSRProximityATR;
   double slDist        = slATR  * InpSL_ATR_Mult;
   double tpDist        = slDist * InpRRTarget1;

   // Enforce broker minimum stop
   double minStop = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(slDist < minStop) slDist = minStop;
   if(tpDist < minStop) tpDist = minStop;

   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double midPx   = (ask + bid) / 2.0;

   // ── Direction lock ────────────────────────────────────────────
   bool allowBuy  = true;
   bool allowSell = true;
   if(InpLockDirection)
     {
      allowBuy  =  InpOnlyBuys;
      allowSell = !InpOnlyBuys;
     }

   // ── Only one trade per direction ──────────────────────────────
   bool buyOpen  = CountPositionsByType(POSITION_TYPE_BUY)  > 0;
   bool sellOpen = CountPositionsByType(POSITION_TYPE_SELL) > 0;

   // ── BUY setup: price near support level ───────────────────────
   if(allowBuy && !buyOpen && EvalEntrySignal(true, midPx, proximityBand))
     {
      double sl   = NormalizeDouble(ask - slDist, _Digits);
      double tp   = NormalizeDouble(ask + tpDist, _Digits);
      double lots = CalcLotSize(slDist);

      if(lots > 0.0)
        {
         if(Trade.Buy(lots, _Symbol, ask, sl, tp, "SR_BUY"))
           {
            ulong ticket = Trade.ResultOrder();
            PrintFormat("[SR BUY]  ticket=%llu lots=%.2f SL=%.5f TP=%.5f VolATR=%.5f SLATR=%.5f",
                        ticket, lots, sl, tp, volATR, slATR);
            // State will be initialised on next ManageOpenTrades() call
           }
         else
            PrintFormat("[SR BUY FAILED] err=%d %s", GetLastError(), Trade.ResultComment());
        }
     }

   // ── SELL setup: price near resistance level ───────────────────
   if(allowSell && !sellOpen && EvalEntrySignal(false, midPx, proximityBand))
     {
      double sl   = NormalizeDouble(bid + slDist, _Digits);
      double tp   = NormalizeDouble(bid - tpDist, _Digits);
      double lots = CalcLotSize(slDist);

      if(lots > 0.0)
        {
         if(Trade.Sell(lots, _Symbol, bid, sl, tp, "SR_SELL"))
           {
            ulong ticket = Trade.ResultOrder();
            PrintFormat("[SR SELL] ticket=%llu lots=%.2f SL=%.5f TP=%.5f VolATR=%.5f SLATR=%.5f",
                        ticket, lots, sl, tp, volATR, slATR);
           }
         else
            PrintFormat("[SR SELL FAILED] err=%d %s", GetLastError(), Trade.ResultComment());
        }
     }
  }
//+------------------------------------------------------------------+
