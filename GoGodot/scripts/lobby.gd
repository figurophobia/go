extends Control

# ── Cambia esta IP por la de tu servidor ──────────────────────────────────────
const SERVER_IP   = "127.0.0.1"
const SERVER_PORT = 9999
# ─────────────────────────────────────────────────────────────────────────────

@onready var game_id_input = $VBoxContainer/GameIDInput
@onready var join_button   = $VBoxContainer/JoinButton
@onready var status_label  = $VBoxContainer/StatusLabel
@onready var game_id_label = $VBoxContainer/GameIDLabel
@onready var back_button   = $BackButton
@onready var quit_button   = $QuitButton

var tcp: StreamPeerTCP
var _connected := false
var _buffer    := ""

func _ready():
	game_id_label.hide()
	game_id_input.placeholder_text = "Game ID (empty = new game)"
	join_button.pressed.connect(_on_join_pressed)
	if back_button:
		back_button.pressed.connect(_on_back_pressed)
	if quit_button:
		quit_button.pressed.connect(_on_quit_pressed)

func _on_join_pressed():
	join_button.disabled = true
	status_label.text    = "Connecting..."

	tcp = StreamPeerTCP.new()
	var err = tcp.connect_to_host(SERVER_IP, SERVER_PORT)
	if err != OK:
		status_label.text    = "Connection error with %s:%d" % [SERVER_IP, SERVER_PORT]
		join_button.disabled = false
		return

	set_process(true)

func _process(_delta):
	if tcp == null: return
	tcp.poll()

	match tcp.get_status():
		StreamPeerTCP.STATUS_CONNECTED:
			if not _connected:
				_connected = true
				status_label.text = "Connected! Sending config..."
				_send_handshake()

		StreamPeerTCP.STATUS_ERROR, StreamPeerTCP.STATUS_NONE:
			status_label.text    = "Connection error"
			join_button.disabled = false
			set_process(false)
			return

	if _connected:
		_read_incoming()

func _send_handshake():
	_send({"type": "config", "board_size": GameConfig.board_size})
	var gid = game_id_input.text.strip_edges()
	_send({"type": "join", "game_id": gid if gid != "" else null})

func _read_incoming():
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
			_handle_server_message(msg)

func _handle_server_message(msg: Dictionary):
	match msg.get("type", ""):

		"waiting":
			var gid: String = msg.get("game_id", "?")
			Network.game_id   = gid
			status_label.text = "Waiting for second player..."
			game_id_label.text = "Your Game ID:\n%s\n(share it with your opponent)" % gid
			game_id_label.show()

		"start":
			Network.my_color = msg.get("your_color", "")
			Network.game_id  = msg.get("game_id", "")
			Network.tcp      = tcp
			# Don't go to game yet — wait for possible resync that follows immediately
			# _go_to_game is called after resync (or right away if not a reconnect)
			if not msg.get("reconnected", false):
				set_process(false)
				_go_to_game()
			# If reconnected, keep reading — resync will arrive next

		"resync":
			# Save resync data; game scene will apply it in _ready
			Network.pending_resync = msg
			set_process(false)
			_go_to_game()

		"error":
			status_label.text    = "Error: " + msg.get("message", "unknown")
			join_button.disabled = false
			set_process(false)

func _go_to_game():
	if GameConfig.board_size == 19:
		get_tree().change_scene_to_file("res://scenes/Game19x19.tscn")
	else:
		get_tree().change_scene_to_file("res://scenes/Game.tscn")

func _on_back_pressed():
	if tcp != null and tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		tcp.disconnect_from_host()
	get_tree().change_scene_to_file("res://scenes/Menu.tscn")

func _on_quit_pressed():
	get_tree().quit()

func _send(msg: Dictionary):
	if tcp == null: return
	tcp.put_data((JSON.stringify(msg) + "\n").to_utf8_buffer())
