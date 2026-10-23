//+------------------------------------------------------------------+
//| TradeLoggerCalc.mqh                                              |
//| Gold Trade Logger: Supertrend and ADX, worked out the same way   |
//| as TradingView's built-in indicators. Shared by our Supertrend   |
//| indicator, the Trade Recorder and (later) the bot, so they all   |
//| use one formula.                                                 |
//|                                                                  |
//| All arrays are in time order: index 0 is the OLDEST candle.      |
//| Direction: +1 = up (green), -1 = down (red), 0 = too few candles.|
//| (TradingView itself uses -1 for up; we use +1 because it reads   |
//| more naturally.)                                                 |
//+------------------------------------------------------------------+

#define GTL_NONE EMPTY_VALUE

// True range of candle i. The first candle has no previous close, so it's just high - low.
double GTL_TrueRange(const int i, const double &high[], const double &low[], const double &close[])
  {
   double tr = high[i] - low[i];
   if(i > 0)
      tr = MathMax(tr, MathMax(MathAbs(high[i] - close[i-1]), MathAbs(low[i] - close[i-1])));
   return tr;
  }

// Supertrend: TradingView's ta.supertrend(factor, atrPeriod) with source (high + low) / 2.
// ATR is Wilder's average (RMA) of the true range: a plain average of the first atrPeriod
// candles, then each new candle counts 1/atrPeriod.
// Works out candles from 'start' to count-1, using the stored results of the candle before
// 'start', so the chart indicator only needs to update the newest candles.
void GTL_Supertrend(const int start, const int count,
                    const double &high[], const double &low[], const double &close[],
                    const int atrPeriod, const double factor,
                    double &atr[], double &upper[], double &lower[], double &dir[])
  {
   for(int i = start; i < count; i++)
     {
      // Not enough candles for an ATR yet. TradingView treats the bands as 0 here.
      if(i < atrPeriod - 1)
        {
         atr[i] = GTL_NONE;
         upper[i] = 0;
         lower[i] = 0;
         dir[i] = 0;
         continue;
        }

      if(i == atrPeriod - 1 || i == 0)
        {
         double sum = 0;
         for(int k = 0; k <= i; k++)
            sum += GTL_TrueRange(k, high, low, close);
         atr[i] = sum / (i + 1);
        }
      else
         atr[i] = (atr[i-1] * (atrPeriod - 1) + GTL_TrueRange(i, high, low, close)) / atrPeriod;

      double mid = (high[i] + low[i]) / 2.0;
      double up  = mid + factor * atr[i];
      double lo  = mid - factor * atr[i];

      // Each band only moves towards price, unless the previous candle closed beyond it.
      if(i > 0)
        {
         if(!(lo > lower[i-1] || close[i-1] < lower[i-1]))
            lo = lower[i-1];
         if(!(up < upper[i-1] || close[i-1] > upper[i-1]))
            up = upper[i-1];
        }
      upper[i] = up;
      lower[i] = lo;

      // TradingView starts in a downtrend. After that, a close above the upper band turns
      // it up, and a close below the lower band turns it down.
      if(i == atrPeriod - 1 || i == 0)
         dir[i] = -1;
      else
         if(dir[i-1] < 0)
            dir[i] = (close[i] > up) ? 1 : -1;
         else
            dir[i] = (close[i] < lo) ? -1 : 1;
     }
  }

// The Supertrend line's price on candle i (the lower band in an uptrend, the upper band in a downtrend).
double GTL_SupertrendLine(const int i, const double &upper[], const double &lower[], const double &dir[])
  {
   if(dir[i] == 0)
      return GTL_NONE;
   return (dir[i] > 0) ? lower[i] : upper[i];
  }

// ADX: TradingView's built-in "Average Directional Index" (DI length and ADX smoothing,
// both 14 by default), using Wilder's averages. Fills adx[] for every candle. Candles
// without enough history before them get GTL_NONE.
void GTL_ADX(const int count, const double &high[], const double &low[], const double &close[],
             const int diLength, const int adxSmoothing, double &adx[])
  {
   ArrayResize(adx, count);
   double trAvg = 0, plusAvg = 0, minusAvg = 0;   // Wilder averages of TR, +DM and -DM
   double plusDI = 0, minusDI = 0;
   double dxSum = 0, adxAvg = 0;
   int dxCount = 0;

   for(int i = 0; i < count; i++)
     {
      adx[i] = GTL_NONE;
      if(i == 0)
         continue;   // the first candle has no previous candle to compare with

      double upMove   = high[i] - high[i-1];
      double downMove = low[i-1] - low[i];
      double plusDM   = (upMove > downMove && upMove > 0) ? upMove : 0;
      double minusDM  = (downMove > upMove && downMove > 0) ? downMove : 0;
      double tr       = GTL_TrueRange(i, high, low, close);

      // First average: a plain average of candles 1 to diLength. Then Wilder smoothing.
      if(i < diLength)
        {
         trAvg += tr;
         plusAvg += plusDM;
         minusAvg += minusDM;
         continue;
        }
      if(i == diLength)
        {
         trAvg = (trAvg + tr) / diLength;
         plusAvg = (plusAvg + plusDM) / diLength;
         minusAvg = (minusAvg + minusDM) / diLength;
        }
      else
        {
         trAvg = (trAvg * (diLength - 1) + tr) / diLength;
         plusAvg = (plusAvg * (diLength - 1) + plusDM) / diLength;
         minusAvg = (minusAvg * (diLength - 1) + minusDM) / diLength;
        }

      // If the range is zero, keep the previous DI values (TradingView's fixnan).
      if(trAvg > 0)
        {
         plusDI = 100 * plusAvg / trAvg;
         minusDI = 100 * minusAvg / trAvg;
        }
      double sum = plusDI + minusDI;
      double dx = MathAbs(plusDI - minusDI) / (sum == 0 ? 1 : sum);

      dxCount++;
      if(dxCount < adxSmoothing)
        {
         dxSum += dx;
         continue;
        }
      if(dxCount == adxSmoothing)
         adxAvg = (dxSum + dx) / adxSmoothing;
      else
         adxAvg = (adxAvg * (adxSmoothing - 1) + dx) / adxSmoothing;
      adx[i] = 100 * adxAvg;
     }
  }
//+------------------------------------------------------------------+
