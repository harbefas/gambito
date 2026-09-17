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

HIST_ANALYSIS = [{"eval": 20}, {"eval": 25}, {"eval": 30}, {"eval": 60, "best": "g8f6", "variation": "Nf6 d3 Bc5",
                  "judgment": {"name": "Inaccuracy", "comment": "Inaccuracy. Nf6 was best."}},
                 {"eval": 55}, {"mate": 1, "best": "g7g6", "variation": "g6 Qf3 Nf6", "judgment": {"name": "Blunder", "comment": "Checkmate is now unavoidable. g6 was best."}},
                 {"mate": 0}]

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
        self.challenge = None
        self.ai_params = None
        self.invitations = {"in": [], "out": []}
        self.challenge_params = None
        self.chat = [{"user": "Opponent", "text": "Olá!"}]
        self.chat_params = None
        self.opponent_takeback = False

    def state(self, gid):
        return dict(type="gameState", moves=self.moves[gid], status="started", wtime=600000, btime=600000)

    def full(self, gid):
        return dict(type="gameFull", id=gid, variant={"key": "standard"}, initialFen="startpos",
                    white={"id": "tester", "name": "José", "rating": 1523}, black={"id": "opponent", "name": "Opponent", "rating": 1610},
                    rated=True, speed="rapid", clock={"initial": 600000, "increment": 5000}, state=self.state(gid))

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
        # Public endpoints, also used without an account.
        if self.path.startswith("/api/puzzle/next?"):
            # A token without puzzle:read is refused; the daemon then retries anonymously.
            authed = self.headers.get("Authorization") == "Bearer test-only-token"
            self.server.puzzle_auth.append(authed)
            if authed and not self.server.puzzle_scope:
                return self.json({"error": "Missing scope: puzzle:read"}, 403)
            from urllib.parse import urlparse, parse_qs
            query = parse_qs(urlparse(self.path).query)
            self.server.puzzle_queries.append(query)
            n = len(self.server.puzzle_queries)
            return self.json({"game": {"id": "src0000%d" % n, "pgn": "e4 e5 Qh5 Nc6 Bc4 Nf6", "clock": "5+0", "perf": {"name": "Blitz"}, "rated": True,
                                       "players": [{"name": "A", "color": "white", "rating": 1500}, {"name": "B", "color": "black", "rating": 1500}]},
                              "puzzle": {"id": "Next%d" % n, "rating": 1400, "plays": 10, "themes": ["mateIn1"], "solution": ["h5f7"]}})
        if self.path == "/api/puzzle/dashboard/30":
            return self.json({"error": "Not found"}, 404)  # nothing played in the last 30 days
        if self.path == "/api/puzzle/dashboard/90" or self.path.startswith("/api/puzzle/activity"):
            if self.headers.get("Authorization") != "Bearer test-only-token" or not self.server.puzzle_scope:
                return self.json({"error": "Missing scope: puzzle:read"}, 403)
            if self.path.startswith("/api/puzzle/activity"):
                raw = (json.dumps({"date": 1789600000000, "win": True, "puzzle": {"id": "Act01", "rating": 1500, "themes": ["fork"]}}) + "\n").encode()
                self.send_response(200); self.send_header("Content-Type", "application/x-ndjson"); self.send_header("Content-Length", str(len(raw))); self.end_headers(); self.wfile.write(raw)
                return
            return self.json({"days": 90, "global": {"nb": 20, "firstWins": 14, "replayWins": 2, "puzzleRatingAvg": 1500, "performance": 1550},
                              "themes": {"fork": {"theme": "Fork", "results": {"nb": 10, "firstWins": 8, "replayWins": 0, "puzzleRatingAvg": 1450, "performance": 1600}}}})
        if self.path == "/training/themes":
            return self.json({"themes": {"Recommended": [{"key": "mix", "name": "Healthy mix", "desc": "A bit of everything.", "count": 6404540}],
                                         "Mates": [{"key": "mateIn1", "name": "Mate in 1", "desc": "Deliver checkmate in one move.", "count": 912293}]}})
        if self.path == "/training/openings":
            return self.json({"openings": [{"family": {"key": "Sicilian_Defense", "name": "Sicilian Defense", "count": 204576}, "openings": []}]})
        if self.path == "/api/puzzle/daily":
            return self.json({"game": {"id": "src00001", "pgn": "e4 e5 Qh5 Nc6 Bc4 Nf6", "clock": "3+2", "perf": {"name": "Blitz"}, "rated": True,
                                       "players": [{"name": "Agadmater", "color": "white", "rating": 1526}, {"name": "Gummyy", "color": "black", "rating": 1532}]},
                              "puzzle": {"id": "Pz001", "rating": 1500, "plays": 58311, "themes": ["mateIn1"], "solution": ["h5f7"]}})
        if self.path in ("/@/Lichess/blog.atom", "/blog/community.atom"):
            name = "Lichess" if "Lichess" in self.path else "writer"
            raw = ("<feed><entry><published>2026-09-16T10:00:00Z</published><link rel=\"alternate\" type=\"text/html\" href=\"https://lichess.org/@/%s/blog/post\" />"
                   "<title>News &amp; notes</title><author><name>%s</name></author></entry></feed>" % (name, name)).encode()
            self.send_response(200); self.send_header("Content-Type", "application/atom+xml"); self.send_header("Content-Length", str(len(raw))); self.end_headers(); self.wfile.write(raw)
            return
        if self.path == "/api/stream/game/watch001":
            return self.stream(self.server.watch, {"id": "watch001", "speed": "blitz", "rated": True, "players": {"white": {"user": {"name": "José"}, "rating": 3000}, "black": {"aiLevel": 8}}})
        if self.path.startswith("/game/export/watch001?"):
            return self.json({"id": "watch001", "status": "mate", "winner": "white"})
        if self.path == "/api/tv/channels":
            return self.json({"bullet": {"user": {"name": "KiKiKiRA", "title": "IM"}, "rating": 2827, "gameId": "t8siWVwF", "color": "white"},
                              "horde": {"user": {"name": "papa_reza"}, "rating": 1866, "gameId": "o5E0OrAR", "color": "white"}})
        if self.path == "/api/crosstable/Frogkiller/McBeast":
            return self.json({"users": {"frogkiller": 15.5, "mcbeast": 26.5}, "nbGames": 42})
        if self.path == "/api/tv/bullet/feed":
            return self.stream(self.server.tv, {"t": "featured", "d": {"id": "bullet01", "orientation": "black", "fen": "8/8/8/8/8/8/8/K6k w - - 0 1", "players": []}})
        if self.path == "/api/tv/feed":
            return self.stream(self.server.tv, {"t": "featured", "d": {"id": "tv000001", "orientation": "white", "fen": "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
                                                                     "players": [{"color": "white", "user": {"name": "José"}, "rating": 3000, "seconds": 60}, {"color": "black", "user": {"name": "Rival"}, "rating": 2990, "seconds": 60}]}})
        if self.headers.get("Authorization") != "Bearer test-only-token":
            return self.json({"error": "bad token"}, 401)
        if self.path == "/masters/pgn/mstr0001":
            raw = b'[White "Carlsen, M."]\n[Black "Caruana, F."]\n[WhiteElo "2882"]\n\n1. e4 {x} e5 2. Nf3 (2. Bc4) Nc6 1/2-1/2\n'
            self.send_response(200); self.send_header("Content-Length", str(len(raw))); self.end_headers(); self.wfile.write(raw)
            return
        if self.path.startswith("/masters?") or self.path.startswith("/lichess?"):
            from urllib.parse import urlparse, parse_qs
            query = parse_qs(urlparse(self.path).query)
            self.server.explorer_fens.append(query["fen"][0])
            self.server.explorer_queries.append(query)
            return self.json({"white": 10, "draws": 5, "black": 5, "opening": {"eco": "C20", "name": "King's Pawn Game"},
                              "moves": [{"san": "Nf3", "uci": "g1f3", "white": 6, "draws": 3, "black": 1, "averageRating": 2400}]})
        if self.path == "/api/challenge":
            return self.json(fake.invitations)
        if self.path == "/api/board/game/game0001/chat":
            return self.json(fake.chat)
        if self.path == "/api/account":
            return self.json({"id": "tester", "username": "Tester"})
        if self.path.startswith("/api/games/user/Tester?"):
            assert self.headers.get("Accept") == "application/x-ndjson" and "finished=true" in self.path
            from urllib.parse import urlparse, parse_qs
            query = parse_qs(urlparse(self.path).query)
            self.server.history_queries.append(query)
            games = [dict(id="hist0001", rated=True, variant="standard", speed="blitz", status="mate", winner="white", lastMoveAt=1700000000000, createdAt=1699999000000,
                          players={"white": {"user": {"name": "Tester", "id": "tester"}, "rating": 1500}, "black": {"user": {"name": "Rival", "id": "rival"}, "rating": 1490}},
                          moves="e4 e5 Bc4 Nc6 Qh5 Nf6 Qxf7#", clock={"initial": 300, "increment": 3, "totalTime": 420},
                          analysis=HIST_ANALYSIS),
                     dict(id="hist0002", rated=False, variant="chess960", speed="blitz", status="draw", players={}, moves="", createdAt=1699998000000)]
            games = games[:int(query["max"][0])]
            if "until" in query:
                games = [g for g in games if g["createdAt"] <= int(query["until"][0])]
            raw = "".join(json.dumps(g) + "\n" for g in games).encode()
            self.send_response(200); self.send_header("Content-Type", "application/x-ndjson")
            self.send_header("Content-Length", str(len(raw))); self.end_headers(); self.wfile.write(raw)
            return
        if self.path == "/api/user/Tester/rating-history":
            return self.json([{"name": "Blitz", "points": [[2023, 0, 1, 1500], [2023, 5, 1, 1520]]}, {"name": "Bullet", "points": []}])
        if self.path == "/api/user/Tester/activity":
            return self.json([{"interval": {"start": 1, "end": 2}, "games": {"blitz": {"win": 1, "loss": 0, "draw": 0}}}])
        if self.path == "/api/user/Tester/perf/blitz":
            return self.json({"perf": {"glicko": {"rating": 1520}, "nb": 2}, "stat": {"highest": {"int": 1530}}})
        if self.path.startswith("/game/export/hist0001?"):
            assert self.headers.get("Accept") == "application/json" and "evals=true" in self.path
            return self.json(dict(id="hist0001", analysis=HIST_ANALYSIS[:2] + [{"eval": 90}] + HIST_ANALYSIS[3:],
                                  players={"white": {"analysis": {"inaccuracy": 0, "mistake": 0, "blunder": 0, "accuracy": 99}}, "black": {}}))
        if self.path.startswith("/api/cloud-eval?"):
            from urllib.parse import urlparse, parse_qs
            fen = parse_qs(urlparse(self.path).query)["fen"][0]
            if fen.startswith("rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b"):
                return self.json({"fen": fen, "depth": 40, "pvs": [{"moves": "e7e5 g1f3", "cp": 18}]})
            return self.json({"error": "No cloud evaluation available for that position"}, 404)
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
        if self.path.startswith("/api/puzzle/batch/"):
            if not self.server.puzzle_scope:
                return self.json({"error": "Missing scope: puzzle:write"}, 403)
            body = json.loads(data)
            self.server.puzzle_batches.append((self.path, body))
            return self.json({"puzzles": [], "rounds": [{"id": body["solutions"][0]["id"], "win": body["solutions"][0]["win"], "ratingDiff": 12}]})
        if self.path == "/api/token":
            import base64, hashlib
            from urllib.parse import parse_qs
            form = {k: v[0] for k, v in parse_qs(data).items()}
            challenge = base64.urlsafe_b64encode(hashlib.sha256(form["code_verifier"].encode()).digest()).rstrip(b"=").decode()
            ok = form["code"] == "test-code" and challenge == fake.challenge and form["grant_type"] == "authorization_code"
            return self.json({"access_token": "test-only-token"} if ok else {"error": "invalid_grant"}, 200 if ok else 400)
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
        if self.path == "/api/challenge/Friend":
            from urllib.parse import parse_qs
            fake.challenge_params = parse_qs(data)
            challenge = {"id": "chall001", "challenger": {"id": "tester", "name": "Tester"}, "destUser": {"id": "friend", "name": "Friend"}, "variant": {"key": "standard", "name": "Standard"}, "speed": "blitz", "timeControl": {"show": "3+2"}, "status": "created"}
            fake.invitations["out"] = [challenge]
            return self.json(challenge)
        if self.path.startswith("/api/challenge/") and self.path.rsplit("/", 1)[-1] in ("accept", "decline", "cancel"):
            cid = self.path.split("/")[-2]
            for direction in ("in", "out"):
                fake.invitations[direction] = [c for c in fake.invitations[direction] if c["id"] != cid]
            return self.json({"ok": True})
        if self.path == "/api/board/game/game0001/chat":
            from urllib.parse import parse_qs
            fake.chat_params = parse_qs(data)
            if fake.chat_params["text"] == ["reject"]:
                return self.json({"error": "Chat disabled"}, 400)
            line = {"user": "Tester", "text": fake.chat_params["text"][0]}
            fake.chat.append(line)
            self.json({"ok": True})
            fake.game_queues["game0001"].put({"type": "chatLine", "room": "player", "username": line["user"], "text": line["text"]})
            return
        if "/takeback/" in self.path:
            accept = self.path.endswith("/yes")
            if accept and fake.opponent_takeback:
                fake.moves["game0001"] = " ".join(fake.moves["game0001"].split()[:-1])
                fake.opponent_takeback = False
                offered = False
            else:
                offered = accept
            self.json({"ok": True})
            fake.game_queues["game0001"].put(dict(fake.state("game0001"), wtakeback=offered))
            return
        if self.path == "/api/challenge/ai":
            from urllib.parse import parse_qs
            fake.ai_params = parse_qs(data)
            return self.json({"id": "game0002"})
        if self.path.endswith("/resign"):
            gid = self.path.split("/")[-2]
            self.json({"ok": True})
            fake.game_queues[gid].put(dict(fake.state(gid), status="resign", winner="black"))
            return
        self.json({"ok": True})

