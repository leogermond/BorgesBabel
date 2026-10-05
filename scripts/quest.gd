class_name Quest
extends RefCounted
## Quête : un livre à retrouver, la page à y lire, et le guidage depuis la galerie d'origine du monde.
##
## Représentation : hexagone et niveau sont, de bout en bout, des chaînes base 25 signées (voir
## BookText) : celles du fil (protocole 3), du catalogue et de main.gd. Une adresse trouvée par la
## recherche inverse en compte ~656 000 par coordonnée (~917 000 chiffres décimaux) : elle se lit,
## se compare et se recopie en temps linéaire par les fonctions natives des chaînes, alors qu'un
## passage au décimal coûterait une conversion quadratique (plusieurs secondes). La différence avec
## l'origine se résume (BookText.b25_difference) : exacte quand elle est petite, sinon en ordre de
## grandeur décimal (« ≈ 10^N »). Un pas d'une galerie ou d'un niveau (paramètre `moved` de
## guidance) la met à jour sans relire les coordonnées.
##
## Ce script lit aussi le catalogue data/quetes/catalogue.json (métadonnées, et pour chaque entrée
## l'adresse de son livre et le SHA-256 de chacune de ses pages : aucun texte) et tient les
## épingles du panneau de quête, enregistrées dans user://quetes_epinglees.json.
##
## Repères du monde : l'hexagone h + 1 est à 12 m vers +Z, le niveau l + 1 à 3,4 m au-dessus.

const QuestScript := preload("res://scripts/quest.gd")
const BookTextScript := preload("res://scripts/book_text.gd")

const CATALOGUE_PATH := "res://data/quetes/catalogue.json"
const CATALOGUE_VERSION := 2
const PINS_PATH := "user://quetes_epinglees.json"
## Version 2 : adresses de livres en base 25 (les épingles de la version 1, adresses de pages en
## décimal, sont abandonnées : le fichier revient aux épingles d'office).
const PINS_VERSION := 2
## Jusqu'à 15 chiffres, une distance s'écrit exactement ; au-delà, en ordre de grandeur.
const EXACT_DIGITS := 15
const KIND_CATALOGUE := "catalogue"
const KIND_SEARCH := "recherche"
const KIND_REGISTER := "registre"
const REGISTER_TITLE := "Registre des livres manquants"
const REGISTER_AUTHOR := "anonyme"
const REGISTER_CONTEXT := "Registre des ouvrages manquants aux étagères."

static var _stolen: Dictionary = {}       # chemin du catalogue → {livre volé: true}
static var _catalogues: Dictionary = {}   # chemin → catalogue lu (JSON), lu une fois

var title := ""
var author := ""
## Identifiant de l'entrée du catalogue, vide pour une recherche du joueur.
var entry_id := ""
## Le livre de la quête, {hexagon, level: String (base 25), wall, shelf, book: int}.
var book: Dictionary = {}
## Les pages proposées, numéros 0 à 409 dans le livre (les pages du texte d'une entrée).
var pages: Array = []
var page_index := 0
var _guide_origin: Array = []      # [hexagone, niveau] du dernier guidage
var _guide_dz: Dictionary = {}
var _guide_dy: Dictionary = {}


## Une quête sur une adresse de livre (page facultative, 0 par défaut) ; null si elle est mal formée.
static func from_address(target: Dictionary, quest_title := "", quest_author := "") -> QuestScript:
	if not is_valid_address(target):
		return null
	return from_book(target, [int(target.get("page", 0))], quest_title, quest_author)


## Une quête sur un livre et quelques-unes de ses pages ; null si l'adresse ou une page est mal formée.
static func from_book(target: Dictionary, page_numbers: Array, quest_title := "", quest_author := "", id := "") -> QuestScript:
	if page_numbers.is_empty() or not is_valid_address(target):
		return null
	var quest := QuestScript.new()
	quest.book = BookTextScript.book_of(target)
	for page: Variant in page_numbers:
		if not _is_page(page):
			return null
		quest.pages.append(int(page))
	quest.title = quest_title
	quest.author = quest_author
	quest.entry_id = id
	return quest


