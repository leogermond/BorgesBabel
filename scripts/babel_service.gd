extends Node
## Autoload : à la fermeture du jeu, arrête les services Python de BookText (et leurs fils), fait
## taire les haut-parleurs (AmbientSpeaker.silence_all : le serveur audio rend leurs lectures à une
## image du jeu) puis quitte ; à la sortie, libère le flux de musique partagé. Rien ne reste en vie
## à la sortie du moteur.

const BookTextScript := preload("res://scripts/book_text.gd")
const AmbientSpeakerScript := preload("res://scripts/ambient_speaker.gd")

var _closing := false


func _ready() -> void:
	get_tree().set_auto_accept_quit(false)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and not _closing:
		_closing = true
		_close()
	elif what == NOTIFICATION_PREDELETE:
		BookTextScript.shutdown()


func _close() -> void:
	BookTextScript.shutdown()
	await AmbientSpeakerScript.silence_all(get_tree())
	get_tree().quit()


func _exit_tree() -> void:
	BookTextScript.shutdown()
	AmbientSpeakerScript.release_shared()
