extends Node3D
## Monde : tire une galerie au hasard, y place le bibliothécaire, et entretient
## autour de lui les galeries voisines, sur une centaine de mètres le long du
## vestibule et par le puits, au-dessus et au-dessous.
##
## L'origine du monde suit le bibliothécaire : quand il franchit le milieu d'un
## vestibule, la galerie qu'il atteint devient l'origine et tout se décale d'un
## pas ; de même d'un niveau quand il passe à mi-hauteur vers le niveau voisin.
## Les coordonnées restent petites, quelle que soit la distance parcourue ; l'adresse de
## l'origine, elle, est un entier de toute taille (origin_hexagon_b25, origin_level_b25), jusqu'aux
## ~917 000 chiffres décimaux d'une adresse trouvée par la recherche.
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
##
## Invocations (écrites dans le carnet du Hud, voir Carnet.INVOCATIONS) : un saut instantané
## (place_origin), caché par un fondu au noir (TRAVEL_FADE à l'aller, autant au retour) ;
## « couloir » mène à l'hexagone du livre de la quête en gardant le niveau, « puits » à son niveau
## en gardant l'hexagone, l'orientation du bibliothécaire restant la même ; « sator » et « golem »
## mènent à la galerie du livre de leur destination (Quest.destination), face à son mur, le livre
## ouvert à sa page ; « vol » emporte le livre ouvert (un au plus : le précédent retourne à sa
## place), gardé d'une session à l'autre (Quest.save_carried). Les livres volés (ceux du catalogue,
## celui qu'emporte le bibliothécaire) laissent un vide sur leur étagère (Gallery.set_missing_books).

const GalleryScript := preload("res://scripts/gallery.gd")
const AmbientSpeakerScript := preload("res://scripts/ambient_speaker.gd")
const FarViewScript := preload("res://scripts/far_view.gd")
const HudScript := preload("res://scripts/hud.gd")
const PlayerScript := preload("res://scripts/player.gd")
const ReaderScript := preload("res://scripts/reader.gd")
const BookTextScript := preload("res://scripts/book_text.gd")
const QuestScript := preload("res://scripts/quest.gd")

const REACH_ALONG_HALL := 8    # galeries de chaque côté le long du vestibule : 8 × 12 m = 96 m
const REACH_VERTICAL := 30     # niveaux au-dessus et au-dessous, par le puits : 30 × 3,4 m = 102 m
const ROOMS_VERTICAL := 4      # niveaux du puits construits en galeries entières ; au-delà, l'anneau
const LIT_ALONG_HALL := 3      # galeries éclairées par de vraies lampes le long du vestibule
const LIT_VERTICAL := 2        # niveaux éclairés par de vraies lampes dans le puits
const DIAGONAL_REACH := 8      # diagonales vues à travers les puits voisins (voir detail_at)

const FOG_COLOR := GalleryScript.FOG_COLOR
const FOG_DENSITY := GalleryScript.FOG_DENSITY
## Fondu au noir d'une invocation, dans chaque sens : ≈ 0,4 s en tout ; le saut se fait au noir.
const TRAVEL_FADE := 0.2
## « tlon » tapé en relisant le livre emporté le rend à sa place (proposé, en attente de
## confirmation : faux, « tlon » sur le livre emporté ne fait rien).
const RETURN_CARRIED_ON_TLON := true
## Après « sator » : distance du centre de la galerie au bibliothécaire, face au mur du livre.
const FACING_DISTANCE := 3.3

## Une invocation a fini (fondu de retour compris).
signal travel_finished

