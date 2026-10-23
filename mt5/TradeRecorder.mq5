//+------------------------------------------------------------------+
//| TradeRecorder.mq5                                                |
//| Gold Trade Logger: reads this account's gold trades from MT5     |
//| history, works out Supertrend and ADX at each entry, and writes  |
//| everything to the Experts log and two CSV files in               |
//| MQL5\Files\GoldTradeLogger.                                      |
//| Task 13: it also saves two chart screenshots per trade (at entry |
//| and at close) to MQL5\Files\GoldTradeLogger\shots_<login>.       |
//| It sends nothing to the app yet. It never places, changes or     |
//| closes a trade.                                                  |
//+------------------------------------------------------------------+
#property copyright "Gold Trade Logger"
#property version   "1.10"
#property description "Reads gold trades from history and writes them, with Supertrend and ADX at entry, to MQL5\\Files\\GoldTradeLogger, plus a 15m chart screenshot at each entry and close. It never trades."

#include <GoldTradeLogger\TradeLoggerCalc.mqh>

input string InpSymbol       = "";    // Gold symbol (empty = this chart's symbol)
input int    InpAtrPeriod    = 10;    // Supertrend ATR period
input double InpFactor       = 3.0;   // Supertrend multiplier
input int    InpAdxLength    = 14;    // ADX length (DI length and smoothing)
input double InpAdxThreshold = 20;    // Rule 3: 1H ADX above this
input int    InpFlipWindow   = 8;     // Rule 2: 15m flipped within this many closed candles
input double InpMinRR        = 2.0;   // Rule 4: risk:reward at least 1:N
input bool   InpScreenshots  = true;  // Save chart screenshots at entry and close
input string InpTemplate     = "";    // Chart template for screenshots (empty = Supertrend and ADX only)
input int    InpShotWidth    = 1600;  // Screenshot width in pixels (the app's limit is 1920)
input int    InpShotHeight   = 900;   // Screenshot height in pixels
input bool   InpRedoShots    = false; // Redo screenshots that already exist

#define CANDLES_WANTED 1000   // candles worked through before each entry, so the readings settle
#define CANDLES_NEEDED 300    // with fewer than this, the readings aren't trusted
#define MAX_ATTEMPTS   30     // seconds to wait for MT5 to connect and download old candles
#define SA_UTC_OFFSET  2      // South Africa is UTC+2 all year
#define MAX_SHOT_SIZE  1920   // the app shrinks images to at most this many pixels
#define CHART_WAIT_MS  15000  // how long to wait for the screenshot chart to load
#define SHOT_STEP_MS   300    // time between screenshot steps, so MT5 can redraw the chart
#define PRICE_SCALE_PX 76     // width of the price scale on the right of the image
#define MARK_PREFIX    "GTL " // our own marks on the screenshot chart start with this

// One MT5 position (a trade), built up from its deals.
struct Trade
  {
   ulong             position;
   int               dir;                // +1 buy, -1 sell
   datetime          openTime;
   datetime          closeTime;
   double            inLots, inValue;    // lots, and lots x price, of the opening deals
   double            outLots, outValue;  // the same for the closing deals
   double            profit, commission, swap;
   double            slEntry, tpEntry;   // stop and target on the opening deal
   double            slLater, tpLater;   // on the last closing deal, or now if still open
   long              openReason, closeReason;
   bool              isOpen;
   bool              reversal;
  };

// Indicator readings from the last closed candles before the entry.
struct Reading
  {
   bool              ok;
   datetime          h1Candle, m15Candle;   // open times (MT5 server time) of the candles used
   int               h1Dir, m15Dir;
   int               sinceFlip;             // 1 = the 15m flipped on the last closed candle
   double            adxH1;
   string            problem;
  };

// One screenshot still to take.
struct ShotJob
  {
   Trade             t;
   Reading           r;
   bool              atClose;   // false = the image at entry
  };

string g_symbol;
int    g_digits;
int    g_serverUtcOffset;   // hours ahead of UTC (Exness: 0)
int    g_attempts = 0;

// Screenshot progress. MT5 only redraws a chart between our timer events, so each image
// takes two: one to scroll and draw the marks, the next to save the image.
long    g_shotChart = 0;
int     g_shotHandles[];
ShotJob g_shotJobs[];
int     g_shotNext = 0;
bool    g_shotReady = false;   // the next image has been drawn and is ready to save
int     g_shotSaved = 0, g_shotFailed = 0, g_shotLines = 0;
string  g_shotFolder;

//+------------------------------------------------------------------+
int OnInit()
  {
   g_symbol = (InpSymbol == "") ? _Symbol : InpSymbol;
   if(!SymbolSelect(g_symbol, true))
     {
      Print("Trade Recorder: can't find the symbol ", g_symbol);
      return INIT_PARAMETERS_INCORRECT;
     }
   if(StringFind(g_symbol, "XAU") < 0 && StringFind(g_symbol, "GOLD") < 0)
      Print("Trade Recorder: warning, ", g_symbol, " doesn't look like gold");
   g_digits = (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);

   // Start a second later, then retry once a second while MT5 connects and loads old candles.
   Print("Trade Recorder: started on ", g_symbol, ", reading history...");
   EventSetTimer(1);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_shotChart != 0)
      FinishScreenshots();
  }

void OnTick()
  {
  }

void OnTimer()
  {
   if(g_shotChart != 0)
     {
      ScreenshotStep();
      return;
     }
   g_attempts++;
   if(g_attempts == 1 || g_attempts % 10 == 0)
      Print("Trade Recorder: attempt ", g_attempts, " of ", MAX_ATTEMPTS);
   if(RunCatchUp(g_attempts >= MAX_ATTEMPTS))
     {
      if(g_shotChart != 0)
         EventSetMillisecondTimer(SHOT_STEP_MS);   // screenshots next, a step at a time
      else
         EventKillTimer();
     }
  }

