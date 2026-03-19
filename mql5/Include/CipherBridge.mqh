// cipher-mt5-bridge/mql5/Include/CipherBridge.mqh

// CipherBridge.mqh - DLL imports and JSON helper functions    
// Part of Cipher MT5 Gateway bridge

#ifndef CIPHER_BRIDGE_MQH
#define CIPHER_BRIDGE_MQH

// DLL Imports
#import "CipherBridge.dll"
int    BridgeInit(int port);
void   BridgeShutdown();
int    BridgeIsClientConnected();
void   BridgePushTick(string symbol, double bid, double ask, double last,
                      long volume, long timeMs);
void   BridgePushCandle(string symbol, string timeframe, long timeMs,
                        double open, double high, double low, double close,
                        long volume, int complete);
int    BridgePollCommand(string &requestId, string &paramsJson);
void   BridgePushResponse(string responseJson);
int    BridgeGetSubscribedSymbolCount();
int    BridgeGetSubscribedSymbol(int index, string &symbol);
int    BridgeGetLogMessage(string &message);
#import


// Command type constants (must match BridgeCommandType enum in C++)
#define CMD_NONE               0
#define CMD_PING               1
#define CMD_STATUS             2
#define CMD_CONNECT            3
#define CMD_DISCONNECT         4
#define CMD_SUBSCRIBE          5
#define CMD_UNSUBSCRIBE        6
#define CMD_GET_ACCOUNT_INFO   7
#define CMD_GET_SYMBOL_INFO    8
#define CMD_GET_HISTORY        9
#define CMD_PLACE_ORDER        10
#define CMD_CLOSE_ORDER        11
#define CMD_MODIFY_ORDER       12
#define CMD_GET_POSITIONS      13
#define CMD_GET_ORDERS         14

// JSON builder helpers
// These build JSON strings for BridgeResponse format:
//   {"type":"<Type>","data":{...}}

//--- Escape a string for safe JSON embedding
string JsonEscape(string s) {
   StringReplace(s, "\\", "\\\\");
   StringReplace(s, "\"", "\\\"");
   StringReplace(s, "\n", "\\n");
   StringReplace(s, "\r", "\\r");
   StringReplace(s, "\t", "\\t");
   return s;
}

// Format a double with proper precision, avoiding trailing zeros
string JsonDouble(double val, int digits = 8) {
   return DoubleToString(val, digits);
}

// Build a Pong response
string BuildPong(string requestId, long timestamp) {
   return "{\"type\":\"Pong\",\"data\":{"
          "\"request_id\":\"" + JsonEscape(requestId) + "\","
          "\"timestamp\":" + IntegerToString(timestamp) +
          "}}";
}

// Build a Subscribed response
string BuildSubscribed(string requestId, string &symbols[], string timeframe = "") {
   string syms = "[";
   for (int i = 0; i < ArraySize(symbols); i++) {
      if (i > 0) syms += ",";
      syms += "\"" + JsonEscape(symbols[i]) + "\"";
   }
   syms += "]";

   string tf = "";
   if (timeframe != "")
      tf = "\"" + JsonEscape(timeframe) + "\"";
   else
      tf = "null";

   return "{\"type\":\"Subscribed\",\"data\":{"
          "\"request_id\":\"" + JsonEscape(requestId) + "\","
          "\"symbols\":" + syms + ","
          "\"timeframe\":" + tf +
          "}}";
}

// Build an Unsubscribed response
string BuildUnsubscribed(string requestId, string &symbols[]) {
   string syms = "[";
   for (int i = 0; i < ArraySize(symbols); i++) {
      if (i > 0) syms += ",";
      syms += "\"" + JsonEscape(symbols[i]) + "\"";
   }
   syms += "]";

   return "{\"type\":\"Unsubscribed\",\"data\":{"
          "\"request_id\":\"" + JsonEscape(requestId) + "\","
          "\"symbols\":" + syms +
          "}}";
}