## La quête d'une entrée du catalogue : son livre, ses pages dans l'ordre.
static func from_entry(entry: Dictionary) -> QuestScript:
	return from_book(entry.address, range(entry.page_count), entry.title, entry.author, entry.id)


## Vrai pour une adresse de livre bien formée : coordonnées base 25, mur, étagère et livre dans la
## galerie, et page (facultative) dans le livre.
static func is_valid_address(target: Dictionary) -> bool:
	if not (target.get("hexagon") is String and target.get("level") is String):
		return false
	if not (BookTextScript.b25_valid(target.hexagon) and BookTextScript.b25_valid(target.level)):
		return false
	var bounds := {"wall": 4, "shelf": 5, "book": 32}
	for key: String in bounds:
		if not _is_index(target.get(key), bounds[key]):
			return false
	return not target.has("page") or _is_page(target.page)


static func _is_page(value: Variant) -> bool:
	return _is_index(value, BookTextScript.PAGES)


static func _is_index(value: Variant, bound: int) -> bool:
	if value is float and is_equal_approx(value, roundf(value)):
		value = int(value)   # JSON lit les nombres en float
	return value is int and value >= 0 and value < bound


## Copie de l'adresse sous forme canonique (base 25 canonique, entiers int ; la page si elle y est).
static func normalized_address(target: Dictionary) -> Dictionary:
	var a := BookTextScript.book_of(target)
	if target.has("page"):
		a.page = int(target.page)
	return a


## L'adresse de la page choisie : le livre et « page ».
func address() -> Dictionary:
	return book.merged({"page": page()})


## Le numéro (0 à 409) de la page choisie.
func page() -> int:
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
	return "mur %d · étagère %d · livre %d · page %d" % [book.wall + 1, book.shelf + 1, book.book + 1, page() + 1]


## Le livre visé quand (hexagone, niveau) — int ou chaînes base 25 — est sa galerie :
## {wall, shelf, book, page} ; sinon {}.
func target_in_gallery(hexagon: Variant, level: Variant) -> Dictionary:
	if BookTextScript.b25(hexagon) != book.hexagon or BookTextScript.b25(level) != book.level:
		return {}
	return {"wall": book.wall, "shelf": book.shelf, "book": book.book, "page": page()}


## Le guidage depuis la galerie (hexagone, niveau) — int ou chaînes base 25 :
## {dz, dy : différences cible − origine résumées (BookText.b25_difference : sign, exact, value,
##  digits), hall, vert : −1, 0 ou +1, here : vrai dans la galerie visée, hall_text, level_text,
##  book_text, summary}. `moved` : le pas (galeries, niveaux) qui mène de la galerie du guidage
## précédent à celle-ci ; la différence suit alors le pas sans relire les coordonnées.
func guidance(hexagon: Variant, level: Variant, moved := Vector2i.ZERO) -> Dictionary:
	if moved != Vector2i.ZERO and not _guide_origin.is_empty() and hexagon is String and level is String:
		# Un pas annoncé : chaînes canoniques de l'appelant, ni relues ni comparées.
		_guide_dz = _step(_guide_dz, -moved.x)
		_guide_dy = _step(_guide_dy, -moved.y)
		_guide_origin = [hexagon, level]
	else:
		var h := BookTextScript.b25(hexagon)
		var l := BookTextScript.b25(level)
		if _guide_origin.is_empty() or _guide_origin[0] != h or _guide_origin[1] != l:
			_guide_dz = BookTextScript.b25_difference(book.hexagon, h)
			_guide_dy = BookTextScript.b25_difference(book.level, l)
		_guide_origin = [h, l]
	var dz := _guide_dz
	var dy := _guide_dy
	var hall: int = dz.sign
	var vert: int = dy.sign
	var hall_text := "couloir : ici"
	if hall != 0:
		hall_text = "couloir : %s %s vers %s" % [magnitude_text(dz), "galerie" if _is_one(dz) else "galeries", "+Z" if hall > 0 else "−Z"]
	var level_text := "étages : ici"
	if vert != 0:
		level_text = "étages : %s %s vers le %s" % [magnitude_text(dy), "niveau" if _is_one(dy) else "niveaux", "haut" if vert > 0 else "bas"]
	var book_text := "dans la galerie : " + book_line()
	return {
		"dz": dz, "dy": dy, "hall": hall, "vert": vert, "here": hall == 0 and vert == 0,
		"hall_text": hall_text, "level_text": level_text, "book_text": book_text,
		"summary": "\n".join([hall_text, level_text, book_text]),
	}


