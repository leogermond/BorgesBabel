extends Node
## Autoload : à la fermeture du jeu, arrête les services Python de BookText (et leurs fils) et
## libère le flux de musique partagé des haut-parleurs (AmbientSpeaker), retenus par des variables
## statiques : rien ne reste en vie à la sortie du moteur.

const BookTextScript := preload("res://scripts/book_text.gd")
const AmbientSpeakerScript := preload("res://scripts/ambient_speaker.gd")
## Attente à la sortie : un mixage du serveur audio (quelques ms) rend les lectures arrêtées.
const EXIT_DRAIN_MSEC := 50


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		BookTextScript.shutdown()


func _exit_tree() -> void:
	BookTextScript.shutdown()
	AmbientSpeakerScript.release_shared()
	OS.delay_msec(EXIT_DRAIN_MSEC)   # le serveur audio rend les lectures arrêtées à son prochain mixage