## Adresse de la galerie placée à l'origine du monde : hexagone et niveau, entiers relatifs de
## toute taille, en base 25 signée (BookText : la forme du fil et du catalogue). Un pas les
## change de ±1 par BookText.b25_add_small : seule la queue de la chaîne change (une copie,
## ~1,4 ms à 900 000 chiffres décimaux), si bien qu'on marche à toute adresse.
var origin_hexagon_b25 := "0"
var origin_level_b25 := "0"
## Repère local des galeries (Gallery.hexagon et Gallery.level, noms des nœuds) : des int qui
## suivent l'origine pas à pas. Ils valent la vraie coordonnée tant qu'elle tient dans un int —
## c'est le cas du départ, tiré au hasard dans la plage des int ; après place_origin sur une
## coordonnée plus grande, ils partent d'un petit entier tiré de la coordonnée. Rien de ce qui se
## voit n'en dépend : graine des livres et titres des dos se tirent de la clé de chaque galerie.
var origin_hexagon: int
var origin_level: int
## Empreintes des vraies coordonnées de l'origine (BookText.b25_print) et leur contexte
## (BookText.print_context) : elles suivent les pas (print_at) et donnent la clé de chaque galerie
## (Gallery.place), celle qu'on obtiendrait en relisant la coordonnée entière : même galerie, même
## aspect, quel que soit le chemin.
var origin_hexagon_print := PackedInt64Array([1, 0, 0])
var origin_level_print := PackedInt64Array([1, 0, 0])
var _hexagon_context: Dictionary = {}
var _level_context: Dictionary = {}
var _hexagon_parts: Dictionary = {}   # décalage → part de clé (_key_part), pour le pas en cours
var _level_parts: Dictionary = {}
## Pas préparés d'avance, par axe (« hexagon », « level ») : pas (±1) → coordonnée voisine prête
## (String), ou calcul en cours sur un fil du moteur ({task, holder}). Le pas en arrière est la
## coordonnée d'où l'on vient ; le pas en avant ne se prépare que lorsqu'une retenue doit traverser
## une longue suite de chiffres (BookText.long_carry) : le pas lui-même ne copie alors rien.
var _prepared := {"hexagon": {}, "level": {}}
var _orphans: Array[int] = []        # calculs préparés devenus inutiles, à relever

var player: PlayerScript
var hud: HudScript
var reader: ReaderScript
var far_view: FarViewScript
static var _cells: Dictionary = {}   # cache de gallery_cells()
var _galleries: Dictionary = {}   # case Vector2i(dz, dy) relative à l'origine → Gallery
var _lit: Array[GalleryScript] = []     # galeries à vraies lampes (LIT et FULL)
static var _lit_cells: Array[Vector2i] = []
var _highlight: MeshInstance3D
var _target: Dictionary = {}        # livre visé, tel que le rend la galerie (repère local)
var _target_book: Dictionary = {}   # le même livre, à sa vraie adresse (base 25)
var _mouse_captured := false
## Dernier mode de souris demandé par le monde (le mode effectif reste VISIBLE sans fenêtre).
var mouse_mode_requested := -1
## Le livre qu'emporte le bibliothécaire, {hexagon, level, wall, shelf, book} ; {} sans livre.
var carried_book: Dictionary = {}
## Fichier du livre emporté ; un test le détourne avant d'ajouter le monde à l'arbre.
var carried_path := QuestScript.user_path(QuestScript.CARRIED_FILE)
## Temps passé sur le fil principal par la dernière invocation, au noir (saut, reconstruction des
## galeries, livre ouvert), en µs.
var last_travel_usec := 0
var _traveling := false
var _queued: Array[String] = []        # sauts invoqués pendant un saut, dans l'ordre
var _save_task := -1                   # écriture du livre emporté sur un fil du moteur, ou −1
var _save_again := false               # le livre emporté a changé pendant l'écriture
var _fade: ColorRect
var _carried_key := ""                 # clé de la galerie du livre emporté
var _reader_key := ""                  # clé de la galerie du livre ouvert, quand elle est connue
var _stolen_keyed: Array = []          # livres volés du catalogue, chacun avec la clé de sa galerie
var _missing_task := -1                # calcul de ces clés sur un fil du moteur (~0,5 s), ou −1
var _missing_holder := {}


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
	origin_hexagon_b25 = BookTextScript.b25_from_int(origin_hexagon)
	origin_level_b25 = BookTextScript.b25_from_int(origin_level)
	_set_prints(BookTextScript.b25_print(origin_hexagon_b25), BookTextScript.b25_print(origin_level_b25))
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
	hud.set_address(origin_hexagon_b25, origin_level_b25)
	hud.set_target({})
	hud.invocation.connect(_on_invocation)
	hud.carried_book_requested.connect(open_carried_book)
	reader = ReaderScript.new()
	add_child(reader)
	_build_fade()
	_start_missing_keys()

	_capture_mouse()


