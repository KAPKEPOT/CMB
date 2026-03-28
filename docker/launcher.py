#!/usr/bin/env python3
"""
cipher-mt5-bridge/docker/launcher.py

Phase A launcher — runs BEFORE MT5 starts.

1. HTTP POST /bridge/register with account_id + auth_token
2. Gets back WS URL with temporary token
3. Connects WebSocket, receives credentials message
4. Writes credentials to output file for entrypoint.sh
5. Exits — MT5 starts after this

Usage:
    python3 launcher.py \
        --account-id UUID \
        --auth-token TOKEN \
        --gateway-url https://gateway.cipherbridge.cloud \
        --output /tmp/mt5_credentials.json
"""

import argparse
import json
import sys
import time
import ssl

import requests
import websocket

def main():
    parser = argparse.ArgumentParser(description="CipherBridge Launcher")
    parser.add_argument("--account-id", required=True, help="Account UUID")
    parser.add_argument("--auth-token", required=True, help="One-time auth token")
    parser.add_argument("--gateway-url", required=True, help="Gateway base URL")
    parser.add_argument("--output", required=True, help="Output credentials file path")
    parser.add_argument("--max-retries", type=int, default=5, help="Max registration retries")
    parser.add_argument("--retry-delay", type=int, default=5, help="Seconds between retries")
    args = parser.parse_args()

    gateway_url = args.gateway_url.rstrip("/")
    
    print(f"  Launcher: account={args.account_id[:8]}...")
    print(f"  Launcher: gateway={gateway_url}")

    # ================================================================
    # Step 1: HTTP Registration
    # ================================================================
    
    ws_url = None
    ws_token = None
    
    for attempt in range(1, args.max_retries + 1):
        print(f"  Launcher: Registering with gateway (attempt {attempt}/{args.max_retries})...")
        
        try:
            register_url = f"{gateway_url}/bridge/register"
            payload = {
                "account_id": args.account_id,
                "auth_token": args.auth_token,
            }
            
            response = requests.post(
                register_url,
                json=payload,
                timeout=10,
                verify=True,  # Verify TLS
            )
            
            if response.status_code == 200:
                data = response.json()
                ws_url = data.get("ws_url")
                ws_token = data.get("ws_token")
                expires_in = data.get("expires_in_secs", 60)
                
                print(f"  Launcher: ✅ Registered (WS token expires in {expires_in}s)")
                break
            elif response.status_code == 401:
                print(f"  Launcher: ❌ Authentication failed — invalid auth token")
                sys.exit(1)
            elif response.status_code == 404:
                print(f"  Launcher: ❌ Account not found")
                sys.exit(1)
            elif response.status_code == 409:
                print(f"  Launcher: ⚠️ Account in invalid state: {response.text}")
                # May be retryable — account might still be initializing
            else:
                print(f"  Launcher: ⚠️ Registration failed ({response.status_code}): {response.text}")
                
        except requests.ConnectionError as e:
            print(f"  Launcher: ⚠️ Connection error: {e}")
        except requests.Timeout:
            print(f"  Launcher: ⚠️ Request timeout")
        except Exception as e:
            print(f"  Launcher: ⚠️ Unexpected error: {e}")
        
        if attempt < args.max_retries:
            delay = args.retry_delay * (2 ** (attempt - 1))  # Exponential backoff
            if delay > 60:
                delay = 60
            print(f"  Launcher: Retrying in {delay}s...")
            time.sleep(delay)
    
    if not ws_url:
        print("  Launcher: ❌ Failed to register after all retries")
        sys.exit(1)
    
    # ================================================================
    # Step 2: WebSocket Credential Retrieval
    # ================================================================
    
    print(f"  Launcher: Connecting WebSocket for credentials...")
    
    credentials = None
    received_event = {"done": False}
    
    def on_message(ws, message):
        nonlocal credentials
        try:
            msg = json.loads(message)
            msg_type = msg.get("type", "")
            
            if msg_type == "credentials":
                credentials = msg.get("data", {})
                print(f"  Launcher: ✅ Credentials received")
                received_event["done"] = True
                ws.close()
            elif msg_type == "error":
                error_data = msg.get("data", {})
                print(f"  Launcher: ❌ Error from gateway: {error_data}")
                received_event["done"] = True
                ws.close()
            else:
                print(f"  Launcher: Received message type: {msg_type}")
        except json.JSONDecodeError as e:
            print(f"  Launcher: Invalid JSON: {e}")
    
    def on_error(ws, error):
        print(f"  Launcher: WebSocket error: {error}")
    
    def on_close(ws, close_status_code, close_msg):
        print(f"  Launcher: WebSocket closed")
    
    def on_open(ws):
        print(f"  Launcher: WebSocket connected, waiting for credentials...")
    
    # Connect with timeout
    try:
        ws = websocket.WebSocketApp(
            ws_url,
            on_message=on_message,
            on_error=on_error,
            on_close=on_close,
            on_open=on_open,
        )
        
        # Run with timeout (credentials should arrive within seconds)
        import threading
        ws_thread = threading.Thread(
            target=ws.run_forever,
            kwargs={"sslopt": {"cert_reqs": ssl.CERT_NONE}},
        )
        ws_thread.daemon = True
        ws_thread.start()
        
        # Wait up to 30 seconds for credentials
        timeout = 30
        start = time.time()
        while not received_event["done"] and (time.time() - start) < timeout:
            time.sleep(0.5)
        
        if not received_event["done"]:
            print("  Launcher: ❌ Timeout waiting for credentials")
            ws.close()
            sys.exit(1)
            
    except Exception as e:
        print(f"  Launcher: ❌ WebSocket connection failed: {e}")
        sys.exit(1)
    
    if not credentials:
        print("  Launcher: ❌ No credentials received")
        sys.exit(1)
    
    # ================================================================
    # Step 3: Write credentials to output file
    # ================================================================
    
    output_data = {
        "mt5_login": credentials.get("mt5_login", ""),
        "mt5_password": credentials.get("mt5_password", ""),
        "mt5_server": credentials.get("mt5_server", ""),
        "ws_url": ws_url,
        "account_id": args.account_id,
    }
    
    with open(args.output, "w") as f:
        json.dump(output_data, f)
    
    print(f"  Launcher: ✅ Credentials written to {args.output}")
    print(f"  Launcher: Done — MT5 can start now")
    

if __name__ == "__main__":
    main()