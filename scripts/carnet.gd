class_name Carnet
extends CanvasLayer
## Carnet : une page blanche où l'on écrit un mot dans l'alphabet de la Bibliothèque.
##
## Seuls les 25 symboles s'écrivent ; le reste se normalise comme la recherche (minuscules,
## accents ôtés, œ → oe, æ → ae, ß → ss, k et q → c, w → v, y → i) ou s'ignore. Espace ou
## Entrée referme le mot : s'il est une des INVOCATIONS et qu'elle vaut ici (can_invoke, que le
## Hud fournit : une quête pour « aleph » et « zahir », un livre ouvert pour « tlon », une
## destination connue pour « sator » et « golem »), le carnet émet invocation(axe) et se ferme ;
## sinon le mot s'efface en fondu et le carnet reste ouvert, comme tout autre mot. Rien à l'écran
## ne nomme les invocations. Le Hud ouvre et ferme le carnet (CARNET_KEY) et lui passe toutes les
## touches tant qu'il est ouvert ; le monde applique l'invocation (main.gd).

const BookSpineScript := preload("res://scripts/book_spine.gd")

signal invocation(axis: String)
signal toggled(open: bool)

## Touche physique sous Échap : « ² » en AZERTY, « ` » en QWERTY.
const CARNET_KEY := KEY_QUOTELEFT
## Mot → invocation : « couloir » (vers l'hexagone de la quête), « puits » (vers son niveau),
## « vol » (le livre ouvert, emporté), « sator » et « golem » (vers le livre de ces destinations).
const INVOCATIONS := {"aleph": "couloir", "zahir": "puits", "tlon": "vol", "sator": "sator", "golem": "golem"}
const ALPHABET := "abcdefghijlmnoprstuvxz ,."
const FONT_PATH := "res://fonts/Lora-VariableFont_wght.ttf"
const PAPER := Color(0.93, 0.89, 0.79)
const PAPER_BORDER := Color(0.45, 0.32, 0.2)
const INK := Color(0.16, 0.11, 0.07)
const CARET_PERIOD := 0.53
const FADE_SECONDS := 0.45
## Lettres accentuées (après passage en minuscules) → leur lettre de base, comme la décomposition
## NFD de la recherche ; les ligatures et les lettres absentes de l'alphabet suivent.
const ACCENTS := {
	"a": "àáâãäåāăąǎǟǡǻȁȃȧạảấầẩẫậắằẳẵặ", "c": "çćĉċč", "d": "ďḍḏ",
	"e": "èéêëēĕėęěȅȇȩẹẻẽếềểễệ", "g": "ĝğġģǧǵ", "h": "ĥȟḥ", "i": "ìíîïĩīĭįǐȉȋỉị",
	"j": "ĵǰ", "k": "ķǩ", "l": "ĺļľḷ", "n": "ñńņňǹṇ", "o": "òóôõöōŏőơǒȍȏȫȭȯȱọỏốồổỗộớờởỡợ",
	"r": "ŕŗřȑȓ", "s": "śŝşšșṣ", "t": "ţťțṭ", "u": "ùúûüũūŭůűųưǔǖǘǚǜȕȗụủứừửữự",
	"w": "ŵẁẃẅ", "y": "ýÿŷỳỹỷ", "z": "źżžẓ",
}
const LIGATURES := {"œ": "oe", "æ": "ae", "ß": "ss", "k": "c", "q": "c", "w": "v", "y": "i"}

## Le mot en cours, normalisé.
var word := ""
## can_invoke(axe) -> bool : vrai quand l'invocation vaut ici ; sans lui, toutes valent.
var can_invoke := Callable()

var _word_label: Label
var _fading: Label
var _caret: Label
var _blink := 0.0
var _mouse_before := Input.MOUSE_MODE_VISIBLE
## Dernier mode de souris demandé par le carnet (le mode effectif reste VISIBLE sans fenêtre).
var mouse_mode_requested := -1
static var _base: Dictionary = {}