func _exit_tree() -> void:
	flush_carried_save()
	if _missing_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_missing_task)
		_missing_task = -1
	GalleryScript.release_pool()
	for axis: String in _prepared:
		_drop_prepared(axis)
	for task in _orphans:
		WorkerThreadPool.wait_for_task_completion(task)
	_orphans.clear()


func _process(_delta: float) -> void:
	if _save_task >= 0 and WorkerThreadPool.is_task_completed(_save_task):
		WorkerThreadPool.wait_for_task_completion(_save_task)
		_save_task = -1
		if _save_again:
			_save_again = false
			_save_carried()
	if _missing_task >= 0 and WorkerThreadPool.is_task_completed(_missing_task):
		_finish_missing_keys()
	_update_lamps()
	GalleryScript.pump_titles()
	for i in range(_orphans.size() - 1, -1, -1):
		if WorkerThreadPool.is_task_completed(_orphans[i]):
			WorkerThreadPool.wait_for_task_completion(_orphans[i])
			_orphans.remove_at(i)


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
	elif _traveling:
		return   # pendant le fondu d'un saut, ni livre ni souris
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
	_open_address(_target_book, 0, _target.gallery.place.key if not _target.is_empty() else "")


## Ouvre le livre `book` (vraie adresse) dans le lecteur, à la page `page` ; `key`, la clé de sa
## galerie quand on la connaît (livre visé, livre emporté) : « tlon » n'a pas à la recalculer.
func _open_address(book: Dictionary, page := 0, key := "") -> void:
	player.hold("lecteur", true)
	_release_mouse()
	reader.open(book, page)
	_reader_key = key


func _close_book() -> void:
	reader.close()
	player.hold("lecteur", false)
	_capture_mouse()


func _capture_mouse() -> void:
	_mouse_captured = true
	mouse_mode_requested = Input.MOUSE_MODE_CAPTURED
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _release_mouse() -> void:
	_mouse_captured = false
	mouse_mode_requested = Input.MOUSE_MODE_VISIBLE
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


## Retour du focus : la souris se recapture si le bibliothécaire marchait, mais pas sous une
## fenêtre du Hud (panneau de quête, carnet) qui l'a libérée ; elle le rendra en se fermant.
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_IN and _mouse_captured and not (hud != null and hud.overlay_open()):
		_capture_mouse()


# --- Invocations ---------------------------------------------------------------------------------

## Applique une invocation du carnet (Hud.invocation) ; le Hud n'émet que celles qui valent ici.
## Un saut demandé pendant un autre attend sa fin (_queued), puis part de la galerie d'arrivée.
func _on_invocation(axis: String) -> void:
	if _traveling and axis in ["couloir", "puits", "sator", "golem"]:
		_queued.append(axis)
		return
	match axis:
		"couloir":
			if hud.quest != null:
				travel(hud.quest.book.hexagon, origin_level_b25)
		"puits":
			if hud.quest != null:
				travel(origin_hexagon_b25, hud.quest.book.level)
		"vol":
			steal_open_book()
		"sator", "golem":
			var place := QuestScript.destination(axis, hud.catalogue_path)
			if not place.is_empty():
				travel(place.address.hexagon, place.address.level, place.address)


