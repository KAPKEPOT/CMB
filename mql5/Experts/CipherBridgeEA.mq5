// cipher-mt5-bridge/mql5/Experts/CipherBridgeEA.mq5
// v2.0 — Supports Docker (auto) and Manual modes
//
// Docker mode:  BridgeInitFromEnv() — reads config from launcher.py output
// Manual mode:  BridgeInit(url, account_id) — uses EA input params
//
// New: handles CMD_CREDENTIALS from gateway and reports login_result

#property copyright "CipherBridge"
#property version   "2.00"
#property strict

#include <CipherBridge.mqh>
#include <Trade\Trade.mqh>

// Input parameters (only used in Manual mode)
input string InpGatewayUrl  = "";    // WebSocket URL (empty = Docker mode)
input string InpAccountId   = "";    // Account ID (empty = auto-detect)
input int    InpTimerMs     = 10;    // Timer interval (ms)
input bool   InpLogVerbose  = false; // Verbose logging

// Globals
CTrade g_trade;
bool   g_initialized = false;
bool   g_credentials_received = false;
bool   g_login_reported = false;

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit() {
    // Check DLL imports
    if (!TerminalInfoInteger(TERMINAL_DLLS_ALLOWED)) {
        Alert("CipherBridge: DLL imports must be enabled!");
        return INIT_FAILED;
    }
    
    int result = 0;
    
    if (InpGatewayUrl == "" || InpGatewayUrl == "auto") {
        // Docker mode — read from config files/env vars
        Print("CipherBridge: Starting in Docker mode");
        result = BridgeInitFromEnv();
    } else {
        // Manual mode — use EA input params
        Print("CipherBridge: Starting in Manual mode");
        string account_id = InpAccountId;
        if (account_id == "")
            account_id = IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
        result = BridgeInit(InpGatewayUrl, account_id);
    }
    
    if (result == 0) {
        Alert("CipherBridge: Failed to initialize bridge");
        return INIT_FAILED;
    }
    
    // Set timer
    if (!EventSetMillisecondTimer(InpTimerMs)) {
        Print("CipherBridge: Failed to set ms timer, using 1s");
        EventSetTimer(1);
    }
    
    // Configure trade object
    g_trade.SetExpertMagicNumber(0);
    g_trade.SetDeviationInPoints(10);
    g_trade.SetTypeFilling(ORDER_FILLING_IOC);
    g_trade.SetAsyncMode(false);
    
    g_initialized = true;
    g_credentials_received = false;
    g_login_reported = false;
    
    Print("CipherBridge: EA initialized v2.0");
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
    EventKillTimer();
    if (g_initialized) {
        BridgeShutdown();
        g_initialized = false;
        Print("CipherBridge: EA deinitialized, reason=", reason);
    }
}

//+------------------------------------------------------------------+
//| Tick handler — push market data                                   |
//+------------------------------------------------------------------+
void OnTick() {
    if (!g_initialized || !BridgeIsClientConnected()) return;
    
    string sym = Symbol();
    MqlTick tick;
    if (SymbolInfoTick(sym, tick)) {
        BridgePushTick(sym, tick.bid, tick.ask, tick.last,
                       tick.volume, (long)(tick.time_msc));
    }
}

//+------------------------------------------------------------------+
//| Timer handler — process commands, push subscribed ticks           |
//+------------------------------------------------------------------+
void OnTimer() {
    if (!g_initialized) return;

    // Drain DLL log messages
    DrainLogMessages();

    // Push subscribed symbol ticks
    if (BridgeIsClientConnected()) {
        PushSubscribedTicks();
        
        // If connected and MT5 is logged in but we haven't reported yet, do it
        if (!g_login_reported) {
            CheckAndReportLogin();
        }
    }

    // Process up to 32 commands per timer tick
    for (int batch = 0; batch < 32; batch++) {
        string requestId = "";
        StringInit(requestId, 128);
        string paramsJson = "";
        StringInit(paramsJson, 8192);

        int cmdType = BridgePollCommand(requestId, paramsJson);
        if (cmdType == CMD_NONE) break;

        if (InpLogVerbose)
            Print("CipherBridge: cmd=", cmdType, " reqId=", requestId);

        ProcessCommand(cmdType, requestId, paramsJson);
    }
}