//+------------------------------------------------------------------+
//| Reads everything and writes it out. Returns false if MT5 isn't   |
//| ready yet (not connected, or candles still downloading), unless  |
//| this is the last attempt, when it writes what it has.            |
//+------------------------------------------------------------------+
bool RunCatchUp(const bool lastAttempt)
  {
   if(!TerminalInfoInteger(TERMINAL_CONNECTED) && !lastAttempt)
      return false;
   g_serverUtcOffset = (int)MathRound((double)(TimeTradeServer() - TimeGMT()) / 3600.0);

   Trade trades[];
   double startBalance = 0;
   datetime startTime = 0;
   int laterBalanceOps = 0;
   if(!LoadHistory(trades, startBalance, startTime, laterBalanceOps))
     {
      if(!lastAttempt)
         return false;
      Print("Trade Recorder: couldn't read the account history");
     }

   int count = ArraySize(trades);
   Reading readings[];
   ArrayResize(readings, count);
   for(int i = 0; i < count; i++)
     {
      if(!ReadAtEntry(trades[i].openTime, readings[i]) && !lastAttempt)
         return false;   // candles still downloading; try again in a second
     }

   WriteTrades(trades, readings);
   WriteAccount(startBalance, startTime, laterBalanceOps, count);
   if(InpScreenshots)
      StartScreenshots(trades, readings);
   return true;
  }

//+------------------------------------------------------------------+
//| Groups the account's gold deals into trades, and finds the first |
//| deposit (the starting balance).                                  |
//+------------------------------------------------------------------+
bool LoadHistory(Trade &trades[], double &startBalance, datetime &startTime, int &laterBalanceOps)
  {
   if(!HistorySelect(0, TimeCurrent() + 86400))
      return false;

   int total = HistoryDealsTotal();
   int balanceOps = 0;
   for(int i = 0; i < total; i++)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;
      long type = HistoryDealGetInteger(deal, DEAL_TYPE);
      datetime when = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);

      // Deposits and withdrawals. The earliest deposit is the starting balance.
      if(type == DEAL_TYPE_BALANCE)
        {
         balanceOps++;
         double amount = HistoryDealGetDouble(deal, DEAL_PROFIT);
         if(amount > 0 && (startTime == 0 || when < startTime))
           {
            startBalance = amount;
            startTime = when;
           }
         continue;
        }

      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL)
         continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != g_symbol)
         continue;

      int k = FindOrAddTrade(trades, (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID));
      long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
      double lots = HistoryDealGetDouble(deal, DEAL_VOLUME);
      double price = HistoryDealGetDouble(deal, DEAL_PRICE);

      // P&L as MT5 reports it: profit plus commission, swap and fees on every deal of the trade.
      trades[k].profit += HistoryDealGetDouble(deal, DEAL_PROFIT);
      trades[k].commission += HistoryDealGetDouble(deal, DEAL_COMMISSION) + HistoryDealGetDouble(deal, DEAL_FEE);
      trades[k].swap += HistoryDealGetDouble(deal, DEAL_SWAP);

      if(entry == DEAL_ENTRY_IN)
        {
         if(trades[k].inLots == 0)
           {
            trades[k].dir = (type == DEAL_TYPE_BUY) ? 1 : -1;
            trades[k].openTime = when;
            trades[k].slEntry = HistoryDealGetDouble(deal, DEAL_SL);
            trades[k].tpEntry = HistoryDealGetDouble(deal, DEAL_TP);
            trades[k].openReason = HistoryDealGetInteger(deal, DEAL_REASON);
           }
         trades[k].inLots += lots;
         trades[k].inValue += lots * price;
        }
      else
        {
         if(entry == DEAL_ENTRY_INOUT)
            trades[k].reversal = true;
         trades[k].outLots += lots;
         trades[k].outValue += lots * price;
         trades[k].closeTime = when;
         trades[k].slLater = HistoryDealGetDouble(deal, DEAL_SL);
         trades[k].tpLater = HistoryDealGetDouble(deal, DEAL_TP);
         trades[k].closeReason = HistoryDealGetInteger(deal, DEAL_REASON);
        }
     }
   laterBalanceOps = (startTime > 0) ? balanceOps - 1 : balanceOps;

   // Trades still open: use their stop and target as they are now.
   for(int k = 0; k < ArraySize(trades); k++)
     {
      if(PositionSelectByTicket(trades[k].position))
        {
         trades[k].isOpen = true;
         trades[k].slLater = PositionGetDouble(POSITION_SL);
         trades[k].tpLater = PositionGetDouble(POSITION_TP);
        }
     }
   return true;
  }

int FindOrAddTrade(Trade &trades[], const ulong position)
  {
   int n = ArraySize(trades);
   for(int k = 0; k < n; k++)
      if(trades[k].position == position)
         return k;
   ArrayResize(trades, n + 1);
   ZeroMemory(trades[n]);
   trades[n].position = position;
   return n;
  }

//+------------------------------------------------------------------+
//| Supertrend and ADX at entry, from the last CLOSED candles before |
//| the entry time (never the candle that was still forming).        |
//| Returns false if MT5 doesn't have enough candles yet.            |
//+------------------------------------------------------------------+
bool ReadAtEntry(const datetime entry, Reading &r)
  {
   ZeroMemory(r);
   r.adxH1 = GTL_NONE;
   r.problem = "";
   if(entry == 0)
     {
      r.problem = "no opening deal found";
      return true;
     }

   MqlRates h1[], m15[];
   int nh = GetCandles(PERIOD_H1, entry, h1);
   int nm = GetCandles(PERIOD_M15, entry, m15);
   if(nh < CANDLES_NEEDED || nm < CANDLES_NEEDED)
     {
      r.problem = StringFormat("only %d 1H and %d 15m candles before entry, so no readings", MathMax(nh, 0), MathMax(nm, 0));
      return false;
     }

   double high[], low[], close[], atr[], upper[], lower[], dir[], adx[];

   // 1H: Supertrend direction and ADX.
   SplitCandles(h1, nh, high, low, close, atr, upper, lower, dir);
   GTL_Supertrend(0, nh, high, low, close, InpAtrPeriod, InpFactor, atr, upper, lower, dir);
   GTL_ADX(nh, high, low, close, InpAdxLength, InpAdxLength, adx);
   r.h1Candle = h1[nh - 1].time;
   r.h1Dir = (int)dir[nh - 1];
   r.adxH1 = adx[nh - 1];

   // 15m: Supertrend direction, and how many closed candles it has pointed that way.
   SplitCandles(m15, nm, high, low, close, atr, upper, lower, dir);
   GTL_Supertrend(0, nm, high, low, close, InpAtrPeriod, InpFactor, atr, upper, lower, dir);
   r.m15Candle = m15[nm - 1].time;
   r.m15Dir = (int)dir[nm - 1];
   int k = 0;
   while(k < nm && dir[nm - 1 - k] == dir[nm - 1])
      k++;
   r.sinceFlip = k;

   r.ok = true;
   return true;
  }

