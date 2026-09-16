#!/usr/bin/env python3
"""Integration tests: real daemon/CLI/sockets, fake HTTP Board API. No account needed."""
import json
import os
from pathlib import Path
import queue
import socket
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BIN = os.environ.get("GAMBITO_TEST_BIN", str(Path(__file__).resolve().parents[1] / "target/debug/gambito"))

def until(fn, timeout=12):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = fn()
        if value:
            return value
        time.sleep(.05)
    raise AssertionError("condition timed out")

class Client:
    def __init__(self, path):
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.settimeout(12)
        self.socket.connect(path)
        self.file = self.socket.makefile("rwb", buffering=0)
        self.initial = self.read()

    def read(self):
        return json.loads(self.file.readline())

    def call(self, cmd, **params):
        self.file.write((json.dumps(dict(cmd=cmd, **params)) + "\n").encode())
        while True:
            event = self.read()
            if event["type"] == "reply":
                return event

    def close(self):
        self.file.close()
        self.socket.close()

class Fake:
    def __init__(self):
        self.events = queue.Queue()
        self.game_queues = {}
        self.moves = {"game0001": "", "game0002": ""}
        self.stream_count = {}
        self.seek_params = None
        self.actions = []

    def state(self, gid):
        return dict(type="gameState", moves=self.moves[gid], status="started", wtime=600000, btime=600000)

    def full(self, gid):
        return dict(type="gameFull", id=gid, variant={"key": "standard"}, initialFen="startpos",
                    white={"id": "tester", "name": "José"}, black={"id": "opponent", "name": "Opponent"}, state=self.state(gid))

