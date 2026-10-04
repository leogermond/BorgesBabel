class_name BookText
extends RefCounted
## Texte des livres de la Bibliothèque, au format décrit par Borges :
## 410 pages, 40 lignes par page, 80 caractères par ligne, 25 symboles.
##
## Les livres viennent du service Python `python/babel.py serve` (protocole 3) : une bijection
## exacte entre les livres et leurs adresses, dans les deux sens, si bien que tout texte (ou toute
## image) se retrouve dans un livre, à une adresse. Ce script en est le client : il lance le
## service au premier appel, lui écrit une requête JSON par ligne et lit la réponse sur la ligne
## suivante, de façon synchrone, sous un délai (voir « Délais » plus bas).
##
## Adresse d'un livre : Dictionary {hexagon: String, level: String, wall, shelf, book: int}.
## Hexagone et niveau sont des entiers relatifs écrits en base 25 signée, comme sur le fil :
## « - » facultatif puis les chiffres « 0123456789abcdefghijklmno », poids fort en premier, sans
## zéro de tête (« 0 » pour zéro). Une adresse trouvée par la recherche en compte ~656 000 par
## coordonnée (~917 000 chiffres décimaux). Le numéro de page (0 à 409) se donne à part, ou dans
## une clé « page » de l'adresse. BookText.address() fabrique une adresse à partir d'entiers ou de
## chaînes base 25 ; les fonctions b25_* font l'arithmétique dont le jeu a besoin sur ces chaînes
## (±1, comparaison, signe, différence, nombre de chiffres décimaux), sans conversion complète.
##
## Le service rend une clé courte pour chaque livre ouvert : les pages suivantes se demandent par
## cette clé (1,3 Mo d'adresse ne repartent pas à chaque page tournée) ; une clé oubliée par le
## service (code unknown_key) est remplacée en renvoyant l'adresse.
##
## Délais : la lecture du tube est bloquante, mais un chien de garde (un fil) arrête le service
## s'il ne répond pas dans le délai (timeout_ms pour une page, search_timeout_ms pour une
## recherche, start_timeout_ms au lancement) ; la lecture bloquée finit alors aussitôt, l'appel
## rend une erreur (last_error) et le service est relancé à la requête suivante.
##
## Interpréteur : le réglage de projet `babel/python_command` (par exemple `py -3` ou un chemin
## entre guillemets) ; à défaut `py -3`, `python`, puis `python3` sous Windows, `python3` ailleurs.
## Sans Python, les pages affichent le message d'erreur et le journal le reprend.

const BookSpineScript := preload("res://scripts/book_spine.gd")

## 22 lettres (l'alphabet latin privé de k, q, w, y), l'espace, la virgule, le point.
const ALPHABET := "abcdefghijlmnoprstuvxz ,."
const PAGES := 410
const LINES := 40
const CHARS := 80
const WALLS := 4
const SHELVES := 5
const BOOKS := 32
## Une page de livre d'images : 50 × 64 pixels, un symbole par pixel.
const IMAGE_WIDTH := 50
const IMAGE_HEIGHT := 64
const PYTHON_SETTING := "babel/python_command"
const SCRIPT_PATH := "res://python/babel.py"
const PROTOCOL := 3
## Chiffres de la base 25 du fil, dans l'ordre de leur valeur (et de leur code ASCII).
const B25_DIGITS := "0123456789abcdefghijklmno"
## Quand le service meurt pendant une requête : attente de sa fin, lignes d'erreur reprises.
const STDERR_WAIT_MS := 1000
const STDERR_TAIL_LINES := 5
## Clés de livres retenues côté jeu (le service en garde 256).
const KEY_CACHE := 64
## 25^12 : les petites valeurs (au plus 12 chiffres base 25) se calculent en int.
const B25_POW12 := 59604644775390625
const B25_POW11 := 2384185791015625
const LOG10_25 := 1.3979400086720377

## Délais de réponse du service, en millisecondes.
static var timeout_ms := 3000
static var search_timeout_ms := 10000
static var start_timeout_ms := 20000

## Dernière erreur du service (vide quand tout va bien).
static var last_error := ""
## La réponse complète de la dernière recherche réussie (key, is_image, text_pages, truncated,
## notice…), sans l'adresse, rendue par search_text et search_image.
static var last_search: Dictionary = {}
static var _stdio: FileAccess
static var _stderr: FileAccess
static var _pid := -1
static var _unavailable := false
static var _palette := PackedByteArray()
static var _keys: Dictionary = {}        # adresse de livre (Dictionary) → clé du service
static var _b25_regex: RegEx
static var _b25_regex_any_case: RegEx
static var _b25_canonical: RegEx
static var _int_limit := ""              # 2^62 en base 25 : au-delà, plus d'arithmétique int


# --- Adresses -------------------------------------------------------------------------------

