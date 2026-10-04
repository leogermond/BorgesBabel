class_name Quest
extends RefCounted
## Quête : un livre à retrouver, ses pages, et le guidage depuis la galerie d'origine du monde.
##
## Une adresse trouvée par la recherche inverse compte quelque 2234 chiffres : l'hexagone et le
## niveau sont des entiers relatifs décimaux en chaînes. La différence avec l'origine (deux int)
## se calcule donc en arithmétique décimale pure GDScript (dec_*), sans appel au service Python.
##
## Ce script lit aussi le catalogue data/quetes/catalogue.json (métadonnées, et pour chaque page
## son adresse et le SHA-256 de ses 3200 symboles : aucun texte) et tient les épingles du panneau
## de quête, enregistrées dans user://quetes_epinglees.json.
##
## Repères du monde : l'hexagone h + 1 est à 12 m vers +Z, le niveau l + 1 à 3,4 m au-dessus.

const CATALOGUE_PATH := "res://data/quetes/catalogue.json"
const PINS_PATH := "user://quetes_epinglees.json"
const PINS_VERSION := 1
## Jusqu'à 15 chiffres, une distance s'écrit exactement ; au-delà, en ordre de grandeur.
const EXACT_DIGITS := 15
const KIND_CATALOGUE := "catalogue"
const KIND_SEARCH := "recherche"

static var _stolen: Dictionary = {}   # cache de is_stolen_book

var title := ""
var author := ""
## Identifiant de l'entrée du catalogue, vide pour une recherche du joueur.
var entry_id := ""
## Les adresses des pages de la quête, {hexagon: String, level: String, wall, shelf, book, page: int}.
var pages: Array = []
var page_index := 0


## Une quête sur une seule adresse ; null si l'adresse est mal formée.
static func from_address(target: Dictionary, quest_title := "", quest_author := "") -> Quest:
	return from_pages([target], quest_title, quest_author)


static func from_pages(targets: Array, quest_title := "", quest_author := "", id := "") -> Quest:
	if targets.is_empty():
		return null
	var quest := Quest.new()
	for target: Variant in targets:
		if not target is Dictionary or not is_valid_address(target):
			return null
		quest.pages.append(normalized_address(target))
	quest.title = quest_title
	quest.author = quest_author
	quest.entry_id = id
	return quest


## La quête d'une entrée du catalogue : ses pages dans l'ordre.
static func from_entry(entry: Dictionary) -> Quest:
	var targets := []
	for page: Dictionary in entry.pages:
		targets.append(page.address)
	return from_pages(targets, entry.title, entry.author, entry.id)


static func is_valid_address(target: Dictionary) -> bool:
	if not (target.get("hexagon") is String and target.get("level") is String):
		return false
	if not (dec_valid(target.hexagon) and dec_valid(target.level)):
		return false
	var bounds := {"wall": 4, "shelf": 5, "book": 32, "page": 410}
	for key: String in bounds:
		var value: Variant = target.get(key)
		if value is float and is_equal_approx(value, roundf(value)):
			value = int(value)   # JSON lit les nombres en float
		if not value is int or value < 0 or value >= bounds[key]:
			return false
	return true


## Copie de l'adresse sous forme canonique : décimaux normalisés, entiers int.
static func normalized_address(target: Dictionary) -> Dictionary:
	return {
		"hexagon": dec_normalize(target.hexagon), "level": dec_normalize(target.level),
		"wall": int(target.wall), "shelf": int(target.shelf), "book": int(target.book), "page": int(target.page),
	}


## L'adresse de la page choisie.
func address() -> Dictionary:
	return pages[page_index]


func set_page(index: int) -> void:
	page_index = clampi(index, 0, pages.size() - 1)


## « titre — auteur », le titre seul, ou vide.
func label() -> String:
	if author.is_empty():
		return title
	return "%s — %s" % [title, author]


## La cote de la page visée, comptée depuis 1 : « mur 2 · étagère 3 · livre 17 · page 205 ».
func book_line() -> String:
	var a := address()
	return "mur %d · étagère %d · livre %d · page %d" % [a.wall + 1, a.shelf + 1, a.book + 1, a.page + 1]


## Le livre visé quand (hexagone, niveau) est sa galerie : {wall, shelf, book, page} ; sinon {}.
func target_in_gallery(hexagon: int, level: int) -> Dictionary:
	var a := address()
	if a.hexagon != str(hexagon) or a.level != str(level):
		return {}
	return {"wall": a.wall, "shelf": a.shelf, "book": a.book, "page": a.page}


