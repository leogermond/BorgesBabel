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
## recherche, start_timeout_ms au lancement), lui et tous ses descendants (un interpréteur lancé
## par un lanceur tient le même tube) ; la lecture bloquée finit alors aussitôt, l'appel rend une
## erreur (last_error) et le service est relancé à la requête suivante. Un lancement trop lent est
## réessayé après start_retry_ms (doublé à chaque nouvel échec) ; seul un Python absent est un
## échec durable (« Python introuvable », jusqu'à restart()).
##
## Interpréteur : le réglage de projet `babel/python_command` (par exemple `py -3` ou un chemin
## entre guillemets) ; à défaut `py -3`, `python`, puis `python3` sous Windows, `python3` ailleurs.
## Sous Windows, le lanceur `py` est remplacé par le python.exe qu'il choisit (direct_command).
## Sans Python, les pages affichent le message d'erreur et le journal le reprend.
##
## Un second service, sur son propre fil, répond aux requêtes qui ne doivent pas coûter une image
## au fil principal (submit, take : voir « Service d'arrière-plan »).

const BookSpineScript := preload("res://scripts/book_spine.gd")
const BookTextScript := preload("res://scripts/book_text.gd")

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

## Délai de relance au plus après des lancements trop lents (voir _start).
const START_RETRY_MAX_MS := 60000
## Délai de la question au lanceur Windows `py` (direct_command).
const RESOLVE_TIMEOUT_MS := 5000
## Descendants d'un processus relevés au plus (_kill_tree).
const KILL_TREE_LIMIT := 64

## Délais de réponse du service, en millisecondes.
static var timeout_ms := 3000
static var search_timeout_ms := 10000
static var start_timeout_ms := 20000
## Attente avant de relancer un service qui ne s'est pas lancé à temps (doublée à chaque échec).
static var start_retry_ms := 5000

## Dernière erreur du service (vide quand tout va bien).
static var last_error := ""
## La réponse complète de la dernière recherche réussie (key, is_image, text_pages, truncated,
## notice…), sans l'adresse, rendue par search_text et search_image.
static var last_search: Dictionary = {}
static var _stdio: FileAccess
static var _stderr: FileAccess
static var _pid := -1
static var _unavailable := false         # Python absent : jusqu'à restart()
static var _unavailable_message := ""
static var _start_failure := ""          # dernier lancement trop lent (réessayé après _retry_at_msec)
static var _start_code := "unavailable"  # code d'erreur du dernier lancement manqué
static var _retry_at_msec := 0
static var _start_backoff_ms := 0
static var _direct_commands: Dictionary = {}   # commande du lanceur `py` → python.exe (direct_command)
# Service d'arrière-plan (voir submit) : état partagé avec son fil, sous _bg_mutex.
static var _bg_mutex := Mutex.new()
static var _bg_semaphore := Semaphore.new()
static var _bg_thread: Thread
static var _bg_jobs: Array = []          # [ticket, requête ou Callable, délai]
static var _bg_results: Dictionary = {}  # ticket → réponse
static var _bg_cancelled: Dictionary = {}
static var _bg_quit := false
static var _bg_pid := -1
static var _bg_busy := 0
static var _bg_next := 0
static var _bg_commands: Array = []      # relevés sur le fil principal à la création du fil
static var _bg_script := ""
static var _bg_start_timeout := 20000
static var _bg_timeout := 3000
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
	var out := ""
	var rest := value
	while rest != 0:
		out = B25_DIGITS[absi(rest % 25)] + out
		@warning_ignore("integer_division")
		rest = rest / 25   # division tronquée vers zéro : aucun débordement, même pour -2^63
	return "-" + out if value < 0 else out


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
			@warning_ignore("integer_division")
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

## Arrête le service, et celui d'arrière-plan (appelé à la fermeture du jeu par l'autoload
## BabelService). Toute la famille de processus du service est arrêtée (voir _kill_tree).
static func shutdown() -> void:
	if _pid > 0:
		_kill_tree(_pid)
	_pid = -1
	_stdio = null
	_stderr = null
	_keys.clear()
	_bg_stop()


