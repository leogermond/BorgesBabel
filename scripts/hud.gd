class_name Hud
extends CanvasLayer
## Adresse de la galerie courante, réticule, cote du livre visé, et quête : un encart en haut à
## droite guide vers le livre cherché ; le panneau de quête (touche QUEST_KEY) libère la souris et
## propose les épingles, l'ouverture d'un fichier et la saisie d'un texte.
##
## Le carnet (Carnet, touche cachée Carnet.CARNET_KEY) est un enfant du Hud : le Hud lui passe
## toutes les touches tant qu'il est ouvert, lui dit quelles invocations valent (can_invoke) et
## relaie son signal invocation(axe) ; la même touche, carnet ouvert, demande le livre emporté
## (carried_book_requested). Aucune touche ni invocation n'est nommée à l'écran.
##
## La quête en cours se garde d'une session à l'autre (Quest.save_active, active_path), son
## effacement aussi ; au premier lancement (rien d'enregistré), c'est l'entrée Quest.FIRST_QUEST.

const BookTextScript := preload("res://scripts/book_text.gd")
const GalleryScript := preload("res://scripts/gallery.gd")
const PlayerScript := preload("res://scripts/player.gd")
const QuestScript := preload("res://scripts/quest.gd")
const CarnetScript := preload("res://scripts/carnet.gd")

## La quête a changé (null quand elle s'efface).
signal quest_changed(quest: QuestScript)
## Invocation écrite dans le carnet (Carnet.INVOCATIONS) : « couloir », « puits », « vol »,
## « sator » ou « golem ».
signal invocation(axis: String)
## La touche du carnet, carnet ouvert : le carnet se ferme, le monde ouvre le livre emporté s'il y en a un.
signal carried_book_requested
## Le panneau de quête s'ouvre (vrai) ou se ferme (faux).
signal quest_panel_toggled(open: bool)

const QUEST_KEY := KEY_TAB
const QUEST_KEY_NAME := "Tab"
const CLEAR_KEY := KEY_DELETE
const CLEAR_KEY_NAME := "Suppr"
const FILE_FILTERS: PackedStringArray = ["*.txt ; Textes", "*.png, *.jpg, *.jpeg, *.webp ; Images"]
const ARROWS: PackedStringArray = ["↑", "↗", "→", "↘", "↓", "↙", "←", "↖"]
const PIN_GLYPH := "📌"
const WIDGET_WIDTH := 460.0

## Quête en cours, ou null.
var quest: QuestScript
## Le carnet, créé au premier _ready.
var carnet: CarnetScript
var catalogue: Array = []
var pins: Array = []
## Chemins lus au premier _ready ; les tests les détournent avant d'ajouter le Hud à l'arbre.
var catalogue_path := QuestScript.CATALOGUE_PATH
var pins_path := QuestScript.user_path(QuestScript.PINS_FILE)
var active_path := QuestScript.user_path(QuestScript.ACTIVE_FILE)
## Message d'erreur de la dernière recherche (vide quand tout va bien).
var last_error := ""
## Le registre des livres manquants est déplié dans le panneau.
var register_open := false

var _address: Label
var _crosshair: Label
var _hint: Label
var _widget: VBoxContainer
var _quest_title: Label
var _quest_glyph: Label
var _arrow: QuestArrow
var _quest_hall: Label
var _quest_level: Label
var _quest_book: Label
var _panel: Control
var _panel_box: VBoxContainer
var _file_dialog: FileDialog
var _text_edit: LineEdit
var _pin_title_edit: LineEdit
## Galerie courante : hexagone et niveau en base 25 signée (BookText), et leurs résumés d'écran.
var _hexagon := "0"
var _level := "0"
var _hexagon_summary: Dictionary = {}
var _level_summary: Dictionary = {}
## Résumés recalculés en arrière-plan (BookText.submit) : axe → [ticket, pas faits depuis la demande].
var _summary_requests: Dictionary = {}
var _guide: Dictionary = {}
var _mouse_before := Input.MOUSE_MODE_VISIBLE
## Dernier mode de souris demandé par le panneau (le mode effectif reste VISIBLE sans fenêtre).
var mouse_mode_requested := -1