## Saut à la galerie (hexagone, niveau), caché par un fondu au noir ; `book` (vraie adresse et
## page), facultatif : le bibliothécaire arrive face à son mur et le livre s'ouvre à cette page ;
## sinon il garde sa place dans la galerie et son orientation. Rend la main au retour du fondu.
func travel(hexagon: Variant, level: Variant, book := {}) -> void:
	if _traveling:
		return
	_traveling = true
	player.hold("saut", true)
	await _fade_to(1.0)
	var started := Time.get_ticks_usec()
	place_origin(hexagon, level)
	player.velocity = Vector3.ZERO
	if not book.is_empty():
		_face_book(book)
		_open_address(book, int(book.get("page", 0)))
	last_travel_usec = Time.get_ticks_usec() - started
	await _fade_to(0.0)
	player.hold("saut", false)
	_traveling = false
	travel_finished.emit()
	if not _queued.is_empty():
		_on_invocation(_queued.pop_front())


## Vrai pendant une invocation (fondus compris).
func traveling() -> bool:
	return _traveling


## Place le bibliothécaire face au livre `book` de la galerie d'origine, à FACING_DISTANCE du
## centre, le regard sur son dos.
func _face_book(book: Dictionary) -> void:
	var turn := GalleryScript.BOOK_SIDES[int(book.wall)] * PI / 3.0
	var along := GalleryScript.SHELF_WIDTH * 0.5 - (int(book.book) + 0.5) * GalleryScript.BOOK_SLOT
	player.position = Basis(Vector3.UP, turn) * Vector3(along, 0.05, FACING_DISTANCE)
	player.rotation = Vector3(0.0, turn + PI, 0.0)
	var spine := GalleryScript.BOARD_BASE + (GalleryScript.SHELVES - 1 - int(book.shelf)) * GalleryScript.BOARD_PITCH \
		+ GalleryScript.BOOK_MIN_HEIGHT * 0.5
	player.camera.rotation.x = atan2(spine - 0.05 - PlayerScript.EYE_HEIGHT, GalleryScript.BOOK_FRONT - FACING_DISTANCE)


func _build_fade() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 100   # au-dessus du lecteur et du carnet
	add_child(layer)
	_fade = ColorRect.new()
	_fade.color = Color(0.0, 0.0, 0.0, 0.0)
	_fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_fade)


func _fade_to(alpha: float) -> void:
	var tween := create_tween()
	tween.tween_property(_fade, "color:a", alpha, TRAVEL_FADE)
	await tween.finished


## « tlon » : le livre ouvert dans le lecteur part avec le bibliothécaire ; celui qu'il emportait
## retourne à sa place. Relu, le livre emporté retourne à sa place (RETURN_CARRIED_ON_TLON).
func steal_open_book() -> void:
	if not reader.visible or reader.book.is_empty():
		return
	var book := BookTextScript.book_of(reader.book)
	if book == carried_book:
		if RETURN_CARRIED_ON_TLON:
			set_carried_book({})
		return
	set_carried_book(book, _reader_key)


## Le livre emporté devient `book` ({} : aucun) : enregistré, son vide posé sur son étagère, celui
## du livre précédent comblé. `key` : la clé de sa galerie, si elle est connue (sinon calculée :
## ~50 ms à 917 000 chiffres).
func set_carried_book(book: Dictionary, key := "") -> void:
	carried_book = BookTextScript.book_of(book) if not book.is_empty() else {}
	_carried_key = ""
	if not carried_book.is_empty():
		_carried_key = key if not key.is_empty() else BookTextScript.gallery_key(carried_book.hexagon, carried_book.level)
	_save_carried()
	_apply_missing()


## Enregistre le livre emporté sur un fil du moteur (~0,8 Mo, ~65 ms à 917 000 chiffres : jamais
## sur le fil principal), une écriture à la fois ; un changement pendant l'écriture en relance une
## à sa fin (_process), avec le livre d'alors.
func _save_carried() -> void:
	if _save_task >= 0:
		_save_again = true
		return
	var book := carried_book
	var path := carried_path
	_save_task = WorkerThreadPool.add_task(func() -> void:
		if not QuestScript.save_carried(book, path):
			push_warning("livre emporté non enregistré : %s" % path), false, "livre emporté")


