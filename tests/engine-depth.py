#!/usr/bin/env python3
"""A silent deep iteration must survive the old ten-second search timeout."""
import os
from pathlib import Path
import subprocess
import tempfile
import time
from integration import Client, until

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="gambito-depth-") as directory:
    base = Path(directory)
    env = dict(os.environ, GAMBITO_SOCKET=str(base / "socket"),
               XDG_CONFIG_HOME=str(base / "config"), XDG_DATA_HOME=str(base / "data"),
               GAMBITO_STOCKFISH=str(root / "tests/fake-stockfish.sh"),
               GAMBITO_TEST_ENGINE_DELAY="11", GAMBITO_NOTIFY_CMD="")
    with (base / "daemon.log").open("w+") as log:
        daemon = subprocess.Popen([os.environ.get("GAMBITO_TEST_BIN", str(root / "target/debug/gambito")), "daemon"],
                                  env=env, stdout=log, stderr=log)
        client = None
        try:
            until(lambda: (base / "socket").exists())
            client = Client(str(base / "socket"))
            client.socket.settimeout(20)
            game = client.call("local")["data"]["game"]
            started = time.monotonic()
            reply = client.call("eval", game=game, depth=37, stream=True)
            assert reply["ok"], reply
            result = reply["data"]["eval"]
            assert result["depth"] == 37 and result["target_depth"] == 37, result
            assert time.monotonic() - started >= 11
            print("PASS depth-only search: requested depth 37 reached after 11 seconds of silence")
        finally:
            if client:
                client.close()
            daemon.terminate()
            daemon.wait(timeout=5)