// Build an AccountInfo response
string BuildAccountInfo(string requestId) {
   long   login      = AccountInfoInteger(ACCOUNT_LOGIN);
   string name       = AccountInfoString(ACCOUNT_NAME);
   string server     = AccountInfoString(ACCOUNT_SERVER);
   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
   double margin     = AccountInfoDouble(ACCOUNT_MARGIN);
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   int    leverage   = (int)AccountInfoInteger(ACCOUNT_LEVERAGE);
   string currency   = AccountInfoString(ACCOUNT_CURRENCY);
   double profit     = AccountInfoDouble(ACCOUNT_PROFIT);

   return "{\"type\":\"AccountInfo\",\"data\":{"
          "\"request_id\":\"" + JsonEscape(requestId) + "\","
          "\"login\":" + IntegerToString(login) + ","
          "\"name\":\"" + JsonEscape(name) + "\","
          "\"server\":\"" + JsonEscape(server) + "\","
          "\"balance\":" + JsonDouble(balance, 2) + ","
          "\"equity\":" + JsonDouble(equity, 2) + ","
          "\"margin\":" + JsonDouble(margin, 2) + ","
          "\"free_margin\":" + JsonDouble(freeMargin, 2) + ","
          "\"leverage\":" + IntegerToString(leverage) + ","
          "\"currency\":\"" + JsonEscape(currency) + "\","
          "\"profit\":" + JsonDouble(profit, 2) +
          "}}";
}

// Build a SymbolInfo response
string BuildSymbolInfo(string requestId, string symbol) {
   if (!SymbolSelect(symbol, true)) {
      return "{\"type\":\"Error\",\"data\":{\"code\":-1,\"message\":\"Symbol not found: " + JsonEscape(symbol) + "\"}}";
   }

   string desc      = SymbolInfoString(symbol, SYMBOL_DESCRIPTION);
   int    digits    = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double point     = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int    spread    = (int)SymbolInfoInteger(symbol, SYMBOL_SPREAD);
   bool   spreadFl  = SymbolInfoInteger(symbol, SYMBOL_SPREAD_FLOAT) != 0;
   double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickVal   = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double contract  = SymbolInfoDouble(symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   double minVol    = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxVol    = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double volStep   = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   double marginIni = SymbolInfoDouble(symbol, SYMBOL_MARGIN_INITIAL);
   double marginMnt = SymbolInfoDouble(symbol, SYMBOL_MARGIN_MAINTENANCE);
   int    freezeLvl = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   int    stopsLvl  = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);

   ENUM_SYMBOL_TRADE_MODE tradeMode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE);
   ENUM_SYMBOL_TRADE_EXECUTION execMode = (ENUM_SYMBOL_TRADE_EXECUTION)SymbolInfoInteger(symbol, SYMBOL_TRADE_EXEMODE);

   string tradeModeStr = "unknown";
   if (tradeMode == SYMBOL_TRADE_MODE_FULL)       tradeModeStr = "full";
   else if (tradeMode == SYMBOL_TRADE_MODE_LONGONLY)  tradeModeStr = "longonly";
   else if (tradeMode == SYMBOL_TRADE_MODE_SHORTONLY) tradeModeStr = "shortonly";
   else if (tradeMode == SYMBOL_TRADE_MODE_CLOSEONLY) tradeModeStr = "closeonly";
   else if (tradeMode == SYMBOL_TRADE_MODE_DISABLED)  tradeModeStr = "disabled";

   string execModeStr = "unknown";
   if (execMode == SYMBOL_TRADE_EXECUTION_REQUEST)   execModeStr = "request";
   else if (execMode == SYMBOL_TRADE_EXECUTION_INSTANT)  execModeStr = "instant";
   else if (execMode == SYMBOL_TRADE_EXECUTION_MARKET)   execModeStr = "market";
   else if (execMode == SYMBOL_TRADE_EXECUTION_EXCHANGE) execModeStr = "exchange";

   return "{\"type\":\"SymbolInfo\",\"data\":{"
          "\"request_id\":\"" + JsonEscape(requestId) + "\","
          "\"symbol\":\"" + JsonEscape(symbol) + "\","
          "\"description\":\"" + JsonEscape(desc) + "\","
          "\"digits\":" + IntegerToString(digits) + ","
          "\"point\":" + JsonDouble(point) + ","
          "\"spread\":" + IntegerToString(spread) + ","
          "\"spread_float\":" + (spreadFl ? "true" : "false") + ","
          "\"tick_size\":" + JsonDouble(tickSize) + ","
          "\"tick_value\":" + JsonDouble(tickVal) + ","
          "\"contract_size\":" + JsonDouble(contract) + ","
          "\"min_volume\":" + JsonDouble(minVol) + ","
          "\"max_volume\":" + JsonDouble(maxVol) + ","
          "\"volume_step\":" + JsonDouble(volStep) + ","
          "\"margin_initial\":" + JsonDouble(marginIni) + ","
          "\"margin_maintenance\":" + JsonDouble(marginMnt) + ","
          "\"trade_mode\":\"" + tradeModeStr + "\","
          "\"execution_mode\":\"" + execModeStr + "\","
          "\"trade_freeze_level\":" + IntegerToString(freezeLvl) + ","
          "\"trade_stops_level\":" + IntegerToString(stopsLvl) +
          "}}";
}