## Attend la fin de l'écriture du livre emporté (et de celle qu'un changement a demandée).
func flush_carried_save() -> void:
	while _save_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_save_task)
		_save_task = -1
		if _save_again:
			_save_again = false
			_save_carried()


## La touche du carnet, carnet ouvert : le livre emporté s'ouvre dans le lecteur (rien sans livre).
func open_carried_book() -> void:
	if not carried_book.is_empty() and not _traveling:
		_open_address(carried_book, 0, _carried_key)


## Les clés des galeries des livres volés du catalogue et du livre emporté (enregistré), calculées
## sur un fil du moteur (~30 ms par coordonnée de 656 000 chiffres) : le jeu démarre sans les
## attendre ; un saut les attend (_finish_missing_keys), aucune galerie volée n'est près du départ.
func _start_missing_keys() -> void:
	carried_book = QuestScript.load_carried(carried_path)
	var books := QuestScript.stolen_books(hud.catalogue_path).filter(func(b: Dictionary) -> bool: return not b.is_empty())
	var carried := carried_book
	var holder := {"stolen": [], "carried": []}
	BookTextScript.b25_fits_int("0")   # borne des int posée sur le fil principal
	_missing_holder = holder
	_missing_task = WorkerThreadPool.add_task(func() -> void:
		holder.stolen = _keyed(books)
		holder.carried = _keyed([carried] if not carried.is_empty() else []), false, "livres volés")


func _finish_missing_keys() -> void:
	if _missing_task < 0:
		return
	WorkerThreadPool.wait_for_task_completion(_missing_task)
	_missing_task = -1
	_stolen_keyed = _missing_holder.stolen
	var carried: Array = _missing_holder.carried
	if not carried.is_empty() and carried[0].hexagon == carried_book.get("hexagon") and carried[0].level == carried_book.get("level"):
		_carried_key = carried[0].key
	_missing_holder = {}
	_apply_missing()


## Les livres `books` avec la clé de leur galerie (sans mémoire partagée : sur un fil du moteur).
static func _keyed(books: Array) -> Array:
	var keyed := []
	for b: Dictionary in books:
		var key := BookTextScript.gallery_key_of(BookTextScript.b25_print(b.hexagon, false), BookTextScript.b25_print(b.level, false))
		keyed.append(b.merged({"key": key}))
	return keyed


## Déclare aux galeries les livres absents : ceux du catalogue (dès que leurs clés sont prêtes) et
## le livre emporté.
func _apply_missing() -> void:
	var books := _stolen_keyed.duplicate()
	if not carried_book.is_empty() and not _carried_key.is_empty():
		books.append(carried_book.merged({"key": _carried_key}))
	GalleryScript.set_missing_books(books)
	for gallery: GalleryScript in _galleries.values():
		gallery.refresh_missing()


func _show_target(target: Dictionary) -> void:
	if target.is_empty() or not is_instance_valid(target.gallery):
		target = {}
	if target != _target:
		_target = target
		_target_book = target_address(target)
		hud.set_target(target)
	_highlight.visible = not target.is_empty()
	if _highlight.visible:
		var gallery: GalleryScript = target.gallery
		var book := gallery.book_transform(target.wall, target.shelf, target.book)
		_highlight.global_transform = gallery.global_transform * book.scaled_local(Vector3(1.12, 1.04, 1.04))


## La vraie adresse (base 25) d'un livre visé dans une galerie : {hexagon, level, wall, shelf,
## book} ; {} sans livre. La galerie le désigne dans le repère local, à quelques cases de l'origine.
func target_address(target: Dictionary) -> Dictionary:
	if target.is_empty():
		return {}
	return {
		"hexagon": BookTextScript.b25_add_small(origin_hexagon_b25, int(target.hexagon) - origin_hexagon),
		"level": BookTextScript.b25_add_small(origin_level_b25, int(target.level) - origin_level),
		"wall": target.wall, "shelf": target.shelf, "book": target.book,
	}