## L'adresse d'un livre, hexagone et niveau donnés en entiers ou en chaînes base 25 ; avec
## `page` ≥ 0, l'adresse porte aussi ce numéro de page. {} si une coordonnée est invalide.
static func address(hexagon: Variant, level: Variant, wall: int, shelf: int, book: int, page := -1) -> Dictionary:
	var h := b25(hexagon)
	var l := b25(level)
	if h.is_empty() or l.is_empty():
		return {}
	var result := {"hexagon": h, "level": l, "wall": wall, "shelf": shelf, "book": book}
	if page >= 0:
		result.page = page
	return result


## Le livre seul d'une adresse (sans page ni autre clé), coordonnées canoniques.
static func book_of(target: Dictionary) -> Dictionary:
	return {"hexagon": b25(target.get("hexagon", "")), "level": b25(target.get("level", "")),
		"wall": int(target.get("wall", 0)), "shelf": int(target.get("shelf", 0)), "book": int(target.get("book", 0))}


## Forme « b25:hexagone:niveau:mur:étagère:livre[:page] », relue par `python babel.py page`.
static func full_form(target: Dictionary) -> String:
	var text := "b25:%s:%s:%d:%d:%d" % [target.hexagon, target.level, target.wall, target.shelf, target.book]
	return text + (":%d" % int(target.page) if target.has("page") else "")


## Forme courte d'une adresse pour l'écran (grands nombres abrégés, mur, étagère, livre, page
## comptés depuis 1), calculée par le service.
static func display(target: Dictionary) -> String:
	var request := {"op": "display", "address": book_of(target)}
	if target.has("page"):
		request.page = int(target.page)
	var response := _request(request)
	return response.get("short", _describe_error(response))


## Résumé d'une coordonnée pour l'écran : {sign, digits (chiffres décimaux), lead (4 premiers),
## tail (4 derniers)}, et value (int) quand elle tient dans un int. Calcul local exact pour une
## petite coordonnée ; pour une grande, la forme « display » du service. {} en cas d'erreur.
static func coordinate_summary(coordinate: String) -> Dictionary:
	var value := b25(coordinate)
	if value.is_empty():
		return {}
	if b25_fits_int(value):
		return _int_summary(b25_to_int(value))
	var response := _request({"op": "display", "address": {"hexagon": value, "level": "0", "wall": 0, "shelf": 0, "book": 0}})
	return response.get("hexagon", {})


## La coordonnée à l'écran : ses chiffres décimaux quand elle tient dans un int, sinon
## « 1096…5665 (917047 chiffres) » (signe en tête s'il y a lieu), d'après son résumé.
static func summary_text(summary: Dictionary) -> String:
	if summary.is_empty():
		return "?"
	if summary.has("value"):
		return str(summary.value)
	return "%s%s…%s (%d chiffres)" % ["-" if int(summary.sign) < 0 else "", summary.lead, summary.tail, int(summary.digits)]


## Le résumé de la coordonnée voisine (coordonnée + delta, |delta| petit), sans la relire : les
## derniers chiffres suivent le pas ; {} quand ils débordent (retenue vers les chiffres de tête,
## une fois tous les 10 000 pas au plus) ou que la valeur tient dans un int (recalcul exact).
static func summary_step(summary: Dictionary, delta: int) -> Dictionary:
	if summary.is_empty() or summary.has("value") or absi(delta) >= 10000:
		return {}
	var magnitude_delta := delta if int(summary.sign) > 0 else -delta
	var tail := int(summary.tail) + magnitude_delta
	if tail < 0 or tail >= 10000:
		return {}
	var result := summary.duplicate()
	result.tail = "%04d" % tail
	return result


static func _int_summary(value: int) -> Dictionary:
	var digits := str(absi(value)) if value != -9223372036854775807 - 1 else "9223372036854775808"
	return {"sign": signi(value), "digits": digits.length(), "lead": digits.left(4), "tail": digits.right(4), "value": value}


# --- Arithmétique en base 25 ------------------------------------------------------------------
# Une coordonnée est une chaîne base 25 signée canonique (voir l'en-tête). Godot garde les chaînes
# en UTF-32 : copier une coordonnée de 656 000 chiffres coûte ~1,4 ms, une boucle GDScript sur ses
# chiffres ~16 ms. Les opérations ci-dessous ne touchent que la queue (±1), comparent par les
# fonctions natives des chaînes (l'ordre des codes ASCII de « 0-9a-o » est celui des chiffres) et
# n'estiment l'ordre de grandeur que d'après les chiffres de tête.

## Forme canonique d'une coordonnée (int, ou chaîne base 25 : « + », zéros de tête et capitales
## admis) ; "" si elle est invalide.
static func b25(value: Variant) -> String:
	if value is int:
		return b25_from_int(value)
	if value is float and is_equal_approx(value, roundf(value)) and absf(value) < 9.0e15:
		return b25_from_int(int(value))   # JSON lit les nombres en float
	if not value is String:
		return ""
	var text: String = value
	if not b25_valid(text):
		return ""
	if _b25_canonical.search(text) != null:
		return text   # déjà canonique : aucune copie
	if _b25_regex.search(text) == null:   # capitales : rare, et seulement ici
		text = text.to_lower()
	var negative := text.begins_with("-")
	var digits := text.trim_prefix("+").trim_prefix("-").lstrip("0")
	if digits.is_empty():
		return "0"
	return "-" + digits if negative else digits


