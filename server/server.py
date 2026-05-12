import socket
import threading
import json
import os
import time

SAVE_DIR = "saved_games"
os.makedirs(SAVE_DIR, exist_ok=True)

_game_id_lock = threading.Lock()
_used_ids: set = set()

def _next_game_id() -> str:
    """Return the lowest positive integer not currently in use."""
    with _game_id_lock:
        # Seed used_ids from saved files on first call
        if not _used_ids:
            try:
                for f in os.listdir(SAVE_DIR):
                    if f.endswith(".json") and f[:-5].isdigit():
                        _used_ids.add(int(f[:-5]))
            except Exception:
                pass
        i = 1
        while i in _used_ids:
            i += 1
        _used_ids.add(i)
        return str(i)

def _release_game_id(game_id: str):
    """Mark an ID as free so it can be reused."""
    with _game_id_lock:
        try:
            _used_ids.discard(int(game_id))
        except ValueError:
            pass


class GameState:
    """Serializable game state, separate from network concerns."""

    def __init__(self, board_size=9, komi=6.5):
        self.game_id = _next_game_id()
        self.board_size = board_size
        self.board_state = {}
        self.previous_board_state = {}
        self.is_black_turn = True
        self.consecutive_passes = 0
        self.captures_black = 0
        self.captures_white = 0
        self.komi = komi
        self.finished = False

    def to_dict(self):
        return {
            "game_id": self.game_id,
            "board_size": self.board_size,
            # JSON keys must be strings; store as "x,y"
            "board_state": {f"{int(k[0])},{int(k[1])}": v for k, v in self.board_state.items()},
            "previous_board_state": {f"{int(k[0])},{int(k[1])}": v for k, v in self.previous_board_state.items()},
            "is_black_turn": self.is_black_turn,
            "consecutive_passes": self.consecutive_passes,
            "captures_black": self.captures_black,
            "captures_white": self.captures_white,
            "komi": self.komi,
            "finished": self.finished,
        }

    @classmethod
    def from_dict(cls, d):
        gs = cls(board_size=d["board_size"], komi=d["komi"])
        gs.game_id = d["game_id"]
        gs.board_state = {tuple(int(float(x)) for x in k.split(",")): v for k, v in d["board_state"].items()}
        gs.previous_board_state = {tuple(int(float(x)) for x in k.split(",")): v for k, v in d["previous_board_state"].items()}
        gs.is_black_turn = d["is_black_turn"]
        gs.consecutive_passes = d["consecutive_passes"]
        gs.captures_black = d["captures_black"]
        gs.captures_white = d["captures_white"]
        gs.finished = d["finished"]
        return gs