## Place l'origine du monde sur la galerie (hexagone, niveau), int ou chaînes base 25 de toute
## taille, et reconstruit les galeries autour ; faux si une coordonnée est invalide.
func place_origin(hexagon: Variant, level: Variant) -> bool:
	var h := BookTextScript.b25(hexagon)
	var l := BookTextScript.b25(level)
	if h.is_empty() or l.is_empty():
		return false
	_finish_missing_keys()   # les vides des livres volés, avant les galeries de la nouvelle origine
	origin_hexagon_b25 = h
	origin_level_b25 = l
	origin_hexagon = _local_coordinate(h)
	origin_level = _local_coordinate(l)
	_set_prints(BookTextScript.b25_print(h), BookTextScript.b25_print(l))
	for axis: String in _prepared:
		_drop_prepared(axis)
		for step: int in [1, -1]:
			_prepare(axis, h if axis == "hexagon" else l, step)
	_update_galleries(Vector2i.ZERO, true)
	if hud != null:
		hud.set_address(origin_hexagon_b25, origin_level_b25)
	_target = {}
	_target_book = {}
	return true


## La coordonnée du repère local d'une vraie coordonnée : elle-même quand elle tient dans un int,
## sinon un entier de 30 bits tiré de ses chiffres (même coordonnée, même entier).
static func _local_coordinate(coordinate: String) -> int:
	if BookTextScript.b25_fits_int(coordinate):
		return BookTextScript.b25_to_int(coordinate)
	return (coordinate.hash() & 0x3FFFFFFF) - (1 << 29)


## Fait de la galerie voisine (+1 ou −1 le long du vestibule) la nouvelle origine.
func _shift(step: int) -> void:
	origin_hexagon += step
	origin_hexagon_b25 = _stepped("hexagon", origin_hexagon_b25, step)
	_hexagon_context = BookTextScript.print_context_step(_hexagon_context, step, origin_hexagon_b25)
	_hexagon_parts = {}
	origin_hexagon_print = _print_of(_hexagon_context)
	player.position.z -= step * GalleryScript.PITCH
	_update_galleries(Vector2i(step, 0))
	hud.set_address(origin_hexagon_b25, origin_level_b25, Vector2i(step, 0))


## Fait du niveau voisin (+1 au-dessus, −1 au-dessous) la nouvelle origine.
func _shift_level(step: int) -> void:
	origin_level += step
	origin_level_b25 = _stepped("level", origin_level_b25, step)
	_level_context = BookTextScript.print_context_step(_level_context, step, origin_level_b25)
	_level_parts = {}
	origin_level_print = _print_of(_level_context)
	player.position.y -= step * GalleryScript.LEVEL_PITCH
	_update_galleries(Vector2i(0, step))
	hud.set_address(origin_hexagon_b25, origin_level_b25, Vector2i(0, step))


## La coordonnée `current` (de l'axe `axis`) ± 1 : préparée d'avance si elle l'est, sinon
## calculée (BookText.b25_add_small) ; puis le pas suivant se prépare (voir _prepared).
func _stepped(axis: String, current: String, step: int) -> String:
	var ready: Variant = _prepared[axis].get(step)
	var next: String
	if ready is String:
		next = ready
	elif ready is Dictionary:
		WorkerThreadPool.wait_for_task_completion(ready.task)   # d'ordinaire déjà fini
		next = ready.holder.result
		_prepared[axis].erase(step)
	else:
		next = BookTextScript.b25_add_small(current, step)
	_drop_prepared(axis)
	_prepared[axis][-step] = current
	_prepare(axis, next, step)
	return next


## Lance sur un fil du moteur le calcul de `coordinate` + step quand il demande une longue retenue.
func _prepare(axis: String, coordinate: String, step: int) -> void:
	if not BookTextScript.long_carry(coordinate, step):
		return
	var holder := {"result": ""}
	var task := WorkerThreadPool.add_task(func() -> void:
		holder.result = BookTextScript.b25_add_small(coordinate, step), false, "pas préparé")
	_prepared[axis][step] = {"task": task, "holder": holder}