## Vrai pour une coordonnée base 25 bien formée (signe facultatif puis chiffres 0-9, a-o, en
## minuscules ou capitales) ; tout autre caractère (blanc, contrôle, non ASCII) la refuse.
static func b25_valid(text: String) -> bool:
	if _b25_regex == null:
		_b25_regex = RegEx.create_from_string("^[+-]?[0-9a-o]+\\z")
		_b25_regex_any_case = RegEx.create_from_string("^[+-]?[0-9a-oA-O]+\\z")
		_b25_canonical = RegEx.create_from_string("^(?:0|-?[1-9a-o][0-9a-o]*)\\z")
	return _b25_regex.search(text) != null or _b25_regex_any_case.search(text) != null


static func b25_from_int(value: int) -> String:
	if value == 0:
		return "0"
	var negative := value < 0
	var out := ""
	var rest := value
	while rest != 0:
		var digit := absi(rest % 25)
		out = B25_DIGITS[digit] + out
		rest = -(-rest / 25) if negative else rest / 25   # vers zéro, sans déborder sur -2^63
	return "-" + out if negative else out


## La valeur d'une petite coordonnée canonique (voir b25_fits_int).
static func b25_to_int(text: String) -> int:
	var negative := text.begins_with("-")
	var value := 0
	for i in range(1 if negative else 0, text.length()):
		value = value * 25 + _digit(text, i)
	return -value if negative else value


## Vrai quand |coordonnée| ≤ 2^62 : elle s'écrit en int, avec de la marge pour un petit pas.
static func b25_fits_int(text: String) -> bool:
	if _int_limit.is_empty():
		_int_limit = b25_from_int(1 << 62)
	var length := text.length() - (1 if text.begins_with("-") else 0)
	if length != _int_limit.length():
		return length < _int_limit.length()
	return text.trim_prefix("-") <= _int_limit


## −1, 0 ou +1.
static func b25_sign(text: String) -> int:
	if text == "0":
		return 0
	return -1 if text.begins_with("-") else 1


static func b25_neg(text: String) -> String:
	if text == "0":
		return text
	return text.substr(1) if text.begins_with("-") else "-" + text


## −1, 0 ou +1 selon que a < b, a = b ou a > b (coordonnées canoniques).
static func b25_compare(a: String, b: String) -> int:
	var sa := b25_sign(a)
	var sb := b25_sign(b)
	if sa != sb:
		return -1 if sa < sb else 1
	if sa == 0:
		return 0
	return _cmp_magnitude(a, 1 if sa < 0 else 0, b, 1 if sb < 0 else 0) * sa


## coordonnée + delta, pour un petit delta (|delta| < 25^12). Seule la queue change : une copie
## de la chaîne (~1,4 ms à 656 000 chiffres), et la retenue ne remonte qu'à travers les « o »
## (ou les « 0 ») qui la précèdent.
static func b25_add_small(text: String, delta: int) -> String:
	if delta == 0:
		return text
	if b25_fits_int(text):
		return b25_from_int(b25_to_int(text) + delta)
	assert(absi(delta) < B25_POW12, "pas trop grand pour b25_add_small : %d" % delta)
	var negative := text.begins_with("-")
	var start := 1 if negative else 0
	var step := -delta if negative else delta   # pas appliqué à la valeur absolue
	var length := text.length()
	# Dernier chiffre seul quand il ne déborde pas : une seule copie (affectation d'un caractère).
	var last := _digit(text, length - 1) + step
	if last >= 0 and last < 25:
		var result := text
		result[length - 1] = B25_DIGITS[last]
		return result
	var width := 12
	var tail := 0
	for i in range(length - width, length):
		tail = tail * 25 + _digit(text, i)
	tail += step
	var head := text.substr(start, length - width - start)
	if tail >= B25_POW12:
		tail -= B25_POW12
		head = _increment(head)
	elif tail < 0:
		tail += B25_POW12
		head = _decrement(head)
	var tail_text := b25_from_int(tail).lpad(width, "0")
	var magnitude := (head + tail_text).lstrip("0")
	return ("-" if negative else "") + magnitude