func _ready() -> void:
	catalogue = QuestScript.load_catalogue(catalogue_path)
	pins = QuestScript.load_pins(catalogue, pins_path)
	var stored := QuestScript.load_active(catalogue, active_path)
	if stored.stored:
		quest = stored.quest
	else:   # premier lancement : la quête d'office, enregistrée
		var first := QuestScript.catalogue_entry(catalogue, QuestScript.FIRST_QUEST)
		quest = QuestScript.from_entry(first) if not first.is_empty() else null
		_save_active()

	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_address = _label(15)
	_address.position = Vector2(16, 12)
	root.add_child(_address)

	_crosshair = _label(22)
	_crosshair.text = "+"
	_crosshair.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_crosshair.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_crosshair.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	root.add_child(_crosshair)

	_hint = _label(15)
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.set_anchors_preset(Control.PRESET_CENTER)
	_hint.offset_left = -400
	_hint.offset_right = 400
	_hint.offset_top = 24
	_hint.offset_bottom = 48
	root.add_child(_hint)

	_build_widget(root)
	_build_panel()
	carnet = CarnetScript.new()
	carnet.can_invoke = can_invoke
	carnet.invocation.connect(invocation.emit)
	carnet.toggled.connect(_hold_player.bind("carnet"))
	add_child(carnet)
	_refresh_widget()


## Affiche l'adresse de la galerie courante, hexagone et niveau en int ou en chaînes base 25.
## Une coordonnée qui tient dans un int s'écrit en entier ; une plus grande, par son résumé
## (BookText.coordinate_summary) : signe, 4 premiers chiffres, 4 derniers, nombre de chiffres.
## `moved` : le pas (galeries, niveaux) qui mène de l'adresse précédente à celle-ci ; les
## derniers chiffres et le guidage suivent alors le pas sans relire les coordonnées (un pas reste
## dans le budget d'une image même à 900 000 chiffres ; les chaînes, canoniques, ne sont alors pas
## relues) ; sinon tout se recalcule.
func set_address(hexagon: Variant, level: Variant, moved := Vector2i.ZERO) -> void:
	var stepping := moved != Vector2i.ZERO and hexagon is String and level is String \
		and not _hexagon_summary.is_empty() and not _level_summary.is_empty()
	if stepping:
		_hexagon = hexagon
		_level = level
		_hexagon_summary = _stepped_summary("hexagon", _hexagon_summary, _hexagon, moved.x)
		_level_summary = _stepped_summary("level", _level_summary, _level, moved.y)
	else:
		_cancel_summary_requests()
		_hexagon = BookTextScript.b25(hexagon)
		_level = BookTextScript.b25(level)
		_hexagon_summary = _fresh_summary("hexagon", _hexagon)
		_level_summary = _fresh_summary("level", _level)
	_show_address()
	_refresh_widget(moved if stepping else Vector2i.ZERO)


## Le résumé d'une coordonnée lue d'un coup (saut) : calcul local pour une petite ; pour une
## grande, un résumé provisoire (signe et nombre de chiffres, sans les chiffres de tête ni de
## queue) et la forme « display » demandée au service d'arrière-plan : le fil principal n'attend pas.
func _fresh_summary(axis: String, coordinate: String) -> Dictionary:
	if coordinate.length() <= BookTextScript.SMALL_SUMMARY_DIGITS + 1:
		return BookTextScript.coordinate_summary(coordinate)
	_summary_requests[axis] = [BookTextScript.submit(BookTextScript.display_request(coordinate)), 0]
	return {"sign": BookTextScript.b25_sign(coordinate), "digits": BookTextScript.b25_decimal_digits(coordinate),
		"lead": "", "tail": "", "pending": true}


func _show_address() -> void:
	_address.text = "Hexagone %s · niveau %s" % [BookTextScript.summary_text(_hexagon_summary), BookTextScript.summary_text(_level_summary)]


