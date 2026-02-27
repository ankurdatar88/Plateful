//+------------------------------------------------------------------+
//|                       Donchian_SMA_ATR_EA.mq5                    |
//|          Donchian Breakout · SMA Trend Filter · ATR Risk Mgmt    |
//|                                                                  |
//|  Strategy                                                        |
//|  ─────────────────────────────────────────────────────────────   |
//|  • Trend  : Price of Bar[1] vs SMA                              |
//|             Above SMA → buy-only  |  Below SMA → sell-only      |
//|  • Buy    : Bar[1] close > Donchian Upper (prior N bars)         |
//|  • Sell   : Bar[1] close < Donchian Lower (prior N bars)         |
//|  • SL     : SL_Multiplier × ATR(Bar[1])                         |
//|  • TP     : RR × SL distance                                    |
//|  • Sizing : Equity × Risk% / SL_value_per_lot                   |
//|  • Max 1 open position at all times                              |
//+------------------------------------------------------------------+
#property copyright   "Plateful"
#property link        ""
#property version     "1.00"
#property description "Donchian Channel breakout filtered by SMA trend with ATR SL/TP."

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//+------------------------------------------------------------------+
//| Enumerations                                                     |
//+------------------------------------------------------------------+
enum ENUM_TRAIL_TYPE
  {
   TRAIL_ATR = 0,  // ATR Based  – trail at X×ATR from current price
   TRAIL_RR  = 1   // RR  Based  – activates at 1R, trails at original SL distance
  };

//+------------------------------------------------------------------+
//| Input parameters                                                 |
//+------------------------------------------------------------------+

input group "━━━━━  Donchian Channel  ━━━━━"
input int                InpDCUpperLen    = 20;           // Upper Band   – Length
input ENUM_APPLIED_PRICE InpDCUpperSrc    = PRICE_HIGH;   // Upper Band   – Source
input int                InpDCLowerLen    = 20;           // Lower Band   – Length
input ENUM_APPLIED_PRICE InpDCLowerSrc    = PRICE_LOW;    // Lower Band   – Source
input int                InpDCMidLen      = 20;           // Middle Band  – Length
input ENUM_APPLIED_PRICE InpDCMidSrc      = PRICE_CLOSE;  // Middle Band  – Source

input group "━━━━━  Simple Moving Average  ━━━━━"
input int                InpSMALen        = 200;          // SMA – Length
input ENUM_APPLIED_PRICE InpSMASrc        = PRICE_CLOSE;  // SMA – Source

input group "━━━━━  ATR  ━━━━━"
// ATR uses its own True Range formula (High, Low, Close) internally.
// The 'source' concept does not apply to ATR; period is the only parameter.
input int                InpATRLen        = 14;           // ATR – Period

input group "━━━━━  Trade Settings  ━━━━━"
input double             InpEquityRisk    = 1.0;          // Equity Risk Per Trade (%)
input double             InpSLMultiplier  = 1.5;          // SL Multiplier  (× ATR)
input double             InpRRRatio       = 2.0;          // Risk : Reward Ratio

input group "━━━━━  Trailing Stop Loss  ━━━━━"
input bool               InpTrailEnable   = false;        // Enable Trailing Stop
input ENUM_TRAIL_TYPE    InpTrailType     = TRAIL_ATR;    // Trailing Stop Type

input group "━━━━━  General  ━━━━━"
input int                InpMagicNumber   = 100001;       // Magic Number

//+------------------------------------------------------------------+
//| Global objects                                                   |
//+------------------------------------------------------------------+
CTrade        Trade;
CPositionInfo PosInfo;

int    hSMA = INVALID_HANDLE;
int    hATR = INVALID_HANDLE;

double bufSMA[];
double bufATR[];

//+------------------------------------------------------------------+
//| Init                                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   Trade.SetExpertMagicNumber(InpMagicNumber);
   Trade.SetDeviationInPoints(20);

   // Auto-detect filling mode (FOK → IOC → Return)
   uint fillFlags = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_FLAGS);
   if((fillFlags & SYMBOL_FILLING_FOK) != 0)
      Trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((fillFlags & SYMBOL_FILLING_IOC) != 0)
      Trade.SetTypeFilling(ORDER_FILLING_IOC);
   else
      Trade.SetTypeFilling(ORDER_FILLING_RETURN);

   hSMA = iMA(_Symbol, PERIOD_CURRENT, InpSMALen, 0, MODE_SMA, InpSMASrc);
   hATR = iATR(_Symbol, PERIOD_CURRENT, InpATRLen);

   if(hSMA == INVALID_HANDLE || hATR == INVALID_HANDLE)
     {
      Alert("Donchian_SMA_ATR EA: Failed to create indicator handles.");
      return INIT_FAILED;
     }

   ArraySetAsSeries(bufSMA, true);
   ArraySetAsSeries(bufATR, true);

   PrintFormat("Donchian_SMA_ATR EA ready | Symbol=%s | Magic=%d",
               _Symbol, InpMagicNumber);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Deinit                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(hSMA != INVALID_HANDLE) { IndicatorRelease(hSMA); hSMA = INVALID_HANDLE; }
   if(hATR != INVALID_HANDLE) { IndicatorRelease(hATR); hATR = INVALID_HANDLE; }
  }