## Oublie tout échec de lancement (Python absent, délai de lancement) : le prochain appel relance
## la recherche de l'interpréteur.
static func restart() -> void:
	shutdown()
	_unavailable = false
	_unavailable_message = ""
	_start_failure = ""
	_retry_at_msec = 0
	_start_backoff_ms = 0


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
## répond pas dans le délai (`timeout`, en ms ; timeout_ms par défaut). Fil principal seulement
## (le fil d'arrière-plan a son propre processus : submit).
static func _request(request: Dictionary, timeout := -1) -> Dictionary:
	if _stdio == null and not _start():
		return {"error": last_error, "code": _start_code}
	var limit := timeout if timeout > 0 else timeout_ms
	var watchdog := Watchdog.new()
	watchdog.start(_pid, limit)
	var response := _exchange_on(_stdio, request)
	if watchdog.finish():
		_pid = -1   # déjà arrêté par le chien de garde
		shutdown_main()
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


## Arrête le service du fil principal seulement (le service d'arrière-plan continue).
static func shutdown_main() -> void:
	if _pid > 0:
		_kill_tree(_pid)
	_pid = -1
	_stdio = null
	_stderr = null
	_keys.clear()


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
	if pid > 0:
		_kill_tree(pid)
	_pid = -1
	shutdown_main()
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


static func _exchange_on(stdio: FileAccess, request: Dictionary) -> Dictionary:
	stdio.store_line(JSON.stringify(request))
	stdio.flush()
	var line := stdio.get_line()
	if line.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(line)
	return parsed if parsed is Dictionary else {"error": "réponse illisible : %s" % line.left(200)}


## Lance le service du fil principal. Trois issues :
## - Python absent (aucune commande ne se lance, ou aucune ne répond au protocole) : échec durable,
##   « Python introuvable », jusqu'à restart() ;
## - lancement trop lent (le ping n'a pas répondu en start_timeout_ms : machine chargée, antivirus,
##   lanceur qui attend…) : échec passager, la requête suivante réessaie après un délai
##   (start_retry_ms, doublé à chaque nouvel échec jusqu'à START_RETRY_MAX_MS) ;
## - succès : les délais repartent de zéro.
static func _start() -> bool:
	if _unavailable:
		last_error = _unavailable_message
		_start_code = "unavailable"
		return false
	var now := Time.get_ticks_msec()
	if now < _retry_at_msec:
		last_error = "%s ; nouvel essai dans %.0f s" % [_start_failure, ceilf((_retry_at_msec - now) / 1000.0)]
		_start_code = "start_timeout"
		return false
	var launched := _launch(_launch_commands(), ProjectSettings.globalize_path(SCRIPT_PATH), start_timeout_ms)
	if launched.has("error"):
		_start_code = launched.code
		if launched.code == "start_timeout":
			_start_backoff_ms = clampi(_start_backoff_ms * 2, start_retry_ms, maxi(start_retry_ms, START_RETRY_MAX_MS))
			_retry_at_msec = Time.get_ticks_msec() + _start_backoff_ms
			_start_failure = launched.error
			last_error = "%s : nouvel essai à la prochaine requête, dans %.1f s au plus tôt" % [launched.error, _start_backoff_ms / 1000.0]
		else:
			_unavailable = true
			_unavailable_message = launched.error
			last_error = launched.error
		push_error(last_error)
		return false
	_stdio = launched.stdio
	_stderr = launched.stderr
	_pid = launched.pid
	_start_backoff_ms = 0
	_start_failure = ""
	_retry_at_msec = 0
	last_error = ""
	return true


## Lance `python … babel.py serve` avec la première commande qui répond au ping :
## {stdio, stderr, pid}, ou {error, code} avec code « start_timeout » (une commande s'est lancée
## mais n'a pas répondu dans `timeout` ms : réessayable, les suivantes ne sont pas essayées) ou
## « unavailable » (aucune ne convient). `on_spawn(pid)`, facultatif, reçoit le processus dès
## son lancement (le fil d'arrière-plan le publie pour qu'un arrêt l'atteigne pendant le ping).
## Sans état partagé : sert au fil principal comme au fil d'arrière-plan.
static func _launch(commands: Array, script: String, timeout: int, on_spawn := Callable()) -> Dictionary:
	var tried := PackedStringArray()
	for command: Array in commands:
		var args := PackedStringArray(command.slice(1))
		args.append_array(["-X", "utf8", "-u", script, "serve"])
		tried.append(" ".join(command))
		var process := OS.execute_with_pipe(command[0], args)
		if process.is_empty():
			continue
		if on_spawn.is_valid():
			on_spawn.call(process.pid)
		var watchdog := Watchdog.new()
		watchdog.start(process.pid, timeout)
		var answer := _exchange_on(process.stdio, {"op": "ping"})
		var fired := watchdog.finish()
		if not fired and answer.get("protocol") == PROTOCOL:
			return process
		_kill_tree(process.pid)
		if on_spawn.is_valid():
			on_spawn.call(-1)
		if fired:
			return {"code": "start_timeout", "error": "le service Python (« %s ») ne s'est pas lancé en %.1f s" % [" ".join(command), timeout / 1000.0]}
	return {"code": "unavailable", "error": "Python 3.10 ou plus est introuvable (essayé : %s). Installer Python, ou indiquer la commande dans le réglage de projet %s." % [", ".join(tried), PYTHON_SETTING]}


