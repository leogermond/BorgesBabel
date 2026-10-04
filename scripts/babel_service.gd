extends Node
## Autoload : arrête le service Python de BookText quand le jeu se ferme.

const BookTextScript := preload("res://scripts/book_text.gd")


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		BookTextScript.shutdown()


func _exit_tree() -> void:
	BookTextScript.shutdown()
