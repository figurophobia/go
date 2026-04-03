extends Control

@export var stone_scene: PackedScene

@onready var board = $Board
@onready var stones_container = $Board/Stones
@onready var top_left = $Board/TopLeft
@onready var bottom_right = $Board/BottomRight

# UI References
@onready var turn_label = $TurnLabel
@onready var captures_label = $CapturesLabel
@onready var pass_button = $PassButton
@onready var game_over_label = $GameOverLabel

var board_size = 9 
var is_black_turn = true
var is_game_over = false
var consecutive_passes = 0
var komi = 6.5 # Puntos extra para el Blanco por jugar en segundo lugar (evita empates)

var cell_size_x: float
var cell_size_y: float
var start_x: float
var start_y: float

# Logic control dictionaries
var board_state = {} # Stores color at each coordinate: Vector2(x,y) -> "black" or "white"
var stone_nodes = {} # Stores the stone node: Vector2(x,y) -> Sprite2D

# Score / Captures
var captures_black = 0 # White stones captured by Black
var captures_white = 0 # Black stones captured by White

# Error message state
var current_error: String = ""

func _ready():
	board.gui_input.connect(_on_board_gui_input)
	
	if pass_button:
		pass_button.pressed.connect(_on_pass_button_pressed)
	
	if game_over_label:
		game_over_label.hide() # Ocultar el texto de fin de juego al empezar
		
	start_x = top_left.position.x
	start_y = top_left.position.y
	var total_width = bottom_right.position.x - top_left.position.x
	var total_height = bottom_right.position.y - top_left.position.y
	cell_size_x = total_width / (board_size - 1)
	cell_size_y = total_height / (board_size - 1)
	
	update_ui()

func _on_board_gui_input(event):
	if is_game_over: return # Ignorar clics si el juego terminó
	
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var mouse_pos = event.position
		var grid_x = round((mouse_pos.x - start_x) / cell_size_x)
		var grid_y = round((mouse_pos.y - start_y) / cell_size_y)
		var grid_pos = Vector2(grid_x, grid_y)
		
		# Clear error message on new click
		current_error = ""
		
		# Check boundaries and empty cell
		if grid_x >= 0 and grid_x < board_size and grid_y >= 0 and grid_y < board_size:
			if not board_state.has(grid_pos):
				try_place_stone(grid_pos)
			else:
				current_error = "Invalid move: Cell occupied"
				update_ui()

func try_place_stone(pos: Vector2):
	var current_color = "black" if is_black_turn else "white"
	var enemy_color = "white" if is_black_turn else "black"
	
	# 1. Place temporarily in logic
	board_state[pos] = current_color
	
	# 2. Check for captured enemy groups
	var captured_any = false
	var adjacents = get_adjacent_positions(pos)
	for adj in adjacents:
		if board_state.has(adj) and board_state[adj] == enemy_color:
			var group_info = get_group_and_liberties(adj, enemy_color)
			if group_info.liberties == 0:
				# Capture this group
				capture_group(group_info.group, current_color)
				captured_any = true
	
	# 3. Check for suicide (if our own group has no liberties and we didn't capture anything)
	var my_group_info = get_group_and_liberties(pos, current_color)
	if my_group_info.liberties == 0 and not captured_any:
		# Invalid move (Suicide), undo logic
		board_state.erase(pos)
		current_error = "Invalid move: Suicide"
		update_ui()
		return
		
	# 4. If valid, spawn visual stone and change turn
	spawn_stone_visual(pos)
	is_black_turn = !is_black_turn
	consecutive_passes = 0 # Alguien movió, se resetean los pases
	update_ui()

func spawn_stone_visual(grid_pos: Vector2):
	var exact_pos = Vector2(
		start_x + (grid_pos.x * cell_size_x),
		start_y + (grid_pos.y * cell_size_y)
	)
	var stone = stone_scene.instantiate()
	stone.position = exact_pos
	stones_container.add_child(stone)
	stone.setup(is_black_turn)
	stone_nodes[grid_pos] = stone

func capture_group(group: Array, capturer_color: String):
	for pos in group:
		board_state.erase(pos)
		if stone_nodes.has(pos):
			stone_nodes[pos].queue_free() # Remove visually
			stone_nodes.erase(pos)
			
		if capturer_color == "black":
			captures_black += 1
		else:
			captures_white += 1

# --- Go Rules: Pass and Game Over ---

func _on_pass_button_pressed():
	if is_game_over: return
	
	consecutive_passes += 1
	var passed_color = "Black" if is_black_turn else "White"
	current_error = passed_color + " passed turn"
	is_black_turn = !is_black_turn
	
	if consecutive_passes >= 2:
		end_game()
	else:
		update_ui()

func end_game():
	is_game_over = true
	var territory = calculate_territory()
	
	var total_black = captures_black + territory["black"]
	var total_white = captures_white + territory["white"] + komi
	
	var winner_text = ""
	if total_black > total_white:
		winner_text = "BLACK WINS!"
	else:
		winner_text = "WHITE WINS!"
		
	if game_over_label:
		game_over_label.show()
		game_over_label.text = "GAME OVER - " + winner_text + "\n\n"
		game_over_label.text += "Black Score: " + str(total_black) + "\n(Territory: " + str(territory["black"]) + ", Captures: " + str(captures_black) + ")\n"
		game_over_label.text += "White Score: " + str(total_white) + "\n(Territory: " + str(territory["white"]) + ", Captures: " + str(captures_white) + ", Komi: 6.5)"

# Calcula las intersecciones vacías rodeadas por un solo color
func calculate_territory() -> Dictionary:
	var visited_empty = {}
	var black_territory = 0
	var white_territory = 0
	
	for x in range(board_size):
		for y in range(board_size):
			var pos = Vector2(x, y)
			
			if not board_state.has(pos) and not visited_empty.has(pos):
				# Explorar área vacía (Flood Fill)
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
							if board_state[adj] == "black":
								touches_black = true
							elif board_state[adj] == "white":
								touches_white = true
						elif not visited_empty.has(adj):
							visited_empty[adj] = true
							to_visit.append(adj)
				
				# Si el área vacía solo toca piedras de un color, es su territorio
				if touches_black and not touches_white:
					black_territory += region_size
				elif touches_white and not touches_black:
					white_territory += region_size
					
	return {"black": black_territory, "white": white_territory}


# --- Go Rules: Liberties Calculation ---

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
					liberties.append(adj) # Empty space = liberty
			elif board_state[adj] == color and not visited.has(adj):
				visited[adj] = true
				to_visit.append(adj) # Same color = expand group
				
	return {"group": group, "liberties": liberties.size()}

# --- UI Updates ---

func update_ui():
	if turn_label:
		turn_label.modulate = Color.WHITE 
		
		var text = ""
		if is_black_turn:
			text = "[color=black]Turn:\nBLACK[/color]"
		else:
			text = "[color=white]Turn:\nWHITE[/color]"
			
		if current_error != "":
			text += "\n\n[color=red]" + current_error + "[/color]"
			
		turn_label.text = text
			
	if captures_label:
		captures_label.text = "Captured Stones:\n\nBlack captures: " + str(captures_black) + "\nWhite captures: " + str(captures_white)