## La différence a − b, résumée : {sign, exact: bool, value: int (valeur exacte quand exact),
## digits: chiffres décimaux de |a − b|, log10: log₁₀ |a − b| (0 pour 0)}. Exacte quand
## |a − b| < 25^12 ; sinon ordre de grandeur d'après les 12 chiffres base 25 de tête de la
## différence (erreur relative < 10^−15). Coût : quelques copies et comparaisons natives ; une
## boucle GDScript ne parcourt les chiffres qu'au-delà du premier chiffre qui diffère.
static func b25_difference(a: String, b: String) -> Dictionary:
	var short_a := a.length() - (1 if a.begins_with("-") else 0) <= 13
	var short_b := b.length() - (1 if b.begins_with("-") else 0) <= 13
	if short_a and short_b:   # au plus 13 chiffres chacun : |a − b| < 3·10^18, en int
		return _exact_difference(b25_to_int(a) - b25_to_int(b))
	var na := a.begins_with("-")
	var nb := b.begins_with("-")
	var oa := 1 if na else 0
	var ob := 1 if nb else 0
	var la := a.length() - oa
	var lb := b.length() - ob
	if na != nb:
		# Signes opposés (zéro compté positif) : |a − b| = |a| + |b|, d'après les chiffres de tête alignés.
		var width := maxi(la, lb)
		var top := _top_window(a, oa, la, width) + _top_window(b, ob, lb, width)
		return _approx_difference(-1 if na else 1, log(float(top)) / log(10.0) + (width - 12) * LOG10_25)
	# Même signe : |a − b| = ||a| − |b||, du signe de la comparaison (inversé pour deux négatifs).
	var order := _cmp_magnitude(a, oa, b, ob)
	if order == 0:
		return _exact_difference(0)
	var sign := -order if na else order
	var x := a.substr(oa) if order > 0 else b.substr(ob)
	var length := x.length()
	var y := (b.substr(ob) if order > 0 else a.substr(oa)).lpad(length, "0")
	# Premier chiffre qui diffère (les préfixes égaux s'annulent).
	var p := _first_difference(x, y, length)
	var value := 0
	var i := p
	while i < length and value < B25_POW11:
		value = value * 25 + _digit(x, i) - _digit(y, i)
		i += 1
		if value == 1 and i < length:
			i += _borrow_run(x, y, i, length)   # « 1 000… − 0 ooo… » : la valeur reste 1
	if i >= length:
		return _exact_difference(value * sign)
	return _approx_difference(sign, log(float(value)) / log(10.0) + (length - i) * LOG10_25)


## Nombre de chiffres décimaux de |coordonnée| (1 pour zéro) : exact pour une petite valeur,
## d'après le logarithme des chiffres de tête au-delà.
static func b25_decimal_digits(text: String) -> int:
	if b25_fits_int(text):
		return str(absi(b25_to_int(text))).length()
	var start := 1 if text.begins_with("-") else 0
	var length := text.length() - start
	return int(floor(log(float(_top_window(text, start, length, length))) / log(10.0) + (length - 12) * LOG10_25)) + 1


## Le résumé d'une différence connue en int : exacte sous 25^12, en ordre de grandeur au-delà
## (nombre de chiffres exact), comme b25_difference.
static func _exact_difference(value: int) -> Dictionary:
	var digits := str(absi(value)).length()
	var log10 := 0.0 if value == 0 else log(float(absi(value))) / log(10.0)
	if absi(value) >= B25_POW12:
		return {"sign": signi(value), "exact": false, "value": 0, "digits": digits, "log10": log10}
	return {"sign": signi(value), "exact": true, "value": value, "digits": digits, "log10": log10}


static func _approx_difference(sign: int, log10: float) -> Dictionary:
	return {"sign": sign, "exact": false, "value": 0, "digits": int(floor(log10)) + 1, "log10": log10}


## Valeur du chiffre i de la chaîne.
static func _digit(text: String, i: int) -> int:
	var c := text.unicode_at(i)
	return c - 48 if c <= 57 else c - 87


## Les 12 chiffres de tête d'un nombre de `length` chiffres (commençant à `start` dans `text`),
## aligné sur `width` chiffres : sa valeur divisée par 25^(width − 12), tronquée.
static func _top_window(text: String, start: int, length: int, width: int) -> int:
	var count := 12 - (width - length)
	var value := 0
	for i in maxi(count, 0):
		value = value * 25 + (_digit(text, start + i) if i < length else 0)
	return value


## Comparaison des valeurs absolues (chiffres à partir de oa et ob).
static func _cmp_magnitude(a: String, oa: int, b: String, ob: int) -> int:
	var la := a.length() - oa
	var lb := b.length() - ob
	if la != lb:
		return -1 if la < lb else 1
	var x := a.substr(oa) if oa > 0 else a
	var y := b.substr(ob) if ob > 0 else b
	if x == y:
		return 0
	return -1 if x < y else 1


## Indice du premier chiffre où x et y (même longueur, différents) diffèrent : dichotomie sur
## des tranches comparées nativement.
static func _first_difference(x: String, y: String, length: int) -> int:
	if x.unicode_at(0) != y.unicode_at(0):
		return 0
	var lo := 1        # x[0, lo) == y[0, lo)
	var hi := length   # x[0, hi) != y[0, hi)
	while hi - lo > 1:
		@warning_ignore("integer_division")
		var mid := (lo + hi) / 2
		if x.substr(lo, mid - lo) == y.substr(lo, mid - lo):
			lo = mid
		else:
			hi = mid
	return lo


