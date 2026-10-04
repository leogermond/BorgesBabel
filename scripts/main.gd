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
## - lointaine (façades peintes, sans lampe réelle) : |dy| ≤ 1 et |dz| ≤ REACH_ALONG_HALL,
##   ou dz = 0 et |dy| ≤ ROOMS_VERTICAL, ou sur les diagonales vues par les puits
##   voisins : 1 ≤ |dz| ≤ DIAGONAL_REACH et |dz| − 1 ≤ |dy| ≤ |dz| + 1.
## Au-delà, le puits garde ses anneaux jusqu'à REACH_VERTICAL, puis les trompe-l'œil
## de FarView prolongent la vue dans les quatre directions.
##
## Rien de ce qui change de détail ne change d'éclat : toutes les surfaces partagent
## le nuanceur de Gallery, qui rend la même lumière quelle que soit la part des vraies
## lampes ; chaque image, _update_lamps donne à chaque vraie lampe sa part selon sa
## distance à l'œil, et le nuanceur ajoute le reste. Les galeries et les anneaux qui
## naissent ou disparaissent à un pas sont hors de vue, ou à plus de
## Gallery.FAR_FADE_END de l'œil, là où la brume a tout recouvert.

const GalleryScript := preload("res://scripts/gallery.gd")
const FarViewScript := preload("res://scripts/far_view.gd")
const HudScript := preload("res://scripts/hud.gd")
const PlayerScript := preload("res://scripts/player.gd")
const ReaderScript := preload("res://scripts/reader.gd")

const REACH_ALONG_HALL := 8    # galeries de chaque côté le long du vestibule : 8 × 12 m = 96 m
const REACH_VERTICAL := 30     # niveaux au-dessus et au-dessous, par le puits : 30 × 3,4 m = 102 m
const ROOMS_VERTICAL := 4      # niveaux du puits construits en galeries entières ; au-delà, l'anneau
const LIT_ALONG_HALL := 3      # galeries éclairées par de vraies lampes le long du vestibule
const LIT_VERTICAL := 2        # niveaux éclairés par de vraies lampes dans le puits
const DIAGONAL_REACH := 8      # diagonales vues à travers les puits voisins (voir detail_at)

const FOG_COLOR := GalleryScript.FOG_COLOR
const FOG_DENSITY := GalleryScript.FOG_DENSITY

## Adresse de la galerie placée à l'origine du monde.
var origin_hexagon: int
var origin_level: int

var player: PlayerScript
var hud: HudScript
var reader: ReaderScript
var far_view: FarViewScript
static var _cells: Dictionary = {}   # cache de gallery_cells()
var _galleries: Dictionary = {}   # case Vector2i(dz, dy) relative à l'origine → Gallery
var _lit: Array[GalleryScript] = []     # galeries à vraies lampes (LIT et FULL)
static var _lit_cells: Array[Vector2i] = []
var _highlight: MeshInstance3D
var _target: Dictionary = {}
var _mouse_captured := false


func _ready() -> void:
	process_physics_priority = 10   # après le bibliothécaire
	_setup_input()
	_setup_environment()
	far_view = FarViewScript.create(REACH_ALONG_HALL, ROOMS_VERTICAL + 1, REACH_VERTICAL, FOG_COLOR, FOG_DENSITY)
	add_child(far_view)

	var rng := RandomNumberGenerator.new()
	rng.randomize()
	origin_hexagon = (rng.randi() << 30) ^ rng.randi()
	origin_level = rng.randi() - (1 << 31)
	_update_galleries()

	player = PlayerScript.new()
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

	hud = HudScript.new()
	add_child(hud)
	hud.set_address(origin_hexagon, origin_level)
	hud.set_target({})
	reader = ReaderScript.new()
	add_child(reader)

	_capture_mouse()


func _exit_tree() -> void:
	GalleryScript.release_pool()


func _process(_delta: float) -> void:
	_update_lamps()


func _physics_process(_delta: float) -> void:
	_show_target(player.target)
	var half := GalleryScript.PITCH * 0.5
	if player.position.z > half:
		_shift(1)
	elif player.position.z < -half:
		_shift(-1)
	var half_level := GalleryScript.LEVEL_PITCH * 0.5
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
		var gallery: GalleryScript = target.gallery
		var book := gallery.book_transform(target.wall, target.shelf, target.book)
		_highlight.global_transform = gallery.global_transform * book.scaled_local(Vector3(1.12, 1.04, 1.04))


## Fait de la galerie voisine (+1 ou −1 le long du vestibule) la nouvelle origine.
func _shift(step: int) -> void:
	origin_hexagon += step
	player.position.z -= step * GalleryScript.PITCH
	_update_galleries(Vector2i(step, 0))
	hud.set_address(origin_hexagon, origin_level)


## Fait du niveau voisin (+1 au-dessus, −1 au-dessous) la nouvelle origine.
func _shift_level(step: int) -> void:
	origin_level += step
	player.position.y -= step * GalleryScript.LEVEL_PITCH
	_update_galleries(Vector2i(0, step))
	hud.set_address(origin_hexagon, origin_level)