## Le guidage depuis la galerie (hexagone, niveau) :
## {dz, dy : différences signées cible − origine (chaînes décimales), hall, vert : −1, 0 ou +1,
##  here : vrai dans la galerie visée, hall_text, level_text, book_text, summary}.
func guidance(hexagon: int, level: int) -> Dictionary:
	var a := address()
	var dz := dec_sub(a.hexagon, str(hexagon))
	var dy := dec_sub(a.level, str(level))
	var hall := dec_sign(dz)
	var vert := dec_sign(dy)
	var hall_text := "couloir : ici"
	if hall != 0:
		hall_text = "couloir : %s %s vers %s" % [magnitude_text(dz), "galerie" if dec_abs(dz) == "1" else "galeries", "+Z" if hall > 0 else "−Z"]
	var level_text := "étages : ici"
	if vert != 0:
		level_text = "étages : %s %s vers le %s" % [magnitude_text(dy), "niveau" if dec_abs(dy) == "1" else "niveaux", "haut" if vert > 0 else "bas"]
	var book_text := "dans la galerie : " + book_line()
	return {
		"dz": dz, "dy": dy, "hall": hall, "vert": vert, "here": hall == 0 and vert == 0,
		"hall_text": hall_text, "level_text": level_text, "book_text": book_text,
		"summary": "\n".join([hall_text, level_text, book_text]),
	}


# --- Arithmétique décimale sur chaînes ---------------------------------------------------------
# Un entier relatif s'écrit « [+-]chiffres » ; dec_normalize rend la forme canonique : sans « + »,
# sans zéros de tête, « 0 » pour zéro (jamais « -0 »). Les opérations parcourent les chiffres un à
# un : quelques millisecondes pour 2234 chiffres, à chaque changement d'origine.

static func dec_valid(text: String) -> bool:
	var bytes := text.to_ascii_buffer()
	var start := 1 if not bytes.is_empty() and (bytes[0] == 43 or bytes[0] == 45) else 0
	if bytes.size() <= start or bytes.size() != text.length():
		return false
	for i in range(start, bytes.size()):
		if bytes[i] < 48 or bytes[i] > 57:
			return false
	return true


static func dec_normalize(text: String) -> String:
	assert(dec_valid(text), "entier décimal invalide : %s" % text.left(40))
	var negative := text.begins_with("-")
	var digits := text.trim_prefix("+").trim_prefix("-").lstrip("0")
	if digits.is_empty():
		return "0"
	return "-" + digits if negative else digits


## −1, 0 ou +1.
static func dec_sign(text: String) -> int:
	var value := dec_normalize(text)
	if value == "0":
		return 0
	return -1 if value.begins_with("-") else 1


static func dec_abs(text: String) -> String:
	return dec_normalize(text).trim_prefix("-")


static func dec_neg(text: String) -> String:
	var value := dec_normalize(text)
	if value == "0":
		return value
	return value.substr(1) if value.begins_with("-") else "-" + value


## Nombre de chiffres de la valeur absolue (1 pour zéro).
static func dec_digits(text: String) -> int:
	return dec_abs(text).length()


## −1, 0 ou +1 selon que a < b, a = b ou a > b.
static func dec_compare(a: String, b: String) -> int:
	var x := dec_normalize(a)
	var y := dec_normalize(b)
	var sx := dec_sign(x)
	var sy := dec_sign(y)
	if sx != sy:
		return -1 if sx < sy else 1
	if sx == 0:
		return 0
	return _cmp_abs(x.trim_prefix("-"), y.trim_prefix("-")) * sx


static func dec_add(a: String, b: String) -> String:
	var x := dec_normalize(a)
	var y := dec_normalize(b)
	var nx := x.begins_with("-")
	var ny := y.begins_with("-")
	var ax := x.trim_prefix("-")
	var ay := y.trim_prefix("-")
	if nx == ny:
		return _signed(_add_abs(ax, ay), nx)
	var order := _cmp_abs(ax, ay)
	if order == 0:
		return "0"
	if order > 0:
		return _signed(_sub_abs(ax, ay), nx)
	return _signed(_sub_abs(ay, ax), ny)


static func dec_sub(a: String, b: String) -> String:
	return dec_add(a, dec_neg(b))


## La valeur absolue exacte jusqu'à 15 chiffres, sinon « ≈ 10^N » avec N = chiffres − 1.
static func magnitude_text(text: String) -> String:
	var digits := dec_abs(text)
	if digits.length() <= EXACT_DIGITS:
		return digits
	return "≈ 10^%d" % (digits.length() - 1)


static func _signed(digits: String, negative: bool) -> String:
	return "-" + digits if negative and digits != "0" else digits


## Comparaison de deux entiers naturels canoniques.
static func _cmp_abs(a: String, b: String) -> int:
	if a.length() != b.length():
		return -1 if a.length() < b.length() else 1
	if a == b:
		return 0
	return -1 if a < b else 1   # même longueur : l'ordre des chaînes est l'ordre des nombres


