extends SceneTree
## Démonstration à regarder sur une vraie carte graphique (hors suite de tests) : une vraie galerie
## (Gallery, détail FULL, lampes réelles et virtuelles du jeu), caméra devant le mur de livres 0.
## Les titres dorés viennent du nuanceur des livres de Gallery et de la texture des titres de la
## galerie ; les livres d'images (drapeaux du service Python) portent un double filet en tête et en pied.
##   godot --path . -s tests/demo_spines.gd [-- hexagone niveau]
##   godot --rendering-driver opengl3 --path . -s tests/demo_spines.gd    (rendu Compatibility)
## Flèches gauche/droite : longer l'étagère ; haut/bas : approcher ou reculer ; Échap : quitter.

const GalleryScript := preload("res://scripts/gallery.gd")
const BookSpineScript := preload("res://scripts/book_spine.gd")
const BookTextScript := preload("res://scripts/book_text.gd")
const SHELF := 2                          # étagère du milieu, à hauteur d'yeux

var _camera: Camera3D
var _gallery: Node3D
var _look := Vector2(0.0, 0.9)            # position le long de l'étagère, distance au dos
var _time := 0.0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var hexagon := int(args[0]) if args.size() > 0 else 1941
	var level := int(args[1]) if args.size() > 1 else 0
	print("Rendu : %s" % RenderingServer.get_current_rendering_method())

	var world := Node3D.new()
	root.add_child(world)
	world.add_child(_environment())
	_gallery = GalleryScript.create(hexagon, level, GalleryScript.Detail.FULL)
	world.add_child(_gallery)
	_gallery.load_titles_now()
	var flags: Array = BookTextScript.gallery_image_books(hexagon, level)
	for book in GalleryScript.BOOKS_PER_SHELF:
		var i: int = SHELF * GalleryScript.BOOKS_PER_SHELF + book
		var image := i < flags.size() and bool(flags[i])
		print("  livre %2d : « %s »%s" % [book + 1, BookTextScript.title(hexagon, level, 0, SHELF, book),
			"  (livre d'images)" if image else ""])

	_camera = Camera3D.new()
	_camera.fov = 50.0
	_camera.near = 0.05
	world.add_child(_camera)
	_place_camera()
	process_frame.connect(_on_frame)


## L'environnement du monde (main.gd) : fond et brume de la Bibliothèque, pénombre ambiante.
func _environment() -> WorldEnvironment:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = GalleryScript.FOG_COLOR
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = GalleryScript.AMBIENT_COLOR
	environment.ambient_light_energy = GalleryScript.AMBIENT_ENERGY
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.fog_enabled = true
	environment.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	environment.fog_light_color = GalleryScript.FOG_COLOR
	environment.fog_density = GalleryScript.FOG_DENSITY
	environment.glow_enabled = true
	var node := WorldEnvironment.new()
	node.environment = environment
	return node


func _on_frame() -> void:
	var delta := 1.0 / 60.0
	_time += delta
	if Input.is_key_pressed(KEY_ESCAPE):
		quit()
	_look.x += (float(Input.is_key_pressed(KEY_LEFT)) - float(Input.is_key_pressed(KEY_RIGHT))) * delta
	_look.y = clampf(_look.y + (float(Input.is_key_pressed(KEY_DOWN)) - float(Input.is_key_pressed(KEY_UP))) * delta, 0.25, 4.0)
	_look.x = clampf(_look.x, -2.4, 2.4)
	_place_camera()
	GalleryScript.pump_titles()
	_gallery.update_lights(_camera.global_position)


## Caméra devant les dos de l'étagère, légèrement balancée pour faire jouer la lumière sur la dorure.
func _place_camera() -> void:
	var middle: Transform3D = _gallery.book_transform(0, SHELF, GalleryScript.BOOKS_PER_SHELF / 2)
	var basis := Basis(Vector3.UP, GalleryScript.BOOK_SIDES[0] * PI / 3.0)
	var toward_room := basis * Vector3.FORWARD
	var along := basis * Vector3.RIGHT
	var target := middle.origin + toward_room * (GalleryScript.BOOK_DEPTH * 0.5) + along * _look.x
	var sway := 0.08 * sin(_time * 0.7)
	_camera.look_at_from_position(target + toward_room * _look.y + along * sway + Vector3.UP * 0.02, target, Vector3.UP)