func _drop_prepared(axis: String) -> void:
	for ready: Variant in _prepared[axis].values():
		if ready is Dictionary:
			_orphans.append(ready.task)
	_prepared[axis] = {}


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
## qui passent par la réserve de Gallery. `readdress_all` : l'origine a sauté (place_origin),
## toutes les galeries prennent une adresse nouvelle.
func _update_galleries(moved := Vector2i.ZERO, readdress_all := false) -> void:
	var cells := gallery_cells()
	var placed: Dictionary = {}
	var spares: Array = [[], [], []]   # par degré de détail
	for old_cell: Vector2i in _galleries:
		var cell := old_cell - moved
		var gallery: GalleryScript = _galleries[old_cell]
		if cells.has(cell) and not readdress_all:
			placed[cell] = gallery
		else:
			spares[gallery.detail].append(gallery)
	for cell: Vector2i in cells:
		var detail: int = cells[cell]
		var gallery: GalleryScript = placed.get(cell)
		if gallery == null:
			gallery = _take_spare(spares, detail)
			if gallery == null:
				gallery = GalleryScript.create(origin_hexagon + cell.x, origin_level + cell.y, detail as GalleryScript.Detail, place_at(cell))
				add_child(gallery)
			else:
				gallery.readdress(origin_hexagon + cell.x, origin_level + cell.y, detail as GalleryScript.Detail, place_at(cell))
			placed[cell] = gallery
		else:
			# Même galerie, même clé : seule sa description passe aux chaînes de la nouvelle origine.
			gallery.place = GalleryScript.place_of(origin_hexagon_b25, cell.x, origin_level_b25, cell.y, gallery.place.key)
			if gallery.detail != detail:
				gallery.set_detail(detail as GalleryScript.Detail)
		gallery.position = Vector3(0.0, cell.y * GalleryScript.LEVEL_PITCH, cell.x * GalleryScript.PITCH)
		gallery.set_speaker(AmbientSpeakerScript.has_speaker(cell))   # musique : vestibules du niveau, ±30 m
	for pool: Array in spares:
		for spare: GalleryScript in pool:
			spare.queue_free()
	_galleries = placed
	_lit.clear()
	for cell: Vector2i in lit_cells():
		_lit.append(placed[cell])
	GalleryScript.prefetch_titles(place_at, lit_cells())   # titres du prochain pas
	_update_lamps()


## La vraie adresse de la galerie de la case `cell` (dz, dy) relative à l'origine (Gallery.place_of) :
## les chaînes de l'origine, partagées sans copie, le décalage, et la clé tirée des empreintes.
func place_at(cell: Vector2i) -> Dictionary:
	return GalleryScript.place_of(origin_hexagon_b25, cell.x, origin_level_b25, cell.y,
		_key_part(_hexagon_parts, _hexagon_context, cell.x) + "|" + _key_part(_level_parts, _level_context, cell.y))


## La part d'un axe dans la clé d'une galerie (BookText.print_text de l'empreinte à `delta` de
## l'origine), calculée une fois par pas pour toutes les galeries de la même rangée.
static func _key_part(parts: Dictionary, context: Dictionary, delta: int) -> String:
	var part: Variant = parts.get(delta)
	if part == null:
		part = BookTextScript.print_text(BookTextScript.print_at(context, delta))
		parts[delta] = part
	return part


## Empreintes de l'origine après un saut (les chaînes origin_*_b25 sont déjà à jour) et leur
## contexte pour les galeries voisines ; un pas les fait suivre par BookText.print_context_step.
func _set_prints(hexagon_print: PackedInt64Array, level_print: PackedInt64Array) -> void:
	_hexagon_context = BookTextScript.print_context(origin_hexagon_b25, hexagon_print)
	_level_context = BookTextScript.print_context(origin_level_b25, level_print)
	_hexagon_parts = {}
	_level_parts = {}
	origin_hexagon_print = hexagon_print
	origin_level_print = level_print


static func _print_of(context: Dictionary) -> PackedInt64Array:
	return BookTextScript.print_at(context, 0)


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