//+------------------------------------------------------------------+
//| Check MT5 login status and report to gateway                     |
//+------------------------------------------------------------------+
void CheckAndReportLogin() {
    // Check if terminal is connected to broker
    bool connected = TerminalInfoInteger(TERMINAL_CONNECTED) != 0;
    long account = AccountInfoInteger(ACCOUNT_LOGIN);
    
    if (connected && account > 0) {
        // MT5 is logged in — report success
        string response = "{\"type\":\"login_result\",\"data\":{"
            "\"success\":true,"
            "\"account\":" + IntegerToString(account) + ","
            "\"server\":\"" + JsonEscape(AccountInfoString(ACCOUNT_SERVER)) + "\","
            "\"balance\":" + JsonDouble(AccountInfoDouble(ACCOUNT_BALANCE), 2) +
            "}}";
        BridgePushResponse(response);
        g_login_reported = true;
        Print("CipherBridge: Login success reported (account=", account, ")");
    }
}

//+------------------------------------------------------------------+
//| Push ticks for all subscribed symbols                            |
//+------------------------------------------------------------------+
void PushSubscribedTicks() {
    string chartSym = Symbol();
    int count = BridgeGetSubscribedSymbolCount();
    for (int i = 0; i < count; i++) {
        string subSym = "";
        StringInit(subSym, 64);
        if (BridgeGetSubscribedSymbol(i, subSym) && subSym != "" && subSym != chartSym) {
            MqlTick subTick;
            if (SymbolInfoTick(subSym, subTick)) {
                BridgePushTick(subSym, subTick.bid, subTick.ask, subTick.last,
                               subTick.volume, (long)(subTick.time_msc));
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Drain and print DLL log messages                                  |
//+------------------------------------------------------------------+
void DrainLogMessages() {
    for (int i = 0; i < 10; i++) {
        string msg = "";
        StringInit(msg, 512);
        if (!BridgeGetLogMessage(msg)) break;
        if (msg != "")
            Print("CipherBridge[DLL]: ", msg);
    }
}

//+------------------------------------------------------------------+
//| Dispatch command to handler                                       |
//+------------------------------------------------------------------+
void ProcessCommand(int cmdType, string requestId, string paramsJson) {
    switch (cmdType) {
        case CMD_PING:             HandlePing(requestId); break;
        case CMD_STATUS:           HandleStatus(requestId); break;
        case CMD_CONNECT:          HandleConnect(requestId, paramsJson); break;
        case CMD_DISCONNECT:       HandleDisconnect(requestId); break;
        case CMD_SUBSCRIBE:        HandleSubscribe(requestId, paramsJson); break;
        case CMD_UNSUBSCRIBE:      HandleUnsubscribe(requestId, paramsJson); break;
        case CMD_GET_ACCOUNT_INFO: HandleGetAccountInfo(requestId); break;
        case CMD_GET_SYMBOL_INFO:  HandleGetSymbolInfo(requestId, paramsJson); break;
        case CMD_GET_HISTORY:      HandleGetHistory(requestId, paramsJson); break;
        case CMD_PLACE_ORDER:      HandlePlaceOrder(requestId, paramsJson); break;
        case CMD_CLOSE_ORDER:      HandleCloseOrder(requestId, paramsJson); break;
        case CMD_MODIFY_ORDER:     HandleModifyOrder(requestId, paramsJson); break;
        case CMD_GET_POSITIONS:    HandleGetPositions(requestId); break;
        case CMD_GET_ORDERS:       HandleGetOrders(requestId); break;
        case CMD_CREDENTIALS:      HandleCredentials(requestId, paramsJson); break;
        default:
            BridgePushResponse(BuildError(-1, "Unknown command: " + IntegerToString(cmdType)));
            break;
    }
}

//+------------------------------------------------------------------+
//| Handle credentials from gateway                                   |
//+------------------------------------------------------------------+
void HandleCredentials(string requestId, string paramsJson) {
    // In Docker mode: MT5 is already logged in (started with /login params)
    // Just acknowledge and report login status
    g_credentials_received = true;
    
    string mt5_login  = JsonGetString(paramsJson, "mt5_login");
    string mt5_server = JsonGetString(paramsJson, "mt5_server");
    
    Print("CipherBridge: Credentials received (login=", mt5_login, ", server=", mt5_server, ")");
    
    // Check if we're already logged into the correct account
    long current_login = AccountInfoInteger(ACCOUNT_LOGIN);
    bool connected = TerminalInfoInteger(TERMINAL_CONNECTED) != 0;
    
    if (connected && current_login > 0) {
        // Already logged in — send success immediately
        string response = "{\"type\":\"login_result\",\"data\":{"
            "\"success\":true,"
            "\"account\":" + IntegerToString(current_login) + ","
            "\"server\":\"" + JsonEscape(AccountInfoString(ACCOUNT_SERVER)) + "\","
            "\"balance\":" + JsonDouble(AccountInfoDouble(ACCOUNT_BALANCE), 2) +
            "}}";
        BridgePushResponse(response);
        g_login_reported = true;
        Print("CipherBridge: Already logged in, reported success");
    } else {
        // Not logged in yet — MT5 might still be connecting
        // The CheckAndReportLogin() in OnTimer will report when ready
        Print("CipherBridge: Waiting for MT5 to connect...");
    }
}

//+------------------------------------------------------------------+
//| Command handlers (unchanged from v2)                              |
//+------------------------------------------------------------------+
void HandlePing(string requestId) {
    long timestamp = (long)TimeCurrent();
    BridgePushResponse(BuildPong(requestId, timestamp));
}

void HandleStatus(string requestId) {
    bool connected = TerminalInfoInteger(TERMINAL_CONNECTED) != 0;
    string terminal = TerminalInfoString(TERMINAL_NAME);
    string server   = AccountInfoString(ACCOUNT_SERVER);
    long   account  = AccountInfoInteger(ACCOUNT_LOGIN);
    long   uptime   = (long)(GetTickCount64() / 1000);
    int    symCount = SymbolsTotal(true);

    string response = "{\"type\":\"Status\",\"data\":{"
        "\"connected\":" + (connected ? "true" : "false") + ","
        "\"terminal\":\"" + JsonEscape(terminal) + "\","
        "\"server\":\"" + JsonEscape(server) + "\","
        "\"account\":" + IntegerToString(account) + ","
        "\"uptime\":" + IntegerToString(uptime) + ","
        "\"symbols_count\":" + IntegerToString(symCount) +
        "}}";
    BridgePushResponse(response);
}

void HandleConnect(string requestId, string paramsJson) {
    bool connected = TerminalInfoInteger(TERMINAL_CONNECTED) != 0;
    long   account  = AccountInfoInteger(ACCOUNT_LOGIN);
    string name     = AccountInfoString(ACCOUNT_NAME);
    double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
    double equity   = AccountInfoDouble(ACCOUNT_EQUITY);

    string errorVal = "null";
    if (!connected)
        errorVal = "\"Terminal not connected to trade server\"";

    string response = "{\"type\":\"ConnectResult\",\"data\":{"
        "\"request_id\":\"" + JsonEscape(requestId) + "\","
        "\"success\":" + (connected ? "true" : "false") + ","
        "\"account\":" + IntegerToString(account) + ","
        "\"name\":\"" + JsonEscape(name) + "\","
        "\"balance\":" + JsonDouble(balance, 2) + ","
        "\"equity\":" + JsonDouble(equity, 2) + ","
        "\"error\":" + errorVal +
        "}}";
    BridgePushResponse(response);
}

void HandleDisconnect(string requestId) {
    string response = "{\"type\":\"DisconnectResult\",\"data\":{"
        "\"request_id\":\"" + JsonEscape(requestId) + "\","
        "\"success\":true"
        "}}";
    BridgePushResponse(response);
}

void HandleSubscribe(string requestId, string paramsJson) {
    string symbols[];
    int count = JsonGetStringArray(paramsJson, "symbols", symbols);
    string timeframe = JsonGetString(paramsJson, "timeframe");
    for (int i = 0; i < count; i++) {
        if (!SymbolSelect(symbols[i], true))
            Print("CipherBridge: Failed to select symbol: ", symbols[i]);
    }
    BridgePushResponse(BuildSubscribed(requestId, symbols, timeframe));
}

void HandleUnsubscribe(string requestId, string paramsJson) {
    string symbols[];
    int count = JsonGetStringArray(paramsJson, "symbols", symbols);
    BridgePushResponse(BuildUnsubscribed(requestId, symbols));
}

void HandleGetAccountInfo(string requestId) {
    BridgePushResponse(BuildAccountInfo(requestId));
}

void HandleGetSymbolInfo(string requestId, string paramsJson) {
    string symbol = JsonGetString(paramsJson, "symbol");
    if (symbol == "") {
        BridgePushResponse(BuildError(-1, "Missing symbol parameter"));
        return;
    }
    BridgePushResponse(BuildSymbolInfo(requestId, symbol));
}

void HandleGetHistory(string requestId, string paramsJson) {
    string symbol    = JsonGetString(paramsJson, "symbol");
    string timeframe = JsonGetString(paramsJson, "timeframe");
    long   fromTime  = JsonGetLong(paramsJson, "from");
    long   toTime    = JsonGetLong(paramsJson, "to");

    if (symbol == "" || timeframe == "") {
        BridgePushResponse(BuildError(-1, "Missing symbol or timeframe"));
        return;
    }

    ENUM_TIMEFRAMES tf = StringToTimeframe(timeframe);
    if (tf == PERIOD_M1 && timeframe != "M1") {
        BridgePushResponse(BuildError(-1, "Unknown timeframe: " + timeframe));
        return;
    }
    
    MqlRates rates[];
    ArraySetAsSeries(rates, false);
    int copied = CopyRates(symbol, tf, (datetime)fromTime, (datetime)toTime, rates);
    if (copied < 0) {
        int err = GetLastError();
        BridgePushResponse(BuildError(err, "CopyRates failed: " + IntegerToString(err)));
        return;
    }
    BridgePushResponse(BuildHistoryData(requestId, symbol, timeframe, rates, copied));
}

void HandlePlaceOrder(string requestId, string paramsJson) {
    string symbol    = JsonGetString(paramsJson, "symbol");
    string side      = JsonGetString(paramsJson, "side");
    string orderType = JsonGetString(paramsJson, "order_type");
    double volume    = JsonGetDouble(paramsJson, "volume");
    double price     = JsonGetDouble(paramsJson, "price");
    double sl        = JsonGetDouble(paramsJson, "sl");
    double tp        = JsonGetDouble(paramsJson, "tp");
    string comment   = JsonGetString(paramsJson, "comment");
    long   magic     = JsonGetLong(paramsJson, "magic");

    if (symbol == "" || side == "" || volume <= 0) {
        BridgePushResponse(BuildOrderResult(requestId, 0, false, "Missing required parameters"));
        return;
    }
    if (!SymbolSelect(symbol, true)) {
        BridgePushResponse(BuildOrderResult(requestId, 0, false, "Symbol not available: " + symbol));
        return;
    }

    ENUM_ORDER_TYPE type = ParseOrderType(side, orderType);
    if (magic > 0) g_trade.SetExpertMagicNumber(magic);

    if (orderType == "market" && (price == 0.0 || price == EMPTY_VALUE)) {
        if (side == "buy")  price = SymbolInfoDouble(symbol, SYMBOL_ASK);
        else                price = SymbolInfoDouble(symbol, SYMBOL_BID);
    }

    bool success = false;
    if (orderType == "market") {
        if (side == "buy")  success = g_trade.Buy(volume, symbol, price, sl, tp, comment);
        else                success = g_trade.Sell(volume, symbol, price, sl, tp, comment);
    } else {
        success = g_trade.OrderOpen(symbol, type, volume, 0.0, price, sl, tp,
                                    ORDER_TIME_GTC, 0, comment);
    }

    if (success) {
        ulong ticket = g_trade.ResultOrder();
        if (ticket == 0) ticket = g_trade.ResultDeal();
        BridgePushResponse(BuildOrderResult(requestId, (long)ticket, true));
    } else {
        uint retcode = g_trade.ResultRetcode();
        string errMsg = "Order failed [" + IntegerToString(retcode) + "]: " +
                        g_trade.ResultRetcodeDescription();
        BridgePushResponse(BuildOrderResult(requestId, 0, false, errMsg));
    }
    g_trade.SetExpertMagicNumber(0);
}

void HandleCloseOrder(string requestId, string paramsJson) {
    long   ticket = JsonGetLong(paramsJson, "ticket");
    double volume = JsonGetDouble(paramsJson, "volume");

    if (ticket <= 0) {
        BridgePushResponse(BuildOrderResult(requestId, 0, false, "Invalid ticket"));
        return;
    }

    if (!PositionSelectByTicket((ulong)ticket)) {
        if (OrderSelect((ulong)ticket)) {
            bool success = g_trade.OrderDelete((ulong)ticket);
            BridgePushResponse(BuildOrderResult(requestId, ticket, success,
                success ? "" : "Failed to delete: " + g_trade.ResultRetcodeDescription()));
            return;
        }
        BridgePushResponse(BuildOrderResult(requestId, ticket, false, "Position/order not found"));
        return;
    }

    bool success = false;
    if (volume > 0 && volume < PositionGetDouble(POSITION_VOLUME)) {
        string sym = PositionGetString(POSITION_SYMBOL);
        int ptype = (int)PositionGetInteger(POSITION_TYPE);
        if (ptype == POSITION_TYPE_BUY)
            success = g_trade.Sell(volume, sym, 0, 0, 0, "Partial close");
        else
            success = g_trade.Buy(volume, sym, 0, 0, 0, "Partial close");
    } else {
        success = g_trade.PositionClose((ulong)ticket);
    }

    BridgePushResponse(BuildOrderResult(requestId, ticket, success,
        success ? "" : "Close failed: " + g_trade.ResultRetcodeDescription()));
}

void HandleModifyOrder(string requestId, string paramsJson) {
    long   ticket = JsonGetLong(paramsJson, "ticket");
    double price  = JsonGetDouble(paramsJson, "price");
    double sl     = JsonGetDouble(paramsJson, "sl");
    double tp     = JsonGetDouble(paramsJson, "tp");

    if (ticket <= 0) {
        BridgePushResponse(BuildOrderResult(requestId, 0, false, "Invalid ticket"));
        return;
    }

    bool success = false;
    if (PositionSelectByTicket((ulong)ticket)) {
        success = g_trade.PositionModify((ulong)ticket, sl, tp);
    } else if (OrderSelect((ulong)ticket)) {
        double cp = (price > 0) ? price : OrderGetDouble(ORDER_PRICE_OPEN);
        double cs = (sl > 0) ? sl : OrderGetDouble(ORDER_SL);
        double ct = (tp > 0) ? tp : OrderGetDouble(ORDER_TP);
        datetime exp = (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);
        success = g_trade.OrderModify((ulong)ticket, cp, cs, ct, ORDER_TIME_GTC, exp);
    } else {
        BridgePushResponse(BuildOrderResult(requestId, ticket, false, "Position/order not found"));
        return;
    }

    BridgePushResponse(BuildOrderResult(requestId, ticket, success,
        success ? "" : "Modify failed: " + g_trade.ResultRetcodeDescription()));
}

void HandleGetPositions(string requestId) {
    BridgePushResponse(BuildPositions(requestId));
}

void HandleGetOrders(string requestId) {
    BridgePushResponse(BuildOrders(requestId));
}