// Build a HistoryData response
string BuildHistoryData(string requestId, string symbol, string timeframe, MqlRates &rates[], int count) {
   string bars = "[";
   for (int i = 0; i < count; i++) {
      if (i > 0) bars += ",";
      bars += "{"
              "\"time\":" + IntegerToString(rates[i].time) + ","
              "\"open\":" + JsonDouble(rates[i].open) + ","
              "\"high\":" + JsonDouble(rates[i].high) + ","
              "\"low\":" + JsonDouble(rates[i].low) + ","
              "\"close\":" + JsonDouble(rates[i].close) + ","
              "\"tick_volume\":" + IntegerToString(rates[i].tick_volume) + ","
              "\"real_volume\":" + IntegerToString(rates[i].real_volume) + ","
              "\"spread\":" + IntegerToString(rates[i].spread) +
              "}";
   }
   bars += "]";

   return "{\"type\":\"HistoryData\",\"data\":{"
          "\"request_id\":\"" + JsonEscape(requestId) + "\","
          "\"symbol\":\"" + JsonEscape(symbol) + "\","
          "\"timeframe\":\"" + JsonEscape(timeframe) + "\","
          "\"bars\":" + bars +
          "}}";
}

// Build an OrderResult response
string BuildOrderResult(string requestId, long ticket, bool success, string error = "") {
   string errorVal = "null";
   if (error != "")
      errorVal = "\"" + JsonEscape(error) + "\"";

   return "{\"type\":\"OrderResult\",\"data\":{"
          "\"request_id\":\"" + JsonEscape(requestId) + "\","
          "\"ticket\":" + IntegerToString(ticket) + ","
          "\"success\":" + (success ? "true" : "false") + ","
          "\"error\":" + errorVal +
          "}}";
}

// Build a Positions response
string BuildPositions(string requestId) {
   int total = PositionsTotal();
   string positions = "[";
   bool first = true;

   for (int i = 0; i < total; i++) {
      ulong ticket = PositionGetTicket(i);
      if (ticket == 0) continue;

      if (!first) positions += ",";
      first = false;

      string symbol   = PositionGetString(POSITION_SYMBOL);
      int    type     = (int)PositionGetInteger(POSITION_TYPE);
      double volume   = PositionGetDouble(POSITION_VOLUME);
      double priceO   = PositionGetDouble(POSITION_PRICE_OPEN);
      double priceC   = PositionGetDouble(POSITION_PRICE_CURRENT);
      double sl       = PositionGetDouble(POSITION_SL);
      double tp       = PositionGetDouble(POSITION_TP);
      double profit   = PositionGetDouble(POSITION_PROFIT);
      double swap     = PositionGetDouble(POSITION_SWAP);
      double comm     = PositionGetDouble(POSITION_COMMISSION);
      long   timeO    = (long)PositionGetInteger(POSITION_TIME);
      long   timeU    = (long)PositionGetInteger(POSITION_TIME_UPDATE);
      string comment  = PositionGetString(POSITION_COMMENT);

      positions += "{"
         "\"ticket\":" + IntegerToString((long)ticket) + ","
         "\"symbol\":\"" + JsonEscape(symbol) + "\","
         "\"type\":" + IntegerToString(type) + ","
         "\"volume\":" + JsonDouble(volume) + ","
         "\"price_open\":" + JsonDouble(priceO) + ","
         "\"price_current\":" + JsonDouble(priceC) + ","
         "\"sl\":" + JsonDouble(sl) + ","
         "\"tp\":" + JsonDouble(tp) + ","
         "\"profit\":" + JsonDouble(profit, 2) + ","
         "\"swap\":" + JsonDouble(swap, 2) + ","
         "\"commission\":" + JsonDouble(comm, 2) + ","
         "\"time_open\":" + IntegerToString(timeO) + ","
         "\"time_update\":" + IntegerToString(timeU) + ","
         "\"comment\":\"" + JsonEscape(comment) + "\""
         "}";
   }
   positions += "]";

   return "{\"type\":\"Positions\",\"data\":{"
          "\"request_id\":\"" + JsonEscape(requestId) + "\","
          "\"positions\":" + positions +
          "}}";
}