## Longueur de la suite de positions i, i + 1 … où x porte « 0 » et y « o » (emprunt en cascade).
static func _borrow_run(x: String, y: String, from: int, length: int) -> int:
	var run := 0
	var probe := 1
	while from + run < length and x.unicode_at(from + run) == 48 and y.unicode_at(from + run) == 111:
		var count := mini(probe, length - from - run)
		if x.substr(from + run, count) == "0".repeat(count) and y.substr(from + run, count) == "o".repeat(count):
			run += count
			probe *= 2
		else:
			probe = maxi(1, probe / 2)
	return run


## +1 sur une suite de chiffres (sans signe) : les « o » de queue deviennent « 0 ».
static func _increment(digits: String) -> String:
	var trimmed := digits.rstrip("o")
	var zeros := "0".repeat(digits.length() - trimmed.length())
	if trimmed.is_empty():
		return "1" + zeros
	var last := _digit(trimmed, trimmed.length() - 1)
	return trimmed.left(-1) + B25_DIGITS[last + 1] + zeros


## −1 sur une suite de chiffres (sans signe, non nulle) : les « 0 » de queue deviennent « o ».
static func _decrement(digits: String) -> String:
	var trimmed := digits.rstrip("0")
	var nines := "o".repeat(digits.length() - trimmed.length())
	var last := _digit(trimmed, trimmed.length() - 1)
	return trimmed.left(-1) + B25_DIGITS[last - 1] + nines


# --- Pages ----------------------------------------------------------------------------------

## Les 40 lignes de la page `page` (0 à 409) du livre désigné.
static func page_lines(hexagon: Variant, level: Variant, wall: int, shelf: int, book: int, page: int) -> PackedStringArray:
	assert(page >= 0 and page < PAGES, "page hors du livre : %d" % page)
	return page_lines_at(address(hexagon, level, wall, shelf, book), page)


## Les 40 lignes d'une page du livre `target` : `page`, ou à défaut la clé « page » de
## l'adresse (0 sans elle) ; en cas d'erreur, le message occupe la page.
static func page_lines_at(target: Dictionary, page := -1) -> PackedStringArray:
	var response := _book_request({"op": "page", "page": _page_of(target, page)}, target)
	if response.has("error"):
		return _error_lines(_describe_error(response))
	return PackedStringArray(response.lines)


## Une page du livre lue comme une image de 50 × 64 pixels aux encres de la palette (quel que
## soit le genre du livre) ; null en cas d'erreur (voir last_error).
static func page_image_at(target: Dictionary, page := -1) -> Image:
	var palette := _ink_bytes()
	if palette.is_empty():
		return null
	var response := _book_request({"op": "page", "page": _page_of(target, page), "as_image": true}, target)
	if response.has("error"):
		return null
	var indices := Marshalls.base64_to_raw(response.indices)
	var rgb := PackedByteArray()
	rgb.resize(indices.size() * 3)
	for i in indices.size():
		var ink := indices[i] * 3
		rgb[i * 3] = palette[ink]
		rgb[i * 3 + 1] = palette[ink + 1]
		rgb[i * 3 + 2] = palette[ink + 2]
	return Image.create_from_data(IMAGE_WIDTH, IMAGE_HEIGHT, false, Image.FORMAT_RGB8, rgb)


static func page_image(hexagon: Variant, level: Variant, wall: int, shelf: int, book: int, page: int) -> Image:
	return page_image_at(address(hexagon, level, wall, shelf, book), page)


## Vrai pour un livre d'images (un sur 144) : toutes ses pages se lisent comme des images.
static func is_image_book(hexagon: Variant, level: Variant, wall: int, shelf: int, book: int) -> bool:
	var flags := image_books([address(hexagon, level, wall, shelf, book)])
	return not flags.is_empty() and flags[0] == true


## Le genre de chaque livre de la liste d'adresses (la page est ignorée), en une seule requête :
## true (livre d'images), false (livre de texte) ou null (emplacement vide, hors de la région
## habitée) ; tableau vide en cas d'erreur.
static func image_books(books: Array) -> Array:
	var targets := []
	for target: Dictionary in books:
		targets.append(book_of(target))
	var response := _request({"op": "is_image_book", "books": targets})
	return response.get("is_image", [])


## Les 640 livres d'une galerie, rangés à l'indice (mur·5 + étagère)·32 + livre : vrai pour un
## livre d'images (forme « gallery » du service : un seul calcul pour la galerie).
static func gallery_image_books(hexagon: Variant, level: Variant) -> Array:
	var response := _request({"op": "is_image_book", "gallery": {"hexagon": b25(hexagon), "level": b25(level)}})
	return response.get("is_image", [])


## Le titre inscrit sur le dos du livre : quelques lettres tirées d'un condensat SHA-256 de son adresse.
static func title(hexagon: Variant, level: Variant, wall: int, shelf: int, book: int) -> String:
	if hexagon is int and level is int:
		return BookSpineScript.display_title(BookSpineScript.title(hexagon, level, wall, shelf, book))
	return title_at(address(hexagon, level, wall, shelf, book))


