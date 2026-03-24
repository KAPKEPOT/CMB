// cipher-mt5-bridge/mql5/Experts/CipherBridgeEA.mq5
// Event-driven version - NO POLLING!

#property copyright "CipherTrade"
#property version   "2.00"
#property strict

#include <CipherBridge.mqh>
#include <Trade\Trade.mqh>

// Input parameters
input string InpGatewayUrl = "wss://gateway.rayonix.site:443";  // WebSocket URL
input string InpAccountId  = "";  // Account ID (leave empty to use MT5 login)
input int    InpTimerMs    = 10;   // Timer interval (commands + ticks)
input bool   InpLogVerbose = false;   // Verbose logging

// Globals
CTrade g_trade;
bool   g_initialized = false;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
    // Allow DLL imports
    if (!TerminalInfoInteger(TERMINAL_DLLS_ALLOWED)) {
        Alert("CipherBridge: DLL imports must be enabled! Enable in Tools → Options → Expert Advisors");
        return INIT_FAILED;
    }
    
    // Determine account ID
    string account_id = InpAccountId;
    if (account_id == "") {
        account_id = IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
    }
    
    // Initialize the bridge (connects to gateway via WebSocket)
    int result = BridgeInit(InpGatewayUrl, account_id);
    if (result == 0) {
        Alert("CipherBridge: Failed to connect to gateway at " + InpGatewayUrl);
        return INIT_FAILED;
    }
    
    // Set timer for pushing ticks only (not for command polling!)
    if (!EventSetMillisecondTimer(InpTimerMs)) {
        Print("CipherBridge: Failed to set ms timer, falling back to 1s timer");
        EventSetTimer(1);
    }
    
    // Configure trade object
    g_trade.SetExpertMagicNumber(0);
    g_trade.SetDeviationInPoints(10);
    g_trade.SetTypeFilling(ORDER_FILLING_IOC);
    g_trade.SetAsyncMode(false);
    
    g_initialized = true;
    Print("CipherBridge: EA initialized (event-driven mode)");
    Print("  Gateway: ", InpGatewayUrl);
    Print("  Account: ", account_id);
    
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
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
//| Tick handler — push market data for subscribed symbols           |
//+------------------------------------------------------------------+
void OnTick() {
    if (!g_initialized) return;
    if (!BridgeIsClientConnected()) return;
    
    // Push tick for the current chart symbol
    string sym = Symbol();
    MqlTick tick;
    if (SymbolInfoTick(sym, tick)) {
        BridgePushTick(sym, tick.bid, tick.ask, tick.last,
                       tick.volume, (long)(tick.time_msc));
    }
}

//+------------------------------------------------------------------+
//| Timer handler — push ticks for subscribed symbols (periodic)     |
//| Also handles any necessary periodic cleanup                      |
//+------------------------------------------------------------------+
void OnTimer() {
    if (!g_initialized) return;

    // Drain bridge log messages
    DrainLogMessages();

    // Push ticks for all subscribed symbols
    if (BridgeIsClientConnected()) {
        PushSubscribedTicks();
    }

    // Process up to 32 commands per timer tick — runs on MT5 main thread, thread-safe
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
//| Drain and print DLL log messages                                 |
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
//| Dispatch a command to the appropriate handler                    |
//+------------------------------------------------------------------+
void ProcessCommand(int cmdType, string requestId, string paramsJson) {
    switch (cmdType) {
        case CMD_PING:
            HandlePing(requestId);
            break;
        case CMD_STATUS:
            HandleStatus(requestId);
            break;
        case CMD_CONNECT:
            HandleConnect(requestId, paramsJson);
            break;
        case CMD_DISCONNECT:
            HandleDisconnect(requestId);
            break;
        case CMD_SUBSCRIBE:
            HandleSubscribe(requestId, paramsJson);
            break;
        case CMD_UNSUBSCRIBE:
            HandleUnsubscribe(requestId, paramsJson);
            break;
        case CMD_GET_ACCOUNT_INFO:
            HandleGetAccountInfo(requestId);
            break;
        case CMD_GET_SYMBOL_INFO:
            HandleGetSymbolInfo(requestId, paramsJson);
            break;
        case CMD_GET_HISTORY:
            HandleGetHistory(requestId, paramsJson);
            break;
        case CMD_PLACE_ORDER:
            HandlePlaceOrder(requestId, paramsJson);
            break;
        case CMD_CLOSE_ORDER:
            HandleCloseOrder(requestId, paramsJson);
            break;
        case CMD_MODIFY_ORDER:
            HandleModifyOrder(requestId, paramsJson);
            break;
        case CMD_GET_POSITIONS:
            HandleGetPositions(requestId);
            break;
        case CMD_GET_ORDERS:
            HandleGetOrders(requestId);
            break;
        default:
            BridgePushResponse(BuildError(-1, "Unknown command type: " + IntegerToString(cmdType)));
            break;
    }
}

//+------------------------------------------------------------------+
//| Command handlers (same as before, but now called instantly)      |
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
    Print("CipherBridge: Connect request handled, account=", account);
}

void HandleDisconnect(string requestId) {
    string response = "{\"type\":\"DisconnectResult\",\"data\":{"
        "\"request_id\":\"" + JsonEscape(requestId) + "\","
        "\"success\":true"
        "}}";
    BridgePushResponse(response);
    Print("CipherBridge: Disconnect request acknowledged");
}