## Le résumé d'écran d'une coordonnée après un pas : celui d'avant (pas nul sur cet axe), ou
## avancé du pas (BookText.summary_step) ; une petite coordonnée se recalcule sur place (calcul
## local exact, en int quand elle y tient de nouveau) ; une grande dont les 18 derniers chiffres
## débordent (une fois tous les 10^18 pas) garde un résumé provisoire (summary_wrap) et se
## recalcule en arrière-plan : aucun pas n'attend le service.
func _stepped_summary(axis: String, previous: Dictionary, coordinate: String, step: int) -> Dictionary:
	if step == 0:
		return previous
	if _summary_requests.has(axis):
		_summary_requests[axis][1] += step
	if not previous.is_empty() and not previous.has("low"):
		return previous   # provisoire : le résumé arrive en arrière-plan, avancé des pas faits d'ici là
	var next := BookTextScript.summary_step(previous, step)
	if not next.is_empty():
		return next
	if coordinate.length() <= BookTextScript.SMALL_SUMMARY_DIGITS + 1 or previous.is_empty():
		return BookTextScript.coordinate_summary(coordinate)
	if not _summary_requests.has(axis):
		_summary_requests[axis] = [BookTextScript.submit(BookTextScript.display_request(coordinate)), 0]
	return BookTextScript.summary_wrap(previous, step)


## Résumés recalculés en arrière-plan : arrivés, ils remplacent le résumé provisoire, avancés des
## pas faits depuis la demande.
func _poll_summaries() -> void:
	for axis: String in _summary_requests.keys():
		var request: Array = _summary_requests[axis]
		var response: Variant = BookTextScript.take(request[0])
		if response == null:
			continue
		_summary_requests.erase(axis)
		var coordinate := _hexagon if axis == "hexagon" else _level
		var summary := BookTextScript.summary_of_display(response)
		if not summary.is_empty() and request[1] != 0:
			summary = BookTextScript.summary_step(summary, request[1])
		if summary.is_empty():   # erreur, ou nouveau débordement : nouvelle demande
			_summary_requests[axis] = [BookTextScript.submit(BookTextScript.display_request(coordinate)), 0]
			continue
		if axis == "hexagon":
			_hexagon_summary = summary
		else:
			_level_summary = summary
		_show_address()


func _cancel_summary_requests() -> void:
	for request: Array in _summary_requests.values():
		BookTextScript.cancel(request[0])
	_summary_requests.clear()


## Vrai tant qu'un résumé d'adresse se recalcule en arrière-plan.
func address_pending() -> bool:
	return not _summary_requests.is_empty()


## Affiche la cote du livre visé, ou rien.
func set_target(target: Dictionary) -> void:
	if target.is_empty():
		_hint.text = ""
		_crosshair.modulate = Color(1, 1, 1, 0.6)
	else:
		_hint.text = "mur %d · étagère %d · livre %d" % [target.wall + 1, target.shelf + 1, target.book + 1]
		_crosshair.modulate = Color(1.0, 0.85, 0.4)


# --- Quête --------------------------------------------------------------------------------------

func start_quest(new_quest: QuestScript) -> void:
	quest = new_quest
	last_error = ""
	_save_active()
	_refresh_widget()
	quest_changed.emit(quest)
	if is_panel_open():
		_rebuild_panel()


func clear_quest() -> void:
	if quest == null:
		return
	quest = null
	_save_active()
	_refresh_widget()
	quest_changed.emit(null)
	if is_panel_open():
		_rebuild_panel()


func set_quest_page(index: int) -> void:
	if quest == null:
		return
	quest.set_page(index)
	_save_active()
	_refresh_widget()
	quest_changed.emit(quest)
	if is_panel_open():
		_rebuild_panel()


func _save_active() -> void:
	if not QuestScript.save_active(quest, active_path):
		push_warning("quête en cours non enregistrée : %s" % active_path)


## Vrai quand l'invocation `axis` (Carnet.INVOCATIONS) vaut ici : « couloir » et « puits » avec
## une quête, « vol » un livre ouvert (le lecteur, ou le carnet ouvert par-dessus), « sator » et
## « golem » quand le catalogue connaît leur destination. Sinon le mot s'efface, comme tout autre.
func can_invoke(axis: String) -> bool:
	match axis:
		"couloir", "puits":
			return quest != null
		"vol":
			return _reader_open()
		"sator", "golem":
			return not QuestScript.destination(axis, catalogue_path).is_empty()
	return false


