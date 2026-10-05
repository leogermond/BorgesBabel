extends SceneTree
## Rend quelques vues du jeu dans un écran virtuel et les enregistre en PNG.
## Lancer dans Xvfb (aucune fenêtre visible) :
##   xvfb-run -a -s "-screen 0 1600x900x24" godot --rendering-driver opengl3 --path . -s tests/render_shots.gd -- [dossier]
## Dossier de sortie par défaut : .foreman/scratch/screenshots

const QuestScript := preload("res://scripts/quest.gd")

const VIEWS := [
	# nom, position, lacet (rad), tangage (rad)
	["shelf", Vector3(0.0, 0.0, 0.0), PI / 3.0 + PI, -0.15],
	["shaft", Vector3(0.0, 0.0, 2.6), 0.0, -0.6],
	["hallway", Vector3(0.0, 0.0, 2.0), PI, 0.0],
	["up", Vector3(0.0, 0.0, 2.6), 0.0, 0.9],
]


func _initialize() -> void:
	QuestScript.user_dir = "user://essai_render_shots"   # jamais les fichiers du joueur
	_clear_user_dir()
	var out := ProjectSettings.globalize_path("res://.foreman/scratch/screenshots")
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		out = args[0]
	DirAccess.make_dir_recursive_absolute(out)

	var main: Node3D = load("res://main.tscn").instantiate()
	root.add_child(main)
	await _frames(30)
	var player: CharacterBody3D = main.player

	for view in VIEWS:
		player.position = view[1]
		player.rotation.y = view[2]
		player.camera.rotation.x = view[3]
		await _frames(10)
		_save(out, view[0])

	player.position = Basis(Vector3.UP, PI / 3.0) * Vector3(0.0, 0.0, 3.4)
	player.rotation.y = PI / 3.0 + PI
	player.camera.rotation.x = -0.2
	await _frames(10)
	if not player.target.is_empty():
		main._open_book()
		await _frames(10)
		_save(out, "reader")
	else:
		push_error("aucun livre visé : capture du lecteur omise")

	_clear_user_dir()
	quit(0)


func _save(out: String, name: String) -> void:
	var path := out.path_join(name + ".png")
	root.get_texture().get_image().save_png(path)
	print("capture : ", path)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


## Retire le dossier des fichiers du joueur du test (quête en cours écrite au premier lancement).
static func _clear_user_dir() -> void:
	var dir := ProjectSettings.globalize_path(QuestScript.user_dir)
	if not QuestScript.user_dir.begins_with("user://essai") or not DirAccess.dir_exists_absolute(dir):
		return
	for file in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(file))
	DirAccess.remove_absolute(dir)
