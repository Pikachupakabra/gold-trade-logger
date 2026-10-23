//+------------------------------------------------------------------+
//| TradeRecorder.mq5                                                |
//| Gold Trade Logger: reads this account's gold trades from MT5     |
//| history, works out Supertrend and ADX at each entry, and writes  |
//| everything to the Experts log and two CSV files in               |
//| MQL5\Files\GoldTradeLogger.                                      |
//| Task 12: it sends nothing to the app yet. It never places,       |
//| changes or closes a trade.                                       |
//+------------------------------------------------------------------+
#property copyright "Gold Trade Logger"
#property version   "1.00"
#property description "Reads gold trades from history and writes them, with Supertrend and ADX at entry, to MQL5\\Files\\GoldTradeLogger. It never trades."

#include <GoldTradeLogger\TradeLoggerCalc.mqh>

input string InpSymbol       = "";    // Gold symbol (empty = this chart's symbol)
input int    InpAtrPeriod    = 10;    // Supertrend ATR period
input double InpFactor       = 3.0;   // Supertrend multiplier
input int    InpAdxLength    = 14;    // ADX length (DI length and smoothing)
input double InpAdxThreshold = 20;    // Rule 3: 1H ADX above this
input int    InpFlipWindow   = 8;     // Rule 2: 15m flipped within this many closed candles
input double InpMinRR        = 2.0;   // Rule 4: risk:reward at least 1:N

#define CANDLES_WANTED 1000   // candles worked through before each entry, so the readings settle
#define CANDLES_NEEDED 300    // with fewer than this, the readings aren't trusted
#define MAX_ATTEMPTS   30     // seconds to wait for MT5 to connect and download old candles
#define SA_UTC_OFFSET  2      // South Africa is UTC+2 all year

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

string g_symbol;
int    g_digits;
int    g_serverUtcOffset;   // hours ahead of UTC (Exness: 0)
int    g_attempts = 0;

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
  }

void OnTick()
  {
  }

void OnTimer()
  {
   g_attempts++;
   if(g_attempts == 1 || g_attempts % 10 == 0)
      Print("Trade Recorder: attempt ", g_attempts, " of ", MAX_ATTEMPTS);
   if(RunCatchUp(g_attempts >= MAX_ATTEMPTS))
      EventKillTimer();
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
//| Small helpers                                                    |
//+------------------------------------------------------------------+
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