## Vrai tant qu'une fenêtre du Hud (panneau de quête, carnet, choix de fichier) tient la souris.
func overlay_open() -> bool:
	return is_panel_open() or (carnet != null and carnet.is_open()) or (_file_dialog != null and _file_dialog.visible)


## Le guidage de la quête depuis la galerie courante ({} sans quête).
func guidance() -> Dictionary:
	return _guide


## Démarre la quête d'une épingle ; faux pour le registre et pour une entrée disparue du catalogue.
func start_pin(pin: Dictionary) -> bool:
	if pin.kind == QuestScript.KIND_REGISTER:
		return false   # le registre ne mène nulle part ; ses lignes, si
	var found := QuestScript.from_pin(pin, catalogue)
	if found == null:
		last_error = "entrée introuvable : %s" % pin.title
		return false
	start_quest(found)
	return true


## Cherche un texte tapé ; faux en cas d'échec (last_error).
func search_typed(text: String) -> bool:
	if text.strip_edges().is_empty():
		last_error = "texte vide"
		return false
	return _start_search(BookTextScript.search_text(text), "texte saisi")


## Cherche un fichier de texte (.txt) ou d'image ; faux en cas d'échec (last_error).
func search_file(path: String) -> bool:
	var found := BookTextScript.search_text_file(path) if path.get_extension().to_lower() == "txt" else BookTextScript.search_image_file(path)
	return _start_search(found, path.get_file())


## Épingle la quête en cours (recherche du joueur) : le titre et l'adresse, jamais la source.
func pin_current(pin_title: String) -> bool:
	if quest == null or not quest.entry_id.is_empty():
		return false
	var pin_name := pin_title.strip_edges() if not pin_title.strip_edges().is_empty() else quest.title
	pins = QuestScript.add_pin(pins, QuestScript.search_pin(pin_name, quest.address(), quest.pages.size()))
	_save_pins()
	return true


func unpin(id: String) -> void:
	pins = QuestScript.remove_pin(pins, id)
	_save_pins()


## Rétablit les entrées du catalogue désépinglées.
func restore_pins() -> void:
	pins = QuestScript.restore_catalogue(pins, catalogue)
	_save_pins()


func _start_search(found: Dictionary, default_title: String) -> bool:
	if found.is_empty():
		last_error = BookTextScript.last_error if not BookTextScript.last_error.is_empty() else "recherche sans résultat"
		if is_panel_open():
			_rebuild_panel()
		return false
	# Les pages qu'occupe le texte (text_pages) et l'avis du service : texte tronqué, livre d'images.
	var search := BookTextScript.last_search
	var notice := str(search.get("notice", "")) if search.get("notice") is String else ""
	if notice.is_empty() and search.get("is_image") == true:
		notice = "livre d'images : chaque page se lit comme une image"
	var pages: Variant = search.get("text_pages", 1)
	start_quest(QuestScript.from_search(found, int(pages) if pages is float or pages is int else 1, default_title, notice))
	return true


func _save_pins() -> void:
	if not QuestScript.save_pins(pins, pins_path):
		push_warning("épingles non enregistrées : %s" % pins_path)
	if is_panel_open():
		_rebuild_panel()


# --- Clavier ------------------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if handle_key(event):
		get_viewport().set_input_as_handled()


## Panneau ou carnet ouvert : ce que leurs contrôles n'ont pas pris s'arrête ici (le Hud, enfant du
## monde, reçoit l'entrée non traitée avant lui) ; E n'ouvre pas de livre sous le panneau.
func _unhandled_input(event: InputEvent) -> void:
	if is_panel_open() or (carnet != null and carnet.is_open()):
		if event is InputEventKey or event is InputEventMouseButton or event is InputEventMouseMotion:
			get_viewport().set_input_as_handled()