// Build an Orders response (pending orders)
string BuildOrders(string requestId) {
   int total = OrdersTotal();
   string orders = "[";
   bool first = true;

   for (int i = 0; i < total; i++) {
      ulong ticket = OrderGetTicket(i);
      if (ticket == 0) continue;

      if (!first) orders += ",";
      first = false;

      string symbol     = OrderGetString(ORDER_SYMBOL);
      int    type       = (int)OrderGetInteger(ORDER_TYPE);
      double volInit    = OrderGetDouble(ORDER_VOLUME_INITIAL);
      double volCurr    = OrderGetDouble(ORDER_VOLUME_CURRENT);
      double priceOpen  = OrderGetDouble(ORDER_PRICE_OPEN);
      double priceCurr  = OrderGetDouble(ORDER_PRICE_CURRENT);
      double sl         = OrderGetDouble(ORDER_SL);
      double tp         = OrderGetDouble(ORDER_TP);
      long   timeSetup  = (long)OrderGetInteger(ORDER_TIME_SETUP);
      long   timeExpire = (long)OrderGetInteger(ORDER_TIME_EXPIRATION);
      string comment    = OrderGetString(ORDER_COMMENT);
      int    state      = (int)OrderGetInteger(ORDER_STATE);

      orders += "{"
         "\"ticket\":" + IntegerToString((long)ticket) + ","
         "\"symbol\":\"" + JsonEscape(symbol) + "\","
         "\"type\":" + IntegerToString(type) + ","
         "\"volume_initial\":" + JsonDouble(volInit) + ","
         "\"volume_current\":" + JsonDouble(volCurr) + ","
         "\"price_open\":" + JsonDouble(priceOpen) + ","
         "\"price_current\":" + JsonDouble(priceCurr) + ","
         "\"sl\":" + JsonDouble(sl) + ","
         "\"tp\":" + JsonDouble(tp) + ","
         "\"time_setup\":" + IntegerToString(timeSetup) + ","
         "\"time_expiration\":" + IntegerToString(timeExpire) + ","
         "\"comment\":\"" + JsonEscape(comment) + "\","
         "\"state\":" + IntegerToString(state) +
         "}";
   }
   orders += "]";

   return "{\"type\":\"Orders\",\"data\":{"
          "\"request_id\":\"" + JsonEscape(requestId) + "\","
          "\"orders\":" + orders +
          "}}";
}

// Build an Error response
string BuildError(int code, string message) {
   return "{\"type\":\"Error\",\"data\":{"
          "\"code\":" + IntegerToString(code) + ","
          "\"message\":\"" + JsonEscape(message) + "\""
          "}}";
}

// JSON parser helpers (minimal — extracts fields from flat JSON objects)
//--- Extract a string value from JSON by key (handles escaped quotes)
string JsonGetString(string json, string key) {
   string search = "\"" + key + "\":\"";
   int pos = StringFind(json, search);
   if (pos < 0) return "";
   pos += StringLen(search);

   // Walk forward, skipping escaped quotes (\")
   string result = "";
   int len = StringLen(json);
   while (pos < len) {
      ushort ch = StringGetCharacter(json, pos);
      if (ch == '\\' && pos + 1 < len) {
         ushort next = StringGetCharacter(json, pos + 1);
         if (next == '"') {
            result += "\"";
            pos += 2;
            continue;
         } else if (next == '\\') {
            result += "\\";
            pos += 2;
            continue;
         } else if (next == 'n') {
            result += "\n";
            pos += 2;
            continue;
         } else if (next == 'r') {
            result += "\r";
            pos += 2;
            continue;
         } else if (next == 't') {
            result += "\t";
            pos += 2;
            continue;
         }
      }
      if (ch == '"') break;  // Unescaped quote = end of value
      result += ShortToString(ch);
      pos++;
   }
   return result;
}

