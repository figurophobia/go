extends Control

@onready var ip_input = $VBoxContainer/IPInput
@onready var join_button = $VBoxContainer/JoinButton
@onready var status_label = $VBoxContainer/StatusLabel

var tcp: StreamPeerTCP

func _on_join_pressed():
	var ip = ip_input.text.strip_edges()
	if ip == "": ip = "127.0.0.1"

	tcp = StreamPeerTCP.new()
	var err = tcp.connect_to_host(ip, 9999)
	if err != OK:
		status_label.text = "Error al conectar"
		return

	status_label.text = "Conectando..."
	set_process(true)

func _process(_delta):
	if tcp == null: return
	tcp.poll()

	match tcp.get_status():
		StreamPeerTCP.STATUS_CONNECTED:
			status_label.text = "Conectado! Esperando al servidor..."
			set_process(false)
			Network.tcp = tcp
			_go_to_game()
			
		StreamPeerTCP.STATUS_ERROR:
			status_label.text = "Error de conexión"
			set_process(false)

func _go_to_game():
	if GameConfig.board_size == 19:
		get_tree().change_scene_to_file("res://scenes/Game19x19.tscn")
	else:
		get_tree().change_scene_to_file("res://scenes/Game.tscn")