## Traite une touche ; vrai quand elle est consommée.
func handle_key(event: InputEvent) -> bool:
	if not event is InputEventKey:
		return false
	var key := event as InputEventKey
	if carnet.is_open():
		if key.pressed and not key.echo and key.physical_keycode == CarnetScript.CARNET_KEY:
			carnet.close()
			carried_book_requested.emit()
			return true
		return carnet.handle_key(key)
	if _file_dialog != null and _file_dialog.visible:
		return false
	if not key.pressed or key.echo:
		return false
	if is_panel_open():
		if key.physical_keycode == KEY_ESCAPE:
			close_panel()
			return true
		if key.physical_keycode == QUEST_KEY and not _typing():
			close_panel()
			return true
		return false
	if key.ctrl_pressed or key.alt_pressed or key.meta_pressed:
		return false
	if key.physical_keycode == CarnetScript.CARNET_KEY:
		carnet.open()
		return true
	if key.physical_keycode == QUEST_KEY:
		if _reader_open():
			return false
		open_panel()
		return true
	if key.physical_keycode == CLEAR_KEY and quest != null:
		clear_quest()
		return true
	return false


## Le bibliothécaire reste immobile tant que le panneau ou le carnet est ouvert (raison
## `reason` de Player.hold, levée à la fermeture quel que soit l'état des autres).
func _hold_player(hold: bool, reason := "panneau") -> void:
	var player := _player()
	if player != null:
		player.hold(reason, hold)


func _typing() -> bool:
	var focus := _panel.get_viewport().gui_get_focus_owner() if _panel.is_inside_tree() else null
	return focus is LineEdit


func _reader_open() -> bool:
	var parent := get_parent()
	if parent == null:
		return false
	var reader: Variant = parent.get("reader")
	return reader is CanvasLayer and reader.visible


func _player() -> PlayerScript:
	var parent := get_parent()
	if parent == null:
		return null
	var player: Variant = parent.get("player")
	return player if player is PlayerScript else null


# --- Encart de quête ----------------------------------------------------------------------------

func _build_widget(root: Control) -> void:
	_widget = VBoxContainer.new()
	_widget.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_widget.anchor_left = 1.0
	_widget.anchor_right = 1.0
	_widget.offset_left = -WIDGET_WIDTH - 16.0
	_widget.offset_right = -16.0
	_widget.offset_top = 12.0
	_widget.add_theme_constant_override("separation", 2)
	root.add_child(_widget)
	_quest_title = _widget_label(14)
	_quest_title.modulate = Color(1.0, 0.9, 0.7)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_widget.add_child(row)
	_quest_glyph = _label(18)
	_quest_glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_quest_glyph)
	_arrow = QuestArrow.new()
	row.add_child(_arrow)
	_quest_hall = _widget_label(14)
	_quest_level = _widget_label(14)
	_quest_book = _widget_label(14)


func _widget_label(size: int) -> Label:
	var label := _label(size)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.clip_text = true
	label.custom_minimum_size.x = WIDGET_WIDTH
	_widget.add_child(label)
	return label


func _refresh_widget(moved := Vector2i.ZERO) -> void:
	if _widget == null:
		return
	_widget.visible = quest != null
	if quest == null:
		_guide = {}
		return
	_guide = quest.guidance(_hexagon, _level, moved)
	_quest_title.text = quest.label()
	_quest_hall.text = _guide.hall_text
	_quest_level.text = _guide.level_text
	_quest_book.text = _guide.book_text
	_update_arrow(get_viewport().get_camera_3d() if is_inside_tree() else null)


func _process(_delta: float) -> void:
	if not _summary_requests.is_empty():
		_poll_summaries()
	if quest != null and not _guide.is_empty():
		_update_arrow(get_viewport().get_camera_3d())


func _update_arrow(camera: Camera3D) -> void:
	var state := direction(_guide, quest.address(), camera)
	_arrow.set_state(state.mode, state.heading)
	_quest_glyph.text = "ici" if state.mode == QuestArrow.HERE else ""


