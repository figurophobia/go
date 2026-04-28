extends Control

func _ready():
	_highlight_size(9)

	$"VBoxContainer/HBoxContainer/9x9".pressed.connect(func(): _select_size(9))
	$"VBoxContainer/HBoxContainer/19x19".pressed.connect(func(): _select_size(19))
	$VBoxContainer/Play.pressed.connect(_on_jugar)

func _select_size(size: int):
	GameConfig.board_size = size
	_highlight_size(size)

func _highlight_size(size: int):
	$"VBoxContainer/HBoxContainer/9x9".modulate  = Color.YELLOW if size == 9  else Color.WHITE
	$"VBoxContainer/HBoxContainer/19x19".modulate = Color.YELLOW if size == 19 else Color.WHITE

func _on_jugar():
	get_tree().change_scene_to_file("res://scenes/lobby.tscn")