## Le titre d'un livre désigné par son adresse. Coordonnées qui tiennent dans un int : la clé
## décimale de BookSpine.title (celle des dos des galeries) ; au-delà, BookSpine.title_at sur
## les chaînes base 25.
static func title_at(target: Dictionary) -> String:
	var a := book_of(target)
	if b25_fits_int(a.hexagon) and b25_fits_int(a.level):
		return BookSpineScript.display_title(BookSpineScript.title(b25_to_int(a.hexagon), b25_to_int(a.level), a.wall, a.shelf, a.book))
	return BookSpineScript.display_title(BookSpineScript.title_at(a))


static func _page_of(target: Dictionary, page: int) -> int:
	if page >= 0:
		return page
	return int(target.get("page", 0))


# --- Recherche inverse ----------------------------------------------------------------------

## L'adresse de l'unique livre qui contient `text` normalisé, suivi seulement d'espaces (le texte
## en occupe les pages 0, 1 …) ; {} en cas d'erreur (voir last_error). last_search garde le reste
## de la réponse (text_pages, truncated, notice, is_image, key).
static func search_text(text: String) -> Dictionary:
	return _found(_request({"op": "search_text", "text": text}, search_timeout_ms))


static func search_text_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		last_error = "fichier introuvable : %s" % path
		push_error(last_error)
		return {}
	return search_text(FileAccess.get_file_as_string(path))


## L'adresse de l'unique livre d'images dont la page 0 montre l'image, ajustée à 50 × 64 et
## tramée aux encres de la palette par le service ; {} en cas d'erreur (voir last_error).
## Seuls les points de la grille image_grid partent au service (au plus 200 × 256 pixels, quelle
## que soit la taille de l'image) : la ligne de commande `babel.py search-image` lit les mêmes
## points dans le PNG, si bien que la même image donne la même adresse dans le jeu et hors du jeu.
static func search_image(source: Image) -> Dictionary:
	var request := image_request(source)
	if request.is_empty():
		return {}
	return _found(_request(request, search_timeout_ms))


static func _found(response: Dictionary) -> Dictionary:
	if response.has("error") or not response.get("address") is Dictionary:
		return {}
	var found := book_of(response.address)
	last_search = response.duplicate()
	last_search.erase("address")
	if response.get("key") is String:
		_remember(found, response.key)
	return found


## La requête search_image d'une image : largeur et hauteur d'origine, et ses points de grille
## en RGBA (4 octets par point, ligne de grille après ligne de grille), en base 64.
static func image_request(source: Image) -> Dictionary:
	if source == null or source.is_empty():
		last_error = "image vide"
		push_error(last_error)
		return {}
	var img := source
	if img.is_compressed() or not (img.get_format() in [Image.FORMAT_L8, Image.FORMAT_LA8, Image.FORMAT_RGB8, Image.FORMAT_RGBA8]):
		img = source.duplicate() as Image
		if img.is_compressed():
			img.decompress()
		img.convert(Image.FORMAT_RGBA8)
	var width := img.get_width()
	var height := img.get_height()
	var grid := image_grid(width, height)
	var cols: PackedInt64Array = grid.cols
	var rows: PackedInt64Array = grid.rows
	var data := img.get_data()   # partagé avec l'image (copie à l'écriture), pas recopié
	var format := img.get_format()
	var bpp: int = {Image.FORMAT_L8: 1, Image.FORMAT_LA8: 2, Image.FORMAT_RGB8: 3, Image.FORMAT_RGBA8: 4}[format]
	var samples := PackedByteArray()
	samples.resize(cols.size() * rows.size() * 4)
	var o := 0
	for y in rows:
		var row := y * width
		for x in cols:
			var p := (row + x) * bpp
			match format:
				Image.FORMAT_RGBA8:
					samples[o] = data[p]
					samples[o + 1] = data[p + 1]
					samples[o + 2] = data[p + 2]
					samples[o + 3] = data[p + 3]
				Image.FORMAT_RGB8:
					samples[o] = data[p]
					samples[o + 1] = data[p + 1]
					samples[o + 2] = data[p + 2]
					samples[o + 3] = 255
				Image.FORMAT_LA8:
					samples[o] = data[p]
					samples[o + 1] = data[p]
					samples[o + 2] = data[p]
					samples[o + 3] = data[p + 1]
				_:
					samples[o] = data[p]
					samples[o + 1] = data[p]
					samples[o + 2] = data[p]
					samples[o + 3] = 255
			o += 4
	return {"op": "search_image", "width": width, "height": height, "samples": Marshalls.raw_to_base64(samples)}