## Degré de détail de la galerie décalée de (dz, dy) par rapport à l'origine, ou −1
## quand elle reste à construire (hors de vue, ou réduite à l'anneau du puits).
##
## Les diagonales : un regard qui descend (ou monte) d'un niveau par galerie passe
## par le vestibule, puis par le puits de la galerie suivante, et ainsi de suite ; il
## voit les cases |dy| = |dz| ± 1 jusqu'au fond de la brume. Elles sont construites,
## lointaines, jusqu'à DIAGONAL_REACH : au passage d'un niveau, les rangées de galeries
## qui naissent et disparaissent restent ainsi hors de vue (vérifié par test_depth).
static func detail_at(dz: int, dy: int) -> int:
	var along := absi(dz)
	var across := absi(dy)
	if dy == 0 and along <= 1:
		return GalleryScript.Detail.FULL
	if (along <= 2 and across <= 1) or (dy == 0 and along <= LIT_ALONG_HALL) \
			or (dz == 0 and across <= LIT_VERTICAL):
		return GalleryScript.Detail.LIT
	if (across <= 1 and along <= REACH_ALONG_HALL) or (dz == 0 and across <= ROOMS_VERTICAL):
		return GalleryScript.Detail.DISTANT
	if along >= 1 and along <= DIAGONAL_REACH and across <= along + 1 and across >= along - 1:
		return GalleryScript.Detail.DISTANT
	return -1


## Les cases construites autour de l'origine : Vector2i(dz, dy) → degré de détail.
static func gallery_cells() -> Dictionary:
	if not _cells.is_empty():
		return _cells
	var cells := {}
	var rise := maxi(ROOMS_VERTICAL, DIAGONAL_REACH + 1)
	for dz in range(-REACH_ALONG_HALL, REACH_ALONG_HALL + 1):
		for dy in range(-rise, rise + 1):
			var detail := detail_at(dz, dy)
			if detail >= 0:
				cells[Vector2i(dz, dy)] = detail
	_cells = cells
	return cells


## Les cases à vraies lampes (LIT et FULL).
static func lit_cells() -> Array[Vector2i]:
	if _lit_cells.is_empty():
		var cells := gallery_cells()
		for cell: Vector2i in cells:
			if cells[cell] >= GalleryScript.Detail.LIT:
				_lit_cells.append(cell)
	return _lit_cells


## Place les galeries autour de l'origine, chacune à son degré de détail, après un
## décalage de l'origine de `moved` (galeries, niveaux). Une galerie dont la case reste
## dans le champ garde son adresse ; les autres servent aux cases nouvelles (même
## détail d'abord) : un pas ne change que des graines, des positions, et des enfants
## qui passent par la réserve de Gallery.
func _update_galleries(moved := Vector2i.ZERO) -> void:
	var cells := gallery_cells()
	var placed: Dictionary = {}
	var spares: Array = [[], [], []]   # par degré de détail
	for old_cell: Vector2i in _galleries:
		var cell := old_cell - moved
		var gallery: GalleryScript = _galleries[old_cell]
		if cells.has(cell):
			placed[cell] = gallery
		else:
			spares[gallery.detail].append(gallery)
	for cell: Vector2i in cells:
		var detail: int = cells[cell]
		var gallery: GalleryScript = placed.get(cell)
		if gallery == null:
			gallery = _take_spare(spares, detail)
			if gallery == null:
				gallery = GalleryScript.create(origin_hexagon + cell.x, origin_level + cell.y, detail as GalleryScript.Detail)
				add_child(gallery)
			else:
				gallery.readdress(origin_hexagon + cell.x, origin_level + cell.y, detail as GalleryScript.Detail)
			placed[cell] = gallery
		elif gallery.detail != detail:
			gallery.set_detail(detail as GalleryScript.Detail)
		gallery.position = Vector3(0.0, cell.y * GalleryScript.LEVEL_PITCH, cell.x * GalleryScript.PITCH)
	for pool: Array in spares:
		for spare: GalleryScript in pool:
			spare.queue_free()
	_galleries = placed
	_lit.clear()
	for cell: Vector2i in lit_cells():
		_lit.append(placed[cell])
	_update_lamps()


## Part réelle de chaque vraie lampe, selon sa distance à l'œil (voir Gallery.real_weight).
func _update_lamps() -> void:
	var eye := Vector3(0.0, PlayerScript.EYE_HEIGHT, 3.2)
	if player != null:
		eye = player.camera.global_position
	for gallery: GalleryScript in _lit:
		gallery.update_lights(eye)


## Une galerie libérée, de préférence au même degré de détail, ou null.
static func _take_spare(spares: Array, detail: int) -> GalleryScript:
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
	env.ambient_light_color = GalleryScript.AMBIENT_COLOR
	env.ambient_light_energy = GalleryScript.AMBIENT_ENERGY
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