## L'état de la flèche de l'encart : {mode, heading, glyph}.
##   mode « haut » / « bas » : la cible est à un autre étage, la flèche se dresse vers le haut ou le bas ;
##   mode « plat » : même étage, la flèche couchée montre le vestibule (+Z ou −Z) ;
##   mode « ici » : galerie atteinte, la flèche couchée montre le livre.
## heading : angle de la flèche couchée par rapport au regard, en radians (0 devant, positif à droite) ;
## glyph : la même direction en un caractère (huit flèches, ▲ ou ▼), ou « +Z » / « −Z » sans caméra.
static func direction(guide: Dictionary, target: Dictionary, camera: Camera3D) -> Dictionary:
	if guide.vert != 0:
		var up: bool = guide.vert > 0
		return {"mode": QuestArrow.UP if up else QuestArrow.DOWN, "heading": 0.0, "glyph": "▲" if up else "▼"}
	var from := camera.global_position if camera != null else Vector3.ZERO
	var mode := QuestArrow.FLAT
	var toward := Vector3(0.0, 0.0, guide.hall)
	if guide.hall == 0:
		mode = QuestArrow.HERE
		var side := Basis(Vector3.UP, GalleryScript.BOOK_SIDES[target.wall] * PI / 3.0)
		var book := side * Vector3(GalleryScript.SHELF_WIDTH * 0.5 - (target.book + 0.5) * GalleryScript.BOOK_SLOT, 0.0, GalleryScript.BOOK_FRONT)
		toward = Vector3(book.x - from.x, 0.0, book.z - from.z)
	if camera == null:
		return {"mode": mode, "heading": 0.0, "glyph": "+Z" if toward.z > 0.0 else "−Z"}
	# Le cap se lit dans le plan horizontal : le regard (−Z de la caméra) couché au sol, quelle que
	# soit l'inclinaison de la tête ; à la verticale, le haut de l'image donne le cap.
	var look := -camera.global_basis.z
	var forward := Vector3(look.x, 0.0, look.z)
	if forward.length_squared() < 1e-8:
		var up := camera.global_basis.y * (1.0 if look.y < 0.0 else -1.0)
		forward = Vector3(up.x, 0.0, up.z)
	forward = forward.normalized()
	var right := forward.cross(Vector3.UP)
	var heading := atan2(toward.x * right.x + toward.z * right.z, toward.x * forward.x + toward.z * forward.z)
	return {"mode": mode, "heading": heading, "glyph": ARROWS[posmod(int(roundf(heading / (PI / 4.0))), 8)]}


## Flèche dessinée de l'encart : couchée (aplatie comme posée au sol, tournée selon le regard) ou
## dressée vers le haut ou le bas.
class QuestArrow:
	extends Control

	const FLAT := "plat"
	const UP := "haut"
	const DOWN := "bas"
	const HERE := "ici"
	## Aplatissement de la flèche couchée : la hauteur à l'écran d'un sol vu en biais.
	const FLAT_SQUASH := 0.45
	const COLOR := Color(1.0, 0.85, 0.45)

	var mode := FLAT
	var heading := 0.0

	func _init() -> void:
		custom_minimum_size = Vector2(56, 56)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_state(new_mode: String, new_heading: float) -> void:
		if new_mode != mode or not is_equal_approx(new_heading, heading):
			mode = new_mode
			heading = new_heading
			queue_redraw()

	## Vecteur unitaire écran de la pointe : vers le haut ou le bas pour une flèche dressée ;
	## pour une flèche couchée, la direction tournée de heading puis aplatie.
	func tip_direction() -> Vector2:
		match mode:
			UP:
				return Vector2.UP
			DOWN:
				return Vector2.DOWN
		return Vector2.UP.rotated(heading) * Vector2(1.0, FLAT_SQUASH)

	func _draw() -> void:
		var center := size * 0.5
		var radius := minf(size.x, size.y) * 0.42
		var squash := Vector2.ONE if mode == UP or mode == DOWN else Vector2(1.0, FLAT_SQUASH)
		var turn := 0.0 if mode == UP else (PI if mode == DOWN else heading)
		var shape := PackedVector2Array([
			Vector2(0.0, -1.0), Vector2(0.55, -0.15), Vector2(0.2, -0.15), Vector2(0.2, 0.9),
			Vector2(-0.2, 0.9), Vector2(-0.2, -0.15), Vector2(-0.55, -0.15)])
		var points := PackedVector2Array()
		for point in shape:
			points.append(center + point.rotated(turn) * radius * squash)
		draw_colored_polygon(points, COLOR)
		points.append(points[0])
		draw_polyline(points, Color(0, 0, 0, 0.7), 1.5, true)