## La grille d'échantillonnage d'une image width × height, en arithmétique entière seule, à
## l'identique de image_grid dans python/babel.py : {fit_w, fit_h, cols, rows}. L'image ajustée
## occupe fit_w × fit_h pixels de la page (arrondi moitié vers le haut) ; chaque pixel lit
## step × step points, step = min(4, ⌈côté source / côté ajusté⌉), et le point k d'un axe est
## ⌊(2k + 1)·côté source / (2·step·côté ajusté)⌋.
@warning_ignore("integer_division")
static func image_grid(width: int, height: int) -> Dictionary:
	var fit_w := IMAGE_WIDTH
	var fit_h := IMAGE_HEIGHT
	if IMAGE_WIDTH * height <= IMAGE_HEIGHT * width:
		fit_h = clampi((2 * height * IMAGE_WIDTH + width) / (2 * width), 1, IMAGE_HEIGHT)
	else:
		fit_w = clampi((2 * width * IMAGE_HEIGHT + height) / (2 * height), 1, IMAGE_WIDTH)
	var step_x := mini(4, (width + fit_w - 1) / fit_w)
	var step_y := mini(4, (height + fit_h - 1) / fit_h)
	var cols := PackedInt64Array()
	for k in fit_w * step_x:
		cols.append((2 * k + 1) * width / (2 * step_x * fit_w))
	var rows := PackedInt64Array()
	for k in fit_h * step_y:
		rows.append((2 * k + 1) * height / (2 * step_y * fit_h))
	return {"fit_w": fit_w, "fit_h": fit_h, "cols": cols, "rows": rows}


## Comme search_image, à partir d'un fichier PNG, JPG ou WebP chargé par Godot.
static func search_image_file(path: String) -> Dictionary:
	var img := Image.load_from_file(path)
	if img == null or img.is_empty():
		last_error = "image illisible : %s" % path
		push_error(last_error)
		return {}
	return search_image(img)


# --- Service --------------------------------------------------------------------------------

## Arrête le service (appelé à la fermeture du jeu par l'autoload BabelService).
static func shutdown() -> void:
	if _pid > 0:
		OS.kill(_pid)
	_pid = -1
	_stdio = null
	_stderr = null
	_keys.clear()


## Oublie un échec de lancement : le prochain appel relance la recherche de l'interpréteur.
static func restart() -> void:
	shutdown()
	_unavailable = false


## Une requête sur un livre : par sa clé quand le service en a rendu une, sinon par son adresse ;
## une clé oubliée par le service (unknown_key) est remplacée en renvoyant l'adresse.
static func _book_request(request: Dictionary, target: Dictionary) -> Dictionary:
	var book := book_of(target)
	if book.hexagon.is_empty() or book.level.is_empty():
		last_error = "adresse invalide"
		return {"error": last_error, "code": "bad_request"}
	var key: String = _keys.get(book, "")
	var response := {}
	if not key.is_empty():
		request.key = key
		response = _request(request)
		if response.get("code") != "unknown_key":
			return response
		_keys.erase(book)
		request.erase("key")
	request.address = book
	response = _request(request)
	if response.get("key") is String:
		_remember(book, response.key)
	return response


static func _remember(book: Dictionary, key: String) -> void:
	if _keys.size() >= KEY_CACHE and not _keys.has(book):
		_keys.erase(_keys.keys()[0])   # la plus ancienne (ordre d'insertion)
	_keys[book] = key


## Une requête au service, sa réponse ; {"error": …} quand le service manque, refuse ou ne
## répond pas dans le délai (`timeout`, en ms ; timeout_ms par défaut).
static func _request(request: Dictionary, timeout := -1) -> Dictionary:
	if _stdio == null and not _start():
		return {"error": last_error, "code": "unavailable"}
	var limit := timeout if timeout > 0 else timeout_ms
	var watchdog := Watchdog.new()
	watchdog.start(_pid, limit)
	var response := _exchange(request)
	if watchdog.finish():
		_pid = -1   # déjà arrêté par le chien de garde
		shutdown()
		last_error = "le service Python n'a pas répondu en %.1f s à la requête « %s » : arrêté, il sera relancé à la prochaine requête" % [limit / 1000.0, request.get("op")]
		push_error(last_error)
		return {"error": last_error, "code": "timeout"}
	if response.is_empty():
		var tail := _stop_and_read_stderr()
		last_error = "le service Python s'est arrêté pendant la requête « %s »" % request.get("op")
		if not tail.is_empty():
			last_error += " : " + tail
		push_error(last_error)
		return {"error": last_error}
	if response.has("error"):
		if response.get("code") != "unknown_key":
			last_error = str(response.error)
			push_error("babel.py : " + last_error)
	else:
		last_error = ""
	return response


