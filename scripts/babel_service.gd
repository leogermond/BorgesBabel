extends Node
## Autoload : arrête le service Python de BookText quand le jeu se ferme.


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		BookText.shutdown()


func _exit_tree() -> void:
	BookText.shutdown()