class GoSession:
    """
    Manages one active game between two clients.
    A session can survive disconnections: players may reconnect to the same game.
    """

    RECONNECT_TIMEOUT = 120  # seconds to wait for a reconnecting player

    def __init__(self, game_state: GameState):
        self.gs = game_state
        # slot index: 0 = black, 1 = white
        self.conns: list[socket.socket | None] = [None, None]
        self.addrs = [None, None]
        self.lock = threading.Lock()
        self._reconnect_timers: list[threading.Timer | None] = [None, None]

    # ── Persistence ───────────────────────────────────────────────────

    def save(self):
        path = os.path.join(SAVE_DIR, f"{self.gs.game_id}.json")
        with open(path, "w") as f:
            json.dump(self.gs.to_dict(), f)
        print(f"[SESSION] Game {self.gs.game_id} saved to {path}")

    @classmethod
    def load(cls, game_id: str):
        path = os.path.join(SAVE_DIR, f"{game_id}.json")
        if not os.path.exists(path):
            return None
        with open(path) as f:
            d = json.load(f)
        gs = GameState.from_dict(d)
        session = cls(gs)
        print(f"[SESSION] Loaded game {game_id} from {path}")
        return session

    def delete_save(self):
        import datetime
        path = os.path.join(SAVE_DIR, f"{self.gs.game_id}.json")
        ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        if os.path.exists(path):
            os.remove(path)
            print(f"[{ts}] [CLEANUP] Save file for game {self.gs.game_id} deleted.")
        _release_game_id(self.gs.game_id)
        print(f"[{ts}] [CLEANUP] Game ID {self.gs.game_id} is now free for reuse.")

    # ── Connection Helpers ────────────────────────────────────────────

    def color_index(self, color: str) -> int:
        return 0 if color == "black" else 1

    def index_color(self, idx: int) -> str:
        return "black" if idx == 0 else "white"

    def send(self, conn: socket.socket, msg: dict):
        if conn is None:
            return
        try:
            conn.send((json.dumps(msg) + "\n").encode())
        except Exception as e:
            print(f"[NET] Send error: {e}")

    def send_all(self, msg: dict):
        for conn in self.conns:
            self.send(conn, msg)

    def send_to(self, color: str, msg: dict):
        self.send(self.conns[self.color_index(color)], msg)

    # ── Reconnect / Disconnect ────────────────────────────────────────

    def attach_player(self, color: str, conn: socket.socket, addr):
        """Attach a connection. Caller must NOT hold self.lock (we acquire it here),
        EXCEPT when called from GoServer._route_client which holds GoServer.lock only."""
        idx = self.color_index(color)
        # Cancel any pending abandon timer for this slot (no lock needed, timer is thread-safe)
        if self._reconnect_timers[idx] is not None:
            self._reconnect_timers[idx].cancel()
            self._reconnect_timers[idx] = None
        self.conns[idx] = conn
        self.addrs[idx] = addr
        print(f"[SESSION] {color} attached ({addr}), game {self.gs.game_id}")

    def detach_player(self, color: str):
        """Called when a client disconnects.  Starts a grace-period timer."""
        # If game is already finished, just clean up silently — don't re-save or start timers
        if self.gs.finished:
            idx = self.color_index(color)
            self.conns[idx] = None
            self.addrs[idx] = None
            print(f"[SESSION] {color} disconnected after game {self.gs.game_id} ended (ignored).")
            return

        idx = self.color_index(color)
        with self.lock:
            self.conns[idx] = None
            self.addrs[idx] = None
            # Notify the opponent (if connected)
            opponent = self.index_color(1 - idx)
            self.send_to(opponent, {
                "type": "opponent_disconnected",
                "message": f"{color} disconnected. Reconnection window: {self.RECONNECT_TIMEOUT}s. Use game ID {self.gs.game_id} to rejoin.",
                "reconnect_timeout": self.RECONNECT_TIMEOUT,
                "game_id": self.gs.game_id,
            })

        # Save state so the game survives a full server restart too
        self.save()

        # Start abandon timer
        timer = threading.Timer(self.RECONNECT_TIMEOUT, self._on_abandon, args=(color,))
        timer.daemon = True
        timer.start()
        self._reconnect_timers[idx] = timer
        print(f"[SESSION] {color} disconnected; {self.RECONNECT_TIMEOUT}s to reconnect.")

    def _on_abandon(self, color: str):
        """Called when the reconnect window expires — forfeit the game."""
        print(f"[SESSION] {color} failed to reconnect; declaring forfeit.")
        opponent = "white" if color == "black" else "black"
        self.gs.finished = True
        self.send_all({
            "type": "forfeit",
            "loser": color,
            "winner": opponent,
            "reason": "disconnected_timeout",
        })
        self.delete_save()  # game over — free the ID

    def send_full_resync(self, color: str):
        """Send the complete board state to a reconnecting player."""
        gs = self.gs
        # Format: each entry is [[x, y], "color_string"]
        board_list = [[list(pos), c] for pos, c in gs.board_state.items()]
        is_your_turn = (color == "black" and gs.is_black_turn) or (color == "white" and not gs.is_black_turn)
        self.send_to(color, {
            "type": "resync",
            "game_id": gs.game_id,
            "board_size": gs.board_size,
            "board": board_list,
            "is_black_turn": gs.is_black_turn,
            "is_your_turn": is_your_turn,
            "captures_black": gs.captures_black,
            "captures_white": gs.captures_white,
            "komi": gs.komi,
        })

    # ── Move Processing ───────────────────────────────────────────────

    def process_message(self, msg: dict, sender_conn: socket.socket, color: str):
        with self.lock:
            t = msg.get("type")
            if t == "place_stone":
                self._handle_place_stone(msg, sender_conn, color)
            elif t == "pass":
                self._handle_pass(color, sender_conn)
            elif t == "chat":
                # Relay chat messages between players
                opponent = "white" if color == "black" else "black"
                self.send_to(opponent, {"type": "chat", "from": color, "text": msg.get("text", "")})

    def _handle_place_stone(self, msg, sender_conn, color):
        gs = self.gs
        expected = "black" if gs.is_black_turn else "white"
        if color != expected:
            self.send(sender_conn, {"type": "error", "message": "Not your turn"})
            return

        pos = tuple(msg["pos"])
        if pos in gs.board_state:
            self.send(sender_conn, {"type": "error", "message": "Invalid move: Cell occupied"})
            return

        state_before = dict(gs.board_state)
        gs.board_state[pos] = color
        enemy_color = "white" if color == "black" else "black"

        captured_positions = []
        for adj in self._get_adjacent(pos):
            if gs.board_state.get(adj) == enemy_color:
                group, liberties = self._get_group_and_liberties(adj, enemy_color)
                if liberties == 0:
                    captured_positions.extend(group)
        captured_positions = list(set(captured_positions))

        _, my_liberties = self._get_group_and_liberties(pos, color)
        if my_liberties == 0 and not captured_positions:
            gs.board_state = state_before
            self.send(sender_conn, {"type": "error", "message": "Invalid move: Suicide"})
            return

        for cap_pos in captured_positions:
            del gs.board_state[cap_pos]

        if gs.board_state == gs.previous_board_state:
            gs.board_state = state_before
            self.send(sender_conn, {"type": "error", "message": "Invalid move: Ko"})
            return

        gs.previous_board_state = state_before

        if color == "black":
            gs.captures_black += len(captured_positions)
        else:
            gs.captures_white += len(captured_positions)

        gs.is_black_turn = not gs.is_black_turn
        gs.consecutive_passes = 0

        self.save()  # persist after every move

        self.send_all({"type": "sync", "pos": list(pos), "color": color})
        if captured_positions:
            self.send_all({
                "type": "captures",
                "positions": [list(p) for p in captured_positions],
                "captures_black": gs.captures_black,
                "captures_white": gs.captures_white,
            })

    def _handle_pass(self, color, sender_conn):
        gs = self.gs
        expected = "black" if gs.is_black_turn else "white"
        if color != expected:
            self.send(sender_conn, {"type": "error", "message": "Not your turn"})
            return

        gs.consecutive_passes += 1
        gs.is_black_turn = not gs.is_black_turn
        self.save()
        self.send_all({"type": "pass", "color": color})

        if gs.consecutive_passes >= 2:
            self._end_game()

    def _end_game(self):
        gs = self.gs
        territory = self._calculate_territory()
        total_black = gs.captures_black + territory["black"]
        total_white = gs.captures_white + territory["white"] + gs.komi
        gs.finished = True
        self.send_all({
            "type": "game_over",
            "total_black": total_black,
            "total_white": total_white,
            "territory_black": territory["black"],
            "territory_white": territory["white"],
            "captures_black": gs.captures_black,
            "captures_white": gs.captures_white,
        })
        self.delete_save()  # clean finished game

    # ── Go Rules ─────────────────────────────────────────────────────

    def _get_adjacent(self, pos):
        x, y = pos
        bs = self.gs.board_size
        adj = []
        if x > 0: adj.append((x - 1, y))
        if x < bs - 1: adj.append((x + 1, y))
        if y > 0: adj.append((x, y - 1))
        if y < bs - 1: adj.append((x, y + 1))
        return adj

    def _get_group_and_liberties(self, start, color):
        gs = self.gs
        group = []
        liberties = set()
        visited = {start}
        stack = [start]
        while stack:
            current = stack.pop()
            group.append(current)
            for adj in self._get_adjacent(current):
                if adj not in gs.board_state:
                    liberties.add(adj)
                elif gs.board_state[adj] == color and adj not in visited:
                    visited.add(adj)
                    stack.append(adj)
        return group, len(liberties)

    def _calculate_territory(self):
        gs = self.gs
        visited = set()
        black_territory = 0
        white_territory = 0
        for x in range(gs.board_size):
            for y in range(gs.board_size):
                pos = (x, y)
                if pos not in gs.board_state and pos not in visited:
                    region = []
                    touches_black = touches_white = False
                    stack = [pos]
                    visited.add(pos)
                    while stack:
                        current = stack.pop()
                        region.append(current)
                        for adj in self._get_adjacent(current):
                            if adj in gs.board_state:
                                if gs.board_state[adj] == "black":
                                    touches_black = True
                                else:
                                    touches_white = True
                            elif adj not in visited:
                                visited.add(adj)
                                stack.append(adj)
                    if touches_black and not touches_white:
                        black_territory += len(region)
                    elif touches_white and not touches_black:
                        white_territory += len(region)
        return {"black": black_territory, "white": white_territory}


