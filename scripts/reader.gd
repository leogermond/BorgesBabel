class_name Reader
extends CanvasLayer
## Fenêtre de lecture : une page de 40 lignes de 80 caractères, la cote du livre,
## et la navigation page par page. Seule la page affichée est calculée.

const BookTextScript := preload("res://scripts/book_text.gd")

var book: Dictionary = {}
var page := 0

var _heading: Label
var _text: Label
var _folio: Label


func _ready() -> void:
	layer = 10
	visible = false

	var shade := ColorRect.new()
	shade.color = Color(0.0, 0.0, 0.0, 0.6)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(shade)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var paper := StyleBoxFlat.new()
	paper.bg_color = Color(0.93, 0.89, 0.79)
	paper.border_color = Color(0.45, 0.32, 0.2)
	paper.set_border_width_all(2)
	paper.set_content_margin_all(18)
	var sheet := PanelContainer.new()
	sheet.add_theme_stylebox_override("panel", paper)
	center.add_child(sheet)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	sheet.add_child(column)

	var ink := Color(0.16, 0.11, 0.07)
	_heading = _label(ink, 15)
	_heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_heading)

	_text = _label(ink, 16)
	var mono := SystemFont.new()
	mono.font_names = PackedStringArray(["DejaVu Sans Mono", "Liberation Mono", "Consolas", "Courier New", "monospace"])
	_text.add_theme_font_override("font", mono)
	_text.add_theme_constant_override("line_spacing", 0)
	column.add_child(_text)

	var footer := HBoxContainer.new()
	footer.alignment = BoxContainer.ALIGNMENT_CENTER
	footer.add_theme_constant_override("separation", 16)
	column.add_child(footer)
	footer.add_child(_button("◀", turn.bind(-1)))
	_folio = _label(ink, 15)
	_folio.custom_minimum_size.x = 140
	_folio.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	footer.add_child(_folio)
	footer.add_child(_button("▶", turn.bind(1)))
	# Aucune aide de commande à l'écran : le « Mode d'emploi » de la Bibliothèque est un livre.


## Ouvre le livre désigné par {hexagon, level, wall, shelf, book} (hexagone et niveau en base 25,
## ou int) à la page `at_page` (la première par défaut).
func open(target: Dictionary, at_page := 0) -> void:
	book = BookTextScript.book_of(target)
	page = clampi(at_page, 0, BookTextScript.PAGES - 1)
	var where := ""
	if BookTextScript.b25_fits_int(book.hexagon) and BookTextScript.b25_fits_int(book.level):
		where = "hexagone %d, niveau %d · mur %d · étagère %d · livre %d" % [
			BookTextScript.b25_to_int(book.hexagon), BookTextScript.b25_to_int(book.level), book.wall + 1, book.shelf + 1, book.book + 1]
	else:
		where = BookTextScript.display(book)   # grands nombres abrégés par le service
	_heading.text = "« %s »   —   %s" % [BookTextScript.title_at(book), where]
	_render()
	visible = true


func close() -> void:
	visible = false
	book = {}


## Avance (+1) ou recule (−1) d'une page, dans les limites du livre.
func turn(step: int) -> void:
	var next := clampi(page + step, 0, BookTextScript.PAGES - 1)
	if next != page:
		page = next
		_render()


func _render() -> void:
	var lines := BookTextScript.page_lines_at(book, page)
	_text.text = "\n".join(lines)
	_folio.text = "page %d / %d" % [page + 1, BookTextScript.PAGES]


static func _label(color: Color, size: int) -> Label:
	var label := Label.new()
	label.add_theme_color_override("font_color", color)
	label.add_theme_font_size_override("font_size", size)
	return label


static func _button(text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(48, 0)
	button.pressed.connect(action)
	return button