# --- Panneau de quête ---------------------------------------------------------------------------

func _set_mouse_mode(mode: Input.MouseMode) -> void:
	mouse_mode_requested = mode
	Input.mouse_mode = mode


func is_panel_open() -> bool:
	return _panel != null and _panel.visible


func open_panel() -> void:
	if is_panel_open():
		return
	_mouse_before = Input.mouse_mode
	_set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_hold_player(true)
	last_error = ""
	_panel.visible = true
	_rebuild_panel()
	quest_panel_toggled.emit(true)


func close_panel() -> void:
	if not is_panel_open():
		return
	_panel.visible = false
	if _file_dialog.visible:
		_file_dialog.hide()
	_set_mouse_mode(_mouse_before)
	_hold_player(false)
	quest_panel_toggled.emit(false)


func _build_panel() -> void:
	_panel = Control.new()
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP   # aucun mouvement de souris ne passe au regard
	_panel.visible = false
	add_child(_panel)

	var shade := ColorRect.new()
	shade.color = Color(0.0, 0.0, 0.0, 0.55)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.add_child(shade)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(center)

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.075, 0.05, 0.96)
	style.border_color = Color(0.55, 0.42, 0.25)
	style.set_border_width_all(2)
	style.set_content_margin_all(16)
	var sheet := PanelContainer.new()
	sheet.add_theme_stylebox_override("panel", style)
	sheet.custom_minimum_size = Vector2(760, 620)
	center.add_child(sheet)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sheet.add_child(scroll)
	_panel_box = VBoxContainer.new()
	_panel_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_panel_box.add_theme_constant_override("separation", 6)
	scroll.add_child(_panel_box)

	_file_dialog = FileDialog.new()
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.filters = FILE_FILTERS
	_file_dialog.title = "Ouvrir un texte ou une image"
	_file_dialog.size = Vector2i(800, 520)
	_file_dialog.file_selected.connect(func(path: String) -> void: search_file(path))
	add_child(_file_dialog)


