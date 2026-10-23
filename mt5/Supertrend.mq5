//+------------------------------------------------------------------+
//| Supertrend.mq5                                                   |
//| Gold Trade Logger: Supertrend matching TradingView's built-in    |
//| (ATR period 10, multiplier 3). The formula itself lives in       |
//| TradeLoggerCalc.mqh, shared with the Trade Recorder.             |
//+------------------------------------------------------------------+
#property copyright "Gold Trade Logger"
#property version   "1.00"
#property description "Supertrend, matching TradingView's built-in (ATR period 10, multiplier 3)."
#property indicator_chart_window
#property indicator_buffers 6
#property indicator_plots   3

#property indicator_label1  "Up trend"
#property indicator_type1   DRAW_LINE
#property indicator_color1  C'76,175,80'
#property indicator_width1  2

#property indicator_label2  "Down trend"
#property indicator_type2   DRAW_LINE
#property indicator_color2  C'255,82,82'
#property indicator_width2  2

// Shows in the Data Window (Ctrl+D) so you can check the direction of any candle.
#property indicator_label3  "Direction (1 up, -1 down)"
#property indicator_type3   DRAW_NONE

#include <GoldTradeLogger\TradeLoggerCalc.mqh>

input int    InpAtrPeriod = 10;    // ATR period
input double InpFactor    = 3.0;   // Multiplier

double UpLine[];
double DownLine[];
double Dir[];
double Atr[];
double Upper[];
double Lower[];

int OnInit()
  {
   if(InpAtrPeriod < 1 || InpFactor <= 0)
      return INIT_PARAMETERS_INCORRECT;
   SetIndexBuffer(0, UpLine, INDICATOR_DATA);
   SetIndexBuffer(1, DownLine, INDICATOR_DATA);
   SetIndexBuffer(2, Dir, INDICATOR_DATA);
   SetIndexBuffer(3, Atr, INDICATOR_CALCULATIONS);
   SetIndexBuffer(4, Upper, INDICATOR_CALCULATIONS);
   SetIndexBuffer(5, Lower, INDICATOR_CALCULATIONS);
   for(int p = 0; p < 3; p++)
      PlotIndexSetDouble(p, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   IndicatorSetString(INDICATOR_SHORTNAME, StringFormat("Supertrend (%d, %s)", InpAtrPeriod, DoubleToString(InpFactor, 1)));
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);
   return INIT_SUCCEEDED;
  }

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
   // Only redo the newest candle (it's still forming) and any new ones.
   int start = (prev_calculated > 0) ? prev_calculated - 1 : 0;
   GTL_Supertrend(start, rates_total, high, low, close, InpAtrPeriod, InpFactor, Atr, Upper, Lower, Dir);

   for(int i = start; i < rates_total; i++)
     {
      // One line per direction, with a gap where it flips, as on TradingView.
      UpLine[i]   = (Dir[i] > 0) ? Lower[i] : EMPTY_VALUE;
      DownLine[i] = (Dir[i] < 0) ? Upper[i] : EMPTY_VALUE;
      if(Dir[i] == 0)
         Dir[i] = EMPTY_VALUE;
     }
   return rates_total;
  }
//+------------------------------------------------------------------+