//+------------------------------------------------------------------+
//| Return the applied-price value for a specific bar                |
//+------------------------------------------------------------------+
double GetAppliedPrice(int bar, ENUM_APPLIED_PRICE priceType)
  {
   double H = iHigh (_Symbol, PERIOD_CURRENT, bar);
   double L = iLow  (_Symbol, PERIOD_CURRENT, bar);
   double C = iClose(_Symbol, PERIOD_CURRENT, bar);
   double O = iOpen (_Symbol, PERIOD_CURRENT, bar);

   switch(priceType)
     {
      case PRICE_OPEN:     return O;
      case PRICE_HIGH:     return H;
      case PRICE_LOW:      return L;
      case PRICE_CLOSE:    return C;
      case PRICE_MEDIAN:   return (H + L) / 2.0;
      case PRICE_TYPICAL:  return (H + L + C) / 3.0;
      case PRICE_WEIGHTED: return (H + L + C + C) / 4.0;
      default:             return C;
     }
  }

//+------------------------------------------------------------------+
//| Donchian Upper Band                                              |
//|  Highest value of [src] over bars [startBar .. startBar+len-1]  |
//+------------------------------------------------------------------+
double DonchianUpper(int len, ENUM_APPLIED_PRICE src, int startBar)
  {
   double highest = -DBL_MAX;
   for(int i = startBar; i < startBar + len; i++)
     {
      double v = GetAppliedPrice(i, src);
      if(v > highest) highest = v;
     }
   return highest;
  }

//+------------------------------------------------------------------+
//| Donchian Lower Band                                              |
//|  Lowest value of [src] over bars [startBar .. startBar+len-1]   |
//+------------------------------------------------------------------+
double DonchianLower(int len, ENUM_APPLIED_PRICE src, int startBar)
  {
   double lowest = DBL_MAX;
   for(int i = startBar; i < startBar + len; i++)
     {
      double v = GetAppliedPrice(i, src);
      if(v < lowest) lowest = v;
     }
   return lowest;
  }

//+------------------------------------------------------------------+
//| Donchian Middle Band                                             |
//|  (max + min) / 2 of [src] over bars [startBar .. startBar+len-1]|
//+------------------------------------------------------------------+
double DonchianMiddle(int len, ENUM_APPLIED_PRICE src, int startBar)
  {
   double hi = -DBL_MAX, lo = DBL_MAX;
   for(int i = startBar; i < startBar + len; i++)
     {
      double v = GetAppliedPrice(i, src);
      if(v > hi) hi = v;
      if(v < lo) lo = v;
     }
   return (hi + lo) / 2.0;
  }

//+------------------------------------------------------------------+
//| Count open positions belonging to this EA on current symbol      |
//+------------------------------------------------------------------+
int CountOpenPositions()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PosInfo.SelectByIndex(i) &&
         PosInfo.Symbol() == _Symbol &&
         PosInfo.Magic()  == (long)InpMagicNumber)
         count++;
   return count;
  }

//+------------------------------------------------------------------+
//| Lot size so that SL distance risks exactly InpEquityRisk%        |
//|                                                                  |
//|  lots = RiskAmount / (SL_in_ticks × TickValue)                  |
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
   lots = MathMax(minLot, MathMin(maxLot, lots));
   return lots;
  }