func _rebuild_panel() -> void:
	for child in _panel_box.get_children():
		_panel_box.remove_child(child)
		child.queue_free()

	_panel_box.add_child(_heading("Quête"))
	if quest == null:
		_panel_box.add_child(_text("aucune", 14, Color(1, 1, 1, 0.6)))
	else:
		_panel_box.add_child(_text(quest.label(), 16, Color(1.0, 0.9, 0.7)))
		if quest.pages.size() > 1:
			var selector := HBoxContainer.new()
			selector.add_child(_text("page", 14, Color(1, 1, 1, 0.7)))
			for i in quest.pages.size():
				var button := Button.new()
				button.text = str(int(quest.pages[i]) + 1)
				button.toggle_mode = true
				button.button_pressed = i == quest.page_index
				button.pressed.connect(set_quest_page.bind(i))
				selector.add_child(button)
			_panel_box.add_child(selector)
		if not quest.notice.is_empty():
			_panel_box.add_child(_text(quest.notice, 13, Color(1.0, 0.75, 0.45)))
		_panel_box.add_child(_text(str(_guide.get("summary", "")), 14, Color(1, 1, 1, 0.85)))
		var actions := HBoxContainer.new()
		if quest.entry_id.is_empty():
			_pin_title_edit = LineEdit.new()
			_pin_title_edit.text = quest.title
			_pin_title_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			actions.add_child(_pin_title_edit)
			actions.add_child(_button(PIN_GLYPH + " épingler", func() -> void: pin_current(_pin_title_edit.text)))
		actions.add_child(_button("abandonner", clear_quest))
		_panel_box.add_child(actions)

	_panel_box.add_child(HSeparator.new())
	var group := ""
	var first := true
	for pin: Dictionary in pins:
		var entry := QuestScript.catalogue_entry(catalogue, pin.entry) if pin.kind == QuestScript.KIND_CATALOGUE else {}
		var pin_group: String = entry.get("group", "") if not entry.is_empty() else ("Recherches" if pin.kind == QuestScript.KIND_SEARCH else "")
		if first or pin_group != group:
			first = false
			group = pin_group
			if not group.is_empty():
				_panel_box.add_child(_text(group, 13, Color(0.85, 0.7, 0.45)))
		var row := HBoxContainer.new()
		var start := Button.new()
		start.text = "%s %s" % [PIN_GLYPH, pin.title if pin.author.is_empty() else "%s — %s" % [pin.title, pin.author]]
		start.flat = true
		start.alignment = HORIZONTAL_ALIGNMENT_LEFT
		start.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		start.clip_text = true
		start.pressed.connect(_on_pin_pressed.bind(pin))
		row.add_child(start)
		row.add_child(_button("désépingler", unpin.bind(pin.id)))
		_panel_box.add_child(row)
		var context: String = entry.get("context", "")
		if pin.kind == QuestScript.KIND_SEARCH:
			context = _search_context(pin.address)
		elif pin.kind == QuestScript.KIND_REGISTER:
			context = QuestScript.REGISTER_CONTEXT
		_panel_box.add_child(_text(context, 13, Color(1, 1, 1, 0.65)))
		if pin.kind == QuestScript.KIND_REGISTER and register_open:
			for item: Dictionary in register_items():
				var line := Button.new()
				line.text = "    " + item.label
				line.flat = true
				line.alignment = HORIZONTAL_ALIGNMENT_LEFT
				line.pressed.connect(_on_register_item_pressed.bind(item))
				_panel_box.add_child(line)
	if not QuestScript.missing_catalogue(pins, catalogue).is_empty():
		_panel_box.add_child(_button("rétablir", restore_pins))

	_panel_box.add_child(HSeparator.new())
	_panel_box.add_child(_heading("Chercher"))
	_panel_box.add_child(_button("ouvrir un fichier…", _file_dialog.popup_centered))
	var line := HBoxContainer.new()
	_text_edit = LineEdit.new()
	_text_edit.placeholder_text = "texte à chercher"
	_text_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_text_edit.text_submitted.connect(func(text: String) -> void: search_typed(text))
	line.add_child(_text_edit)
	line.add_child(_button("chercher", func() -> void: search_typed(_text_edit.text)))
	_panel_box.add_child(line)
	if not last_error.is_empty():
		_panel_box.add_child(_text(last_error, 13, Color(1.0, 0.55, 0.45)))
	_panel_box.add_child(_button("fermer", close_panel))


func _on_pin_pressed(pin: Dictionary) -> void:
	if pin.kind == QuestScript.KIND_REGISTER:
		register_open = not register_open
		_rebuild_panel()
	elif start_pin(pin):
		close_panel()
	else:
		_rebuild_panel()


## Les lignes du registre des livres manquants : {label, address}.
func register_items() -> Array:
	return QuestScript.register_items(catalogue_path)


## Démarre la quête d'une ligne du registre : le livre manquant, à sa première page.
func start_register_item(item: Dictionary) -> void:
	start_quest(QuestScript.from_address(item.address, item.label))


func _on_register_item_pressed(item: Dictionary) -> void:
	start_register_item(item)
	close_panel()


static func _search_context(target: Dictionary) -> String:
	return "hexagone de %d chiffres · mur %d · étagère %d · livre %d · page %d" % [
		BookTextScript.b25_decimal_digits(target.hexagon), target.wall + 1, target.shelf + 1, target.book + 1, int(target.get("page", 0)) + 1]


static func _heading(text: String) -> Label:
	return _text(text, 17, Color(1.0, 0.85, 0.55))


static func _text(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size.x = 700
	label.add_theme_font_size_override("font_size", size)
	label.modulate = color
	return label


static func _button(text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(action)
	return button


static func _label(size: int) -> Label:
	var label := Label.new()
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label