def main():
    http = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    http.history_queries = []
    http.tv = queue.Queue()
    http.watch = queue.Queue()
    http.explorer_fens = []
    http.explorer_queries = []
    http.puzzle_queries = []
    http.puzzle_auth = []
    http.puzzle_scope = False
    http.puzzle_batches = []
    threading.Thread(target=http.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix="gambito-test-") as folder:
        base = Path(folder)
        env = dict(os.environ, XDG_DATA_HOME=str(base / "data"), XDG_CONFIG_HOME=str(base / "config"),
                   GAMBITO_SOCKET=str(base / "socket"), GAMBITO_API_URL=f"http://127.0.0.1:{http.server_port}", GAMBITO_EXPLORER_URL=f"http://127.0.0.1:{http.server_port}",
                   GAMBITO_NOTIFY_CMD=str(base / "notify"), GAMBITO_STOCKFISH=str(Path(__file__).with_name("fake-stockfish.sh")))
        (base / "notify").write_text(f"#!/bin/sh\necho \"$@\" >> {base / 'notifications'}\n")
        (base / "notify").chmod(0o755)
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
            positions = a.call("positions", game=g1)["data"]
            assert positions["plies"] == 3 and len(positions["positions"]) == 4 and positions["for"] == g1
            pgn = a.call("export", game=g1)["data"]
            assert "1. e4 e5 2. Nf3 *" in pgn
            a.file.write((json.dumps(dict(cmd="eval", game=g1, ply=1, stream=True, request_id="live-eval")) + "\n").encode())
            updates = []
            while True:
                event = a.read()
                if event["type"] == "eval":
                    assert event["request_id"] == "live-eval"
                    updates.append(event["eval"])
                if event["type"] == "reply":
                    assert event["ok"], event
                    ev = event["data"]["eval"]
                    break
            assert updates and updates[0]["depth"] == 4 and updates[0]["cp"] == -10, updates
            assert updates[0]["for"] == g1 and updates[0]["ply"] == 1, updates
            assert (ev["cp"], ev["depth"], ev["pv"], ev["source"], ev["ply"]) == (-35, 30, ["e5", "Nf3"], "FakeFish", 1), ev
            # Cancel an unfinished search, then verify the engine can search again.
            a.file.write((json.dumps(dict(cmd="eval", game=g1, ply=0, stream=True, request_id="cancelled-search")) + "\n").encode())
            while True:
                event = a.read()
                if event["type"] == "eval" and event["request_id"] == "cancelled-search":
                    break
            a.file.write(b'{"cmd":"cancel_eval","request_id":"stop"}\n')
            replies = {}
            while len(replies) < 2:
                event = a.read()
                if event["type"] == "reply":
                    replies[event["request_id"]] = event
            assert not replies["cancelled-search"]["ok"], replies
            assert replies["stop"]["ok"], replies
            assert a.call("eval", game=g1, ply=0)["data"]["eval"]["depth"] == 30
            deeper = a.call("eval", game=g1, ply=1, depth=35)["data"]["eval"]
            assert deeper["depth"] == 35 and deeper["target_depth"] == 35, deeper
            shallower = a.call("eval", game=g1, ply=1, depth=8)["data"]["eval"]
            assert shallower["depth"] == 8 and shallower["target_depth"] == 8, shallower
            for invalid in [0, 246, -1, 2.5, "30"]:
                assert not a.call("eval", game=g1, depth=invalid)["ok"]
            branch = a.call("analyse", game=g1, ply=1)["data"]["game"]
            assert a.call("move", game=branch, notation="c5")["ok"]
            assert state_game(g1)["san"] == ["e4", "e5", "Nf3"]
            assert state_game(branch)["analysis"] and not state_game(branch)["online"]
            assert state_game(branch)["san"] == ["e4", "c5"]
            alternate = a.call("analyse", game=branch, ply=1)["data"]["game"]
            assert a.call("move", game=alternate, notation="e5")["ok"]
            assert state_game(branch)["san"] == ["e4", "c5"]
            assert state_game(alternate)["analysis_source"] == branch
            assert not a.call("analyse", game=g1, ply=999)["ok"]
            assert not a.call("analyse", fen="invalid")["ok"]
            fen_board = a.call("analyse", fen="7k/8/8/8/8/8/8/K7 b - - 0 20")["data"]["game"]
            assert a.call("move", game=fen_board, notation="Kg7")["ok"]
            assert "20... Kg7" in a.call("export", game=fen_board)["data"]
            nested = a.call("analyse", game=alternate, ply=1)["data"]["game"]
            assert "Only analysis boards and puzzles" in a.call("delete", game=g1)["error"]
            assert a.call("delete", game=alternate)["data"] == "Variation and 1 branches deleted"
            assert state_game(alternate) is None and state_game(nested) is None
            assert state_game(branch)["san"] == ["e4", "c5"] and state_game(g1)["san"] == ["e4", "e5", "Nf3"]
            alternate = a.call("analyse", game=branch, ply=1)["data"]["game"]
            assert a.call("move", game=alternate, notation="e5")["ok"]
            print("PASS analysis: historical branches, alternatives, FEN, delete with sub-branches, original preserved")
            print("PASS streaming: intermediate scores, cancellation and engine recovery")
            for client in clients: client.close()
            clients.clear()
            daemon.terminate(); daemon.wait(timeout=5)
            env["GAMBITO_STOCKFISH"] = str(base / "no-engine")
            start()
            assert state_game(g1)["san"] == ["e4", "e5", "Nf3"]
            assert state_game(branch)["san"] == ["e4", "c5"]
            assert state_game(alternate)["analysis_source"] == branch
            print("PASS local: rules, independent clients, shared state, PGN, persistence, lock and permissions")

            token = base / "config/gambito/token"
            token.parent.mkdir(parents=True)
            token.write_text("test-only-token"); token.chmod(0o600)
            c = Client(str(base / "socket")); clients.append(c)
            assert c.call("reload_auth")["ok"]
            until(lambda: state_game("game0001"))
            # Invitations: creation, validation, cancellation, incoming stream and reconnect snapshot.
            assert c.call("challenge", username="Friend", minutes=3, increment=2)["ok"]
            assert fake.challenge_params["clock.limit"] == ["180"]
            assert fake.challenge_params["clock.increment"] == ["2"]
            assert fake.challenge_params["variant"] == ["standard"]
            assert cli("status")["challenges"][0]["direction"] == "out"
            assert not c.call("challenge_accept", challenge="chall001")["ok"]
            assert c.call("challenge_cancel", challenge="chall001")["ok"]
            assert not cli("status")["challenges"]
            assert not c.call("challenge", username="../account")["ok"]
            assert not c.call("challenge", username="Friend", minutes=1, increment=0)["ok"]
            assert not c.call("challenge", username="Friend", minutes=10, increment=61)["ok"]
            assert c.call("challenge", username="Friend", days=3, color="black", rated=True)["ok"]
            assert fake.challenge_params["days"] == ["3"] and "clock.limit" not in fake.challenge_params
            assert fake.challenge_params["color"] == ["black"] and fake.challenge_params["rated"] == ["true"]
            assert c.call("challenge_cancel", challenge="chall001")["ok"]
            incoming = {"id": "invit001", "challenger": {"id": "friend", "name": "Friend"}, "destUser": {"id": "tester", "name": "Tester"}, "variant": {"key": "standard"}, "speed": "blitz"}
            fake.events.put({"type": "challenge", "challenge": incoming})
            until(lambda: cli("status")["challenges"])
            assert cli("status")["challenges"][0]["direction"] == "in"
            assert c.call("challenge_accept", challenge="invit001")["ok"]
            assert "/api/challenge/invit001/accept" in fake.actions
            fake.events.put({"type": "challenge", "challenge": dict(incoming, variant={"key": "atomic"})})
            until(lambda: cli("status")["challenges"])
            assert not c.call("challenge_accept", challenge="invit001")["ok"]
            assert c.call("challenge_decline", challenge="invit001")["ok"]
            fake.invitations["in"] = [incoming]
            fake.events.put("disconnect")
            until(lambda: cli("status")["challenges"])
            assert c.call("challenge_decline", challenge="invit001")["ok"]
            fake.events.put({"type": "challenge", "challenge": incoming})
            until(lambda: cli("status")["challenges"])
            fake.events.put({"type": "challengeCanceled", "challenge": incoming})
            until(lambda: not cli("status")["challenges"])
            # Private chat: UTF-8, exact POST room, live delivery to another socket, error propagation.
            assert cli("chat", "game0001")["lines"] == fake.chat
            observer = Client(str(base / "socket")); clients.append(observer)
            cli("chat", "game0001", "Boa partida! ♟")
            assert fake.chat_params == {"room": ["player"], "text": ["Boa partida! ♟"]}
            while True:
                event = observer.read()
                if event["type"] == "chat": break
            assert event["game"] == "game0001" and event["line"]["text"] == "Boa partida! ♟"
            assert not c.call("chat", game="game0001", text=" ")["ok"]
            assert not c.call("chat", game="game0001", text="x" * 141)["ok"]
            assert not c.call("chat", game="game0001", text="a\nb")["ok"]
            assert "Chat disabled" in c.call("chat", game="game0001", text="reject")["error"]
            assert not c.call("chat", game=g1, text="hello")["ok"]
            assert not c.call("takeback", game=g1, accept=True)["ok"]
            assert not c.call("takeback", game="game0001", accept="no")["ok"]
            cli("takeback", "game0001")
            until(lambda: state_game("game0001")["takeback_offer"] == "white")
            fake.game_queues["game0001"].put(dict(fake.state("game0001"), btakeback=True))
            until(lambda: state_game("game0001")["takeback_offer"] == "black")
            cli("takeback", "game0001", "--decline")
            until(lambda: state_game("game0001")["takeback_offer"] is None)
            assert "/api/board/game/game0001/takeback/no" in fake.actions
            print("PASS social: invitations, reconnect, unsupported controls, player chat delivery, takeback offers and refusals")
            # Finished games stay out of the broadcast state until opened from the profile.
            assert state_game("hist0001") is None
            page = c.call("history", max=1)["data"]["history"]
            assert [g["id"] for g in page["games"]] == ["hist0001"] and page["next_until"] == 1699998999999, page
            assert page["games"][0]["accuracy"] == {"white": None, "black": None} and page["games"][0]["plies"] == 7
            last = c.call("history", max=2, until=page["next_until"], perf="blitz", rated=True)["data"]["history"]
            assert last["games"] == [] and last["next_until"] is None, last  # hist0002 is chess960, end of history
            q = http.history_queries[-1]
            assert (q["until"], q["perfType"], q["rated"]) == (["1699998999999"], ["blitz"], ["true"]), q
            assert "Unknown speed" in c.call("history", perf="atomic")["error"]
            assert c.call("open", game="hist0001")["ok"]
            until(lambda: state_game("hist0001"))
            profile = c.call("profile")["data"]["profile"]
            assert profile["account"]["username"] == "Tester" and profile["ratings"][0]["points"][1][3] == 1520
            assert profile["activity"][0]["games"]["blitz"]["win"] == 1
            assert c.call("perf", perf="blitz")["data"]["perf"]["stat"]["highest"]["int"] == 1530
            assert "Unknown speed" in c.call("perf", perf="../account")["error"]
            puzzle = c.call("puzzle")["data"]["puzzle"]
            assert (puzzle["id"], puzzle["solution"], puzzle["last_move"], puzzle["sans"]) == ("Pz001", ["h5f7"], "g8f6", ["Qxf7#"]), puzzle
            assert len(puzzle["fens"]) == 2 and puzzle["fens"][0].split()[1] == "w" and puzzle["fens"][1].startswith("r1bqkb1r/pppp1Qpp")
            assert puzzle["history"] == ["e2e4", "e7e5", "d1h5", "b8c6", "f1c4", "g8f6"] and puzzle["source"]["clock"] == "3+2"
            # Puzzle on the main board: source game first, solution checked, engine hidden until solved.
            pid = c.call("puzzle_open")["data"]["game"]
            assert pid == "puzzle-Pz001" and c.call("puzzle_open")["data"]["game"] == pid
            pg = state_game(pid)
            assert (len(pg["moves"]), pg["color"], pg["white"], pg["black_rating"], pg["puzzle"]["start"], pg["puzzle"]["plays"]) == (6, "white", "Agadmater", 1532, 6, 58311), pg
            assert "until the puzzle is solved" in c.call("eval", game=pid)["error"]
            assert "Not the move" in c.call("move", game=pid, notation="Qxe5+")["error"]
            assert c.call("move", game=pid, notation="Qxf7#")["ok"]
            assert state_game(pid)["status"] == "solved" and state_game(pid)["san"][-1] == "Qxf7#"
            assert "until the puzzle is solved" not in c.call("eval", game=pid).get("error", "")
            assert c.call("puzzle_retry", game=pid)["ok"] and len(state_game(pid)["moves"]) == 6 and state_game(pid)["status"] == "started"
            assert c.call("puzzle_solution", game=pid)["ok"] and state_game(pid)["status"] == "solved"
            assert "Not a puzzle" in c.call("puzzle_retry", game=g1)["error"]
            themes = c.call("puzzle_themes")["data"]["puzzle_themes"]
            assert themes["themes"]["Mates"][0]["key"] == "mateIn1" and themes["openings"][0]["family"]["name"] == "Sicilian Defense"
            nxt = c.call("puzzle_next", angle="mateIn1", difficulty="harder")["data"]["game"]
            assert http.puzzle_queries[-1]["angle"] == ["mateIn1"] and http.puzzle_queries[-1]["difficulty"] == ["harder"]
            assert state_game(nxt)["puzzle"]["angle"] == "mateIn1" and len(state_game(nxt)["moves"]) == 6
            assert c.call("move", game=nxt, notation="Qxf7#")["ok"] and state_game(nxt)["status"] == "solved"
            nxt2 = c.call("puzzle_next", angle="mateIn1")["data"]["game"]
            assert nxt2 != nxt and state_game(nxt) is None  # solved themed puzzles are replaced
            assert state_game(pid)  # the daily puzzle is kept
            assert http.puzzle_auth[-2:] == [True, False]  # tried with the account, fell back to anonymous
            assert "sign out and connect Lichess again" in c.call("puzzle_dashboard")["error"]
            # With the puzzle scopes: account puzzles, results reported once, dashboard and history.
            http.puzzle_scope = True
            scoped = c.call("puzzle_next", angle="fork")["data"]["game"]
            assert http.puzzle_auth[-1] is True
            assert "Not the move" in c.call("move", game=scoped, notation="Qxe5+")["error"]
            assert c.call("move", game=scoped, notation="Qxf7#")["ok"]
            until(lambda: state_game(scoped)["puzzle"].get("submitted"))
            path, body = http.puzzle_batches[-1]
            assert path == "/api/puzzle/batch/fork" and body["solutions"] == [{"id": state_game(scoped)["puzzle"]["id"], "win": False, "rated": True}], body
            assert state_game(scoped)["puzzle"]["rating_diff"] == 12
            batches = len(http.puzzle_batches)
            assert c.call("puzzle_retry", game=scoped)["ok"] and c.call("puzzle_solution", game=scoped)["ok"]
            time.sleep(.5); assert len(http.puzzle_batches) == batches  # a puzzle is reported once
            dash = c.call("puzzle_dashboard")["data"]["puzzle_dashboard"]
            assert dash["dashboard"]["days"] == 90 and dash["dashboard"]["global"]["firstWins"] == 14 and dash["activity"][0]["puzzle"]["id"] == "Act01"
            c.call("delete", game=scoped)
            assert "Unknown difficulty" in c.call("puzzle_next", angle="fork", difficulty="brutal")["error"]
            assert "Invalid name" in c.call("puzzle_next", angle="a&b")["error"]
            assert c.call("delete", game=nxt2)["ok"] and state_game(nxt2) is None
            blog = c.call("blog")["data"]["blog"]
            assert blog["official"][0] == {"title": "News & notes", "author": "Lichess", "published": "2026-09-16T10:00:00Z", "url": "https://lichess.org/@/Lichess/blog/post"}, blog
            assert blog["community"][0]["author"] == "writer"
            # TV streams only to the connection that asked, until it stops.
            tv = Client(str(base / "socket")); clients.append(tv)
            tv.file.write(b'{"cmd":"tv_watch","request_id":"t"}\n')
            featured = until(lambda: next((e for e in iter(tv.read, None) if e["type"] == "tv"), None))
            assert featured["event"]["d"]["players"][0]["user"]["name"] == "José"
            http.tv.put({"t": "fen", "d": {"fen": "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1", "lm": "e2e4", "wc": 59, "bc": 60}})
            move = next(e for e in iter(tv.read, None) if e["type"] == "tv")
            assert move["event"]["d"]["lm"] == "e2e4"
            # Watching a TV game: replayed and live moves, spectator-only, final result from the export.
            for event in ({"fen": "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", "wc": 180, "bc": 180},
                          {"fen": "x", "lm": "e2e4", "wc": 180, "bc": 180}, {"fen": "x", "lm": "e7e5", "wc": 178, "bc": 179}, {"fen": "x", "lm": "g1f3", "wc": 177, "bc": 179}):
                http.watch.put(event)
            assert c.call("watch", game="watch001")["data"]["game"] == "watch001"
            until(lambda: state_game("watch001") and state_game("watch001")["san"] == ["e4", "e5", "Nf3"])
            w = state_game("watch001")
            assert (w["white"], w["black"], w["color"], w["white_ms"], w["speed"]) == ("José", "Stockfish level 8", None, 177000, "blitz"), w
            assert "watching" in c.call("move", game="watch001", notation="Nc6")["error"]
            # Spectators may analyse; fair play only restricts the player's own games.
            ev = c.call("eval", game="watch001", depth=5)  # no engine installed yet at this point
            assert "fair play" not in ev.get("error", "") and "Install Stockfish" in ev.get("error", ""), ev
            assert c.call("analyse", game="watch001", ply=2)["ok"]
            http.watch.put({"fen": "x", "lm": "b8c6", "wc": 177, "bc": 175})
            until(lambda: state_game("watch001")["san"][-1] == "Nc6")
            # Lichess repeats the game info with the result when the game ends: moves must survive.
            http.watch.put({"id": "watch001", "status": {"id": 30, "name": "resign"}, "winner": "black", "players": {"white": {"user": {"name": "José"}}, "black": {"aiLevel": 8}}})
            until(lambda: state_game("watch001")["status"] == "resign")
            assert state_game("watch001")["winner"] == "black" and state_game("watch001")["san"] == ["e4", "e5", "Nf3", "Nc6"]
            # A watch that never connects publishes nothing, and unwatch stops it.
            assert c.call("watch", game="nowatch1")["ok"]
            time.sleep(1)
            assert state_game("nowatch1") is None
            assert c.call("unwatch", game="nowatch1")["ok"]
            # Two windows watching: the first leaving keeps the game; the last one drops it.
            assert c.call("watch", game="watch001")["ok"]  # second window
            assert c.call("unwatch", game="watch001")["ok"]
            time.sleep(.5); assert state_game("watch001")
            # Leaving a watched game drops it; your own games are never removed this way.
            assert c.call("unwatch", game="watch001")["ok"]
            until(lambda: state_game("watch001") is None)
            assert c.call("unwatch", game="game0001")["ok"] and state_game("game0001")
            # Opening explorer for the shown position (needs the account token).
            ex = c.call("explorer", game=g1, ply=2, db="masters")["data"]
            assert ex["explorer"]["moves"][0]["san"] == "Nf3" and ex["explorer"]["opening"]["eco"] == "C20" and ex["db"] == "masters"
            assert http.explorer_fens[-1] == "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2", http.explorer_fens
            assert c.call("explorer", game=g1, ply=2, db="lichess")["ok"] and len(http.explorer_fens) == 2
            c.call("explorer", game=g1, ply=2, db="masters"); assert len(http.explorer_fens) == 2  # cached
            assert "masters or lichess" in c.call("explorer", game=g1, db="player")["error"]
            assert ex["explorer"]["moves"][0]["fen"] == "rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2", ex
            # Openings page: explorer by line with filters and example games.
            line = c.call("explorer", line=["e2e4"], db="lichess", games=True, speeds=["rapid", "blitz"], ratings=[1600, 1800])["data"]
            assert line["fen"] == "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1", line
            q = http.explorer_queries[-1]
            assert (q["speeds"], q["ratings"], q["topGames"], q["recentGames"]) == (["rapid,blitz"], ["1600,1800"], ["8"], ["8"]), q
            assert "Invalid explorer filter" in c.call("explorer", line=["e2e4"], db="lichess", speeds=["a&b=1"])["error"]
            assert "Illegal" in c.call("explorer", line=["e2e5"], db="masters")["error"]
            board = c.call("analyse", line=["e2e4", "c7c5"])["data"]["game"]
            assert state_game(board)["san"] == ["e4", "c5"] and state_game(board)["analysis"]
            master = c.call("analyse", master="mstr0001")["data"]["game"]
            m = state_game(master)
            assert (m["san"], m["white"], m["white_rating"]) == (["e4", "e5", "Nf3", "Nc6"], "Carlsen, M.", 2882), m
            c.call("delete", game=board); c.call("delete", game=master)
            channels = c.call("tv_channels")["data"]["tv_channels"]
            assert channels["bullet"]["gameId"] == "t8siWVwF" and "horde" in channels
            assert c.call("crosstable", a="Frogkiller", b="McBeast")["data"]["crosstable"]["nbGames"] == 42
            assert "Invalid name" in c.call("crosstable", a="../api", b="x")["error"]
            # Switching channels replaces this connection's feed.
            tv.file.write(b'{"cmd":"tv_watch","channel":"bullet","request_id":"b"}\n')
            bullet = next(e for e in iter(tv.read, None) if e["type"] == "tv" and e["event"]["d"]["id"] == "bullet01")
            assert bullet["event"]["d"]["orientation"] == "black"
            tv.file.write(b'{"cmd":"tv_watch","channel":"../x","request_id":"x"}\n')
            assert "Invalid name" in next(e for e in iter(tv.read, None) if e["type"] == "reply" and e["request_id"] == "x")["error"]
            tv.file.write(b'{"cmd":"tv_stop","request_id":"s"}\n')
            assert next(e for e in iter(tv.read, None) if e["type"] == "reply" and e["request_id"] == "s")["ok"]
            cloud = c.call("eval", game=g1, ply=1)["data"]["eval"]
            assert (cloud["cp"], cloud["source"], cloud["pv"]) == (18, "Lichess cloud", ["e5", "Nf3"]), cloud
            assert "Install Stockfish" in c.call("eval", game=g1, ply=3)["error"]
            assert "fair play" in c.call("eval", game="game0001")["error"]
            assert "fair play" in c.call("analyse", game="game0001", ply=0)["error"]
            # Install the engine after the daemon has cached a cloud result.
            # The same position must switch to local analysis without a restart.
            Path(env["GAMBITO_STOCKFISH"]).symlink_to(Path(__file__).resolve().parent / "fake-stockfish.sh")
            until(lambda: c.call("eval", game=g1, ply=1)["data"]["eval"]["source"] == "FakeFish")
            recovered = c.call("eval", game=g1, ply=3)["data"]["eval"]
            assert recovered["source"] == "FakeFish", recovered
            assert "fair play" in c.call("eval", game="game0001")["error"]
            print("PASS engine recovery: installed after startup, cached cloud upgraded, fair play retained")
            h = state_game("hist0001")
            assert (h["status"], h["winner"], h["color"], h["time_control"], h["black_rating"]) == ("mate", "white", "white", "5+3", 1490)
            assert h["moves"][-1] == "h5f7" and h["san"][-1] == "Qxf7#" and h["updated_ms"] == 1700000000000
            assert state_game("hist0002") is None
            assert h["lichess_analysis"]["moves"][5]["judgment"]["name"] == "Blunder"
            assert "loaded" in c.call("lichess_analysis", game="hist0001")["data"]
            until(lambda: state_game("hist0001")["lichess_analysis"]["moves"][2] == {"eval": 90})
            assert state_game("hist0001")["lichess_analysis"]["white"]["accuracy"] == 99
            assert "finished Lichess games" in c.call("lichess_analysis", game="game0001")["error"]
            assert state_game("game0001")["white"] == "José"
            assert state_game("game0001")["color"] == "white"
            g = state_game("game0001")
            assert (g["white_rating"], g["black_rating"], g["rated"], g["speed"], g["time_control"]) == (1523, 1610, True, "rapid", "10+5")
            cli("move", "game0001", "e4")
            until(lambda: state_game("game0001")["san"] == ["e4"])
            assert "opponent" in cli("move", "game0001", "Nf3", ok=False)
            fake.moves["game0001"] = "e2e4 e7e5"
            fake.game_queues["game0001"].put(fake.state("game0001"))
            until(lambda: state_game("game0001")["san"] == ["e4", "e5"])
            fake.opponent_takeback = True
            fake.game_queues["game0001"].put(dict(fake.state("game0001"), btakeback=True))
            until(lambda: state_game("game0001")["takeback_offer"] == "black")
            cli("takeback", "game0001")
            until(lambda: state_game("game0001")["san"] == ["e4"])
            assert state_game("game0001")["takeback_offer"] is None
            fake.moves["game0001"] = "e2e4 e7e5"
            fake.game_queues["game0001"].put(fake.state("game0001"))
            until(lambda: state_game("game0001")["san"] == ["e4", "e5"])

            until(lambda: "Opponent played e5" in (base / "notifications").read_text() if (base / "notifications").exists() else False)
            assert "Your turn" in (base / "notifications").read_text()
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
            fake.seek_params = None
            assert c.call("seek", days=3, rated=False)["ok"]
            until(lambda: fake.seek_params)
            assert fake.seek_params["days"] == ["3"] and "time" not in fake.seek_params
            assert not c.call("seek", days=4)["ok"]
            c.call("cancel")
            assert c.call("ai", level=3, color="black", minutes=5, increment=3)["ok"]
            assert fake.ai_params["clock.limit"] == ["300"] and fake.ai_params["color"] == ["black"] and fake.ai_params["level"] == ["3"]
            assert c.call("ai", level=1, days=2)["ok"]
            assert fake.ai_params["days"] == ["2"] and "clock.limit" not in fake.ai_params
            cli("ai", "2")
            until(lambda: state_game("game0002"))
            cli("draw", "game0002")
            assert "/api/board/game/game0002/draw/yes" in fake.actions
            cli("resign", "game0002", "--yes")
            until(lambda: state_game("game0002")["status"] == "resign")
            assert state_game("game0001")["status"] == "started"
            assert c.call("logout")["ok"]
            assert not token.exists() and cli("status")["account"] is None
            assert state_game("game0001") is None
            from urllib.parse import urlparse, parse_qs, urlencode
            from urllib.request import urlopen
            url = urlparse(c.call("login")["data"]["url"])
            query = {k: v[0] for k, v in parse_qs(url.query).items()}
            assert url.path == "/oauth" and query["code_challenge_method"] == "S256" and query["client_id"] == "gambito"
            assert query["scope"] == "board:play challenge:read challenge:write puzzle:read puzzle:write"
            assert cli("status")["logging_in"]
            fake.challenge = query["code_challenge"]
            page = urlopen(query["redirect_uri"] + "?" + urlencode({"code": "test-code", "state": query["state"]})).read().decode()
            assert "connected" in page, page
            until(lambda: cli("status")["account"] and not cli("status")["logging_in"])
            assert token.read_text() == "test-only-token" and token.stat().st_mode & 0o777 == 0o600
            print("PASS mock Lichess: auth, fragmented NDJSON, turns, moves, reconnect, seek, cancel, AI and correspondence options, ratings, history, engine (local, cloud, fair play), notifications, actions, logout and OAuth login")
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
