extends Control

@export var stone_scene: PackedScene

@onready var board            = $Board
@onready var stones_container = $Board/Stones
@onready var top_left         = $Board/TopLeft
@onready var bottom_right     = $Board/BottomRight
@onready var turn_label       = $TurnLabel
@onready var captures_label   = $CapturesLabel
@onready var pass_button      = $PassButton
@onready var game_over_label  = $GameOverLabel
@onready var exit_button      = $EXIT

var board_size = GameConfig.board_size
var is_black_turn   = true
var is_game_over    = false
var komi            = 6.5

var cell_size_x: float
var cell_size_y: float
var start_x: float
var start_y: float

var board_state  = {}
var stone_nodes  = {}
var captures_black = 0
var captures_white = 0
var current_error: String = ""

var tcp: StreamPeerTCP
var _buffer := ""
var _waiting_for_server := false   # bloquea clicks hasta recibir sync/error
var _opponent_disconnected := false
var _reconnect_deadline := 0.0     # Time.get_ticks_msec() + timeout_ms

# ── Ready ─────────────────────────────────────────────────────────────────────

func _ready():
	board.gui_input.connect(_on_board_gui_input)
	if game_over_label:
		game_over_label.hide()
	# QuitButton may be named differently per scene — connect whichever exists
	var qb = get_node_or_null("QuitButton")
	if qb == null: qb = get_node_or_null("DISCONNECT")
	if qb: qb.pressed.connect(_on_quit_pressed)
	start_x = top_left.position.x
	start_y  = top_left.position.y
	var total_width  = bottom_right.position.x - top_left.position.x
	var total_height = bottom_right.position.y - top_left.position.y
	cell_size_x = total_width  / (board_size - 1)
	cell_size_y = total_height / (board_size - 1)

	tcp = Network.tcp
	set_process(true)

	# Apply pending resync (reconnection) now that cell_size is calculated
	if not Network.pending_resync.is_empty():
		var resync = Network.pending_resync
		Network.pending_resync = {}
		# Update board_size BEFORE recalculating cell sizes
		if resync.has("board_size") and resync["board_size"] != board_size:
			board_size = resync["board_size"]
			cell_size_x = total_width  / (board_size - 1)
			cell_size_y = total_height / (board_size - 1)
		_apply_resync(resync)

	update_ui()

# ── Process / Network ─────────────────────────────────────────────────────────

func _process(_delta):
	if tcp == null: return
	tcp.poll()

	if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_on_disconnected()
		return

	# Update disconnect countdown
	if _opponent_disconnected and _reconnect_deadline > 0:
		var secs_left = int((_reconnect_deadline - Time.get_ticks_msec()) / 1000.0)
		secs_left = max(secs_left, 0)
		current_error = "Opponent disconnected. Reconnect window: %ds\nGame ID: %s" % [secs_left, Network.game_id]
		update_ui()

	var available = tcp.get_available_bytes()
	if available <= 0: return

	_buffer += tcp.get_utf8_string(available)
	while "\n" in _buffer:
		var nl   = _buffer.find("\n")
		var line = _buffer.substr(0, nl).strip_edges()
		_buffer  = _buffer.substr(nl + 1)
		if line == "": continue
		var msg = JSON.parse_string(line)
		if msg != null:
			_handle_message(msg)

# ── Message Handler ───────────────────────────────────────────────────────────

func _handle_message(msg: Dictionary):
	match msg.get("type", ""):

		# El lobby ya procesó "start"; pero si por algún motivo llega aquí lo manejamos igual.
		"start":
			Network.my_color = msg.get("your_color", Network.my_color)
			current_error = "Game started – you are " + Network.my_color.to_upper()
			update_ui()

		# Reconexión: el servidor nos manda el tablero completo
		"resync":
			_apply_resync(msg)

		"sync":
			var pos   = Vector2(msg["pos"][0], msg["pos"][1])
			var color = msg["color"]
			board_state[pos] = color
			spawn_stone_visual(pos, color == "black")
			is_black_turn = !is_black_turn
			current_error = ""
			_waiting_for_server = false   # unlock clicks
			update_ui()

		"captures":
			for p in msg["positions"]:
				var pos = Vector2(p[0], p[1])
				board_state.erase(pos)
				if stone_nodes.has(pos):
					stone_nodes[pos].queue_free()
					stone_nodes.erase(pos)
			captures_black = msg["captures_black"]
			captures_white = msg["captures_white"]
			update_ui()

		"pass":
			is_black_turn = !is_black_turn
			current_error = msg["color"].capitalize() + " passed their turn"
			update_ui()

		"error":
			_waiting_for_server = false   # unlock clicks aunque haya error
			current_error = msg["message"]
			update_ui()

		"game_over":
			_show_game_over(msg)

		"opponent_disconnected":
			var timeout = msg.get("reconnect_timeout", 120)
			_opponent_disconnected = true
			_reconnect_deadline = Time.get_ticks_msec() + timeout * 1000.0
			current_error = "Opponent disconnected. Reconnect window: %ds\nGame ID: %s" % [timeout, Network.game_id]
			update_ui()

		"opponent_reconnected":
			_opponent_disconnected = false
			_reconnect_deadline = 0.0
			current_error = "Opponent reconnected!"
			update_ui()

		"forfeit":
			var loser  = msg.get("loser", "?")
			var winner = msg.get("winner", "?")
			is_game_over = true
			_show_forfeit(winner, loser)

