extends Node3D
## Monde : tire une galerie au hasard, y place le bibliothécaire, et entretient
## autour de lui les galeries voisines (le long du vestibule, et un niveau
## au-dessus et au-dessous, visibles par le puits).
##
## L'origine du monde suit le bibliothécaire : quand il franchit le milieu d'un
## vestibule, la galerie qu'il atteint devient l'origine et tout se décale d'un
## pas. Les coordonnées restent petites, quelle que soit la distance parcourue.

const REACH_ALONG_HALL := 2   # galeries entretenues de chaque côté le long du vestibule
const REACH_VERTICAL := 1     # niveaux entretenus au-dessus et au-dessous

## Adresse de la galerie placée à l'origine du monde.
var origin_hexagon: int
var origin_level: int

var player: Player
var hud: Hud
var reader: Reader
var _galleries: Dictionary = {}   # "hexagone:niveau" → Gallery
var _highlight: MeshInstance3D
var _target: Dictionary = {}


func _ready() -> void:
	process_physics_priority = 10   # après le bibliothécaire
	_setup_input()
	_setup_environment()

	var rng := RandomNumberGenerator.new()
	rng.randomize()
	origin_hexagon = (rng.randi() << 30) ^ rng.randi()
	origin_level = rng.randi() - (1 << 31)
	_update_galleries()

	player = Player.new()
	player.name = "Player"
	player.position = Vector3(0.0, 0.05, 3.2)
	player.rotation.y = rng.randf_range(-PI, PI)
	add_child(player)

	_highlight = MeshInstance3D.new()
	_highlight.mesh = BoxMesh.new()
	var glow := StandardMaterial3D.new()
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glow.albedo_color = Color(1.0, 0.85, 0.45, 0.35)
	_highlight.material_override = glow
	_highlight.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_highlight.visible = false
	add_child(_highlight)

	hud = Hud.new()
	add_child(hud)
	hud.set_address(origin_hexagon, origin_level)
	hud.set_target({})
	reader = Reader.new()
	add_child(reader)

	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _physics_process(_delta: float) -> void:
	_show_target(player.target)
	var half := Gallery.PITCH * 0.5
	if player.position.z > half:
		_shift(1)
	elif player.position.z < -half:
		_shift(-1)


func _unhandled_input(event: InputEvent) -> void:
	if reader.visible:
		if event.is_action_pressed("page_prev"):
			reader.turn(-1)
		elif event.is_action_pressed("page_next"):
			reader.turn(1)
		elif event.is_action_pressed("toggle_mouse") or _is_key_action(event, "interact"):
			_close_book()
		return

	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if event is InputEventMouseMotion and captured:
		player.look(event.relative)
	elif event.is_action_pressed("toggle_mouse"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if captured else Input.MOUSE_MODE_CAPTURED
	elif event.is_action_pressed("interact"):
		if not captured:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		elif not _target.is_empty():
			_open_book()


func _open_book() -> void:
	player.frozen = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	reader.open(_target)


func _close_book() -> void:
	reader.close()
	player.frozen = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _show_target(target: Dictionary) -> void:
	if target.is_empty() or not is_instance_valid(target.gallery):
		target = {}
	if target != _target:
		_target = target
		hud.set_target(target)
	_highlight.visible = not target.is_empty()
	if _highlight.visible:
		var gallery: Gallery = target.gallery
		var book := gallery.book_transform(target.wall, target.shelf, target.book)
		_highlight.global_transform = gallery.global_transform * book.scaled_local(Vector3(1.12, 1.04, 1.04))


## Fait de la galerie voisine (+1 ou −1 le long du vestibule) la nouvelle origine.
func _shift(step: int) -> void:
	origin_hexagon += step
	player.position.z -= step * Gallery.PITCH
	_update_galleries()
	hud.set_address(origin_hexagon, origin_level)


## Crée les galeries manquantes autour de l'origine, replace les autres, libère les lointaines.
func _update_galleries() -> void:
	var wanted: Dictionary = {}
	for dz in range(-REACH_ALONG_HALL, REACH_ALONG_HALL + 1):
		for dy in range(-REACH_VERTICAL, REACH_VERTICAL + 1):
			var hexagon := origin_hexagon + dz
			var level := origin_level + dy
			var key := "%d:%d" % [hexagon, level]
			var gallery: Gallery = _galleries.get(key)
			if gallery == null:
				gallery = Gallery.create(hexagon, level)
				add_child(gallery)
			gallery.position = Vector3(0.0, dy * Gallery.LEVEL_PITCH, dz * Gallery.PITCH)
			wanted[key] = gallery
	for key in _galleries:
		if not wanted.has(key):
			_galleries[key].queue_free()
	_galleries = wanted


func _setup_environment() -> void:
	var env := Environment.new()
	var dusk := Color(0.05, 0.035, 0.022)
	env.background_mode = Environment.BG_COLOR
	env.background_color = dusk
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.42, 0.3)
	env.ambient_light_energy = 0.35
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_light_color = dusk
	env.fog_density = 0.06
	env.glow_enabled = true
	var world := WorldEnvironment.new()
	world.environment = env
	add_child(world)


## Clavier repéré par position physique : ZQSD en AZERTY, WASD en QWERTY.
static func _setup_input() -> void:
	var bindings := {
		"move_forward": [KEY_W, KEY_UP],
		"move_back": [KEY_S, KEY_DOWN],
		"move_left": [KEY_A, KEY_LEFT],
		"move_right": [KEY_D, KEY_RIGHT],
		"interact": [KEY_E],
		"toggle_mouse": [KEY_ESCAPE],
		"page_prev": [KEY_LEFT, KEY_PAGEUP],
		"page_next": [KEY_RIGHT, KEY_PAGEDOWN],
	}
	for action in bindings:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		for key in bindings[action]:
			var event := InputEventKey.new()
			event.physical_keycode = key
			InputMap.action_add_event(action, event)
		if action == "interact":
			var click := InputEventMouseButton.new()
			click.button_index = MOUSE_BUTTON_LEFT
			InputMap.action_add_event(action, click)


static func _is_key_action(event: InputEvent, action: String) -> bool:
	return event is InputEventKey and event.is_action_pressed(action)
