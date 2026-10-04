class_name Hud
extends CanvasLayer
## Adresse de la galerie courante, réticule, cote du livre visé, et quête : un encart en haut à
## droite guide vers le livre cherché ; le panneau de quête (touche QUEST_KEY) libère la souris et
## propose les épingles, l'ouverture d'un fichier et la saisie d'un texte.
##
## Le carnet (Carnet, touche cachée Carnet.CARNET_KEY) est un enfant du Hud : le Hud lui passe
## toutes les touches tant qu'il est ouvert et relaie son signal invocation(axe).

## La quête a changé (null quand elle s'efface).
signal quest_changed(quest: Quest)
## Invocation écrite dans le carnet : axe « couloir », « puits » ou « galerie ».
signal invocation(axis: String)
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
var quest: Quest
## Le carnet, créé au premier _ready.
var carnet: Carnet
var catalogue: Array = []
var pins: Array = []
## Chemins lus au premier _ready ; les tests les détournent avant d'ajouter le Hud à l'arbre.
var catalogue_path := Quest.CATALOGUE_PATH
var pins_path := Quest.PINS_PATH
## Message d'erreur de la dernière recherche (vide quand tout va bien).
var last_error := ""

var _address: Label
var _crosshair: Label
var _hint: Label
var _widget: VBoxContainer
var _quest_title: Label
var _quest_glyph: Label
var _quest_hall: Label
var _quest_level: Label
var _quest_book: Label
var _panel: Control
var _panel_box: VBoxContainer
var _file_dialog: FileDialog
var _text_edit: LineEdit
var _pin_title_edit: LineEdit
var _hexagon := 0
var _level := 0
var _guide: Dictionary = {}
var _mouse_before := Input.MOUSE_MODE_VISIBLE
var _player_was_frozen := false


func _ready() -> void:
	catalogue = Quest.load_catalogue(catalogue_path)
	pins = Quest.load_pins(catalogue, pins_path)

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
	carnet = Carnet.new()
	carnet.invocation.connect(invocation.emit)
	carnet.toggled.connect(_hold_player)
	add_child(carnet)
	_refresh_widget()


func set_address(hexagon: int, level: int) -> void:
	_hexagon = hexagon
	_level = level
	_address.text = "Hexagone %d · niveau %d" % [hexagon, level]
	_refresh_widget()


## Affiche la cote du livre visé, ou rien.
func set_target(target: Dictionary) -> void:
	if target.is_empty():
		_hint.text = ""
		_crosshair.modulate = Color(1, 1, 1, 0.6)
	else:
		_hint.text = "mur %d · étagère %d · livre %d" % [target.wall + 1, target.shelf + 1, target.book + 1]
		_crosshair.modulate = Color(1.0, 0.85, 0.4)


# --- Quête --------------------------------------------------------------------------------------

func start_quest(new_quest: Quest) -> void:
	quest = new_quest
	last_error = ""
	_refresh_widget()
	quest_changed.emit(quest)
	if is_panel_open():
		_rebuild_panel()


func clear_quest() -> void:
	if quest == null:
		return
	quest = null
	_refresh_widget()
	quest_changed.emit(null)
	if is_panel_open():
		_rebuild_panel()


func set_quest_page(index: int) -> void:
	if quest == null:
		return
	quest.set_page(index)
	_refresh_widget()
	quest_changed.emit(quest)
	if is_panel_open():
		_rebuild_panel()


## Le guidage de la quête depuis la galerie courante ({} sans quête).
func guidance() -> Dictionary:
	return _guide


## Démarre la quête d'une épingle ; faux si l'entrée a disparu du catalogue.
func start_pin(pin: Dictionary) -> bool:
	var found := Quest.from_pin(pin, catalogue)
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
	return _start_search(BookText.search_text(text), "texte saisi")


## Cherche un fichier de texte (.txt) ou d'image ; faux en cas d'échec (last_error).
func search_file(path: String) -> bool:
	var found := BookText.search_text_file(path) if path.get_extension().to_lower() == "txt" else BookText.search_image_file(path)
	return _start_search(found, path.get_file())


## Épingle la quête en cours (recherche du joueur) : le titre et l'adresse, jamais la source.
func pin_current(pin_title: String) -> bool:
	if quest == null or not quest.entry_id.is_empty():
		return false
	var pin_name := pin_title.strip_edges() if not pin_title.strip_edges().is_empty() else quest.title
	pins = Quest.add_pin(pins, Quest.search_pin(pin_name, quest.address()))
	_save_pins()
	return true


func unpin(id: String) -> void:
	pins = Quest.remove_pin(pins, id)
	_save_pins()


## Rétablit les entrées du catalogue désépinglées.
func restore_pins() -> void:
	pins = Quest.restore_catalogue(pins, catalogue)
	_save_pins()


func _start_search(found: Dictionary, default_title: String) -> bool:
	if found.is_empty():
		last_error = BookText.last_error if not BookText.last_error.is_empty() else "recherche sans résultat"
		if is_panel_open():
			_rebuild_panel()
		return false
	start_quest(Quest.from_address(found, default_title))
	return true


func _save_pins() -> void:
	if not Quest.save_pins(pins, pins_path):
		push_warning("épingles non enregistrées : %s" % pins_path)
	if is_panel_open():
		_rebuild_panel()


