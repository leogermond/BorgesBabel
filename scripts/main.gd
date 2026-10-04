extends Node3D
## Monde : tire une galerie au hasard, y place le bibliothécaire, et entretient
## autour de lui les galeries voisines, sur une centaine de mètres le long du
## vestibule et par le puits, au-dessus et au-dessous.
##
## L'origine du monde suit le bibliothécaire : quand il franchit le milieu d'un
## vestibule, la galerie qu'il atteint devient l'origine et tout se décale d'un
## pas ; de même d'un niveau quand il passe à mi-hauteur vers le niveau voisin.
## Les coordonnées restent petites, quelle que soit la distance parcourue.
##
## Degrés de détail des galeries (dz : galeries le long du vestibule, dy : niveaux) :
## - complète, avec collisionneurs : dy = 0, |dz| ≤ 1 ;
## - éclairée (livres un à un, vraies lampes) : |dz| ≤ 2 et |dy| ≤ 1, ou dy = 0 et
##   |dz| ≤ LIT_ALONG_HALL, ou dz = 0 et |dy| ≤ LIT_VERTICAL ;
## - lointaine (maillage partagé, lumière cuite) : |dy| ≤ 1 et |dz| ≤ REACH_ALONG_HALL,
##   ou dz = 0 et |dy| ≤ ROOMS_VERTICAL.
## Au-delà, le puits garde ses anneaux jusqu'à REACH_VERTICAL, puis les trompe-l'œil
## de FarView prolongent la vue dans les quatre directions.

const REACH_ALONG_HALL := 8    # galeries de chaque côté le long du vestibule : 8 × 12 m = 96 m
const REACH_VERTICAL := 30     # niveaux au-dessus et au-dessous, par le puits : 30 × 3,4 m = 102 m
const ROOMS_VERTICAL := 4      # niveaux du puits construits en galeries entières ; au-delà, l'anneau
const LIT_ALONG_HALL := 3      # galeries éclairées par de vraies lampes le long du vestibule
const LIT_VERTICAL := 2        # niveaux éclairés par de vraies lampes dans le puits

const FOG_COLOR := Color(0.05, 0.035, 0.022)
const FOG_DENSITY := 0.04      # reste de lumière : 38 % à 24 m, 15 % à 48 m, 2 % à 96 m

## Adresse de la galerie placée à l'origine du monde.
var origin_hexagon: int
var origin_level: int

var player: Player
var hud: Hud
var reader: Reader
var far_view: FarView
static var _cells: Dictionary = {}   # cache de gallery_cells()
var _galleries: Dictionary = {}   # "hexagone:niveau" → Gallery
var _highlight: MeshInstance3D
var _target: Dictionary = {}
var _mouse_captured := false


func _ready() -> void:
	process_physics_priority = 10   # après le bibliothécaire
	_setup_input()
	_setup_environment()
	far_view = FarView.create(REACH_ALONG_HALL, ROOMS_VERTICAL + 1, REACH_VERTICAL, FOG_COLOR, FOG_DENSITY)
	add_child(far_view)

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

	_capture_mouse()


func _physics_process(_delta: float) -> void:
	_show_target(player.target)
	var half := Gallery.PITCH * 0.5
	if player.position.z > half:
		_shift(1)
	elif player.position.z < -half:
		_shift(-1)
	var half_level := Gallery.LEVEL_PITCH * 0.5
	if player.position.y > half_level:
		_shift_level(1)
	elif player.position.y < -half_level:
		_shift_level(-1)


func _unhandled_input(event: InputEvent) -> void:
	if reader.visible:
		if event.is_action_pressed("page_prev"):
			reader.turn(-1)
		elif event.is_action_pressed("page_next"):
			reader.turn(1)
		elif event.is_action_pressed("toggle_mouse") or _is_key_action(event, "interact"):
			_close_book()
		return

	if event is InputEventMouseMotion and _mouse_captured:
		player.look(event.relative)
	elif event.is_action_pressed("toggle_mouse"):
		if _mouse_captured:
			_release_mouse()
		else:
			_capture_mouse()
	elif event.is_action_pressed("interact"):
		if not _mouse_captured:
			_capture_mouse()
		elif not _target.is_empty():
			_open_book()