fake = Fake()

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *args):
        pass

    def json(self, body, status=200):
        raw = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def stream(self, q, first=None):
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.end_headers()
        try:
            self.wfile.write(b"\n"); self.wfile.flush()
            if first is not None:
                raw = json.dumps(first, ensure_ascii=False).encode() + b"\n"
                split = raw.index("é".encode()) + 1 if "é".encode() in raw else 10
                self.wfile.write(raw[:split]); self.wfile.flush()
                time.sleep(.02)
                self.wfile.write(raw[split:]); self.wfile.flush()
            while True:
                try:
                    event = q.get(timeout=.5)
                except queue.Empty:
                    event = "heartbeat"
                if event == "disconnect":
                    self.close_connection = True
                    return
                self.wfile.write(b"\n" if event == "heartbeat" else json.dumps(event).encode() + b"\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        if self.headers.get("Authorization") != "Bearer test-only-token":
            return self.json({"error": "bad token"}, 401)
        if self.path == "/api/account":
            return self.json({"id": "tester", "username": "Tester"})
        if self.path == "/api/account/playing":
            return self.json({"nowPlaying": [{"gameId": "game0001"}]})
        if self.path == "/api/stream/event":
            return self.stream(fake.events)
        if self.path.startswith("/api/board/game/stream/"):
            gid = self.path.rsplit("/", 1)[1]
            fake.stream_count[gid] = fake.stream_count.get(gid, 0) + 1
            q = queue.Queue(); fake.game_queues[gid] = q
            return self.stream(q, fake.full(gid))
        self.json({"error": "missing"}, 404)

    def do_POST(self):
        data = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        fake.actions.append(self.path)
        if self.path == "/api/board/seek":
            from urllib.parse import parse_qs
            fake.seek_params = parse_qs(data)
            return self.stream(queue.Queue())
        if "/move/" in self.path:
            gid, _, move = self.path.removeprefix("/api/board/game/").partition("/move/")
            fake.moves[gid] = (fake.moves[gid] + " " + move).strip()
            self.json({"ok": True})
            fake.game_queues[gid].put(fake.state(gid))
            return
        if self.path == "/api/challenge/ai":
            return self.json({"id": "game0002"})
        if self.path.endswith("/resign"):
            gid = self.path.split("/")[-2]
            self.json({"ok": True})
            fake.game_queues[gid].put(dict(fake.state(gid), status="resign", winner="black"))
            return
        self.json({"ok": True})

def main():
    http = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=http.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix="gambito-test-") as folder:
        base = Path(folder)
        env = dict(os.environ, XDG_DATA_HOME=str(base / "data"), XDG_CONFIG_HOME=str(base / "config"),
                   GAMBITO_SOCKET=str(base / "socket"), GAMBITO_API_URL=f"http://127.0.0.1:{http.server_port}")
        log = (base / "daemon.log").open("w+")
        daemon = None
        clients = []

        def start():
            nonlocal daemon
            daemon = subprocess.Popen([BIN, "daemon"], env=env, stdout=log, stderr=log)
            until(lambda: (base / "socket").exists() or daemon.poll() is not None)
            assert daemon.poll() is None

        def cli(*args, ok=True):
            p = subprocess.run([BIN, "--json", *args], env=env, text=True, capture_output=True, timeout=35)
            if ok:
                assert p.returncode == 0, p.stderr
                return json.loads(p.stdout)
            assert p.returncode != 0
            return p.stderr

        def state_game(gid):
            return next((g for g in cli("list") if g["id"] == gid), None)

        try:
            start()
            assert (base / "socket").stat().st_mode & 0o777 == 0o600
            duplicate = subprocess.run([BIN, "daemon"], env=env, capture_output=True, timeout=5)
            assert duplicate.returncode != 0
            a, b = Client(str(base / "socket")), Client(str(base / "socket")); clients += [a, b]
            g1 = a.call("local")["data"]["game"]
            g2 = b.call("local")["data"]["game"]
            assert g1 != g2
            assert a.call("move", game=g1, notation="e4")["ok"]
            assert b.call("move", game=g2, notation="d4")["ok"]
            assert not b.call("move", game=g1, notation="e4")["ok"]
            assert b.call("move", game=g1, notation="e5")["ok"]
            assert state_game(g1)["san"] == ["e4", "e5"]
            assert state_game(g2)["san"] == ["d4"]
            # A partially received command must survive broadcasts on that socket.
            b.file.write(b'{"cmd":"move","game":')
            assert a.call("move", game=g1, notation="Nf3")["ok"]
            b.file.write((json.dumps(g2) + ',"notation":"d5"}\n').encode())
            while True:
                event = b.read()
                if event["type"] == "reply":
                    assert event["ok"]
                    break
            assert state_game(g2)["san"] == ["d4", "d5"]
            pgn = a.call("export", game=g1)["data"]
            assert "1. e4 e5 2. Nf3 *" in pgn
            for client in clients: client.close()
            clients.clear()
            daemon.terminate(); daemon.wait(timeout=5)
            start()
            assert state_game(g1)["san"] == ["e4", "e5", "Nf3"]
            print("PASS local: regras, clientes independentes, estado compartilhado, PGN, persistência, lock e permissões")

            token = base / "config/gambito/token"
            token.parent.mkdir(parents=True)
            token.write_text("test-only-token"); token.chmod(0o600)
            c = Client(str(base / "socket")); clients.append(c)
            assert c.call("reload_auth")["ok"]
            until(lambda: state_game("game0001"))
            assert state_game("game0001")["white"] == "José"
            assert state_game("game0001")["color"] == "white"
            cli("move", "game0001", "e4")
            until(lambda: state_game("game0001")["san"] == ["e4"])
            assert "adversário" in cli("move", "game0001", "Nf3", ok=False)
            fake.moves["game0001"] = "e2e4 e7e5"
            fake.game_queues["game0001"].put(fake.state("game0001"))
            until(lambda: state_game("game0001")["san"] == ["e4", "e5"])
            fake.game_queues["game0001"].put("disconnect")
            until(lambda: fake.stream_count["game0001"] >= 2)
            until(lambda: state_game("game0001")["connected"])
            cli("move", "game0001", "Nf3")
            until(lambda: state_game("game0001")["san"] == ["e4", "e5", "Nf3"])
            cli("seek", "15", "10", "--rated")
            until(lambda: fake.seek_params)
            assert fake.seek_params["time"] == ["15"]
            assert fake.seek_params["increment"] == ["10"]
            assert fake.seek_params["rated"] == ["true"]
            assert cli("status")["seeking"]
            cli("cancel")
            assert not cli("status")["seeking"]
            cli("ai", "2")
            until(lambda: state_game("game0002"))
            cli("draw", "game0002")
            assert "/api/board/game/game0002/draw/yes" in fake.actions
            cli("resign", "game0002", "--yes")
            until(lambda: state_game("game0002")["status"] == "resign")
            assert state_game("game0001")["status"] == "started"
            print("PASS Lichess simulado: auth, NDJSON fragmentado, turnos, lances, reconexão, busca, cancelamento, IA e ações")
        except Exception:
            log.flush(); log.seek(0); print(log.read())
            raise
        finally:
            for client in clients: client.close()
            if daemon and daemon.poll() is None:
                daemon.terminate(); daemon.wait(timeout=5)
            http.shutdown()

if __name__ == "__main__":
    main()
