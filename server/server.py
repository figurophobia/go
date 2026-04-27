import socket
import threading
import json
 
 
class GoServer:
    def __init__(self):
        self.board_size = 9
        self.board_state = {}           # (x,y) -> "black" or "white"
        self.previous_board_state = {}  # for Ko rule
        self.is_black_turn = True
        self.consecutive_passes = 0
        self.captures_black = 0
        self.captures_white = 0
        self.komi = 6.5
        self.clients = []               # [conn_black, conn_white]
        self.lock = threading.Lock()
 
    def start(self, port=9999):
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("0.0.0.0", port))
        server.listen(2)
        print(f"[SERVER] Listening on port {port}...")
 
        while len(self.clients) < 2:
            conn, addr = server.accept()
            self.clients.append(conn)
            color = "black" if len(self.clients) == 1 else "white"
            print(f"[SERVER] Client {color} connected: {addr}")
            t = threading.Thread(target=self.handle_client, args=(conn, addr, color))
            t.daemon = True
            t.start()
 
        print("[SERVER] 2 players ready, starting game...")
        self.send(self.clients[0], {"type": "start", "your_color": "black"})
        self.send(self.clients[1], {"type": "start", "your_color": "white"})
 
        # Keep main process alive
        threading.Event().wait()
 
    # ── Client Management ───────────────────────────────────────────────
 
    def handle_client(self, conn, addr, color):
        buffer = ""
        try:
            while True:
                data = conn.recv(1024).decode()
                if not data:
                    break
                buffer += data
                while "\n" in buffer:
                    line, buffer = buffer.split("\n", 1)
                    if line.strip():
                        msg = json.loads(line)
                        print(f"[PROTOCOL] Received from {color}: {msg}")
                        self.process_message(msg, conn, color)
        except (ConnectionResetError, json.JSONDecodeError, OSError) as e:
            print(f"[SERVER] Error with {color}: {e}")
        finally:
            print(f"[SERVER] {color} disconnected")
            self.handle_disconnect(conn)
 
    def process_message(self, msg, sender_conn, color):
        with self.lock:
            if msg["type"] == "place_stone":
                self.handle_place_stone(msg, sender_conn, color)
            elif msg["type"] == "pass":
                self.handle_pass(color, sender_conn)
 
    def handle_disconnect(self, conn):
        if conn in self.clients:
            self.clients.remove(conn)
        self.send_all({"type": "opponent_disconnected"})
 
    # ── Place Stone ────────────────────────────────────────────────────
 
    def handle_place_stone(self, msg, sender_conn, color):
        expected = "black" if self.is_black_turn else "white"
        if color != expected:
            self.send(sender_conn, {"type": "error", "message": "Not your turn"})
            return
 
        pos = tuple(msg["pos"])
 
        if pos in self.board_state:
            self.send(sender_conn, {"type": "error", "message": "Invalid move: Cell occupied"})
            return
 
        # Save state before modifying (for Ko)
        state_before = dict(self.board_state)
 
        # 1. Place temporarily
        self.board_state[pos] = color
        enemy_color = "white" if color == "black" else "black"
 
        # 2. Find enemy captures
        captured_positions = []
        for adj in self.get_adjacent(pos):
            if self.board_state.get(adj) == enemy_color:
                group, liberties = self.get_group_and_liberties(adj, enemy_color)
                if liberties == 0:
                    captured_positions.extend(group)
        captured_positions = list(set(captured_positions))
 
        # 3. Check suicide
        my_group, my_liberties = self.get_group_and_liberties(pos, color)
        if my_liberties == 0 and len(captured_positions) == 0:
            self.board_state = state_before
            self.send(sender_conn, {"type": "error", "message": "Invalid move: Suicide"})
            return
 
        # 4. Apply captures
        for cap_pos in captured_positions:
            del self.board_state[cap_pos]
 
        # 5. Check Ko
        if self.board_state == self.previous_board_state:
            self.board_state = state_before
            self.send(sender_conn, {"type": "error", "message": "Invalid move: Ko"})
            return
 
        # 6. Valid move — update previous state
        self.previous_board_state = state_before
 
        # 7. Update captures
        if color == "black":
            self.captures_black += len(captured_positions)
        else:
            self.captures_white += len(captured_positions)
 
        self.is_black_turn = not self.is_black_turn
        self.consecutive_passes = 0
 
        # 8. Sync to all
        print(f"[PROTOCOL] Sending sync: pos={list(pos)}, color={color}")
        self.send_all({"type": "sync", "pos": list(pos), "color": color})
 
        if captured_positions:
            print(f"[PROTOCOL] Sending captures: {captured_positions}")
            self.send_all({
                "type": "captures",
                "positions": [list(p) for p in captured_positions],
                "captures_black": self.captures_black,
                "captures_white": self.captures_white
            })
 
    # ── Pass Turn ───────────────────────────────────────────────────────
 
    def handle_pass(self, color, sender_conn):
        expected = "black" if self.is_black_turn else "white"
        if color != expected:
            self.send(sender_conn, {"type": "error", "message": "Not your turn"})
            return
 
        self.consecutive_passes += 1
        self.is_black_turn = not self.is_black_turn
        print(f"[SERVER] {color} passed. Consecutive passes: {self.consecutive_passes}")
 
        self.send_all({"type": "pass", "color": color})
 
        if self.consecutive_passes >= 2:
            self.end_game()
 
    # ── End Game ────────────────────────────────────────────────────
 
    def end_game(self):
        territory = self.calculate_territory()
        total_black = self.captures_black + territory["black"]
        total_white = self.captures_white + territory["white"] + self.komi
        print(f"[SERVER] END - Black: {total_black}, White: {total_white}")
        self.send_all({
            "type": "game_over",
            "total_black": total_black,
            "total_white": total_white,
            "territory_black": territory["black"],
            "territory_white": territory["white"],
            "captures_black": self.captures_black,
            "captures_white": self.captures_white
        })
 
    # ── Go Rules ──────────────────────────────────────────────────────
 
    def get_adjacent(self, pos):
        x, y = pos
        adj = []
        if x > 0: adj.append((x - 1, y))
        if x < self.board_size - 1: adj.append((x + 1, y))
        if y > 0: adj.append((x, y - 1))
        if y < self.board_size - 1: adj.append((x, y + 1))
        return adj
 
    def get_group_and_liberties(self, start, color):
        group = []
        liberties = set()
        visited = {start}
        stack = [start]
        while stack:
            current = stack.pop()
            group.append(current)
            for adj in self.get_adjacent(current):
                if adj not in self.board_state:
                    liberties.add(adj)
                elif self.board_state[adj] == color and adj not in visited:
                    visited.add(adj)
                    stack.append(adj)
        return group, len(liberties)
 
    def calculate_territory(self):
        visited = set()
        black_territory = 0
        white_territory = 0
        for x in range(self.board_size):
            for y in range(self.board_size):
                pos = (x, y)
                if pos not in self.board_state and pos not in visited:
                    region = []
                    touches_black = False
                    touches_white = False
                    stack = [pos]
                    visited.add(pos)
                    while stack:
                        current = stack.pop()
                        region.append(current)
                        for adj in self.get_adjacent(current):
                            if adj in self.board_state:
                                if self.board_state[adj] == "black":
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
 
    # ── Network ───────────────────────────────────────────────────────────
 
    def send(self, conn, msg):
        try:
            conn.send((json.dumps(msg) + "\n").encode())
        except Exception as e:
            print(f"[SERVER] Error sending message: {e}")
 
    def send_all(self, msg):
        for client in self.clients:
            self.send(client, msg)
 
 
if __name__ == "__main__":
    GoServer().start()