## Les commandes candidates, chacune en tableau [exécutable, arguments…].
static func _interpreters() -> Array:
	var setting := str(ProjectSettings.get_setting(PYTHON_SETTING, "")).strip_edges()
	if not setting.is_empty():
		return [_split_command(setting)]
	if OS.get_name() == "Windows":
		return [["py", "-3"], ["python"], ["python3"]]
	return [["python3"]]


## Les commandes à lancer : celles de _interpreters, le lanceur Windows `py` remplacé par le
## python.exe qu'il choisit (direct_command) : le service n'a alors qu'un processus.
static func _launch_commands() -> Array:
	var commands := []
	for command: Array in _interpreters():
		commands.append(direct_command(command) if OS.get_name() == "Windows" else command)
	return commands


## Sous Windows, `py -3` lance python.exe dans un second processus : la commande devient le
## chemin de cet interpréteur (sys.executable, demandé une fois au lanceur, sous un délai de
## RESOLVE_TIMEOUT_MS), suivi des arguments qui ne sont pas des sélecteurs de version du lanceur
## (-3, -3.12, -V:3.12…). Toute autre commande, ou un lanceur qui ne répond pas, reste telle quelle.
static func direct_command(command: Array) -> Array:
	if command.is_empty() or str(command[0]).get_file().get_basename().to_lower() != "py":
		return command
	var key := " ".join(command)
	if _direct_commands.has(key):
		return _direct_commands[key]
	var resolved := command
	var args := PackedStringArray(command.slice(1))
	args.append_array(["-c", "import sys; print(sys.executable)"])
	var process := OS.execute_with_pipe(command[0], args)
	if not process.is_empty():
		var watchdog := Watchdog.new()
		watchdog.start(process.pid, RESOLVE_TIMEOUT_MS)
		var path: String = process.stdio.get_line().strip_edges()
		watchdog.finish()
		if not path.is_empty() and FileAccess.file_exists(path):
			resolved = [path]
			for arg: String in command.slice(1):
				if not launcher_selector(arg):
					resolved.append(arg)
	_direct_commands[key] = resolved
	return resolved


## Vrai pour un argument propre au lanceur `py` (choix de version : -3, -3.12, -3-64, -V:3.12).
static func launcher_selector(arg: String) -> bool:
	return arg.begins_with("-V:") or RegEx.create_from_string("^-[23](\\.[0-9]+)?(-(32|64))?$").search(arg) != null


## Arrête un processus et tous ses descendants : un interpréteur lancé par un lanceur (`py -3`
## sous Windows, `uv run` ailleurs) est un enfant du processus lancé et tient le même tube ; tant
## qu'il vit, la lecture bloquée ne finit pas. Windows : `taskkill /T /F` (l'arbre entier). Linux :
## les descendants relevés dans /proc (fichiers children, à défaut le parent de chaque processus),
## macOS et autres : `pgrep -P` ; tous relevés avant le premier arrêt (un orphelin change de
## parent), puis le processus et ses descendants arrêtés (SIGKILL).
static func _kill_tree(pid: int) -> void:
	if pid <= 0:
		return
	if OS.get_name() == "Windows":
		OS.execute("taskkill", ["/T", "/F", "/PID", str(pid)])
		if OS.is_process_running(pid):
			OS.kill(pid)
		return
	var family := descendants(pid)
	OS.kill(pid)
	for child in family:
		OS.kill(child)


## Les descendants d'un processus (enfants, petits-enfants…), au plus KILL_TREE_LIMIT.
static func descendants(pid: int) -> PackedInt64Array:
	var found := PackedInt64Array()
	var frontier: Array[int] = [pid]
	while not frontier.is_empty() and found.size() < KILL_TREE_LIMIT:
		for child in _children(frontier.pop_back()):
			if child != pid and not found.has(child):
				found.append(child)
				frontier.append(child)
	return found