## La distance d'une différence résumée : exacte jusqu'à 15 chiffres, sinon « ≈ 10^N »,
## N = chiffres décimaux − 1.
static func magnitude_text(difference: Dictionary) -> String:
	if difference.exact and int(difference.digits) <= EXACT_DIGITS:
		return str(absi(difference.value))
	return "≈ 10^%d" % (int(difference.digits) - 1)


static func _is_one(difference: Dictionary) -> bool:
	return difference.exact and absi(difference.value) == 1


## La différence résumée après un pas de `delta` : exacte, elle suit le pas ; en ordre de
## grandeur (au moins 25^12 ≈ 6·10^16), un pas ne change ni son signe ni son nombre de chiffres.
static func _step(difference: Dictionary, delta: int) -> Dictionary:
	if delta == 0 or not difference.exact:
		return difference
	return BookTextScript._exact_difference(int(difference.value) + delta)


# --- Catalogue ----------------------------------------------------------------------------------
# Version 2. Une entrée : {id, title, author, year, language, context, group, licence, protected,
# address : le livre (base 25), page_count, pages : [{page, sha256}] (les pages du texte, dans
# l'ordre, chacune avec le SHA-256 de ses 3200 symboles), notice_book : rang dans stolen_books du
# livre de la notice, notice_hash : SHA-256 de la première page de ce livre}. La notice (titre,
# auteur et contexte, une ligne chacun) est le contenu d'un livre de la Bibliothèque, suivi
# d'espaces : un livre volé. stolen_books garde l'adresse de chaque livre volé une seule fois
# (1,3 Mo par adresse) ; load_catalogue la recopie dans entry.notice_address. destinations :
# {nom: {address, page, sha256}} ou {} (lieux du monde que les quêtes savent atteindre ; « sator »,
# « golem » encore vide). Les entrées incomplètes sont écartées ; l'ordre du fichier est gardé.

static func load_catalogue(path := CATALOGUE_PATH) -> Array:
	var parsed: Variant = _catalogue(path)
	if not parsed is Dictionary or not parsed.get("entries") is Array:
		return []
	var stolen := stolen_books(path)
	var entries := []
	var seen := {}
	for raw: Variant in parsed.entries:
		var entry := _valid_entry(raw, stolen)
		if not entry.is_empty() and not seen.has(entry.id):
			seen[entry.id] = true
			entries.append(entry)
	return entries


## Une destination du catalogue : {address (livre et page), sha256} ; {} si elle manque ou est
## encore vide (« golem »).
static func destination(name: String, path := CATALOGUE_PATH) -> Dictionary:
	var parsed: Variant = _catalogue(path)
	var places: Variant = parsed.get("destinations") if parsed is Dictionary else null
	var place: Variant = places.get(name) if places is Dictionary else null
	if not place is Dictionary or not place.get("address") is Dictionary:
		return {}
	var target: Dictionary = place.address.merged({"page": place.get("page", 0)})
	if not is_valid_address(target):
		return {}
	return {"address": normalized_address(target), "sha256": str(place.get("sha256", ""))}


## Vrai pour un livre volé à la Bibliothèque (liste stolen_books, lue une fois) : ceux dont le
## contenu est la notice d'une entrée du catalogue. Hexagone et niveau en base 25 (ou int).
static func is_stolen_book(hexagon: Variant, level: Variant, wall: int, shelf: int, book: int, path := CATALOGUE_PATH) -> bool:
	if not _stolen.has(path):
		var known := {}
		for b: Dictionary in stolen_books(path):
			known[b] = true
		_stolen[path] = known
	return _stolen[path].has(BookTextScript.book_of({"hexagon": hexagon, "level": level, "wall": wall, "shelf": shelf, "book": book}))


