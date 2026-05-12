# Network.gd  –  Autoload singleton
extends Node

var tcp: StreamPeerTCP = null
var my_color: String   = ""
var game_id: String    = ""
var pending_resync: Dictionary = {}   # si llega resync antes de cargar la escena del juego
