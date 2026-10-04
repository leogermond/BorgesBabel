extends SceneTree
## Rend quelques vues du jeu dans un écran virtuel et les enregistre en PNG.
## Lancer dans Xvfb (aucune fenêtre visible) :
##   xvfb-run -a -s "-screen 0 1600x900x24" godot --rendering-driver opengl3 --path . -s tests/render_shots.gd -- [dossier]
## Dossier de sortie par défaut : .foreman/scratch/screenshots

const VIEWS := [
	# nom, position, lacet (rad), tangage (rad)
	["shelf", Vector3(0.0, 0.0, 0.0), PI / 3.0 + PI, -0.15],
	["shaft", Vector3(0.0, 0.0, 2.6), 0.0, -0.6],
	["hallway", Vector3(0.0, 0.0, 2.0), PI, 0.0],
	["up", Vector3(0.0, 0.0, 2.6), 0.0, 0.9],
]


func _initialize() -> void:
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

	quit(0)


func _save(out: String, name: String) -> void:
	var path := out.path_join(name + ".png")
	root.get_texture().get_image().save_png(path)
	print("capture : ", path)


func _frames(n: int) -> void:
	for i in n:
		await process_frame