void HandleSubscribe(string requestId, string paramsJson) {
    string symbols[];
    int count = JsonGetStringArray(paramsJson, "symbols", symbols);
    string timeframe = JsonGetString(paramsJson, "timeframe");

    for (int i = 0; i < count; i++) {
        if (!SymbolSelect(symbols[i], true)) {
            Print("CipherBridge: Failed to select symbol: ", symbols[i]);
        }
    }

    BridgePushResponse(BuildSubscribed(requestId, symbols, timeframe));
    Print("CipherBridge: Subscribed to ", count, " symbols");
}

void HandleUnsubscribe(string requestId, string paramsJson) {
    string symbols[];
    int count = JsonGetStringArray(paramsJson, "symbols", symbols);
    BridgePushResponse(BuildUnsubscribed(requestId, symbols));
    Print("CipherBridge: Unsubscribed from ", count, " symbols");
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
        g_trade.SetExpertMagicNumber(0);
        BridgePushResponse(BuildOrderResult(requestId, 0, false, "Missing required parameters"));
        return;
    }

    if (!SymbolSelect(symbol, true)) {
        g_trade.SetExpertMagicNumber(0);
        BridgePushResponse(BuildOrderResult(requestId, 0, false, "Symbol not available: " + symbol));
        return;
    }

    ENUM_ORDER_TYPE type = ParseOrderType(side, orderType);

    if (side != "buy" && side != "sell") {
        g_trade.SetExpertMagicNumber(0);
        BridgePushResponse(BuildOrderResult(requestId, 0, false, "Unknown side: " + side));
        return;
    }
    if (orderType != "market" && orderType != "limit" && orderType != "stop" && orderType != "stop_limit") {
        g_trade.SetExpertMagicNumber(0);
        BridgePushResponse(BuildOrderResult(requestId, 0, false, "Unknown order_type: " + orderType));
        return;
    }

    if (magic > 0) g_trade.SetExpertMagicNumber(magic);

    if (orderType == "market" && (price == 0.0 || price == EMPTY_VALUE)) {
        if (side == "buy")
            price = SymbolInfoDouble(symbol, SYMBOL_ASK);
        else
            price = SymbolInfoDouble(symbol, SYMBOL_BID);
    }

    bool success = false;

    if (orderType == "market") {
        if (side == "buy")
            success = g_trade.Buy(volume, symbol, price, sl, tp, comment);
        else
            success = g_trade.Sell(volume, symbol, price, sl, tp, comment);
    } else {
        success = g_trade.OrderOpen(symbol, type, volume, 0.0, price, sl, tp,
                                    ORDER_TIME_GTC, 0, comment);
    }

    if (success) {
        ulong ticket = g_trade.ResultOrder();
        if (ticket == 0) ticket = g_trade.ResultDeal();
        BridgePushResponse(BuildOrderResult(requestId, (long)ticket, true));
        Print("CipherBridge: Order placed, ticket=", ticket);
    } else {
        uint retcode = g_trade.ResultRetcode();
        string errMsg = "Order failed [" + IntegerToString(retcode) + "]: " +
                        g_trade.ResultRetcodeDescription();
        BridgePushResponse(BuildOrderResult(requestId, 0, false, errMsg));
        Print("CipherBridge: ", errMsg);
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
            if (success) {
                BridgePushResponse(BuildOrderResult(requestId, ticket, true));
            } else {
                BridgePushResponse(BuildOrderResult(requestId, ticket, false,
                    "Failed to delete order: " + g_trade.ResultRetcodeDescription()));
            }
            return;
        }
        BridgePushResponse(BuildOrderResult(requestId, ticket, false, "Position/order not found"));
        return;
    }

    bool success = false;

    if (volume > 0 && volume < PositionGetDouble(POSITION_VOLUME)) {
        string symbol = PositionGetString(POSITION_SYMBOL);
        int    type   = (int)PositionGetInteger(POSITION_TYPE);
        if (type == POSITION_TYPE_BUY)
            success = g_trade.Sell(volume, symbol, 0, 0, 0, "Partial close");
        else
            success = g_trade.Buy(volume, symbol, 0, 0, 0, "Partial close");
    } else {
        success = g_trade.PositionClose((ulong)ticket);
    }

    if (success) {
        BridgePushResponse(BuildOrderResult(requestId, ticket, true));
        Print("CipherBridge: Position closed, ticket=", ticket);
    } else {
        BridgePushResponse(BuildOrderResult(requestId, ticket, false,
            "Close failed: " + g_trade.ResultRetcodeDescription()));
    }
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
    }
    else if (OrderSelect((ulong)ticket)) {
        double currentPrice = (price > 0) ? price : OrderGetDouble(ORDER_PRICE_OPEN);
        double currentSl    = (sl > 0) ? sl : OrderGetDouble(ORDER_SL);
        double currentTp    = (tp > 0) ? tp : OrderGetDouble(ORDER_TP);
        datetime expiry     = (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);
        success = g_trade.OrderModify((ulong)ticket, currentPrice, currentSl, currentTp,
                                      ORDER_TIME_GTC, expiry);
    }
    else {
        BridgePushResponse(BuildOrderResult(requestId, ticket, false, "Position/order not found"));
        return;
    }

    if (success) {
        BridgePushResponse(BuildOrderResult(requestId, ticket, true));
    } else {
        BridgePushResponse(BuildOrderResult(requestId, ticket, false,
            "Modify failed: " + g_trade.ResultRetcodeDescription()));
    }
}

void HandleGetPositions(string requestId) {
    BridgePushResponse(BuildPositions(requestId));
}

void HandleGetOrders(string requestId) {
    BridgePushResponse(BuildOrders(requestId));
}