# --- Clavier ------------------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if handle_key(event):
		get_viewport().set_input_as_handled()


## Traite une touche ; vrai quand elle est consommée.
func handle_key(event: InputEvent) -> bool:
	if not event is InputEventKey:
		return false
	var key := event as InputEventKey
	if carnet.is_open():
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
	if key.physical_keycode == Carnet.CARNET_KEY:
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


## Le bibliothécaire reste immobile tant que le panneau ou le carnet est ouvert.
func _hold_player(hold: bool) -> void:
	var player := _player()
	if player == null:
		return
	if hold:
		_player_was_frozen = player.frozen
		player.frozen = true
	else:
		player.frozen = _player_was_frozen


func _typing() -> bool:
	var focus := _panel.get_viewport().gui_get_focus_owner() if _panel.is_inside_tree() else null
	return focus is LineEdit


func _reader_open() -> bool:
	var parent := get_parent()
	if parent == null:
		return false
	var reader: Variant = parent.get("reader")
	return reader is CanvasLayer and reader.visible


func _player() -> Player:
	var parent := get_parent()
	if parent == null:
		return null
	var player: Variant = parent.get("player")
	return player if player is Player else null


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
	_quest_glyph = _widget_label(26)
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


func _refresh_widget() -> void:
	if _widget == null:
		return
	_widget.visible = quest != null
	if quest == null:
		_guide = {}
		return
	_guide = quest.guidance(_hexagon, _level)
	_quest_title.text = quest.label()
	_quest_hall.text = _guide.hall_text
	_quest_level.text = _guide.level_text
	_quest_book.text = _guide.book_text
	_quest_glyph.text = direction_glyph(_guide, quest.address(), get_viewport().get_camera_3d() if is_inside_tree() else null)


func _process(_delta: float) -> void:
	if quest != null and not _guide.is_empty():
		_quest_glyph.text = direction_glyph(_guide, quest.address(), get_viewport().get_camera_3d())


## Le glyphe de direction : flèche horizontale relative au regard (le long du vestibule, vers le
## puits, ou vers le livre dans la galerie visée), suivie de ▲ ou ▼ quand l'étage diffère.
static func direction_glyph(guide: Dictionary, target: Dictionary, camera: Camera3D) -> String:
	var vertical := "▲" if guide.vert > 0 else ("▼" if guide.vert < 0 else "")
	var from := camera.global_position if camera != null else Vector3.ZERO
	var direction := Vector3.ZERO
	if guide.hall != 0:
		direction = Vector3(0.0, 0.0, guide.hall)
	elif guide.vert != 0:
		direction = -Vector3(from.x, 0.0, from.z)   # vers le puits, au centre de la galerie
		if direction.length() < Gallery.SHAFT_APOTHEM:
			direction = Vector3.ZERO
	else:
		var side := Basis(Vector3.UP, Gallery.BOOK_SIDES[target.wall] * PI / 3.0)
		var book := side * Vector3(Gallery.SHELF_WIDTH * 0.5 - (target.book + 0.5) * Gallery.BOOK_SLOT, 0.0, Gallery.BOOK_FRONT)
		direction = Vector3(book.x - from.x, 0.0, book.z - from.z)
	if direction == Vector3.ZERO:
		return vertical if not vertical.is_empty() else "·"
	if camera == null:
		var axis := ("+Z" if direction.z > 0.0 else "−Z") if guide.hall != 0 else "·"
		return (axis + " " + vertical).strip_edges()
	var forward := -camera.global_basis.z
	var right := camera.global_basis.x
	var ahead := direction.x * forward.x + direction.z * forward.z
	var aside := direction.x * right.x + direction.z * right.z
	var octant := int(roundf(atan2(aside, ahead) / (PI / 4.0)))
	return (ARROWS[posmod(octant, 8)] + " " + vertical).strip_edges()


# --- Panneau de quête ---------------------------------------------------------------------------

func is_panel_open() -> bool:
	return _panel != null and _panel.visible


func open_panel() -> void:
	if is_panel_open():
		return
	_mouse_before = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
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
	Input.mouse_mode = _mouse_before
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
				button.text = str(i + 1)
				button.toggle_mode = true
				button.button_pressed = i == quest.page_index
				button.pressed.connect(set_quest_page.bind(i))
				selector.add_child(button)
			_panel_box.add_child(selector)
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
		var entry := Quest.catalogue_entry(catalogue, pin.entry) if pin.kind == Quest.KIND_CATALOGUE else {}
		var pin_group: String = entry.get("group", "") if not entry.is_empty() else "Recherches"
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
		var context: String = entry.get("context", "") if not entry.is_empty() else _search_context(pin.address)
		_panel_box.add_child(_text(context, 13, Color(1, 1, 1, 0.65)))
	if not Quest.missing_catalogue(pins, catalogue).is_empty():
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
	if start_pin(pin):
		close_panel()
	else:
		_rebuild_panel()


static func _search_context(target: Dictionary) -> String:
	return "hexagone de %d chiffres · mur %d · étagère %d · livre %d · page %d" % [
		Quest.dec_digits(target.hexagon), target.wall + 1, target.shelf + 1, target.book + 1, target.page + 1]


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