static func _add_abs(a: String, b: String) -> String:
	var x := a.to_ascii_buffer()
	var y := b.to_ascii_buffer()
	var count := maxi(x.size(), y.size())
	var out := PackedByteArray()
	out.resize(count + 1)
	var carry := 0
	for i in count:
		var s := carry
		if i < x.size():
			s += x[x.size() - 1 - i] - 48
		if i < y.size():
			s += y[y.size() - 1 - i] - 48
		carry = 1 if s >= 10 else 0
		out[count - i] = 48 + s - 10 * carry
	out[0] = 48 + carry
	var text := out.get_string_from_ascii().lstrip("0")
	return "0" if text.is_empty() else text


## a − b pour deux entiers naturels canoniques, a ≥ b.
static func _sub_abs(a: String, b: String) -> String:
	var x := a.to_ascii_buffer()
	var y := b.to_ascii_buffer()
	var out := PackedByteArray()
	out.resize(x.size())
	var borrow := 0
	for i in x.size():
		var d: int = x[x.size() - 1 - i] - 48 - borrow
		if i < y.size():
			d -= y[y.size() - 1 - i] - 48
		borrow = 1 if d < 0 else 0
		out[x.size() - 1 - i] = 48 + d + 10 * borrow
	var text := out.get_string_from_ascii().lstrip("0")
	return "0" if text.is_empty() else text


# --- Catalogue ----------------------------------------------------------------------------------
# Une entrée : {id, title, author, year, language, context, group, licence, protected, page_count,
# pages: [{address, sha256}], notice_address, notice_hash}. La notice (titre, auteur et contexte, une
# ligne chacun) est elle-même une page de la Bibliothèque, à notice_address. Les entrées incomplètes
# sont écartées ; l'ordre du fichier est gardé.

static func load_catalogue(path := CATALOGUE_PATH) -> Array:
	var parsed: Variant = _read_json(path)
	if not parsed is Dictionary or not parsed.get("entries") is Array:
		return []
	var entries := []
	var seen := {}
	for raw: Variant in parsed.entries:
		var entry := _valid_entry(raw)
		if not entry.is_empty() and not seen.has(entry.id):
			seen[entry.id] = true
			entries.append(entry)
	return entries


## Vrai pour un livre dont une page est la notice d'une entrée du catalogue (liste stolen_books,
## lue une fois) : un livre volé à la Bibliothèque. Hexagone et niveau en chaînes décimales.
static func is_stolen_book(hexagon: String, level: String, wall: int, shelf: int, book: int) -> bool:
	if _stolen.is_empty():
		var parsed: Variant = _read_json(CATALOGUE_PATH)
		var books: Variant = parsed.get("stolen_books") if parsed is Dictionary else null
		_stolen["loaded"] = true
		if books is Array:
			for raw: Variant in books:
				if raw is Dictionary and is_valid_address(raw.merged({"page": 0})):
					_stolen[_book_key(dec_normalize(raw.hexagon), dec_normalize(raw.level), int(raw.wall), int(raw.shelf), int(raw.book))] = true
	return _stolen.has(_book_key(hexagon, level, wall, shelf, book))


static func _book_key(hexagon: String, level: String, wall: int, shelf: int, book: int) -> String:
	return "%s:%s:%d:%d:%d" % [hexagon, level, wall, shelf, book]


static func catalogue_entry(entries: Array, id: String) -> Dictionary:
	for entry: Dictionary in entries:
		if entry.id == id:
			return entry
	return {}


static func _valid_entry(raw: Variant) -> Dictionary:
	if not raw is Dictionary:
		return {}
	for key in ["id", "title", "author", "context"]:
		if not raw.get(key) is String or raw[key].is_empty():
			return {}
	if not raw.get("pages") is Array or raw.pages.is_empty():
		return {}
	var pages := []
	for page: Variant in raw.pages:
		if not page is Dictionary or not page.get("address") is Dictionary or not page.get("sha256") is String:
			return {}
		if not is_valid_address(page.address):
			return {}
		pages.append({"address": normalized_address(page.address), "sha256": page.sha256})
	var entry: Dictionary = raw.duplicate()
	if raw.get("notice_address") is Dictionary and is_valid_address(raw.notice_address):
		entry.notice_address = normalized_address(raw.notice_address)
	else:
		entry.erase("notice_address")
	entry.group = str(raw.get("group", ""))
	entry.protected = raw.get("protected", false) == true
	entry.pages = pages
	entry.page_count = pages.size()
	return entry


