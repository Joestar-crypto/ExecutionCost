import websocket
import msgpack
import json
import sys

WS_URL = "wss://mainnet.zklighter.elliot.ai/stream?encoding=msgpack&readonly=true"

def on_message(ws, message):
    try:
        data = msgpack.unpackb(message)
        print(f"MSG: {json.dumps(data, default=str)[:500]}")
    except:
        print(f"RAW ({len(message)}B): {message[:200].hex()}")

def on_error(ws, error):
    print(f"ERR: {error}")

def on_close(ws, status, msg):
    print(f"CLOSE: {status} {msg}")

def on_open(ws):
    print("CONNECTED")
    # Try JSON subscription
    subs = [
        '{"type":"subscribe","channel":"orderbook","symbol":"ETH"}',
        '{"type":"subscribe","channel":"orderbook","market":"ETH"}',
        '{"type":"subscribe","channel":"orderbook","market_id":0}',
        '{"method":"subscribe","params":{"channel":"orderbook","symbol":"ETH"}}',
        '{"type":"subscribe","stream":"orderbook@ETH"}',
    ]
    for s in subs:
        ws.send(s)
        print(f"SENT: {s}")

ws = websocket.WebSocketApp(WS_URL,
    on_message=on_message,
    on_error=on_error,
    on_close=on_close,
    on_open=on_open)

# Run for 10 seconds
import threading, time
t = threading.Thread(target=ws.run_forever)
t.daemon = True
t.start()
time.sleep(10)
print("DONE - received data above")
ws.close()
