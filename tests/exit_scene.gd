extends SceneTree
## Lance la scène principale, attend que les services Python tournent (titres des dos sur le fil
## d'arrière-plan, une page lue sur le fil principal), puis ferme la fenêtre comme le joueur :
## l'autoload BabelService arrête les services, fait taire les haut-parleurs et quitte. Appelé par
## test_world (sous-processus) qui compte les lignes « ERROR » du journal.
## godot --headless --path . -s tests/exit_scene.gd -- --dossier-joueur=user://essai_sortie

const BookTextScript := preload("res://scripts/book_text.gd")
const GalleryScript := preload("res://scripts/gallery.gd")
const FRAMES := 240
const DEADLINE_MSEC := 30000


func _initialize() -> void:
	var main: Node3D = load("res://main.tscn").instantiate()
	root.add_child(main)
	for _i in FRAMES:
		await process_frame
	var started := Time.get_ticks_msec()
	while not GalleryScript.titles_idle() and Time.get_ticks_msec() - started < DEADLINE_MSEC:
		await process_frame
	main.reader.open({"hexagon": "0", "level": "0", "wall": 0, "shelf": 0, "book": 0})
	main.reader.close()
	print("sortie : services lancés, titres %s" % ("posés" if GalleryScript.titles_idle() else "en cours"))
	root.propagate_notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	await create_timer(10.0).timeout
	print("sortie : la fenêtre fermée n'a pas quitté le jeu")
	quit(2)
