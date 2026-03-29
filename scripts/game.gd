extends Control

@export var stone_scene: PackedScene

@onready var board = $Board
@onready var stones_container = $Board/Stones
@onready var start_point = $Board/StartPoint
@onready var next_point = $Board/NextPoint

var board_size = 9 
var is_black_turn = true

func _ready():
	board.gui_input.connect(_on_board_gui_input)

func _on_board_gui_input(event):
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		
		var current_start_x = start_point.position.x
		var current_start_y = start_point.position.y
		var current_cell_size = next_point.position.x - start_point.position.x
		
		var mouse_pos = event.position
		
		var grid_x = round((mouse_pos.x - current_start_x) / current_cell_size)
		var grid_y = round((mouse_pos.y - current_start_y) / current_cell_size)
		
		if grid_x >= 0 and grid_x < board_size and grid_y >= 0 and grid_y < board_size:
			place_stone(grid_x, grid_y, current_start_x, current_start_y, current_cell_size)

func place_stone(grid_x: int, grid_y: int, c_start_x: float, c_start_y: float, c_cell: float):
	var exact_pos = Vector2(
		c_start_x + (grid_x * c_cell),
		c_start_y + (grid_y * c_cell)
	)
	
	var stone = stone_scene.instantiate()
	stone.position = exact_pos
	
	stones_container.add_child(stone)
	stone.setup(is_black_turn)
	
	is_black_turn = !is_black_turn
