extends SceneTree
## Démonstration à regarder sur une vraie carte graphique (hors suite de tests) : une étagère de
## 32 livres titrés en lettres dorées, sous une lampe. Le 8e livre est un livre d'images (filets).
##   godot --path . -s tests/demo_spines.gd [-- hexagone niveau]
## Flèches gauche/droite : longer l'étagère ; haut/bas : approcher ou reculer ; Échap : quitter.
## Le titre exige Forward+ ou Mobile : sous Compatibility (OpenGL), les dos restent nus.

const BookSpineScript := preload("res://scripts/book_spine.gd")
const LEATHER: Array[Color] = [
	Color(0.42, 0.12, 0.08), Color(0.30, 0.18, 0.10), Color(0.16, 0.24, 0.14),
	Color(0.48, 0.34, 0.16), Color(0.20, 0.14, 0.22), Color(0.12, 0.16, 0.26),
	Color(0.55, 0.45, 0.30),
]                                         # mêmes cuirs que gallery.gd
const BOOKS := 32
const SLOT := 4.8 / BOOKS
const IMAGE_BOOK := 7

var _camera: Camera3D
var _look := Vector2(0.0, 0.9)            # position le long de l'étagère, distance au dos
var _time := 0.0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var hexagon := int(args[0]) if args.size() > 0 else 1941
	var level := int(args[1]) if args.size() > 1 else 0
	print("Rendu : %s" % RenderingServer.get_current_rendering_method())
	if RenderingServer.get_current_rendering_method() == "gl_compatibility":
		print("  Compatibility : la donnée personnalisée passe en demi-flottants, les titres ne s'affichent pas.")

	var world := Node3D.new()
	root.add_child(world)
	world.add_child(_environment())
	world.add_child(_shelf(hexagon, level))

	var board := MeshInstance3D.new()
	board.mesh = BoxMesh.new()
	(board.mesh as BoxMesh).size = Vector3(SLOT * BOOKS + 0.1, 0.03, 0.3)
	board.position = Vector3(0.0, -0.015, 0.12)
	board.material_override = _plain(Color(0.30, 0.19, 0.11), 0.7)
	world.add_child(board)
	var back := MeshInstance3D.new()
	back.mesh = BoxMesh.new()
	(back.mesh as BoxMesh).size = Vector3(SLOT * BOOKS + 0.1, 0.5, 0.02)
	back.position = Vector3(0.0, 0.2, 0.28)
	back.material_override = _plain(Color(0.12, 0.08, 0.05), 0.9)
	world.add_child(back)

	var lamp := OmniLight3D.new()
	lamp.light_color = Color(1.0, 0.78, 0.5)
	lamp.light_energy = 1.6
	lamp.omni_range = 6.0
	lamp.shadow_enabled = true
	lamp.position = Vector3(0.8, 1.0, -1.2)
	world.add_child(lamp)

	_camera = Camera3D.new()
	_camera.fov = 50.0
	world.add_child(_camera)
	_place_camera()
	process_frame.connect(_on_frame)


func _shelf(hexagon: int, level: int) -> MultiMeshInstance3D:
	var rng := RandomNumberGenerator.new()
	rng.seed = hexagon * 7919 + level
	var buffer := PackedFloat32Array()
	buffer.resize(BOOKS * 20)
	for book in BOOKS:
		var height := rng.randf_range(0.28, 0.36)
		var leather := LEATHER[rng.randi() % LEATHER.size()].darkened(rng.randf_range(0.0, 0.35))
		var title := BookSpineScript.title(hexagon, level, 0, 0, book)
		var code := BookSpineScript.encode_title(title, book == IMAGE_BOOK)
		print("  livre %2d : « %s »%s" % [book + 1, title, "  (livre d'images)" if book == IMAGE_BOOK else ""])
		# Le dos (face −Z de la boîte) regarde la caméra ; le livre 1 est à gauche du lecteur.
		var row := [0.13, 0.0, 0.0, SLOT * (BOOKS * 0.5 - book - 0.5),
			0.0, height, 0.0, height * 0.5,
			0.0, 0.0, 0.22, 0.11,
			leather.r, leather.g, leather.b, 1.0,
			code.r, code.g, code.b, code.a]
		for k in 20:
			buffer[book * 20 + k] = row[k]
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE
	mesh.material = BookSpineScript.material()
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.use_custom_data = true
	multimesh.mesh = mesh
	multimesh.instance_count = BOOKS
	multimesh.buffer = buffer
	var instance := MultiMeshInstance3D.new()
	instance.multimesh = multimesh
	return instance


func _environment() -> WorldEnvironment:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.05, 0.035, 0.025)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.55, 0.42, 0.3)
	environment.ambient_light_energy = 0.35
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var node := WorldEnvironment.new()
	node.environment = environment
	return node


func _plain(albedo: Color, roughness: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = albedo
	material.roughness = roughness
	return material


func _on_frame() -> void:
	var delta := 1.0 / 60.0
	_time += delta
	if Input.is_key_pressed(KEY_ESCAPE):
		quit()
	_look.x += (float(Input.is_key_pressed(KEY_LEFT)) - float(Input.is_key_pressed(KEY_RIGHT))) * delta
	_look.y = clampf(_look.y + (float(Input.is_key_pressed(KEY_DOWN)) - float(Input.is_key_pressed(KEY_UP))) * delta, 0.25, 3.0)
	_look.x = clampf(_look.x, -2.4, 2.4)
	_place_camera()


## Caméra devant les dos, légèrement balancée pour faire jouer la lumière sur la dorure.
func _place_camera() -> void:
	var sway := 0.08 * sin(_time * 0.7)
	_camera.look_at_from_position(Vector3(_look.x + sway, 0.18, -_look.y), Vector3(_look.x, 0.17, 0.0), Vector3.UP)