//+------------------------------------------------------------------+
//| Manage trailing stop loss (called on every tick)                 |
//+------------------------------------------------------------------+
void ManageTrailingStop()
  {
   if(!InpTrailEnable) return;
   if(CopyBuffer(hATR, 0, 0, 2, bufATR) <= 0) return;

   double atr = bufATR[0]; // live ATR value

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!PosInfo.SelectByIndex(i)) continue;
      if(PosInfo.Symbol() != _Symbol || PosInfo.Magic() != (long)InpMagicNumber) continue;

      ulong  ticket     = PosInfo.Ticket();
      double openPx     = PosInfo.PriceOpen();
      double curSL      = PosInfo.StopLoss();
      double curTP      = PosInfo.TakeProfit();
      double origSLDist = MathAbs(openPx - curSL);  // SL distance locked at entry
      double bid        = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask        = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double newSL      = curSL;

      if(PosInfo.PositionType() == POSITION_TYPE_BUY)
        {
         if(InpTrailType == TRAIL_ATR)
            newSL = bid - atr * InpSLMultiplier;
         else // TRAIL_RR – activate only after 1R profit
            if(bid - openPx >= origSLDist)
               newSL = bid - origSLDist;

         newSL = NormalizeDouble(newSL, _Digits);
         if(newSL > curSL && newSL < bid)  // only move in profit direction
            Trade.PositionModify(ticket, newSL, curTP);
        }
      else if(PosInfo.PositionType() == POSITION_TYPE_SELL)
        {
         if(InpTrailType == TRAIL_ATR)
            newSL = ask + atr * InpSLMultiplier;
         else // TRAIL_RR – activate only after 1R profit
            if(openPx - ask >= origSLDist)
               newSL = ask + origSLDist;

         newSL = NormalizeDouble(newSL, _Digits);
         if(newSL < curSL && newSL > ask)  // only move in profit direction
            Trade.PositionModify(ticket, newSL, curTP);
        }
     }
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   //--- Trailing stop runs on every tick for responsiveness
   ManageTrailingStop();

   //--- Entry logic is evaluated only on the open of a new bar
   static datetime lastBarTime = 0;
   datetime curBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(curBarTime == lastBarTime) return;
   lastBarTime = curBarTime;

   //--- Only one position allowed at a time
   if(CountOpenPositions() > 0) return;

   //--- Load indicator buffers (index 0 = current forming bar, 1 = last closed bar)
   if(CopyBuffer(hSMA, 0, 0, 3, bufSMA) <= 0) return;
   if(CopyBuffer(hATR, 0, 0, 3, bufATR) <= 0) return;

   //--- Bar[1] values (last fully closed candle – avoids repainting)
   double closeB1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   double smaB1   = bufSMA[1];
   double atrB1   = bufATR[1];

   //--- Donchian channel: built from bars BEFORE Bar[1] (bars 2 … 2+N-1)
   //    This is the classic breakout check:
   //    "Did Bar[1] close beyond the previous N-bar extreme?"
   double dcUpper  = DonchianUpper (InpDCUpperLen, InpDCUpperSrc, 2);
   double dcLower  = DonchianLower (InpDCLowerLen, InpDCLowerSrc, 2);
   // double dcMiddle = DonchianMiddle(InpDCMidLen,  InpDCMidSrc,  2); // available if needed

   //--- SL and TP distances in price units
   double slDist   = atrB1 * InpSLMultiplier;
   double tpDist   = slDist * InpRRRatio;

   //--- Enforce broker minimum stop level
   double minStop  = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(slDist < minStop) slDist = minStop;
   if(tpDist < minStop) tpDist = minStop;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // ─── BUY SIGNAL ───────────────────────────────────────────────
   // Condition 1 (Trend)  : Bar[1] closed above SMA  → bullish bias
   // Condition 2 (Breakout): Bar[1] closed above the prior N-bar Donchian upper
   if(closeB1 > smaB1 && closeB1 > dcUpper)
     {
      double sl   = NormalizeDouble(ask - slDist, _Digits);
      double tp   = NormalizeDouble(ask + tpDist, _Digits);
      double lots = CalcLotSize(slDist);

      if(lots > 0.0)
        {
         if(Trade.Buy(lots, _Symbol, ask, sl, tp, "DC_BUY"))
            PrintFormat("[BUY]  lots=%.2f  SL=%.5f  TP=%.5f  ATR=%.5f  DC_Upper=%.5f",
                        lots, sl, tp, atrB1, dcUpper);
         else
            PrintFormat("[BUY FAILED] Error=%d  %s", GetLastError(), Trade.ResultComment());
        }
     }

   // ─── SELL SIGNAL ──────────────────────────────────────────────
   // Condition 1 (Trend)  : Bar[1] closed below SMA  → bearish bias
   // Condition 2 (Breakout): Bar[1] closed below the prior N-bar Donchian lower
   else if(closeB1 < smaB1 && closeB1 < dcLower)
     {
      double sl   = NormalizeDouble(bid + slDist, _Digits);
      double tp   = NormalizeDouble(bid - tpDist, _Digits);
      double lots = CalcLotSize(slDist);

      if(lots > 0.0)
        {
         if(Trade.Sell(lots, _Symbol, bid, sl, tp, "DC_SELL"))
            PrintFormat("[SELL] lots=%.2f  SL=%.5f  TP=%.5f  ATR=%.5f  DC_Lower=%.5f",
                        lots, sl, tp, atrB1, dcLower);
         else
            PrintFormat("[SELL FAILED] Error=%d  %s", GetLastError(), Trade.ResultComment());
        }
     }
  }
//+------------------------------------------------------------------+