## Les livres volés du catalogue, dans son ordre : {hexagon, level, wall, shelf, book}, forme
## canonique ; un livre mal formé laisse sa place vide ({}), pour garder les rangs de notice_book.
static func stolen_books(path := CATALOGUE_PATH) -> Array:
	var parsed: Variant = _catalogue(path)
	var books: Variant = parsed.get("stolen_books") if parsed is Dictionary else null
	var result := []
	if books is Array:
		for raw: Variant in books:
			if raw is Dictionary and is_valid_address(raw) and not raw.has("page"):
				result.append(BookTextScript.book_of(raw))
			else:
				result.append({})
	return result


static func catalogue_entry(entries: Array, id: String) -> Dictionary:
	for entry: Dictionary in entries:
		if entry.id == id:
			return entry
	return {}


static func _valid_entry(raw: Variant, stolen: Array) -> Dictionary:
	if not raw is Dictionary:
		return {}
	for key in ["id", "title", "author", "context"]:
		if not raw.get(key) is String or raw[key].is_empty():
			return {}
	if not raw.get("address") is Dictionary or raw.address.has("page") or not is_valid_address(raw.address):
		return {}
	if not raw.get("pages") is Array or raw.pages.is_empty():
		return {}
	var pages := []
	for page: Variant in raw.pages:
		if not page is Dictionary or not _is_page(page.get("page")) or not page.get("sha256") is String:
			return {}
		pages.append({"page": int(page.page), "sha256": page.sha256})
	var entry: Dictionary = raw.duplicate()
	entry.address = BookTextScript.book_of(raw.address)
	entry.erase("notice_address")
	var notice: Variant = raw.get("notice_book")
	if _is_index(notice, stolen.size()) and not stolen[int(notice)].is_empty():
		entry.notice_address = stolen[int(notice)]
	entry.group = str(raw.get("group", ""))
	entry.protected = raw.get("protected", false) == true
	entry.pages = pages
	entry.page_count = pages.size()
	return entry


# --- Épingles -----------------------------------------------------------------------------------
# Une épingle : {id, kind, title, author, address}.
#   catalogue : id « catalogue:<id de l'entrée> », livre et pages lus dans le catalogue ;
#   recherche : id « recherche:<condensat de l'adresse> », titre et adresse seuls (jamais la source) ;
#   registre  : id « registre », le registre des livres manquants, tiré de stolen_books.
# Ordre : les entrées du catalogue dans l'ordre du catalogue, puis les recherches, de la plus ancienne
# à la plus récente, puis le registre.

static func catalogue_pin(entry: Dictionary) -> Dictionary:
	return {"id": "%s:%s" % [KIND_CATALOGUE, entry.id], "kind": KIND_CATALOGUE, "entry": entry.id,
		"title": entry.title, "author": entry.author, "address": {}}


static func search_pin(pin_title: String, target: Dictionary) -> Dictionary:
	var a := normalized_address(target)
	if not a.has("page"):
		a.page = 0
	var key := BookTextScript.full_form(a).sha256_text().left(16)
	return {"id": "%s:%s" % [KIND_SEARCH, key], "kind": KIND_SEARCH, "entry": "",
		"title": pin_title.strip_edges(), "author": "", "address": a}


static func register_pin() -> Dictionary:
	return {"id": KIND_REGISTER, "kind": KIND_REGISTER, "entry": "",
		"title": REGISTER_TITLE, "author": REGISTER_AUTHOR, "address": {}}


## Les lignes du registre, une par livre de stolen_books dans l'ordre du catalogue :
## {label : « Ouvrage manquant n — mur · étagère · livre », address : le livre, page 1}.
static func register_items(path := CATALOGUE_PATH) -> Array:
	var items := []
	for book: Dictionary in stolen_books(path):
		if book.is_empty():
			continue
		var a: Dictionary = book.merged({"page": 0})
		items.append({
			"label": "Ouvrage manquant %d — mur %d · étagère %d · livre %d" % [items.size() + 1, a.wall + 1, a.shelf + 1, a.book + 1],
			"address": a,
		})
	return items


static func default_pins(entries: Array) -> Array:
	var pins := []
	for entry: Dictionary in entries:
		pins.append(catalogue_pin(entry))
	pins.append(register_pin())
	return pins