# ── Resync (reconexión) ───────────────────────────────────────────────────────

func _apply_resync(msg: Dictionary):
	# Limpiar estado visual actual
	for node in stone_nodes.values():
		node.queue_free()
	stone_nodes.clear()
	board_state.clear()

	board_size     = msg.get("board_size", board_size)
	captures_black = msg.get("captures_black", 0)
	captures_white = msg.get("captures_white", 0)
	# El servidor manda is_black_turn directamente
	is_black_turn  = msg.get("is_black_turn", true)

	# Rebuild board — format: [[x, y], "color"]
	for entry in msg.get("board", []):
		var pos   = Vector2(entry[0][0], entry[0][1])
		var color = entry[1]
		board_state[pos] = color
		spawn_stone_visual(pos, color == "black")

	current_error = "Reconnected to game."
	update_ui()

# ── Disconnect ────────────────────────────────────────────────────────────────

func _on_disconnected():
	if is_game_over: return
	current_error = "Disconnected from server.\nGame ID: " + Network.game_id
	set_process(false)
	update_ui()

# ── Board Input ───────────────────────────────────────────────────────────────

func _on_board_gui_input(event):
	if is_game_over: return
	if _waiting_for_server: return   # ignore clicks until server responds
	if _opponent_disconnected: return  # no plays while opponent is away

	var current_color = "black" if is_black_turn else "white"
	if current_color != Network.my_color:
		current_error = "Wait for your turn"
		update_ui()
		return

	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var mouse_pos = event.position
		var grid_x = round((mouse_pos.x - start_x) / cell_size_x)
		var grid_y = round((mouse_pos.y - start_y) / cell_size_y)
		var grid_pos = Vector2(grid_x, grid_y)
		current_error = ""

		if grid_x >= 0 and grid_x < board_size and grid_y >= 0 and grid_y < board_size:
			if not board_state.has(grid_pos):
				_waiting_for_server = true   # lock until sync or error received
				_send({"type": "place_stone", "pos": [grid_x, grid_y]})
			else:
				current_error = "Invalid move: cell occupied"
				update_ui()

func _on_pass_button_pressed():
	if is_game_over: return
	if _opponent_disconnected: return
	var current_color = "black" if is_black_turn else "white"
	if current_color != Network.my_color: return
	_send({"type": "pass"})

# ── Send ──────────────────────────────────────────────────────────────────────

func _send(msg: Dictionary):
	if tcp == null: return
	var data = JSON.stringify(msg) + "\n"
	tcp.put_data(data.to_utf8_buffer())

# ── Game Over UI ──────────────────────────────────────────────────────────────

func _show_game_over(msg: Dictionary):
	is_game_over = true
	if game_over_label:
		var style_box = StyleBoxFlat.new()
		style_box.bg_color = Color(0, 0, 0, 0.7)
		style_box.set_content_margin_all(20)
		game_over_label.add_theme_stylebox_override("normal", style_box)
		game_over_label.add_theme_constant_override("outline_size", 10)
		game_over_label.add_theme_color_override("font_outline_color", Color.BLACK)

		var winner = "BLACK WINS!" if msg["total_black"] > msg["total_white"] else "WHITE WINS!"
		game_over_label.text  = "[center][b][font_size=40]%s[/font_size][/b]\n\n" % winner
		game_over_label.text += "--- FINAL SCORE ---\n"
		game_over_label.text += "[color=cyan]BLACK:[/color] [b]%s[/b] (Territory: %d, Captures: %d)\n" % [str(msg["total_black"]), msg["territory_black"], msg["captures_black"]]
		game_over_label.text += "[color=orange]WHITE:[/color] [b]%s[/b] (Territory: %d, Captures: %d, Komi: 6.5)\n" % [str(msg["total_white"]), msg["territory_white"], msg["captures_white"]]
		game_over_label.show()