## Arrête le service et rend les dernières lignes de son erreur standard (une trace Python,
## par exemple), jointes par « | ». Le processus est attendu une seconde au plus, puis tué :
## une fois le processus fini, la lecture du tube atteint sa fin au lieu d'attendre.
static func _stop_and_read_stderr() -> String:
	var err := _stderr
	var pid := _pid
	var waited := 0
	while pid > 0 and OS.is_process_running(pid) and waited < STDERR_WAIT_MS:
		OS.delay_msec(10)
		waited += 10
	if pid > 0 and OS.is_process_running(pid):
		OS.kill(pid)
	_pid = -1
	shutdown()
	if err == null:
		return ""
	var lines := PackedStringArray()
	for _i in 10000:
		var line := err.get_line()
		if line.is_empty() and err.get_error() != OK:
			break
		if not line.strip_edges().is_empty():
			lines.append(line.strip_edges())
	return " | ".join(lines.slice(-STDERR_TAIL_LINES))


static func _exchange(request: Dictionary) -> Dictionary:
	_stdio.store_line(JSON.stringify(request))
	_stdio.flush()
	var line := _stdio.get_line()
	if line.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(line)
	return parsed if parsed is Dictionary else {"error": "réponse illisible : %s" % line.left(200)}


static func _start() -> bool:
	if _unavailable:
		return false
	var script := ProjectSettings.globalize_path(SCRIPT_PATH)
	var tried := PackedStringArray()
	for command in _interpreters():
		var args := PackedStringArray(command.slice(1))
		args.append_array(["-X", "utf8", "-u", script, "serve"])
		tried.append(" ".join(command))
		var process := OS.execute_with_pipe(command[0], args)
		if process.is_empty():
			continue
		_stdio = process.stdio
		_stderr = process.stderr
		_pid = process.pid
		var watchdog := Watchdog.new()
		watchdog.start(_pid, start_timeout_ms)
		var answer := _exchange({"op": "ping"})
		if watchdog.finish():
			_pid = -1
		if answer.get("protocol") == PROTOCOL:
			last_error = ""
			return true
		shutdown()
	_unavailable = true
	last_error = "Python 3.10 ou plus est introuvable (essayé : %s). Installer Python, ou indiquer la commande dans le réglage de projet %s." % [", ".join(tried), PYTHON_SETTING]
	push_error(last_error)
	return false


## Les commandes candidates, chacune en tableau [exécutable, arguments…].
static func _interpreters() -> Array:
	var setting := str(ProjectSettings.get_setting(PYTHON_SETTING, "")).strip_edges()
	if not setting.is_empty():
		return [_split_command(setting)]
	if OS.get_name() == "Windows":
		return [["py", "-3"], ["python"], ["python3"]]
	return [["python3"]]


## Découpe une commande aux espaces, en gardant entier ce qui est entre guillemets.
static func _split_command(command: String) -> Array:
	var parts := []
	var current := ""
	var quoted := false
	for c in command:
		if c == "\"":
			quoted = not quoted
		elif c == " " and not quoted:
			if not current.is_empty():
				parts.append(current)
			current = ""
		else:
			current += c
	if not current.is_empty():
		parts.append(current)
	return parts


## La palette du service en octets RVB (25 × 3), chargée une fois.
static func _ink_bytes() -> PackedByteArray:
	if _palette.is_empty():
		var response := _request({"op": "palette"})
		for ink in response.get("palette", []):
			var color := Color.html(ink)
			_palette.append_array([color.r8, color.g8, color.b8])
	return _palette


static func _describe_error(response: Dictionary) -> String:
	return "Bibliothèque indisponible : %s" % response.get("error", "erreur inconnue")


static func _error_lines(message: String) -> PackedStringArray:
	var lines := PackedStringArray()
	var words := message.split(" ")
	var line := ""
	for word in words:
		if not line.is_empty() and line.length() + 1 + word.length() > CHARS:
			lines.append(line)
			line = word
		else:
			line = word if line.is_empty() else line + " " + word
	lines.append(line)
	while lines.size() < LINES:
		lines.append("")
	return lines


## Chien de garde d'une requête : un fil qui arrête le processus du service si la requête n'est
## pas finie à l'échéance. Arrêter le processus ferme ses tubes : l'écriture ou la lecture
## bloquée du fil principal se termine aussitôt (fin de fichier).
class Watchdog:
	extends RefCounted

	## Période de surveillance : la fin d'une requête attend au plus ce délai.
	const POLL_USEC := 250

	var _mutex := Mutex.new()
	var _thread := Thread.new()
	var _done := false
	var _fired := false
	var _pid := -1
	var _deadline := 0

	func start(pid: int, timeout_ms: int) -> void:
		_pid = pid
		_deadline = Time.get_ticks_msec() + timeout_ms
		_thread.start(_watch)

	## Fin de la requête : arrête la surveillance ; vrai si le délai a été dépassé (service arrêté).
	func finish() -> bool:
		_mutex.lock()
		_done = true
		_mutex.unlock()
		_thread.wait_to_finish()
		return _fired

	func _watch() -> void:
		while true:
			_mutex.lock()
			var done := _done
			if not done and Time.get_ticks_msec() >= _deadline:
				_fired = true
				done = true
			var fire := _fired
			_mutex.unlock()
			if fire:
				OS.kill(_pid)
				return
			if done:
				return
			OS.delay_usec(POLL_USEC)