func _ready() -> void:
	layer = 11   # au-dessus du lecteur
	visible = false

	var shade := ColorRect.new()
	shade.color = Color(0.0, 0.0, 0.0, 0.5)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(shade)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var paper := StyleBoxFlat.new()
	paper.bg_color = PAPER
	paper.border_color = PAPER_BORDER
	paper.set_border_width_all(2)
	paper.set_content_margin_all(18)
	var sheet := PanelContainer.new()
	sheet.add_theme_stylebox_override("panel", paper)
	sheet.custom_minimum_size = Vector2(520, 680)
	sheet.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(sheet)

	var font: Font = null
	if ResourceLoader.exists(FONT_PATH):
		font = load(FONT_PATH) as Font
	var line := HBoxContainer.new()
	line.alignment = BoxContainer.ALIGNMENT_CENTER
	line.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	line.add_theme_constant_override("separation", 0)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sheet.add_child(line)
	_word_label = _ink_label(font)
	_fading = _ink_label(font)
	_fading.modulate.a = 0.0
	_caret = _ink_label(font)
	_caret.text = "|"
	var word_box := MarginContainer.new()
	word_box.add_theme_constant_override("margin_top", 120)
	word_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_child(word_box)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 1)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	word_box.add_child(row)
	row.add_child(_word_label)
	row.add_child(_caret)
	word_box.add_child(_fading)   # superposé au mot : le mot effacé s'estompe à sa place


func _ink_label(font: Font) -> Label:
	var label := Label.new()
	label.add_theme_color_override("font_color", INK)
	label.add_theme_font_size_override("font_size", 34)
	if font != null:
		label.add_theme_font_override("font", font)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func is_open() -> bool:
	return visible


func open() -> void:
	if visible:
		return
	word = ""
	_render()
	_mouse_before = Input.mouse_mode
	_set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	visible = true
	toggled.emit(true)


func close() -> void:
	if not visible:
		return
	visible = false
	word = ""
	_set_mouse_mode(_mouse_before)
	toggled.emit(false)


func _set_mouse_mode(mode: Input.MouseMode) -> void:
	mouse_mode_requested = mode
	Input.mouse_mode = mode


## Traite une touche quand le carnet est ouvert : il les consomme toutes (vrai).
func handle_key(key: InputEventKey) -> bool:
	if not key.pressed:
		return true
	var code := key.physical_keycode
	if not key.echo and (code == KEY_ESCAPE or code == CARNET_KEY):
		close()
	elif code == KEY_BACKSPACE:
		word = word.left(-1) if not word.is_empty() else word
		_render()
	elif code == KEY_SPACE or code == KEY_ENTER or code == KEY_KP_ENTER or key.unicode == 32:
		if not key.echo:
			submit()
	elif key.unicode > 32 and not key.ctrl_pressed and not key.meta_pressed:
		word += normalize(String.chr(key.unicode)).replace(" ", "")
		_render()
	return true


## Referme le mot : l'invocation s'il en est une, sinon le mot s'efface.
func submit() -> void:
	var axis: String = INVOCATIONS.get(word, "")
	if not axis.is_empty() and (not can_invoke.is_valid() or can_invoke.call(axis)):
		close()
		invocation.emit(axis)
		return
	if not word.is_empty() and is_inside_tree():
		_fading.text = _word_label.text
		_fading.modulate.a = 1.0
		create_tween().tween_property(_fading, "modulate:a", 0.0, FADE_SECONDS)
	word = ""
	_render()


## Le texte ramené à l'alphabet de 25 symboles, comme la normalisation de la recherche.
static func normalize(text: String) -> String:
	if _base.is_empty():
		for letter: String in ACCENTS:
			for accented in ACCENTS[letter]:
				_base[accented] = letter
	var out := ""
	for c in text.to_lower():
		var base: String = _base.get(c, c)
		var mapped: String = LIGATURES.get(base, base)
		if mapped in ["\t", "\n", "\r", "\u00a0", "\u202f"]:
			mapped = " "
		for s in mapped:
			if ALPHABET.contains(s):
				out += s
	return out


func _render() -> void:
	_word_label.text = BookSpineScript.display_title(word) if not word.is_empty() else ""
	_blink = 0.0
	_caret.modulate.a = 1.0


func _process(delta: float) -> void:
	if not visible:
		return
	_blink += delta
	_caret.modulate.a = 1.0 if fmod(_blink, CARET_PERIOD * 2.0) < CARET_PERIOD else 0.0