// Copies up to CANDLES_WANTED candles, oldest first, ending with the last one that had
// closed at the entry time.
int GetCandles(const ENUM_TIMEFRAMES tf, const datetime entry, MqlRates &rates[])
  {
   int secs = PeriodSeconds(tf);
   datetime lastClosed = entry - entry % secs - secs;   // open time of that candle
   ArraySetAsSeries(rates, false);
   int got = CopyRates(g_symbol, tf, lastClosed, CANDLES_WANTED, rates);
   if(got > 0 && rates[got - 1].time > lastClosed)
      return -1;   // shouldn't happen: never use a candle that was still forming
   return got;
  }

void SplitCandles(const MqlRates &rates[], const int n, double &high[], double &low[], double &close[],
                  double &atr[], double &upper[], double &lower[], double &dir[])
  {
   ArrayResize(high, n);
   ArrayResize(low, n);
   ArrayResize(close, n);
   ArrayResize(atr, n);
   ArrayResize(upper, n);
   ArrayResize(lower, n);
   ArrayResize(dir, n);
   for(int i = 0; i < n; i++)
     {
      high[i] = rates[i].high;
      low[i] = rates[i].low;
      close[i] = rates[i].close;
     }
  }

//+------------------------------------------------------------------+
//| Writes one row per trade to the CSV and one line to the log.     |
//+------------------------------------------------------------------+
void WriteTrades(const Trade &trades[], const Reading &readings[])
  {
   long login = AccountInfoInteger(ACCOUNT_LOGIN);
   string fileName = StringFormat("GoldTradeLogger\\trades_%I64d.csv", login);
   int file = FileOpen(fileName, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(file == INVALID_HANDLE)
      Print("Trade Recorder: can't write ", fileName, " (is it open in Excel? Close it and run again)");

   // Semicolons and comma decimals, because the owner's Excel (South Africa) needs them.
   WriteLine(file, "Position;Status;Symbol;Direction;Placed from;Open time (SA);Open time (MT5);"
             "Close time (SA);Close time (MT5);Closed by;Lots;Entry;Stop;Target;Stop and target from;"
             "Close price;Profit $;Commission $;Swap $;P&L $;Risk $;Planned risk:reward;"
             "1H Supertrend;15m Supertrend;15m candles since flip;1H ADX;"
             "1H candle used (SA);15m candle used (SA);"
             "Tick 1: 1H bias;Tick 2: 15m flip;Tick 3: ADX;Tick 4: risk:reward;Notes");

   Print(StringFormat("Trade Recorder: account %I64d, %s, %d gold trades. Times are SA (MT5 server is UTC%+d).",
                      login, g_symbol, ArraySize(trades), g_serverUtcOffset));

   for(int i = 0; i < ArraySize(trades); i++)
     {
      Trade t = trades[i];
      Reading r = readings[i];
      string notes = r.problem;

      if(t.inLots <= 0)
        {
         // Only the position, symbol and notes (columns 1, 3 and 33).
         string row = StringFormat("%I64u;;%s", t.position, g_symbol);
         for(int c = 4; c <= 33; c++)
            row += ";";
         WriteLine(file, row + notes);
         continue;
        }
      if(t.reversal)
         AddNote(notes, "position was reversed in one deal, check by hand");

      double lots = t.inLots;
      double entry = t.inValue / t.inLots;
      double closePrice = (!t.isOpen && t.outLots > 0) ? t.outValue / t.outLots : GTL_NONE;
      double pnl = t.isOpen ? GTL_NONE : t.profit + t.commission + t.swap;

      // Stop and target: as placed with the trade if set then, otherwise as they were at the
      // close (or now, if still open).
      double stop = (t.slEntry > 0) ? t.slEntry : t.slLater;
      double target = (t.tpEntry > 0) ? t.tpEntry : t.tpLater;
      string later = t.isOpen ? "now" : "at close";
      string from = "";
      if(stop > 0 || target > 0)
        {
         if((stop <= 0 || t.slEntry > 0) && (target <= 0 || t.tpEntry > 0))
            from = "at entry";
         else
            if(t.slEntry <= 0 && t.tpEntry <= 0)
               from = later;
            else
               from = (t.slEntry > 0) ? "stop at entry, target " + later : "target at entry, stop " + later;
        }

      // Risk in $ if the stop is hit, and the planned risk:reward. Left empty, not guessed,
      // when there's no stop or no target.
      double risk = GTL_NONE, rr = GTL_NONE;
      if(stop > 0)
        {
         double p = 0;
         if(OrderCalcProfit(t.dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, g_symbol, lots, entry, stop, p) && p < 0)
            risk = -p;
         else
            AddNote(notes, "stop at or past entry, so no risk");
        }
      else
         AddNote(notes, "no stop");
      if(target <= 0)
         AddNote(notes, "no target");
      else
         if(risk != GTL_NONE)
           {
            if((target - entry) * t.dir > 0)
               rr = MathAbs(target - entry) / MathAbs(entry - stop);
            else
               AddNote(notes, "target on the wrong side of entry");
           }

      // The four pre-ticks. The owner confirms or changes them in the app (Task 16).
      bool tick1 = r.ok && r.h1Dir == t.dir;
      bool tick2 = r.ok && r.m15Dir == t.dir && r.sinceFlip <= InpFlipWindow;
      bool tick3 = r.ok && r.adxH1 != GTL_NONE && r.adxH1 > InpAdxThreshold;
      bool tick4 = rr != GTL_NONE && rr >= InpMinRR - 1e-9;
      if(t.isOpen)
         AddNote(notes, "still open");

      WriteLine(file, StringFormat("%I64u;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s",
                t.position,
                t.isOpen ? "open" : "closed",
                g_symbol,
                t.dir > 0 ? "buy" : "sell",
                Origin(t.openReason),
                When(ToSA(t.openTime)), When(t.openTime),
                t.isOpen ? "" : When(ToSA(t.closeTime)), t.isOpen ? "" : When(t.closeTime),
                t.isOpen ? "" : Origin(t.closeReason),
                Num(lots, 2), Num(entry, g_digits),
                stop > 0 ? Num(stop, g_digits) : "", target > 0 ? Num(target, g_digits) : "", from,
                Num(closePrice, g_digits),
                t.isOpen ? "" : Num(t.profit, 2), t.isOpen ? "" : Num(t.commission, 2), t.isOpen ? "" : Num(t.swap, 2),
                Num(pnl, 2), Num(risk, 2), Num(rr, 2),
                r.ok ? UpDown(r.h1Dir) : "", r.ok ? UpDown(r.m15Dir) : "",
                r.ok ? IntegerToString(r.sinceFlip) : "", r.ok ? Num(r.adxH1, 2) : "",
                r.ok ? When(ToSA(r.h1Candle)) : "", r.ok ? When(ToSA(r.m15Candle)) : "",
                YesNo(tick1), YesNo(tick2), YesNo(tick3), YesNo(tick4),
                notes));

      Print(StringFormat("Trade Recorder: #%I64u %s %s %.2f lots (placed from %s), open %s, entry %s, stop %s, target %s, %s, "
                         "P&L %s $, risk %s $, risk:reward %s, 1H %s, 15m %s (%d candles since flip), 1H ADX %s, ticks %s %s %s %s%s",
                         t.position, t.isOpen ? "OPEN" : "closed", t.dir > 0 ? "buy" : "sell", lots, Origin(t.openReason),
                         When(ToSA(t.openTime)), DoubleToString(entry, g_digits),
                         stop > 0 ? DoubleToString(stop, g_digits) : "-", target > 0 ? DoubleToString(target, g_digits) : "-",
                         t.isOpen ? "still open" : "closed " + When(ToSA(t.closeTime)) + " at " + DoubleToString(closePrice, g_digits) + " by " + Origin(t.closeReason),
                         pnl != GTL_NONE ? DoubleToString(pnl, 2) : "-", risk != GTL_NONE ? DoubleToString(risk, 2) : "-",
                         rr != GTL_NONE ? DoubleToString(rr, 2) : "-",
                         UpDown(r.h1Dir), UpDown(r.m15Dir), r.sinceFlip,
                         r.adxH1 != GTL_NONE ? DoubleToString(r.adxH1, 2) : "-",
                         YesNo(tick1), YesNo(tick2), YesNo(tick3), YesNo(tick4),
                         notes != "" ? " (" + notes + ")" : ""));
     }

   if(file != INVALID_HANDLE)
     {
      FileClose(file);
      Print("Trade Recorder: wrote MQL5\\Files\\", fileName);
     }
  }

// The account's balance and starting balance, to a second small CSV and the log.
void WriteAccount(const double startBalance, const datetime startTime, const int laterBalanceOps, const int tradeCount)
  {
   long login = AccountInfoInteger(ACCOUNT_LOGIN);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   datetime nowSA = TimeGMT() + SA_UTC_OFFSET * 3600;

   string fileName = StringFormat("GoldTradeLogger\\account_%I64d.csv", login);
   int file = FileOpen(fileName, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(file == INVALID_HANDLE)
      Print("Trade Recorder: can't write ", fileName, " (is it open in Excel? Close it and run again)");
   WriteLine(file, "Item;Value");
   WriteLine(file, StringFormat("Account;%I64d", login));
   WriteLine(file, "Server;" + AccountInfoString(ACCOUNT_SERVER));
   WriteLine(file, "Currency;" + AccountInfoString(ACCOUNT_CURRENCY));
   WriteLine(file, "Balance $;" + Num(balance, 2));
   WriteLine(file, "Balance time (SA);" + When(nowSA));
   WriteLine(file, "Starting balance $ (first deposit);" + (startTime > 0 ? Num(startBalance, 2) : ""));
   WriteLine(file, "First deposit time (SA);" + When(startTime > 0 ? ToSA(startTime) : 0));
   WriteLine(file, "Later deposits or withdrawals;" + IntegerToString(laterBalanceOps));
   WriteLine(file, StringFormat("MT5 server time zone;UTC%+d", g_serverUtcOffset));
   WriteLine(file, "Gold trades found;" + IntegerToString(tradeCount));
   if(file != INVALID_HANDLE)
     {
      FileClose(file);
      Print("Trade Recorder: wrote MQL5\\Files\\", fileName);
     }

   Print(StringFormat("Trade Recorder: balance %.2f %s at %s SA. Starting balance %s (first deposit %s SA), %d later deposits or withdrawals.",
                      balance, AccountInfoString(ACCOUNT_CURRENCY), When(nowSA),
                      startTime > 0 ? DoubleToString(startBalance, 2) : "not found",
                      When(startTime > 0 ? ToSA(startTime) : 0), laterBalanceOps));
  }

//+------------------------------------------------------------------+
//| Screenshots. Opens one extra gold 15m chart, copies the owner's  |
//| drawn lines onto it from their other gold charts, then for each  |
//| trade scrolls it so the entry candle (then the close candle) is  |
//| the last one showing, marks entry and exit, and saves a PNG.     |
//| Images that already exist are skipped, so a later run only adds  |
//| new trades and the close image of trades that were still open.   |
//| The chart shows lines as they are NOW, so a line drawn after the |
//| trade shows too.                                                 |
//+------------------------------------------------------------------+
#define SHOT_ZOOM    4                   // MT5 chart zoom 0-5: 4 = 16 pixels per candle
#define ENTRY_COLOR  C'33,150,243'       // blue
#define WIN_COLOR    C'46,160,67'        // green
#define LOSS_COLOR   C'229,57,53'        // red

// Lists the missing images and opens the chart. OnTimer then calls ScreenshotStep.
void StartScreenshots(const Trade &trades[], const Reading &readings[])
  {
   g_shotFolder = StringFormat("GoldTradeLogger\\shots_%I64d", AccountInfoInteger(ACCOUNT_LOGIN));
   ArrayResize(g_shotJobs, 0);
   for(int i = 0; i < ArraySize(trades); i++)
     {
      if(NeedEntryShot(g_shotFolder, trades[i]))
         AddShotJob(trades[i], readings[i], false);
      if(NeedCloseShot(g_shotFolder, trades[i]))
         AddShotJob(trades[i], readings[i], true);
     }
   if(ArraySize(g_shotJobs) == 0)
     {
      Print("Trade Recorder: every trade already has its screenshots in MQL5\\Files\\", g_shotFolder);
      return;
     }
   FolderCreate(g_shotFolder);

   g_shotChart = OpenShotChart(g_shotHandles);
   if(g_shotChart == 0)
      return;
   g_shotLines = CopyOwnerLines(g_shotChart);
   g_shotNext = 0;
   g_shotReady = false;
   g_shotSaved = 0;
   g_shotFailed = 0;
  }

void AddShotJob(const Trade &t, const Reading &r, const bool atClose)
  {
   int n = ArraySize(g_shotJobs);
   ArrayResize(g_shotJobs, n + 1);
   g_shotJobs[n].t = t;
   g_shotJobs[n].r = r;
   g_shotJobs[n].atClose = atClose;
  }

// One step: either scroll and draw the next image, or save the one drawn last time.
void ScreenshotStep()
  {
   if(g_shotNext >= ArraySize(g_shotJobs))
     {
      EventKillTimer();
      FinishScreenshots();
      return;
     }
   ShotJob job = g_shotJobs[g_shotNext];
   string file = ShotFile(g_shotFolder, job.t, job.atClose ? "close" : "entry");
   if(!g_shotReady)
     {
      if(DrawShot(g_shotChart, job))
         g_shotReady = true;
      else
        {
         g_shotFailed++;
         g_shotNext++;
        }
      return;
     }

   if(ChartScreenShot(g_shotChart, file, ShotWidth(), ShotHeight(), ALIGN_LEFT))
      g_shotSaved++;
   else
     {
      Print("Trade Recorder: couldn't save ", file, " (error ", GetLastError(), ")");
      g_shotFailed++;
     }
   g_shotReady = false;
   g_shotNext++;
  }

void FinishScreenshots()
  {
   ChartClose(g_shotChart);
   g_shotChart = 0;
   for(int k = 0; k < ArraySize(g_shotHandles); k++)
      IndicatorRelease(g_shotHandles[k]);
   ArrayResize(g_shotHandles, 0);
   Print(StringFormat("Trade Recorder: saved %d screenshots (%d x %d) to MQL5\\Files\\%s, with %d of your drawn lines copied from your %s charts.%s",
                      g_shotSaved, ShotWidth(), ShotHeight(), g_shotFolder, g_shotLines, g_symbol,
                      g_shotFailed > 0 ? StringFormat(" %d couldn't be taken, see above.", g_shotFailed) : ""));
  }

// Rounded down so the candles fill the image exactly (32 px is a multiple of every zoom's
// candle width). Otherwise a sliver of the candle after the entry would show.
int ShotWidth()
  {
   int candles = MathMin(InpShotWidth, MAX_SHOT_SIZE) - PRICE_SCALE_PX;
   return PRICE_SCALE_PX + candles - candles % 32;
  }

int ShotHeight()
  {
   return MathMin(InpShotHeight, MAX_SHOT_SIZE);
  }

bool NeedEntryShot(const string folder, const Trade &t)
  {
   return t.inLots > 0 && (InpRedoShots || !FileIsExist(ShotFile(folder, t, "entry")));
  }

bool NeedCloseShot(const string folder, const Trade &t)
  {
   return t.inLots > 0 && !t.isOpen && (InpRedoShots || !FileIsExist(ShotFile(folder, t, "close")));
  }

string ShotFile(const string folder, const Trade &t, const string kind)
  {
   return StringFormat("%s\\%I64u_%s.png", folder, t.position, kind);
  }

// Opens the 15m chart, with the owner's template if one is set, and makes sure it has
// Supertrend and ADX. Returns 0 if it can't.
long OpenShotChart(int &handles[])
  {
   long chart = ChartOpen(g_symbol, PERIOD_M15);
   if(chart == 0)
     {
      Print("Trade Recorder: couldn't open a chart for screenshots (error ", GetLastError(), ")");
      return 0;
     }
   if(InpTemplate != "")
     {
      if(!ChartApplyTemplate(chart, InpTemplate))
         Print("Trade Recorder: couldn't use the template ", InpTemplate, " (error ", GetLastError(), "), using the plain chart");
      ChartSetSymbolPeriod(chart, g_symbol, PERIOD_M15);   // in case the template has another timeframe
      // Reading a chart property waits for the template to finish loading.
      string expert = ChartGetString(chart, CHART_EXPERT_NAME);
      if(expert != "")
        {
         Print("Trade Recorder: the template ", InpTemplate, " has an Expert Advisor in it (", expert, "). Save it again from a chart without the recorder.");
         ChartClose(chart);
         return 0;
        }
     }

   if(InpTemplate == "")
      ChartSetInteger(chart, CHART_MODE, CHART_CANDLES);
   ChartSetInteger(chart, CHART_AUTOSCROLL, false);
   ChartSetInteger(chart, CHART_SHIFT, false);
   ChartSetInteger(chart, CHART_SHOW_ONE_CLICK, false);
   ChartSetInteger(chart, CHART_SHOW_TRADE_LEVELS, false);
   ChartSetInteger(chart, CHART_SHOW_TRADE_HISTORY, false);   // MT5's own arrows for every trade; ours are clearer

   if(!ChartHasIndicator(chart, "supertrend"))
      AddIndicator(chart, 0, iCustom(g_symbol, PERIOD_M15, "GoldTradeLogger\\Supertrend", InpAtrPeriod, InpFactor), handles);
   if(!ChartHasIndicator(chart, "adx"))
      AddIndicator(chart, (int)ChartGetInteger(chart, CHART_WINDOWS_TOTAL), iADXWilder(g_symbol, PERIOD_M15, InpAdxLength), handles);

   if(!WaitForChart(chart))
     {
      Print("Trade Recorder: the screenshot chart didn't finish loading in ", CHART_WAIT_MS / 1000, " seconds, so no screenshots this time");
      ChartClose(chart);
      for(int k = 0; k < ArraySize(handles); k++)
         IndicatorRelease(handles[k]);
      return 0;
     }
   return chart;
  }

bool ChartHasIndicator(const long chart, const string part)
  {
   int windows = (int)ChartGetInteger(chart, CHART_WINDOWS_TOTAL);
   for(int w = 0; w < windows; w++)
      for(int k = 0; k < ChartIndicatorsTotal(chart, w); k++)
        {
         string name = ChartIndicatorName(chart, w, k);
         StringToLower(name);
         if(StringFind(name, part) >= 0)
            return true;
        }
   return false;
  }

void AddIndicator(const long chart, const int window, const int handle, int &handles[])
  {
   if(handle == INVALID_HANDLE || !ChartIndicatorAdd(chart, window, handle))
     {
      Print("Trade Recorder: couldn't add an indicator to the screenshot chart (error ", GetLastError(), ")");
      return;
     }
   int n = ArraySize(handles);
   ArrayResize(handles, n + 1);
   handles[n] = handle;
  }

// Waits until the chart has its candles and every indicator on it has worked them all out.
bool WaitForChart(const long chart)
  {
   uint started = GetTickCount();
   while(GetTickCount() - started < CHART_WAIT_MS && !IsStopped())
     {
      int bars = Bars(g_symbol, PERIOD_M15);
      bool ready = bars > 0 && ChartGetInteger(chart, CHART_VISIBLE_BARS) > 0;
      int windows = (int)ChartGetInteger(chart, CHART_WINDOWS_TOTAL);
      for(int w = 0; w < windows && ready; w++)
         for(int k = 0; k < ChartIndicatorsTotal(chart, w) && ready; k++)
           {
            int h = ChartIndicatorGet(chart, w, ChartIndicatorName(chart, w, k));
            if(h != INVALID_HANDLE)
              {
               ready = BarsCalculated(h) >= bars;
               IndicatorRelease(h);
              }
           }
      if(ready)
         return true;
      Sleep(200);
     }
   return false;
  }

// Copies every line, Fibonacci and other drawing from the owner's other charts of this
// symbol (any timeframe) onto the screenshot chart. Skips MT5's own trade arrows.
int CopyOwnerLines(const long shotChart)
  {
   int copied = 0;
   for(long c = ChartFirst(); c >= 0; c = ChartNext(c))
     {
      if(c == shotChart || ChartSymbol(c) != g_symbol)
         continue;
      for(int i = ObjectsTotal(c, 0) - 1; i >= 0; i--)
        {
         string name = ObjectName(c, i, 0);
         if(StringFind(name, MARK_PREFIX) == 0 || StringFind(name, "autotrade") == 0 ||
            ObjectGetInteger(c, name, OBJPROP_HIDDEN) || ObjectFind(shotChart, name) >= 0)
            continue;
         if(CopyObject(c, shotChart, name))
            copied++;
        }
     }
   return copied;
  }

bool CopyObject(const long from, const long to, const string name)
  {
   ENUM_OBJECT type = (ENUM_OBJECT)ObjectGetInteger(from, name, OBJPROP_TYPE);
   if(!ObjectCreate(to, name, type, 0, (datetime)ObjectGetInteger(from, name, OBJPROP_TIME, 0), ObjectGetDouble(from, name, OBJPROP_PRICE, 0)))
      return false;

   // The second and third anchor points, where the drawing has them.
   long l;
   double d;
   for(int p = 1; p < 3; p++)
     {
      if(ObjectGetInteger(from, name, OBJPROP_TIME, p, l))
         ObjectSetInteger(to, name, OBJPROP_TIME, p, l);
      if(ObjectGetDouble(from, name, OBJPROP_PRICE, p, d))
         ObjectSetDouble(to, name, OBJPROP_PRICE, p, d);
     }

   // Look and settings. A property a drawing doesn't have is just ignored.
   ENUM_OBJECT_PROPERTY_INTEGER ints[] = {OBJPROP_COLOR, OBJPROP_STYLE, OBJPROP_WIDTH, OBJPROP_BACK, OBJPROP_FILL,
                                          OBJPROP_RAY_LEFT, OBJPROP_RAY_RIGHT, OBJPROP_RAY, OBJPROP_ELLIPSE,
                                          OBJPROP_ARROWCODE, OBJPROP_ANCHOR, OBJPROP_TIMEFRAMES, OBJPROP_FONTSIZE,
                                          OBJPROP_DIRECTION, OBJPROP_DEGREE, OBJPROP_DRAWLINES,
                                          OBJPROP_XDISTANCE, OBJPROP_YDISTANCE, OBJPROP_XSIZE, OBJPROP_YSIZE,
                                          OBJPROP_CORNER, OBJPROP_BGCOLOR, OBJPROP_BORDER_TYPE, OBJPROP_BORDER_COLOR};
   for(int k = 0; k < ArraySize(ints); k++)
      if(ObjectGetInteger(from, name, ints[k], 0, l))
         ObjectSetInteger(to, name, ints[k], l);
   ENUM_OBJECT_PROPERTY_DOUBLE doubles[] = {OBJPROP_ANGLE, OBJPROP_SCALE, OBJPROP_DEVIATION};
   for(int k = 0; k < ArraySize(doubles); k++)
      if(ObjectGetDouble(from, name, doubles[k], 0, d))
         ObjectSetDouble(to, name, doubles[k], d);
   ObjectSetString(to, name, OBJPROP_TEXT, ObjectGetString(from, name, OBJPROP_TEXT));
   ObjectSetString(to, name, OBJPROP_FONT, ObjectGetString(from, name, OBJPROP_FONT));

   // Levels, for Fibonacci and similar drawings.
   int levels = (int)ObjectGetInteger(from, name, OBJPROP_LEVELS);
   if(levels > 0)
     {
      ObjectSetInteger(to, name, OBJPROP_LEVELS, levels);
      for(int k = 0; k < levels; k++)
        {
         ObjectSetDouble(to, name, OBJPROP_LEVELVALUE, k, ObjectGetDouble(from, name, OBJPROP_LEVELVALUE, k));
         ObjectSetInteger(to, name, OBJPROP_LEVELCOLOR, k, ObjectGetInteger(from, name, OBJPROP_LEVELCOLOR, k));
         ObjectSetInteger(to, name, OBJPROP_LEVELSTYLE, k, ObjectGetInteger(from, name, OBJPROP_LEVELSTYLE, k));
         ObjectSetInteger(to, name, OBJPROP_LEVELWIDTH, k, ObjectGetInteger(from, name, OBJPROP_LEVELWIDTH, k));
         ObjectSetString(to, name, OBJPROP_LEVELTEXT, k, ObjectGetString(from, name, OBJPROP_LEVELTEXT, k));
        }
     }
   ObjectSetInteger(to, name, OBJPROP_SELECTED, false);
   ObjectSetInteger(to, name, OBJPROP_SELECTABLE, false);
   return true;
  }

// Zooms, draws the marks and caption, and scrolls so the entry (or close) candle is the
// last one showing. Anything after it is off the right edge. ScreenshotStep saves the
// image on the next timer event, once MT5 has redrawn the chart.
bool DrawShot(const long chart, const ShotJob &job)
  {
   Trade t = job.t;
   int openShift = iBarShift(g_symbol, PERIOD_M15, t.openTime);
   int closeShift = t.isOpen ? 0 : iBarShift(g_symbol, PERIOD_M15, t.closeTime);
   if(openShift < 0 || closeShift < 0)
     {
      Print(StringFormat("Trade Recorder: #%I64u has no 15m candles on the chart, so no screenshot", t.position));
      return false;
     }

   // Zoom out if the whole trade, plus some candles before it, wouldn't fit on the close
   // image. Both images of a trade use the same zoom.
   int zoom = SHOT_ZOOM;
   while(zoom > 0 && (openShift - closeShift + 30) * (1 << zoom) > ShotWidth() - 80)
      zoom--;
   ChartSetInteger(chart, CHART_SCALE, zoom);

   // The caption, in short lines because MT5 cuts chart text off at 63 characters.
   double entry = t.inValue / t.inLots;
   string lines[5];
   lines[0] = StringFormat("#%I64u  %s %s lots", t.position, t.dir > 0 ? "Buy" : "Sell", DoubleToString(t.inLots, 2));
   lines[1] = StringFormat("Entry %s at %s SA", DoubleToString(entry, g_digits), Hhmm(ToSA(t.openTime)));
   lines[2] = "Image at entry";
   if(job.r.ok)
     {
      lines[3] = StringFormat("At entry: 1H Supertrend %s, 15m %s (%d candles since flip)",
                              UpDown(job.r.h1Dir), UpDown(job.r.m15Dir), job.r.sinceFlip);
      lines[4] = "At entry: 1H ADX " + DoubleToString(job.r.adxH1, 1);
     }
   else
      lines[3] = "At entry: no readings";

   ObjectsDeleteAll(chart, MARK_PREFIX);
   Mark(chart, "entry", t.openTime, entry, t.dir > 0 ? 233 : 234, t.dir > 0 ? ANCHOR_TOP : ANCHOR_BOTTOM,
        (t.dir > 0 ? "Buy " : "Sell ") + DoubleToString(entry, g_digits), ENTRY_COLOR);

   if(job.atClose)
     {
      double closePrice = t.outValue / t.outLots;
      double pnl = t.profit + t.commission + t.swap;
      string money = (pnl >= 0 ? "+$" : "-$") + DoubleToString(MathAbs(pnl), 2);
      color result = (pnl >= 0) ? WIN_COLOR : LOSS_COLOR;
      string name = MARK_PREFIX + "path";
      ObjectCreate(chart, name, OBJ_TREND, 0, t.openTime, entry, t.closeTime, closePrice);
      ObjectSetInteger(chart, name, OBJPROP_COLOR, result);
      ObjectSetInteger(chart, name, OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(chart, name, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(chart, name, OBJPROP_SELECTABLE, false);
      Mark(chart, "exit", t.closeTime, closePrice, 251, ANCHOR_TOP,
           "Exit " + DoubleToString(closePrice, g_digits) + "  " + money, result);
      lines[2] = StringFormat("Exit %s at %s SA by %s, P&L %s", DoubleToString(closePrice, g_digits),
                              Hhmm(ToSA(t.closeTime)), Origin(t.closeReason), money);
     }
   Caption(chart, lines);

   // The image is saved from the chart's left edge, so put the left edge one image-width
   // of candles before the candle that should be last.
   int shift = job.atClose ? closeShift : openShift;
   int first = shift + (ShotWidth() - PRICE_SCALE_PX) / (1 << zoom) - 1;
   int widthInBars = (int)ChartGetInteger(chart, CHART_WIDTH_IN_BARS);
   ChartNavigate(chart, CHART_END, -(first - widthInBars + 1));
   int actual = (int)ChartGetInteger(chart, CHART_FIRST_VISIBLE_BAR);
   if(actual != first)
      ChartNavigate(chart, CHART_CURRENT_POS, actual - first);
   ChartRedraw(chart);
   return true;
  }

// An arrow at a candle, with a label just to its left (the candle is at the right edge).
void Mark(const long chart, const string id, const datetime when, const double price,
          const int arrowCode, const ENUM_ARROW_ANCHOR anchor, const string label, const color clr)
  {
   string name = MARK_PREFIX + id;
   ObjectCreate(chart, name, OBJ_ARROW, 0, when, price);
   ObjectSetInteger(chart, name, OBJPROP_ARROWCODE, arrowCode);
   ObjectSetInteger(chart, name, OBJPROP_ANCHOR, anchor);
   ObjectSetInteger(chart, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(chart, name, OBJPROP_WIDTH, 4);
   ObjectSetInteger(chart, name, OBJPROP_SELECTABLE, false);

   name = MARK_PREFIX + id + " label";
   ObjectCreate(chart, name, OBJ_TEXT, 0, when - PeriodSeconds(PERIOD_M15), price);
   ObjectSetString(chart, name, OBJPROP_TEXT, label + "  ");
   ObjectSetString(chart, name, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(chart, name, OBJPROP_FONTSIZE, 11);
   ObjectSetInteger(chart, name, OBJPROP_ANCHOR, ANCHOR_RIGHT);
   ObjectSetInteger(chart, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(chart, name, OBJPROP_SELECTABLE, false);
  }

// Lines of text in the top-left corner saying which trade this is, on a plain panel so
// the candles behind don't make it hard to read.
void Caption(const long chart, const string &lines[])
  {
   string panel = MARK_PREFIX + "caption panel";
   if(ObjectFind(chart, panel) < 0)
     {
      ObjectCreate(chart, panel, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(chart, panel, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(chart, panel, OBJPROP_XDISTANCE, 4);
      ObjectSetInteger(chart, panel, OBJPROP_YDISTANCE, 22);
      ObjectSetInteger(chart, panel, OBJPROP_XSIZE, 520);
      ObjectSetInteger(chart, panel, OBJPROP_YSIZE, 8 + 20 * ArraySize(lines));
      ObjectSetInteger(chart, panel, OBJPROP_BGCOLOR, (color)ChartGetInteger(chart, CHART_COLOR_BACKGROUND));
      ObjectSetInteger(chart, panel, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(chart, panel, OBJPROP_COLOR, (color)ChartGetInteger(chart, CHART_COLOR_FOREGROUND));
      ObjectSetInteger(chart, panel, OBJPROP_SELECTABLE, false);
     }
   for(int i = 0; i < ArraySize(lines); i++)
     {
      string name = MARK_PREFIX + "caption " + IntegerToString(i);
      if(ObjectFind(chart, name) < 0)
        {
         ObjectCreate(chart, name, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(chart, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(chart, name, OBJPROP_XDISTANCE, 8);
         ObjectSetInteger(chart, name, OBJPROP_YDISTANCE, 24 + 20 * i);
         ObjectSetString(chart, name, OBJPROP_FONT, "Arial");
         ObjectSetInteger(chart, name, OBJPROP_FONTSIZE, 11);
         ObjectSetInteger(chart, name, OBJPROP_COLOR, (color)ChartGetInteger(chart, CHART_COLOR_FOREGROUND));
         ObjectSetInteger(chart, name, OBJPROP_SELECTABLE, false);
        }
      ObjectSetString(chart, name, OBJPROP_TEXT, lines[i]);
     }
  }

//+------------------------------------------------------------------+
//| Small helpers                                                    |
//+------------------------------------------------------------------+
string Hhmm(const datetime t)
  {
   string s = TimeToString(t, TIME_DATE | TIME_MINUTES);
   StringReplace(s, ".", "-");
   return s;
  }

void WriteLine(const int file, const string line)
  {
   if(file != INVALID_HANDLE)
      FileWriteString(file, line + "\r\n");
  }

void AddNote(string &notes, const string note)
  {
   notes = (notes == "") ? note : notes + ", " + note;
  }

// A number with comma decimals for the owner's Excel, or empty if there's no value.
string Num(const double value, const int digits)
  {
   if(value == GTL_NONE)
      return "";
   string s = DoubleToString(value, digits);
   StringReplace(s, ".", ",");
   return s;
  }

// "YYYY-MM-DD HH:MM:SS", which Excel reads as a date and time.
string When(const datetime t)
  {
   if(t == 0)
      return "";
   string s = TimeToString(t, TIME_DATE | TIME_SECONDS);
   StringReplace(s, ".", "-");
   return s;
  }

datetime ToSA(const datetime serverTime)
  {
   return serverTime + (SA_UTC_OFFSET - g_serverUtcOffset) * 3600;
  }

string UpDown(const int dir)
  {
   return (dir > 0) ? "up" : (dir < 0) ? "down" : "";
  }

string YesNo(const bool b)
  {
   return b ? "yes" : "no";
  }

// Where a deal came from (opening) or what closed it (closing).
string Origin(const long reason)
  {
   switch((int)reason)
     {
      case DEAL_REASON_CLIENT:
         return "desktop";
      case DEAL_REASON_MOBILE:
         return "phone";
      case DEAL_REASON_WEB:
         return "web";
      case DEAL_REASON_EXPERT:
         return "EA";
      case DEAL_REASON_SL:
         return "stop";
      case DEAL_REASON_TP:
         return "target";
      case DEAL_REASON_SO:
         return "stop out";
     }
   return "other";
  }
//+------------------------------------------------------------------+
