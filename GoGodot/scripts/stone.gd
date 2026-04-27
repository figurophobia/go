extends Node2D

@export var black_textures: Array[Texture2D]
@export var white_textures: Array[Texture2D]

@onready var sprite = $Stone

var is_black: bool

func setup(black: bool):
	is_black = black 
	
	if is_black:
		if black_textures.size() > 0:
			sprite.texture = black_textures.pick_random()
	else:
		if white_textures.size() > 0:
			sprite.texture = white_textures.pick_random()
			
	rotation_degrees = randf_range(0, 360)