# ─────────────────────────────────────────────────────────────────────────────
# GoServer — always-on, manages multiple sessions
# ─────────────────────────────────────────────────────────────────────────────

class GoServer:
    """
    Always-on TCP server.  Accepts clients forever; never exits after a game ends.

    Handshake protocol (client → server, first message):
        {"type": "join",  "game_id": null}          → create new game (wait for partner)
        {"type": "join",  "game_id": "<id>"}         → rejoin existing/pending game
        {"type": "config","board_size": 9}           → (optional) set board size before join
    """

    def __init__(self):
        self.sessions: dict[str, GoSession] = {}   # game_id → GoSession
        self.waiting: GoSession | None = None       # session waiting for 2nd player
        self.lock = threading.Lock()

    # ── Server Loop ───────────────────────────────────────────────────

    def start(self, port=9999):
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("0.0.0.0", port))
        server.listen(10)
        print(f"[SERVER] Always-on Go server listening on port {port}  (Ctrl-C to stop)")

        # Restore any unfinished saved games into memory
        self._restore_saved_games()

        while True:
            try:
                conn, addr = server.accept()
                print(f"[SERVER] New connection from {addr}")
                t = threading.Thread(target=self._handshake, args=(conn, addr), daemon=True)
                t.start()
            except KeyboardInterrupt:
                print("[SERVER] Shutting down.")
                break
            except Exception as e:
                print(f"[SERVER] Accept error: {e}")

    # ── Saved-game Restore ────────────────────────────────────────────

    def _restore_saved_games(self):
        files = [f for f in os.listdir(SAVE_DIR) if f.endswith(".json")]
        for fname in files:
            game_id = fname[:-5]
            session = GoSession.load(game_id)
            if session and not session.gs.finished:
                self.sessions[game_id] = session
                print(f"[SERVER] Restored unfinished game {game_id}")
        print(f"[SERVER] {len(self.sessions)} unfinished game(s) restored.")

    # ── Handshake ─────────────────────────────────────────────────────

    def _handshake(self, conn: socket.socket, addr):
        """Read the first message(s) from a new connection, then route to a session."""
        buffer = ""
        board_size = 9
        game_id = None

        conn.settimeout(30)  # 30 s to complete handshake
        try:
            while True:
                data = conn.recv(1024).decode()
                if not data:
                    conn.close()
                    return
                buffer += data
                while "\n" in buffer:
                    line, buffer = buffer.split("\n", 1)
                    line = line.strip()
                    if not line:
                        continue
                    msg = json.loads(line)
                    print(f"[HANDSHAKE] {addr}: {msg}")

                    if msg["type"] == "config":
                        board_size = msg.get("board_size", 9)

                    elif msg["type"] == "join":
                        game_id = msg.get("game_id")
                        conn.settimeout(None)  # back to blocking
                        self._route_client(conn, addr, game_id, board_size)
                        return  # handshake done, session thread takes over

        except socket.timeout:
            print(f"[HANDSHAKE] {addr} timed out during handshake")
            conn.close()
        except Exception as e:
            print(f"[HANDSHAKE] Error with {addr}: {e}")
            conn.close()

    def _route_client(self, conn: socket.socket, addr, game_id: str | None, board_size: int):
        """Assign a connection to a new or existing session as black or white."""
        color = None
        session = None

        with self.lock:
            # ── Join/reconnect by game_id ─────────────────────────────
            if game_id and game_id in self.sessions:
                session = self.sessions[game_id]

                # Reject if client sends a different board size than the saved game
                if board_size not in (9, 13, 19):
                    board_size = 9
                if board_size != session.gs.board_size:
                    self._send_raw(conn, {
                        "type": "error",
                        "message": f"Board size mismatch: game uses {session.gs.board_size}x{session.gs.board_size}"
                    })
                    conn.close()
                    return

                black_connected = session.conns[0] is not None
                white_connected = session.conns[1] is not None
                game_started    = session.gs.captures_black > 0 or session.gs.captures_white > 0 or len(session.gs.board_state) > 0

                if not black_connected and not white_connected:
                    # Both slots free (server restarted): first reconnector gets black
                    color = "black"
                    session.attach_player(color, conn, addr)
                    self._send_raw(conn, {"type": "start", "your_color": color, "game_id": game_id, "reconnected": True})
                    session.send_full_resync(color)
                    print(f"[SERVER] {color} reconnected (first) to restored game {game_id}")

                elif not white_connected and black_connected and not game_started:
                    # White slot free and game hasn't started → 2nd player joining fresh
                    color = "white"
                    session.attach_player(color, conn, addr)
                    if session == self.waiting:
                        self.waiting = None
                    self._send_raw(conn, {"type": "start", "your_color": "white", "game_id": game_id})
                    session.send_to("black", {"type": "start", "your_color": "black", "game_id": game_id})
                    print(f"[SERVER] Game {game_id} started (white joined by ID)")

                elif not black_connected:
                    # Black disconnected mid-game → reconnect
                    color = "black"
                    session.attach_player(color, conn, addr)
                    self._send_raw(conn, {"type": "start", "your_color": color, "game_id": game_id, "reconnected": True})
                    session.send_full_resync(color)
                    if white_connected:
                        session.send_to("white", {"type": "opponent_reconnected", "color": color})
                    print(f"[SERVER] {color} reconnected to game {game_id}")

                elif not white_connected:
                    # White disconnected mid-game → reconnect
                    color = "white"
                    session.attach_player(color, conn, addr)
                    self._send_raw(conn, {"type": "start", "your_color": color, "game_id": game_id, "reconnected": True})
                    session.send_full_resync(color)
                    if black_connected:
                        session.send_to("black", {"type": "opponent_reconnected", "color": color})
                    print(f"[SERVER] {color} reconnected to game {game_id}")

                else:
                    # Both already connected
                    self._send_raw(conn, {"type": "error", "message": "Game full"})
                    conn.close()
                    return

            # ── No game_id: create new game (1st player / black) ──────────
            else:
                # Validate board_size
                if board_size not in (9, 13, 19):
                    board_size = 9
                gs = GameState(board_size=board_size)
                session = GoSession(gs)
                self.sessions[gs.game_id] = session
                self.waiting = session
                color = "black"
                session.attach_player("black", conn, addr)
                self._send_raw(conn, {
                    "type": "waiting",
                    "game_id": gs.game_id,
                    "message": "Waiting for opponent...",
                })
                print(f"[SERVER] Game {gs.game_id} created, waiting for white player")

        # Launch the receive loop for this client (outside the lock)
        self._client_loop(conn, addr, session, color)

    def _client_loop(self, conn: socket.socket, addr, session: GoSession, color: str):
        """Receive loop for an established player connection."""
        buffer = ""
        try:
            while True:
                data = conn.recv(4096).decode()
                if not data:
                    break
                buffer += data
                while "\n" in buffer:
                    line, buffer = buffer.split("\n", 1)
                    line = line.strip()
                    if line:
                        try:
                            msg = json.loads(line)
                            print(f"[PROTOCOL] From {color}: {msg}")
                            session.process_message(msg, conn, color)
                        except json.JSONDecodeError as e:
                            print(f"[PROTOCOL] Bad JSON from {color}: {e}")
        except (ConnectionResetError, OSError) as e:
            print(f"[NET] {color} connection lost: {e}")
        finally:
            print(f"[SERVER] {color} ({addr}) loop ended")
            session.detach_player(color)

    @staticmethod
    def _send_raw(conn: socket.socket, msg: dict):
        try:
            conn.send((json.dumps(msg) + "\n").encode())
        except Exception as e:
            print(f"[SERVER] send_raw error: {e}")


if __name__ == "__main__":
    GoServer().start()