## La quête d'une épingle ; null pour une entrée disparue du catalogue, et pour le registre
## (ses lignes démarrent chacune une quête).
static func from_pin(pin: Dictionary, entries: Array) -> QuestScript:
	if pin.kind == KIND_REGISTER:
		return null
	if pin.kind == KIND_CATALOGUE:
		var entry := catalogue_entry(entries, pin.entry)
		return null if entry.is_empty() else from_entry(entry)
	return from_address(pin.address, pin.title, pin.author)


## Ajoute une épingle à sa place (une recherche après les autres, avant le registre), ou remplace
## celle de même id.
static func add_pin(pins: Array, pin: Dictionary) -> Array:
	var result := pins.duplicate()
	for i in result.size():
		if result[i].id == pin.id:
			result[i] = pin
			return result
	result.append(pin)
	return _ordered(result, [])


static func remove_pin(pins: Array, id: String) -> Array:
	return pins.filter(func(p: Dictionary) -> bool: return p.id != id)


## Les épingles d'office (catalogue et registre) désépinglées.
static func missing_catalogue(pins: Array, entries: Array) -> Array:
	var present := {}
	for p: Dictionary in pins:
		present[p.id] = true
	return default_pins(entries).filter(func(p: Dictionary) -> bool: return not present.has(p.id))


## Rétablit les épingles d'office désépinglées ; les recherches du joueur restent.
static func restore_catalogue(pins: Array, entries: Array) -> Array:
	return _ordered(default_pins(entries) + pins.filter(func(p: Dictionary) -> bool: return p.kind == KIND_SEARCH), entries)


## Lit les épingles. Fichier absent, illisible ou d'un autre format → les épingles d'office ;
## épingles abîmées ou entrées disparues du catalogue écartées une à une.
static func load_pins(entries: Array, path := PINS_PATH) -> Array:
	var parsed: Variant = _read_json(path)
	if not parsed is Dictionary or parsed.get("version") != PINS_VERSION or not parsed.get("pins") is Array:
		return default_pins(entries)
	var pins := []
	var seen := {}
	for raw: Variant in parsed.pins:
		var pin := _restore_pin(raw, entries)
		if not pin.is_empty() and not seen.has(pin.id):
			seen[pin.id] = true
			pins.append(pin)
	return _ordered(pins, entries)


## Range les épingles : catalogue (dans l'ordre de `entries`, ou dans l'ordre donné si vide),
## recherches dans l'ordre donné, registre.
static func _ordered(pins: Array, entries: Array) -> Array:
	var catalogue_pins := pins.filter(func(p: Dictionary) -> bool: return p.kind == KIND_CATALOGUE)
	if not entries.is_empty():
		var rank := {}
		for i in entries.size():
			rank[entries[i].id] = i
		catalogue_pins.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return rank.get(a.entry, 0) < rank.get(b.entry, 0))
	var searches := pins.filter(func(p: Dictionary) -> bool: return p.kind == KIND_SEARCH)
	var register := pins.filter(func(p: Dictionary) -> bool: return p.kind == KIND_REGISTER)
	return catalogue_pins + searches + register.slice(0, 1)


## Écrit les épingles ; faux si le fichier ne s'ouvre pas en écriture.
static func save_pins(pins: Array, path := PINS_PATH) -> bool:
	var stored := []
	for p: Dictionary in pins:
		match p.kind:
			KIND_CATALOGUE:
				stored.append({"kind": KIND_CATALOGUE, "entry": p.entry})
			KIND_SEARCH:
				stored.append({"kind": KIND_SEARCH, "title": p.title, "address": p.address})
			KIND_REGISTER:
				stored.append({"kind": KIND_REGISTER})
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
		KIND_REGISTER:
			return register_pin()
	return {}


## Le catalogue lu (une fois par chemin : 22 Mo de JSON, ~0,3 s), ou null s'il manque, est
## illisible ou n'est pas de la version attendue.
static func _catalogue(path: String) -> Variant:
	if not _catalogues.has(path):
		var parsed: Variant = _read_json(path)
		if not parsed is Dictionary or parsed.get("version") != CATALOGUE_VERSION:
			parsed = null
		_catalogues[path] = parsed
	return _catalogues[path]


static func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK:
		return null
	return json.data