func _open_book() -> void:
	player.frozen = true
	_release_mouse()
	reader.open(_target)


func _close_book() -> void:
	reader.close()
	player.frozen = false
	_capture_mouse()


func _capture_mouse() -> void:
	_mouse_captured = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _release_mouse() -> void:
	_mouse_captured = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_IN and _mouse_captured:
		_capture_mouse()


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


## Fait du niveau voisin (+1 au-dessus, −1 au-dessous) la nouvelle origine.
func _shift_level(step: int) -> void:
	origin_level += step
	player.position.y -= step * Gallery.LEVEL_PITCH
	_update_galleries()
	hud.set_address(origin_hexagon, origin_level)


## Degré de détail de la galerie décalée de (dz, dy) par rapport à l'origine, ou −1
## quand elle reste à construire (hors de vue, ou réduite à l'anneau du puits).
static func detail_at(dz: int, dy: int) -> int:
	var along := absi(dz)
	var across := absi(dy)
	if dy == 0 and along <= 1:
		return Gallery.Detail.FULL
	if (along <= 2 and across <= 1) or (dy == 0 and along <= LIT_ALONG_HALL) \
			or (dz == 0 and across <= LIT_VERTICAL):
		return Gallery.Detail.LIT
	if (across <= 1 and along <= REACH_ALONG_HALL) or (dz == 0 and across <= ROOMS_VERTICAL):
		return Gallery.Detail.DISTANT
	return -1


## Les cases construites autour de l'origine : Vector2i(dz, dy) → degré de détail.
static func gallery_cells() -> Dictionary:
	if not _cells.is_empty():
		return _cells
	var cells := {}
	for dz in range(-REACH_ALONG_HALL, REACH_ALONG_HALL + 1):
		for dy in range(-ROOMS_VERTICAL, ROOMS_VERTICAL + 1):
			var detail := detail_at(dz, dy)
			if detail >= 0:
				cells[Vector2i(dz, dy)] = detail
	_cells = cells
	return cells


## Place les galeries autour de l'origine, chacune à son degré de détail. Les galeries
## sorties du champ servent aux cases nouvelles (même détail d'abord) : un pas ne
## refait que les livres et les collisionneurs qui changent de main.
func _update_galleries() -> void:
	var cells := gallery_cells()
	var wanted: Dictionary = {}
	var placed: Dictionary = {}   # clé → [case, détail]
	for cell: Vector2i in cells:
		var key := "%d:%d" % [origin_hexagon + cell.x, origin_level + cell.y]
		placed[key] = [cell, cells[cell]]
	var spares: Array = [[], [], []]   # par degré de détail
	for key in _galleries:
		if not placed.has(key):
			var spare: Gallery = _galleries[key]
			spares[spare.detail].append(spare)
	for key: String in placed:
		var cell: Vector2i = placed[key][0]
		var detail: int = placed[key][1]
		var gallery: Gallery = _galleries.get(key)
		if gallery == null:
			gallery = _take_spare(spares, detail)
			if gallery == null:
				gallery = Gallery.create(origin_hexagon + cell.x, origin_level + cell.y, detail as Gallery.Detail)
				add_child(gallery)
			else:
				gallery.readdress(origin_hexagon + cell.x, origin_level + cell.y, detail as Gallery.Detail)
		elif gallery.detail != detail:
			gallery.set_detail(detail as Gallery.Detail)
		gallery.position = Vector3(0.0, cell.y * Gallery.LEVEL_PITCH, cell.x * Gallery.PITCH)
		wanted[key] = gallery
	for pool: Array in spares:
		for spare: Gallery in pool:
			spare.queue_free()
	_galleries = wanted


## Une galerie libérée, de préférence au même degré de détail, ou null.
static func _take_spare(spares: Array, detail: int) -> Gallery:
	if not spares[detail].is_empty():
		return spares[detail].pop_back()
	for pool: Array in spares:
		if not pool.is_empty():
			return pool.pop_back()
	return null


func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = FOG_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Gallery.AMBIENT_COLOR
	env.ambient_light_energy = Gallery.AMBIENT_ENERGY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_light_color = FOG_COLOR
	env.fog_density = FOG_DENSITY
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