// Extract a double value from JSON by key
double JsonGetDouble(string json, string key) {
   string search = "\"" + key + "\":";
   int pos = StringFind(json, search);
   if (pos < 0) return 0.0;
   pos += StringLen(search);
   // Skip whitespace
   while (pos < StringLen(json) && StringGetCharacter(json, pos) == ' ') pos++;
   int end = pos;
   while (end < StringLen(json)) {
      ushort ch = StringGetCharacter(json, end);
      if (ch != '-' && ch != '.' && (ch < '0' || ch > '9') && ch != 'e' && ch != 'E' && ch != '+')
         break;
      end++;
   }
   return StringToDouble(StringSubstr(json, pos, end - pos));
}

//--- Extract a long value from JSON by key
long JsonGetLong(string json, string key) {
   string search = "\"" + key + "\":";
   int pos = StringFind(json, search);
   if (pos < 0) return 0;
   pos += StringLen(search);
   while (pos < StringLen(json) && StringGetCharacter(json, pos) == ' ') pos++;
   int end = pos;
   while (end < StringLen(json)) {
      ushort ch = StringGetCharacter(json, end);
      if (ch != '-' && (ch < '0' || ch > '9')) break;
      end++;
   }
   return StringToInteger(StringSubstr(json, pos, end - pos));
}

// Extract a JSON array of strings (e.g. ["EURUSD","GBPUSD"])
int JsonGetStringArray(string json, string key, string &result[]) {
   string search = "\"" + key + "\":[";
   int pos = StringFind(json, search);
   if (pos < 0) return 0;
   pos += StringLen(search);
   int end = StringFind(json, "]", pos);
   if (end < 0) return 0;

   string arrayContent = StringSubstr(json, pos, end - pos);
   // Parse comma-separated quoted strings
   int count = 0;
   int idx = 0;
   while (idx < StringLen(arrayContent)) {
      int qStart = StringFind(arrayContent, "\"", idx);
      if (qStart < 0) break;
      int qEnd = StringFind(arrayContent, "\"", qStart + 1);
      if (qEnd < 0) break;

      ArrayResize(result, count + 1);
      result[count] = StringSubstr(arrayContent, qStart + 1, qEnd - qStart - 1);
      count++;
      idx = qEnd + 1;
   }
   return count;
}

// Timeframe string ↔ ENUM_TIMEFRAMES conversion

ENUM_TIMEFRAMES StringToTimeframe(string tf) {
   if (tf == "M1")  return PERIOD_M1;
   if (tf == "M5")  return PERIOD_M5;
   if (tf == "M15") return PERIOD_M15;
   if (tf == "M30") return PERIOD_M30;
   if (tf == "H1")  return PERIOD_H1;
   if (tf == "H4")  return PERIOD_H4;
   if (tf == "D1")  return PERIOD_D1;
   if (tf == "W1")  return PERIOD_W1;
   if (tf == "MN1") return PERIOD_MN1;
   if (tf == "M2")  return PERIOD_M2;
   if (tf == "M3")  return PERIOD_M3;
   if (tf == "M4")  return PERIOD_M4;
   if (tf == "M6")  return PERIOD_M6;
   if (tf == "M10") return PERIOD_M10;
   if (tf == "M12") return PERIOD_M12;
   if (tf == "M20") return PERIOD_M20;
   if (tf == "H2")  return PERIOD_H2;
   if (tf == "H3")  return PERIOD_H3;
   if (tf == "H6")  return PERIOD_H6;
   if (tf == "H8")  return PERIOD_H8;
   if (tf == "H12") return PERIOD_H12;
   return PERIOD_M1;  // Default
}

// Order type string → ENUM_ORDER_TYPE

ENUM_ORDER_TYPE ParseOrderType(string side, string orderType) {
   if (orderType == "market") {
      if (side == "buy")  return ORDER_TYPE_BUY;
      if (side == "sell") return ORDER_TYPE_SELL;
   }
   if (orderType == "limit") {
      if (side == "buy")  return ORDER_TYPE_BUY_LIMIT;
      if (side == "sell") return ORDER_TYPE_SELL_LIMIT;
   }
   if (orderType == "stop") {
      if (side == "buy")  return ORDER_TYPE_BUY_STOP;
      if (side == "sell") return ORDER_TYPE_SELL_STOP;
   }
   if (orderType == "stop_limit") {
      if (side == "buy")  return ORDER_TYPE_BUY_STOP_LIMIT;
      if (side == "sell") return ORDER_TYPE_SELL_STOP_LIMIT;
   }
   return ORDER_TYPE_BUY;  // Default
}

#endif // CIPHER_BRIDGE_MQH