# ── Spawn Stone ───────────────────────────────────────────────────────────────

func spawn_stone_visual(grid_pos: Vector2, is_black: bool):
	var exact_pos = Vector2(
		start_x + (grid_pos.x * cell_size_x),
		start_y + (grid_pos.y * cell_size_y)
	)
	var stone = stone_scene.instantiate()
	stone.position = exact_pos
	stones_container.add_child(stone)
	stone.setup(is_black)
	stone_nodes[grid_pos] = stone

# ── Exit ─────────────────────────────────────────────────────────────────────

func _on_exit_pressed():
	set_process(false)
	if tcp != null and tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		tcp.disconnect_from_host()
	Network.tcp      = null
	Network.my_color = ""
	Network.game_id  = ""
	get_tree().change_scene_to_file("res://scenes/Menu.tscn")

func _on_quit_pressed():
	get_tree().quit()

# ── UI ────────────────────────────────────────────────────────────────────────

func _show_forfeit(winner: String, loser: String):
	if game_over_label:
		var style_box = StyleBoxFlat.new()
		style_box.bg_color = Color(0, 0, 0, 0.7)
		style_box.set_content_margin_all(20)
		game_over_label.add_theme_stylebox_override("normal", style_box)
		game_over_label.add_theme_constant_override("outline_size", 10)
		game_over_label.add_theme_color_override("font_outline_color", Color.BLACK)

		var you_won = (winner == Network.my_color)
		if you_won:
			game_over_label.text  = "[center][b][font_size=40]YOU WIN![/font_size][/b]\n\n"
			game_over_label.text += "[color=red]Opponent (%s) disconnected.[/color][/center]" % loser.to_upper()
		else:
			game_over_label.text  = "[center][b][font_size=40]YOU LOSE[/font_size][/b]\n\n"
			game_over_label.text += "[color=gray]You were disconnected too long.[/color][/center]"
		game_over_label.show()
	update_ui()

func update_ui():
	if turn_label:
		turn_label.add_theme_constant_override("outline_size", 12)
		turn_label.add_theme_color_override("font_outline_color", Color.BLACK)
		turn_label.add_theme_constant_override("shadow_offset_x", 4)
		turn_label.add_theme_constant_override("shadow_offset_y", 4)
		var text = ""
		if is_black_turn:
			text = "[center]Turn:\n[b][color=cyan]BLACK[/color][/b][/center]"
		else:
			text = "[center]Turn:\n[b][color=orange]WHITE[/color][/b][/center]"
		if Network.my_color != "":
			var mine = "black" if is_black_turn else "white"
			if mine == Network.my_color:
				text += "\n[color=green](Your turn)[/color]"
		if current_error != "":
			text += "\n\n[color=red]  " + current_error + "[/color]"
		turn_label.text = text
	if captures_label:
		captures_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		captures_label.add_theme_constant_override("margin_left", 24)
		captures_label.text = "Captured stones\n\nBlack: " + str(int(captures_black)) + "\nWhite: " + str(int(captures_white))

# ── Helpers (territory/groups – usados solo si se quiere calcular localmente) ─

func calculate_territory() -> Dictionary:
	var visited_empty = {}
	var black_territory = 0
	var white_territory = 0
	for x in range(board_size):
		for y in range(board_size):
			var pos = Vector2(x, y)
			if not board_state.has(pos) and not visited_empty.has(pos):
				var region_size = 0
				var touches_black = false
				var touches_white = false
				var to_visit = [pos]
				visited_empty[pos] = true
				while to_visit.size() > 0:
					var current = to_visit.pop_back()
					region_size += 1
					for adj in get_adjacent_positions(current):
						if board_state.has(adj):
							if board_state[adj] == "black": touches_black = true
							elif board_state[adj] == "white": touches_white = true
						elif not visited_empty.has(adj):
							visited_empty[adj] = true
							to_visit.append(adj)
				if touches_black and not touches_white:
					black_territory += region_size
				elif touches_white and not touches_black:
					white_territory += region_size
	return {"black": black_territory, "white": white_territory}

func get_adjacent_positions(pos: Vector2) -> Array:
	var adj = []
	if pos.x > 0:               adj.append(pos + Vector2.LEFT)
	if pos.x < board_size - 1:  adj.append(pos + Vector2.RIGHT)
	if pos.y > 0:               adj.append(pos + Vector2.UP)
	if pos.y < board_size - 1:  adj.append(pos + Vector2.DOWN)
	return adj


func _on_quit_button_pressed() -> void:
	pass # Replace with function body.