static func _children(pid: int) -> PackedInt64Array:
	var children := PackedInt64Array()
	var tasks := "/proc/%d/task" % pid
	if DirAccess.dir_exists_absolute("/proc/self"):
		var listed := false
		if DirAccess.dir_exists_absolute(tasks):
			for task in DirAccess.get_directories_at(tasks):
				var path := "%s/%s/children" % [tasks, task]
				if not FileAccess.file_exists(path):
					continue
				listed = true
				for word in _read_proc(path).split(" ", false):
					children.append(int(word))
		if not listed:   # noyau sans fichiers children : le parent de chaque processus
			for entry in DirAccess.get_directories_at("/proc"):
				if entry.is_valid_int():
					var stat := _read_proc("/proc/%s/stat" % entry)
					var fields := stat.substr(stat.rfind(")") + 2).split(" ")
					if fields.size() > 1 and int(fields[1]) == pid:
						children.append(int(entry))
		return children
	var output := []
	OS.execute("pgrep", ["-P", str(pid)], output)
	for line in "".join(output).split("\n", false):
		if line.strip_edges().is_valid_int():
			children.append(int(line.strip_edges()))
	return children


## Contenu d'un fichier de /proc (longueur annoncée nulle : lu ligne à ligne).
static func _read_proc(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text := ""
	while not file.eof_reached():
		var line := file.get_line()
		text += line + " "
		if text.length() > 65536:
			break
	return text.strip_edges()


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


# --- Service d'arrière-plan ---------------------------------------------------------------------
# Un second processus `babel.py serve`, propre à un fil : le fil principal n'en attend jamais la
# réponse. Il sert aux calculs qui ne doivent pas coûter une image (genres des livres d'une galerie
# pour les titres des dos, résumé d'une coordonnée pour l'adresse affichée). submit() met une
# requête en file et rend un ticket ; take(ticket) rend la réponse une fois arrivée (null avant).
# Une requête peut être un Callable qui rend la requête : il s'appelle sur le fil (une coordonnée
# de 656 000 chiffres s'y calcule et s'y sérialise, hors du fil principal). Le fil a ses propres
# délais (chien de garde, relance après un lancement trop lent) ; shutdown() arrête son processus
# (la lecture en cours finit aussitôt) et attend le fil ; les requêtes encore en file reçoivent
# une erreur de code « stopped ».

## Met une requête (Dictionary, ou Callable sans argument qui la rend) en file pour le service
## d'arrière-plan ; rend son ticket.
static func submit(request: Variant, timeout := -1) -> int:
	b25_valid("0")   # expressions régulières créées ici, sur le fil principal
	if _bg_thread == null:
		_bg_commands = _launch_commands()
		_bg_script = ProjectSettings.globalize_path(SCRIPT_PATH)
		_bg_start_timeout = start_timeout_ms
		_bg_timeout = timeout_ms
		_bg_quit = false
		_bg_thread = Thread.new()
		_bg_thread.start(_bg_loop)
	_bg_mutex.lock()
	_bg_next += 1
	var ticket := _bg_next
	_bg_jobs.append([ticket, request, timeout])
	_bg_mutex.unlock()
	_bg_semaphore.post()
	return ticket


## La réponse d'un ticket (retirée de la mémoire), ou null tant qu'elle n'est pas arrivée.
static func take(ticket: int) -> Variant:
	_bg_mutex.lock()
	var response: Variant = _bg_results.get(ticket)
	_bg_results.erase(ticket)
	_bg_mutex.unlock()
	return response


## Oublie un ticket : retiré de la file s'il y attend, sa réponse jetée si elle arrive.
static func cancel(ticket: int) -> void:
	_bg_mutex.lock()
	for i in range(_bg_jobs.size() - 1, -1, -1):
		if _bg_jobs[i][0] == ticket:
			_bg_jobs.remove_at(i)
	if not _bg_results.erase(ticket):
		_bg_cancelled[ticket] = true
	_bg_mutex.unlock()


## Requêtes en file ou en cours sur le fil d'arrière-plan.
static func pending() -> int:
	_bg_mutex.lock()
	var count := _bg_jobs.size() + _bg_busy
	_bg_mutex.unlock()
	return count


## Les genres des 640 livres de la galerie (hexagone, niveau) = (hexagon_base + dh, level_base +
## dl), demandés au service d'arrière-plan (forme « gallery » de is_image_book) : rend un ticket ;
## la réponse porte « is_image » (640 valeurs) ou « error ». Les coordonnées (base 25, toute
## taille) se calculent sur le fil.
static func submit_gallery_flags(hexagon_base: String, dh: int, level_base: String, dl: int) -> int:
	return submit(func() -> Dictionary:
		return {"op": "is_image_book", "gallery": {
			"hexagon": BookTextScript.b25_add_small(hexagon_base, dh), "level": BookTextScript.b25_add_small(level_base, dl)}})


static func _bg_stop() -> void:
	if _bg_thread == null:
		return
	_bg_mutex.lock()
	_bg_quit = true
	var pid := _bg_pid
	for job: Array in _bg_jobs:
		_bg_store(job[0], {"error": "service d'arrière-plan arrêté", "code": "stopped"})
	_bg_jobs.clear()
	_bg_mutex.unlock()
	_kill_tree(pid)   # la lecture en cours (s'il y en a une) finit aussitôt
	_bg_semaphore.post()
	_bg_thread.wait_to_finish()
	_bg_thread = null
	_bg_pid = -1
	_bg_busy = 0
	_bg_semaphore = Semaphore.new()


## Range une réponse (mutex tenu).
static func _bg_store(ticket: int, response: Dictionary) -> void:
	if _bg_cancelled.erase(ticket):
		return
	_bg_results[ticket] = response


static func _bg_publish_pid(pid: int) -> void:
	_bg_mutex.lock()
	_bg_pid = pid
	var quitting := _bg_quit
	_bg_mutex.unlock()
	if quitting and pid > 0:
		_kill_tree(pid)


## Le fil d'arrière-plan : une requête après l'autre, sur son propre processus.
static func _bg_loop() -> void:
	var stdio: FileAccess = null
	var pid := -1
	var retry_at := 0
	var backoff := 0
	var failure := {}
	while true:
		_bg_semaphore.wait()
		_bg_mutex.lock()
		var quit := _bg_quit
		var job: Array = [] if quit or _bg_jobs.is_empty() else _bg_jobs.pop_front()
		_bg_busy = 0 if job.is_empty() else 1
		_bg_mutex.unlock()
		if quit:
			break
		if job.is_empty():
			continue
		var response := {}
		if stdio == null:
			if failure.get("code") == "unavailable":
				response = failure
			elif Time.get_ticks_msec() < retry_at:
				response = failure
			else:
				var launched := _launch(_bg_commands, _bg_script, _bg_start_timeout, _bg_publish_pid)
				if launched.has("error"):
					failure = launched
					if launched.code == "start_timeout":
						backoff = clampi(backoff * 2, start_retry_ms, maxi(start_retry_ms, START_RETRY_MAX_MS))
						retry_at = Time.get_ticks_msec() + backoff
					response = failure
				else:
					stdio = launched.stdio
					pid = launched.pid
					backoff = 0
					failure = {}
		if response.is_empty():
			var request: Variant = job[1].call() if job[1] is Callable else job[1]
			var limit: int = job[2] if job[2] > 0 else _bg_timeout
			var watchdog := Watchdog.new()
			watchdog.start(pid, limit)
			response = _exchange_on(stdio, request)
			var fired := watchdog.finish()
			if fired or response.is_empty():
				if not fired:   # le chien de garde l'a déjà arrêté
					_kill_tree(pid)
				stdio = null
				pid = -1
				_bg_publish_pid(-1)
				response = {"error": "le service d'arrière-plan n'a pas répondu en %.1f s" % (limit / 1000.0), "code": "timeout"} if fired \
					else {"error": "le service d'arrière-plan s'est arrêté pendant la requête", "code": "stopped"}
		_bg_mutex.lock()
		_bg_store(job[0], response)
		_bg_busy = 0
		_bg_mutex.unlock()
	if pid > 0:
		_kill_tree(pid)


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
## pas finie à l'échéance. Arrêter le processus et ses descendants ferme ses tubes : l'écriture
## ou la lecture bloquée du fil qui attend se termine aussitôt (fin de fichier).
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
				BookTextScript._kill_tree(_pid)   # le processus et ses descendants (lanceur)
				return
			if done:
				return
			OS.delay_usec(POLL_USEC)
