import asyncio
import json
import logging
import websockets

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S"
)
logger = logging.getLogger("TabCircle")

clients = set()

async def handler(websocket):
    logger.info("Extension connected.")
    clients.add(websocket)
    
    # Request settings to verify two-way communication
    await websocket.send(json.dumps({
        "type": "settings",
        "scopeToWindow": True,
        "tabLifetimeHours": 12
    }))
    
    # Request MRU list
    await websocket.send(json.dumps({
        "type": "requestMRU"
    }))
    
    try:
        async for message in websocket:
            try:
                data = json.loads(message)
                msg_type = data.get("type", "unknown")
                
                if msg_type == "log":
                    logger.info(f"[Extension Log] {data.get('message')}")
                elif msg_type == "mru":
                    tabs = data.get("tabs", [])
                    windows = data.get("windows", [])
                    logger.info(f"Received MRU update: {len(tabs)} tabs across {len(windows)} windows.")
                elif msg_type == "thumb":
                    tab_id = data.get("tabId")
                    logger.info(f"Received thumbnail for tab {tab_id}.")
                elif msg_type == "requestSettings":
                    logger.info("Extension requested settings.")
                    await websocket.send(json.dumps({
                        "type": "settings",
                        "scopeToWindow": True,
                        "tabLifetimeHours": 12
                    }))
                else:
                    # Ignore loud repetitive messages if any, or log them
                    logger.debug(f"Received message type: {msg_type}")
            except json.JSONDecodeError:
                logger.error("Failed to parse JSON from extension.")
    except websockets.exceptions.ConnectionClosed:
        logger.info("Extension disconnected.")
    finally:
        clients.remove(websocket)

async def main():
    server = await websockets.serve(handler, "127.0.0.1", 41573)
    logger.info("WebSocket server listening on ws://127.0.0.1:41573/")
    await server.wait_closed()

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        logger.info("Server shut down.")
