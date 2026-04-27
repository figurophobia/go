extends Control

@export var stone_scene: PackedScene

@onready var board = $Board
@onready var stones_container = $Board/Stones
@onready var top_left = $Board/TopLeft
@onready var bottom_right = $Board/BottomRight
@onready var turn_label = $TurnLabel
@onready var captures_label = $CapturesLabel
@onready var pass_button = $PassButton
@onready var game_over_label = $GameOverLabel

var board_size = 9
var is_black_turn = true
var is_game_over = false
var consecutive_passes = 0
var komi = 6.5

var cell_size_x: float
var cell_size_y: float
var start_x: float
var start_y: float

var board_state = {}
var stone_nodes = {}
var captures_black = 0
var captures_white = 0
var current_error: String = ""

# --- NUEVO: referencia al TCP del Autoload ---
var tcp: StreamPeerTCP

func _ready():
	board.gui_input.connect(_on_board_gui_input)
	if pass_button:
		pass_button.pressed.connect(_on_pass_button_pressed)
	if game_over_label:
		game_over_label.hide()

	start_x = top_left.position.x
	start_y = top_left.position.y
	var total_width = bottom_right.position.x - top_left.position.x
	var total_height = bottom_right.position.y - top_left.position.y
	cell_size_x = total_width / (board_size - 1)
	cell_size_y = total_height / (board_size - 1)

	# Coger el TCP del Autoload
	tcp = Network.tcp
	set_process(true)
	update_ui()

# --- NUEVO: recibir mensajes del servidor cada frame ---
func _process(_delta):
	if tcp == null: return
	tcp.poll()

	if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_on_disconnected()
		return

	# Leer todos los mensajes disponibles
	while tcp.get_available_bytes() > 0:
		var line = tcp.get_utf8_string(tcp.get_available_bytes())
		# Puede llegar más de un mensaje junto, separar por newline
		for raw in line.split("\n", false):
			if raw.strip_edges() != "":
				_handle_message(JSON.parse_string(raw))

func _handle_message(msg: Dictionary):
	if msg == null: return

	match msg["type"]:
		"start":
			Network.my_color = msg["your_color"]
			current_error = "Game started! You are " + Network.my_color.to_upper()
			update_ui()

		"sync":
			var pos = Vector2(msg["pos"][0], msg["pos"][1])
			var color = msg["color"]
			board_state[pos] = color
			spawn_stone_visual(pos, color == "black")
			is_black_turn = !is_black_turn
			current_error = ""
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
			current_error = msg["color"].capitalize() + " passed turn"
			update_ui()

		"error":
			current_error = msg["message"]
			update_ui()

		"game_over":
			_show_game_over(msg)

		"opponent_disconnected":
			current_error = "Opponent disconnected."
			is_game_over = true
			update_ui()

func _on_disconnected():
	is_game_over = true
	current_error = "Disconnected from server."
	set_process(false)
	update_ui()

# --- Input: solo actúa si es tu turno ---
func _on_board_gui_input(event):
	if is_game_over: return

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
				# Enviar al servidor Python
				_send({"type": "place_stone", "pos": [grid_x, grid_y]})
			else:
				current_error = "Invalid move: Cell occupied"
				update_ui()

func _on_pass_button_pressed():
	if is_game_over: return
	var current_color = "black" if is_black_turn else "white"
	if current_color != Network.my_color: return
	_send({"type": "pass"})

func _send(msg: Dictionary):
	if tcp == null: return
	var data = JSON.stringify(msg) + "\n"
	tcp.put_data(data.to_utf8_buffer())

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
		game_over_label.text = "[center][b][font_size=40]%s[/font_size][/b]\n\n" % winner
		game_over_label.text += "--- FINAL SCORE ---\n"
		game_over_label.text += "[color=cyan]BLACK:[/color] [b]%s[/b] (Territory: %d, Captures: %d)\n" % [str(msg["total_black"]), msg["territory_black"], msg["captures_black"]]
		game_over_label.text += "[color=orange]WHITE:[/color] [b]%s[/b] (Territory: %d, Captures: %d, Komi: 6.5)\n" % [str(msg["total_white"]), msg["territory_white"], msg["captures_white"]]
		game_over_label.show()

# --- Estas funciones NO cambian respecto al original ---

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
	if pos.x > 0: adj.append(pos + Vector2.LEFT)
	if pos.x < board_size - 1: adj.append(pos + Vector2.RIGHT)
	if pos.y > 0: adj.append(pos + Vector2.UP)
	if pos.y < board_size - 1: adj.append(pos + Vector2.DOWN)
	return adj

func get_group_and_liberties(start_pos: Vector2, color: String) -> Dictionary:
	var group = []
	var liberties = []
	var to_visit = [start_pos]
	var visited = {start_pos: true}
	while to_visit.size() > 0:
		var current = to_visit.pop_back()
		group.append(current)
		for adj in get_adjacent_positions(current):
			if not board_state.has(adj):
				if not adj in liberties:
					liberties.append(adj)
			elif board_state[adj] == color and not visited.has(adj):
				visited[adj] = true
				to_visit.append(adj)
	return {"group": group, "liberties": liberties.size()}

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
			text += "\n\n[color=red]" + current_error + "[/color]"
		turn_label.text = text
	if captures_label:
		captures_label.text = "Captured Stones:\n\nBlack captures: " + str(int(captures_black)) + "\nWhite captures: " + str(int(captures_white))
