class_name Hud
extends CanvasLayer
## Adresse de la galerie courante, réticule, et nom du livre visé.

var _address: Label
var _crosshair: Label
var _hint: Label


func _ready() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_address = _label(15)
	_address.position = Vector2(16, 12)
	root.add_child(_address)

	var controls := _label(13)
	controls.text = "ZQSD / WASD / flèches : marcher    souris : regarder    E ou clic : lire    Échap : libérer la souris"
	controls.modulate.a = 0.6
	controls.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, 16)
	root.add_child(controls)

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


func set_address(hexagon: int, level: int) -> void:
	_address.text = "Hexagone %d · niveau %d" % [hexagon, level]


## Affiche la cote du livre visé, ou rien.
func set_target(target: Dictionary) -> void:
	if target.is_empty():
		_hint.text = ""
		_crosshair.modulate = Color(1, 1, 1, 0.6)
	else:
		_hint.text = "E : lire — mur %d, étagère %d, livre %d" % [target.wall + 1, target.shelf + 1, target.book + 1]
		_crosshair.modulate = Color(1.0, 0.85, 0.4)


static func _label(size: int) -> Label:
	var label := Label.new()
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label