# --- Épingles -----------------------------------------------------------------------------------
# Une épingle : {id, kind, title, author, address}.
#   catalogue : id « catalogue:<id de l'entrée> », pages lues dans le catalogue ;
#   recherche : id « recherche:<condensat de l'adresse> », titre et adresse seuls (jamais la source).
# Ordre : les entrées du catalogue dans l'ordre du catalogue, puis les recherches, de la plus ancienne
# à la plus récente.

static func catalogue_pin(entry: Dictionary) -> Dictionary:
	return {"id": "%s:%s" % [KIND_CATALOGUE, entry.id], "kind": KIND_CATALOGUE, "entry": entry.id,
		"title": entry.title, "author": entry.author, "address": {}}


static func search_pin(pin_title: String, target: Dictionary) -> Dictionary:
	var a := normalized_address(target)
	var key := BookText.full_form(a).sha256_text().left(16)
	return {"id": "%s:%s" % [KIND_SEARCH, key], "kind": KIND_SEARCH, "entry": "",
		"title": pin_title.strip_edges(), "author": "", "address": a}


static func default_pins(entries: Array) -> Array:
	var pins := []
	for entry: Dictionary in entries:
		pins.append(catalogue_pin(entry))
	return pins


## La quête d'une épingle ; null pour une entrée disparue du catalogue.
static func from_pin(pin: Dictionary, entries: Array) -> Quest:
	if pin.kind == KIND_CATALOGUE:
		var entry := catalogue_entry(entries, pin.entry)
		return null if entry.is_empty() else from_entry(entry)
	return from_address(pin.address, pin.title, pin.author)


## Ajoute une épingle à la fin, ou remplace celle de même id à sa place.
static func add_pin(pins: Array, pin: Dictionary) -> Array:
	var result := pins.duplicate()
	for i in result.size():
		if result[i].id == pin.id:
			result[i] = pin
			return result
	result.append(pin)
	return result


static func remove_pin(pins: Array, id: String) -> Array:
	return pins.filter(func(p: Dictionary) -> bool: return p.id != id)


## Les entrées du catalogue désépinglées.
static func missing_catalogue(pins: Array, entries: Array) -> Array:
	var present := {}
	for p: Dictionary in pins:
		present[p.id] = true
	return default_pins(entries).filter(func(p: Dictionary) -> bool: return not present.has(p.id))


## Rétablit les entrées du catalogue désépinglées ; les recherches du joueur restent, après elles.
static func restore_catalogue(pins: Array, entries: Array) -> Array:
	var searches := pins.filter(func(p: Dictionary) -> bool: return p.kind == KIND_SEARCH)
	return default_pins(entries) + searches


## Lit les épingles. Fichier absent, illisible ou d'un autre format → le catalogue entier ;
## épingles abîmées ou entrées disparues du catalogue écartées une à une.
static func load_pins(entries: Array, path := PINS_PATH) -> Array:
	var parsed: Variant = _read_json(path)
	if not parsed is Dictionary or parsed.get("version") != PINS_VERSION or not parsed.get("pins") is Array:
		return default_pins(entries)
	var catalogue_pins := {}
	var searches := []
	var seen := {}
	for raw: Variant in parsed.pins:
		var pin := _restore_pin(raw, entries)
		if pin.is_empty() or seen.has(pin.id):
			continue
		seen[pin.id] = true
		if pin.kind == KIND_CATALOGUE:
			catalogue_pins[pin.id] = pin
		else:
			searches.append(pin)
	var pins := []
	for p: Dictionary in default_pins(entries):
		if catalogue_pins.has(p.id):
			pins.append(p)
	return pins + searches


## Écrit les épingles ; faux si le fichier ne s'ouvre pas en écriture.
static func save_pins(pins: Array, path := PINS_PATH) -> bool:
	var stored := []
	for p: Dictionary in pins:
		if p.kind == KIND_CATALOGUE:
			stored.append({"kind": KIND_CATALOGUE, "entry": p.entry})
		else:
			stored.append({"kind": KIND_SEARCH, "title": p.title, "address": p.address})
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify({"version": PINS_VERSION, "pins": stored}, "\t"))
	file.close()
	return true


static func _restore_pin(raw: Variant, entries: Array) -> Dictionary:
	if not raw is Dictionary:
		return {}
	match raw.get("kind"):
		KIND_CATALOGUE:
			if not raw.get("entry") is String:
				return {}
			var entry := catalogue_entry(entries, raw.entry)
			return {} if entry.is_empty() else catalogue_pin(entry)
		KIND_SEARCH:
			if not raw.get("title") is String or not raw.get("address") is Dictionary:
				return {}
			if not is_valid_address(raw.address):
				return {}
			return search_pin(raw.title, raw.address)
	return {}


static func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK:
		return null
	return json.data
