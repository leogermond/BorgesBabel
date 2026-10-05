extends SceneTree
## Vérifie la quête : arithmétique décimale (contre-épreuve par Python), guidage, catalogue
## (chaque page relue au service et comparée à son condensat), épingles, Hud et carnet.
## godot --headless --path . -s tests/test_quest.gd

const QuestScript := preload("res://scripts/quest.gd")
const HudScript := preload("res://scripts/hud.gd")
const CarnetScript := preload("res://scripts/carnet.gd")
const BookTextScript := preload("res://scripts/book_text.gd")
const PINS_TEST_PATH := "user://test_quete_epinglees.json"
const ARITH_CASES_PATH := "user://test_quete_arith.json"
const ARITH_SCRIPT_PATH := "user://test_quete_arith.py"
## Contre-épreuve de l'arithmétique base 25 de BookText par les entiers de Python (conversions
## sous-quadratiques de babel.py) : lit [[a, b, k], …] et écrit une ligne JSON, pour chaque cas,
## {add : a + k en base 25, sign_diff, exact, value, digits_diff : différence a − b résumée comme
## b25_difference, cmp, sign : signe de a, digits : chiffres décimaux de |a|}.
const ARITH_CHECK := """
import json, sys
sys.path.insert(0, sys.argv[2])
import babel
def digits10(x):
    x = abs(x)
    if x < 10:
        return 1
    k = max(1, int((x.bit_length() - 1) * 0.30102999566398114))
    p = 10 ** k
    while p <= x:
        p *= 10
        k += 1
    return k
M1, M2 = 25 ** 8 - 1, 25 ** 8 + 1
out = []
for a, b, k in json.load(open(sys.argv[1], encoding='utf-8')):
    y = babel.b25_to_int(b)
    if isinstance(a, dict):   # a = b ± (10^p + delta) : différence au ras d'une puissance de dix
        x = y + a['sign'] * (10 ** a['pow10'] + a['delta'])
    else:
        x = babel.b25_to_int(a)
    d = x - y
    exact = abs(d) < 25 ** 12
    out.append({'a': babel.int_to_b25(x) if isinstance(a, dict) else a, 'add': babel.int_to_b25(x + k), 'sign_diff': (d > 0) - (d < 0),
                'exact': exact, 'value': str(d) if exact else '', 'digits_diff': digits10(d),
                'cmp': (x > y) - (x < y), 'sign': (x > 0) - (x < 0), 'digits': digits10(x),
                'print': [x % M1, x % M2], 'print_add': [(x + k) % M1, (x + k) % M2]})
print(json.dumps(out))
"""
const ENTRY_KEYS := ["id", "title", "author", "year", "language", "context", "group", "licence", "protected", "address", "page_count", "pages", "notice_book", "notice_hash"]

var _failures := 0
## Événements parvenus au « jeu » (un nœud placé avant le Hud, servi après lui comme main.gd).
var _game_events: Array = []
var _game: Node
var _jumps: Array = []


func _initialize() -> void:
	_test_arithmetic()
	_test_guidance()
	_test_catalogue()
	_test_pins()
	await _test_hud()
	_test_direction_glyph()
	await _test_main_panel()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PINS_TEST_PATH))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(ARITH_CASES_PATH))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(ARITH_SCRIPT_PATH))
	print("test_quest : %s" % ("OK" if _failures == 0 else "%d échec(s)" % _failures))
	BookTextScript.shutdown()
	quit(1 if _failures else 0)


# --- Arithmétique -------------------------------------------------------------------------------

func _test_arithmetic() -> void:
	_check(BookTextScript.b25("+007") == "7" and BookTextScript.b25("-00C") == "-c", "forme canonique de « +007 » et « -00C »")
	_check(BookTextScript.b25("-000") == "0", "« -000 » vaut 0, sans signe")
	_check(BookTextScript.b25(-625) == "-100" and BookTextScript.b25(24) == "o" and BookTextScript.b25(105) == "45"
		and BookTextScript.b25(-9223372036854775807 - 1) == "-64ie1focnn5g78", "entiers → base 25 (jusqu'à -2^63)")
	_check(BookTextScript.b25_fits_int("32970kc6bo2kg4") and not BookTextScript.b25_fits_int("32970kc6bo2kg5") and BookTextScript.b25_to_int("-32970kc6bo2kg4") == -(1 << 62),
		"les coordonnées jusqu'à 2^62 se calculent en int")
	_check(BookTextScript.b25_add_small("o", 1) == "10" and BookTextScript.b25_add_small("-1", 1) == "0" and BookTextScript.b25_add_small("0", -1) == "-1", "±1 autour de 0 et de 25")
	for bad in ["12p", "-", "", "1 2", "1\t2", "12\n", "+-1", "１２", "-٣", "x"]:
		_check(not BookTextScript.b25_valid(bad) and BookTextScript.b25(bad).is_empty(), "« %s » refusé (sans erreur de décodage)" % bad.c_escape())

	# Contre-épreuve par les entiers de Python : ±k, différence résumée, comparaison, signe, chiffres décimaux.
	var rng := RandomNumberGenerator.new()
	rng.seed = 2234
	var huge := _b25_digits(rng, 656000)     # ~917 000 chiffres décimaux, comme une adresse trouvée
	var big_a := _b25_digits(rng, 2234)
	var big_b := _b25_digits(rng, 2100)
	var cascade := "1" + "0".repeat(3000) + "5"           # emprunt en cascade sur 3000 chiffres
	var under := "o".repeat(3001)
	var cases := [
		[big_a, big_b, 1], ["-" + big_a, big_b, -1], [big_a, "-" + big_b, 7], ["-" + big_a, "-" + big_b, -7],
		[big_a, big_a, 0], ["-" + big_a, big_a, 1], [big_b, big_a, 24], ["o".repeat(2050), "1", 1],
		["1" + "0".repeat(2049), "1", -1], ["0", "-" + big_b, 5], ["-" + "o".repeat(40), "-1", -1],
		[cascade, under, 1], [under, cascade, -1], ["-" + cascade, "-" + under, 3],
		[big_a, big_a.left(-3) + "000", 2], [big_a.left(-14) + "1" + "0".repeat(13), big_a.left(-14) + "0" + "o".repeat(13), 1],
		[huge, huge.left(-5) + "00000", 25], [huge, "-" + huge.left(-1), -1], ["-" + huge, huge.left(-2) + "oo", 1],
		[huge, huge, -24], ["1" + "0".repeat(2233), "-c", 1], ["-" + "4".repeat(2234), "7", 1],
		[BookTextScript.b25_from_int(4611686018427387904), "-" + BookTextScript.b25_from_int(4611686018427387904), 1],
	]
	for _i in 8:
		cases.append([("-" if rng.randi() % 2 else "") + _b25_digits(rng, rng.randi_range(1, 2300)),
			("-" if rng.randi() % 2 else "") + _b25_digits(rng, rng.randi_range(1, 2300)), rng.randi_range(-30, 30)])
	# Au ras d'une puissance de dix, de 10^12 à 10^20000 : a − b = ±(10^p + δ), δ ∈ {−1, 0, 1}, b de
	# toute taille (le nombre de chiffres de a − b, et de a quand b = 0, se tranche exactement).
	for p: int in [12, 17, 18, 25, 100, 999, 4000, 12345, 20000]:
		for delta: int in [-1, 0, 1]:
			var base: String = ["0", _b25_digits(rng, 30), "-" + _b25_digits(rng, 5000), _b25_digits(rng, 20000)][(p + delta + 1) % 4]
			cases.append([{"pow10": p, "delta": delta, "sign": 1 if (p + delta) % 3 else -1}, base, 1])
	var file := FileAccess.open(ARITH_CASES_PATH, FileAccess.WRITE)
	file.store_string(JSON.stringify(cases))
	file.close()
	file = FileAccess.open(ARITH_SCRIPT_PATH, FileAccess.WRITE)
	file.store_string(ARITH_CHECK)
	file.close()
	var command: Array = BookTextScript._interpreters()[0]
	var args := PackedStringArray(command.slice(1))
	args.append_array([ProjectSettings.globalize_path(ARITH_SCRIPT_PATH), ProjectSettings.globalize_path(ARITH_CASES_PATH),
		ProjectSettings.globalize_path("res://python")])
	var output := []
	var code := OS.execute(command[0], args, output, true)
	var expected: Variant = JSON.parse_string(output[0] if code == 0 and not output.is_empty() else "")
	_check(expected is Array and expected.size() == cases.size(), "Python rend la contre-épreuve de %d cas (code %d)" % [cases.size(), code])
	if not expected is Array or expected.size() != cases.size():
		return
	var mismatches := 0
	var worst_usec := 0
	var print_mismatches := 0
	for i in cases.size():
		var want: Dictionary = expected[i]
		var a: String = want.a
		var b: String = cases[i][1]
		var k: int = cases[i][2]
		var t := Time.get_ticks_usec()
		var d := BookTextScript.b25_difference(a, b)
		worst_usec = maxi(worst_usec, Time.get_ticks_usec() - t)
		var exact_ok: bool = d.exact == want.exact and (not d.exact or str(d.value) == want.value)
		if BookTextScript.b25_add_small(a, k) != want.add or d.sign != int(want.sign_diff) or not exact_ok \
				or d.digits != int(want.digits_diff) or BookTextScript.b25_compare(a, b) != int(want.cmp) \
				or BookTextScript.b25_sign(a) != int(want.sign) or BookTextScript.b25_decimal_digits(a) != int(want.digits):
			mismatches += 1
			print("    écart sur le cas %d (%d et %d chiffres) : %s / %s ; chiffres de a : %d / %d" % [i, a.length(), b.length(), d,
				{"sign": want.sign_diff, "exact": want.exact, "digits": want.digits_diff}, BookTextScript.b25_decimal_digits(a), int(want.digits)])
		var print_a := BookTextScript.b25_print(a)
		var want_print := PackedInt64Array(want.print)
		var want_add := PackedInt64Array(want.print_add)
		if print_a != want_print or BookTextScript.print_add(print_a, k) != want_add \
				or BookTextScript.b25_print(BookTextScript.b25_add_small(a, k)) != want_add:
			print_mismatches += 1
			print("    empreinte : écart sur le cas %d (%d chiffres) : %s, attendu %s" % [i, a.length(), print_a, want_print])
	_check(mismatches == 0, "±k, différence (signe, valeur exacte ou chiffres décimaux), comparaison, signe, chiffres : identiques à Python sur %d cas de 1 à 656 000 chiffres, dont 27 au ras de 10^12 … 10^20000" % cases.size())
	_check(print_mismatches == 0, "empreintes (restes modulo 25^8 ∓ 1) : identiques à Python, et print_add(empreinte, k) = empreinte de la coordonnée ± k, relue (%d cas)" % cases.size())
	var t_print := Time.get_ticks_usec()
	BookTextScript._print_cache.clear()
	BookTextScript.b25_print(huge)
	print("    empreinte d'une coordonnée de 656 000 chiffres : %.1f ms" % ((Time.get_ticks_usec() - t_print) / 1000.0))
	print("    différence résumée la plus lente : %.1f ms" % (worst_usec / 1000.0))


## Un nombre de `count` chiffres base 25, sans zéro de tête.
static func _b25_digits(rng: RandomNumberGenerator, count: int) -> String:
	var bytes := PackedByteArray()
	bytes.resize(count)
	for i in count:
		bytes[i] = BookTextScript.B25_DIGITS.unicode_at(rng.randi_range(1 if i == 0 else 0, 24))
	return bytes.get_string_from_ascii()


# --- Guidage ------------------------------------------------------------------------------------

func _test_guidance() -> void:
	var quest := QuestScript.from_address({"hexagon": BookTextScript.b25(105), "level": "-3", "wall": 1, "shelf": 2, "book": 16, "page": 204}, "Titre", "Auteur")
	_check(quest != null and quest.label() == "Titre — Auteur", "quête sur une adresse, « titre — auteur »")
	var g := quest.guidance(100, 0)
	_check(g.dz.exact and g.dz.value == 5 and g.dy.value == -3 and g.hall == 1 and g.vert == -1 and not g.here, "différences signées depuis (100, 0) : +5, -3")
	_check(g.hall_text == "couloir : 5 galeries vers +Z", "couloir : %s" % g.hall_text)
	_check(g.level_text == "étages : 3 niveaux vers le bas", "étages : %s" % g.level_text)
	_check(g.book_text == "dans la galerie : mur 2 · étagère 3 · livre 17 · page 205", "cote : %s" % g.book_text)
	g = quest.guidance(106, -4)
	_check(g.hall_text == "couloir : 1 galerie vers −Z" and g.level_text == "étages : 1 niveau vers le haut", "singulier et sens inverses : %s / %s" % [g.hall_text, g.level_text])
	g = quest.guidance(BookTextScript.b25(105), "-3")
	_check(g.here and g.hall_text == "couloir : ici" and g.level_text == "étages : ici", "dans la galerie visée (coordonnées base 25) : ici")
	g = quest.guidance(104, -3, Vector2i(-1, 0))
	_check(g.hall_text == "couloir : 1 galerie vers +Z" and g.level_text == "étages : ici", "un pas en arrière suivi sans relire les coordonnées : %s" % g.hall_text)
	_check(quest.target_in_gallery(105, -3) == {"wall": 1, "shelf": 2, "book": 16, "page": 204}, "livre visé dans la galerie")
	_check(quest.target_in_gallery(105, -2).is_empty(), "aucun livre visé ailleurs")
	_check(quest.address() == {"hexagon": "45", "level": "-3", "wall": 1, "shelf": 2, "book": 16, "page": 204}, "adresse de la page visée : le livre et sa page")

	# Loin : « ≈ 10^N » en chiffres décimaux (25^2233 a 3122 chiffres, 4…4 sur 2234 chiffres base 25, 3123).
	var far := QuestScript.from_address({"hexagon": "1" + "0".repeat(2233), "level": "-" + "4".repeat(2234), "wall": 0, "shelf": 0, "book": 0})
	g = far.guidance(-12, 7)
	_check(g.hall_text == "couloir : ≈ 10^3121 galeries vers +Z", "grande distance : %s" % g.hall_text)
	_check(g.level_text == "étages : ≈ 10^3122 niveaux vers le bas", "grande hauteur : %s" % g.level_text)
	var stepped := far.guidance(-11, 7, Vector2i(1, 0))
	_check(stepped.hall_text == g.hall_text and stepped.dz.digits == g.dz.digits, "un pas ne change pas un ordre de grandeur")
	_check(QuestScript.magnitude_text(BookTextScript._exact_difference(-999999999999999)) == "999999999999999", "15 chiffres : valeur exacte")
	_check(QuestScript.magnitude_text(BookTextScript._exact_difference(1000000000000000)) == "≈ 10^15", "16 chiffres : ordre de grandeur")
	_check(QuestScript.from_address({"hexagon": "1", "level": "x", "wall": 0, "shelf": 0, "book": 0, "page": 0}) == null, "adresse mal formée refusée")
	_check(QuestScript.from_address({"hexagon": "1", "level": "2", "wall": 4, "shelf": 0, "book": 0, "page": 0}) == null, "mur hors de la galerie refusé")
	_check(QuestScript.from_address({"hexagon": "1", "level": "2", "wall": 0, "shelf": 0, "book": 0, "page": 410}) == null, "page hors du livre refusée")
	_check(QuestScript.from_address({"hexagon": "1\t", "level": "2", "wall": 0, "shelf": 0, "book": 0}) == null, "caractère de contrôle refusé")


# --- Catalogue ----------------------------------------------------------------------------------

func _test_catalogue() -> void:
	var entries := QuestScript.load_catalogue()
	var titles := entries.map(func(e: Dictionary) -> String: return e.title)
	_check(titles == ["La biblioteca de Babel", "El Aleph", "El Zahir", "Tlön, Uqbar, Orbis Tertius", "El Golem",
		"Mode d'emploi de la Bibliothèque", "Sur la vertu", "Sur l'humour"], "catalogue : 8 entrées dans l'ordre (lu : %s)" % [titles])
	var raw: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(QuestScript.CATALOGUE_PATH))
	_check(int(raw.version) == QuestScript.CATALOGUE_VERSION and raw.keys().size() == 5, "catalogue version %d : entries, stolen_books, destinations" % QuestScript.CATALOGUE_VERSION)
	var extra := []
	for entry: Dictionary in raw.entries:
		for key: String in entry:
			if not key in ENTRY_KEYS:
				extra.append(key)
		if entry.address.keys().size() != 5:
			extra.append("address")
		for page: Dictionary in entry.pages:
			if page.keys().size() != 2 or not page.has("page") or not page.has("sha256"):
				extra.append("pages")
	_check(extra.is_empty(), "le catalogue ne porte que des métadonnées, des adresses de livres et des condensats (en trop : %s)" % [extra])
	var borges := entries.filter(func(e: Dictionary) -> bool: return e.author == "Jorge Luis Borges")
	_check(borges.size() == 5 and borges.all(func(e: Dictionary) -> bool: return e.protected and e.page_count >= 2 and e.pages.size() == e.page_count),
		"5 livres protégés de Borges : la citation et la loi en page 1, le texte français ensuite (pages : %s)" % [borges.map(func(e: Dictionary) -> int: return e.page_count)])
	var claude := entries.filter(func(e: Dictionary) -> bool: return e.author == "Claude")
	_check(claude.size() == 3 and claude.all(func(e: Dictionary) -> bool: return e.licence == "texte original écrit pour le jeu" and e.pages.size() == 1),
		"3 textes de Claude, un livre d'une page chacun, « texte original écrit pour le jeu »")
	var books := {}
	for entry: Dictionary in entries:
		_check(not entry.author.strip_edges().is_empty() and not entry.context.strip_edges().is_empty(), "%s : auteur et contexte présents" % entry.title)
		books[entry.address] = true
	_check(books.size() == entries.size(), "chaque entrée a son propre livre")
	var start := Time.get_ticks_usec()
	for entry: Dictionary in entries:
		var numbers: Array = entry.pages.map(func(p: Dictionary) -> int: return p.page)
		_check(numbers == range(entry.page_count), "%s : pages consécutives du livre, à partir de la première (%s)" % [entry.title, numbers])
		for page: Dictionary in entry.pages:
			var text := "".join(BookTextScript.page_lines_at(entry.address, page.page))
			_check(text.length() == 3200 and text.sha256_text() == page.sha256, "%s, page %d : relue au service, elle a le condensat du catalogue" % [entry.title, page.page + 1])
		_check("".join(BookTextScript.page_lines_at(entry.address, entry.page_count)) == " ".repeat(3200), "%s : la page qui suit le texte est blanche" % entry.title)
		var flags := BookTextScript.image_books([entry.address])
		_check(flags.size() == 1 and flags[0] == false, "%s : l'adresse est un livre de texte" % entry.title)
	print("    pages du catalogue relues au service : %.1f s" % ((Time.get_ticks_usec() - start) / 1.0e6))
	# Notices : chaque notice est le contenu d'un livre volé à la Bibliothèque.
	for entry: Dictionary in entries:
		var notice := "\n".join([entry.title, entry.author, entry.context])
		var expected := CarnetScript.normalize(notice).rpad(3200)
		_check(expected.length() == 3200 and expected.sha256_text() == entry.notice_hash, "%s : la notice normalisée a le condensat du catalogue" % entry.title)
		var a: Dictionary = entry.get("notice_address", {})
		_check(not a.is_empty() and "".join(BookTextScript.page_lines_at(a, 0)).sha256_text() == entry.notice_hash, "%s : la première page du livre de la notice relue au service a ce condensat" % entry.title)
		if a.is_empty():
			continue
		_check("".join(BookTextScript.page_lines_at(a, 1)) == " ".repeat(3200), "%s : le livre de la notice continue en blanc" % entry.title)
		_check(QuestScript.is_stolen_book(a.hexagon, a.level, a.wall, a.shelf, a.book), "%s : le livre de la notice est volé" % entry.title)
		_check(not QuestScript.is_stolen_book(a.hexagon, a.level, a.wall, a.shelf, (a.book + 1) % 32), "%s : le livre voisin est en place" % entry.title)
		_check(not QuestScript.is_stolen_book(entry.address.hexagon, entry.address.level, entry.address.wall, entry.address.shelf, entry.address.book), "%s : le livre de l'œuvre est en place" % entry.title)
	_check(raw.stolen_books.size() == entries.size(), "stolen_books : un livre par notice (%d)" % raw.stolen_books.size())
	_check(not QuestScript.is_stolen_book("0", "0", 0, 0, 0) and not QuestScript.is_stolen_book(0, 0, 0, 0, 0), "le livre (0, 0, 0, 0, 0) est en place")

	# Destinations : le carré SATOR, page 1 de son livre, sans épingle ; le Golem, encore vide.
	var sator := QuestScript.destination("sator")
	_check(not sator.is_empty() and sator.address.page == 0 and "".join(BookTextScript.page_lines_at(sator.address)).sha256_text() == sator.sha256,
		"destination « sator » : la page 1 de son livre relue au service a son condensat")
	_check(QuestScript.destination("golem").is_empty() and raw.destinations.golem == {}, "destination « golem » : vide pour l'instant")
	var pinned_books := QuestScript.default_pins(entries).filter(func(p: Dictionary) -> bool: return p.kind == QuestScript.KIND_CATALOGUE).size()
	_check(pinned_books == entries.size() and not books.has(BookTextScript.book_of(sator.get("address", {}))), "le livre du carré SATOR n'est pas épinglé")

	var quest := QuestScript.from_entry(entries[0])
	_check(quest != null and quest.pages == range(entries[0].page_count) and quest.book == entries[0].address and quest.author == "Jorge Luis Borges",
		"quête d'une entrée du catalogue : son livre, ses pages")
	var tool := FileAccess.get_file_as_string("res://tools/make_catalogue.py")
	_check(tool.contains("KEY_NAMES = {\"QUETE\": \"%s\", \"EFFACER\": \"%s\"}" % [HudScript.QUEST_KEY_NAME, HudScript.CLEAR_KEY_NAME]),
		"le mode d'emploi reçoit les noms des touches du Hud (%s, %s)" % [HudScript.QUEST_KEY_NAME, HudScript.CLEAR_KEY_NAME])
	_check(QuestScript.load_catalogue("res://absent.json").is_empty(), "catalogue absent → aucune entrée")


# --- Épingles -----------------------------------------------------------------------------------

func _test_pins() -> void:
	var entries := QuestScript.load_catalogue()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PINS_TEST_PATH))
	var pins := QuestScript.load_pins(entries, PINS_TEST_PATH)
	_check(pins.size() == 9 and pins.slice(0, 8).all(func(p: Dictionary) -> bool: return p.kind == QuestScript.KIND_CATALOGUE) and pins[8].kind == QuestScript.KIND_REGISTER,
		"sans fichier : le catalogue entier est épinglé, le registre à la fin")

	var target := {"hexagon": "-123456789012345678901234567890", "level": "42", "wall": 3, "shelf": 4, "book": 31, "page": 409}
	pins = QuestScript.remove_pin(pins, "catalogue:borges-el-zahir")
	pins = QuestScript.add_pin(pins, QuestScript.search_pin("ma recherche", target))
	pins = QuestScript.add_pin(pins, QuestScript.search_pin("ma recherche", target))
	_check(pins.size() == 9 and pins[8].kind == QuestScript.KIND_REGISTER, "désépingler une entrée, épingler une recherche (une seule fois, avant le registre)")
	_check(QuestScript.save_pins(pins, PINS_TEST_PATH), "épingles enregistrées")
	var again := QuestScript.load_pins(entries, PINS_TEST_PATH)
	_check(again.map(func(p: Dictionary) -> String: return p.id) == pins.map(func(p: Dictionary) -> String: return p.id), "épingles relues à l'identique")
	var stored: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(PINS_TEST_PATH))
	var search_stored: Array = stored.pins.filter(func(p: Dictionary) -> bool: return p.kind == QuestScript.KIND_SEARCH)
	_check(search_stored.size() == 1 and search_stored[0].keys().size() == 3, "une recherche s'enregistre en titre et adresse seuls")
	var restored := QuestScript.restore_catalogue(again, entries)
	_check(restored.size() == 10 and QuestScript.missing_catalogue(restored, entries).is_empty() and restored[2].entry == "borges-el-zahir",
		"rétablir remet l'entrée désépinglée à sa place, la recherche reste")
	var quest := QuestScript.from_pin(restored[8], entries)
	_check(quest != null and quest.title == "ma recherche" and quest.address().hexagon == target.hexagon, "une épingle de recherche rend sa quête")

	var old_pins := JSON.stringify({"version": 1, "pins": [{"kind": "recherche", "title": "ancienne", "address": target}]})
	for broken in ["{pas du json", "[]", "{\"version\": 99, \"pins\": []}", old_pins]:
		_write(PINS_TEST_PATH, broken)
		_check(QuestScript.load_pins(entries, PINS_TEST_PATH).size() == 9, "fichier abîmé (%s) → le catalogue" % broken.left(14))
	_write(PINS_TEST_PATH, JSON.stringify({"version": QuestScript.PINS_VERSION, "pins": [
		{"kind": "catalogue", "entry": "inconnue"}, {"kind": "recherche", "title": "x", "address": {"hexagon": "z"}},
		{"kind": "catalogue", "entry": "claude-sur-l-humour"}, 7, {"kind": "recherche", "title": "y", "address": target}]}))
	var partial := QuestScript.load_pins(entries, PINS_TEST_PATH)
	_check(partial.size() == 2 and partial[0].entry == "claude-sur-l-humour" and partial[1].title == "y", "épingles abîmées écartées une à une")
	_write(PINS_TEST_PATH, JSON.stringify({"version": QuestScript.PINS_VERSION, "pins": []}))
	_check(QuestScript.load_pins(entries, PINS_TEST_PATH).is_empty(), "tout désépinglé reste désépinglé")

	# Registre des livres manquants : une ligne par livre de stolen_books, sans dire de quelle notice.
	var register := QuestScript.register_pin()
	_check(register.title == "Registre des livres manquants" and register.author == "anonyme" and QuestScript.from_pin(register, entries) == null,
		"le registre, « anonyme », ne démarre aucune quête")
	var books := QuestScript.stolen_books()
	var items := QuestScript.register_items()
	_check(books.size() == entries.size() and items.size() == books.size(), "le registre compte %d lignes, une par livre volé" % items.size())
	var titles_seen := []
	for i in items.size():
		var a: Dictionary = items[i].address
		var b: Dictionary = books[i]
		_check(a.hexagon == b.hexagon and a.level == b.level and a.wall == b.wall and a.shelf == b.shelf and a.book == b.book and a.page == 0,
			"ligne %d : le livre volé, page 1" % (i + 1))
		_check(items[i].label == "Ouvrage manquant %d — mur %d · étagère %d · livre %d" % [i + 1, b.wall + 1, b.shelf + 1, b.book + 1], "ligne %d : %s" % [i + 1, items[i].label])
		for entry: Dictionary in entries:
			if items[i].label.contains(entry.title):
				titles_seen.append(entry.title)
	_check(titles_seen.is_empty(), "le registre ne nomme aucune œuvre")


static func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


# --- Hud et carnet ------------------------------------------------------------------------------

func _test_hud() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PINS_TEST_PATH))
	var game_script := GDScript.new()
	game_script.source_code = "extends Node\nsignal got(event)\nfunc _unhandled_input(event: InputEvent) -> void:\n\tgot.emit(event)\n"
	game_script.reload()
	_game = Node.new()
	_game.set_script(game_script)
	_game.connect("got", func(event: InputEvent) -> void: _game_events.append(event))
	root.add_child(_game)
	var hud: Hud = HudScript.new()
	hud.pins_path = PINS_TEST_PATH
	root.add_child(hud)
	await process_frame
	hud.invocation.connect(func(axis: String) -> void: _jumps.append(axis))

	var texts := _texts(hud)
	var instructions := texts.filter(func(t: String) -> bool:
		return t.contains("ZQSD") or t.contains("WASD") or t.contains("souris") or t.contains("E :") or t.contains("Échap"))
	_check(instructions.is_empty(), "aucune instruction de commande à l'écran (lu : %s)" % [instructions])
	hud.set_target({"wall": 1, "shelf": 2, "book": 16})
	_check(hud._hint.text == "mur 2 · étagère 3 · livre 17", "cote seule sous le réticule : %s" % hud._hint.text)
	hud.set_address(5, -2)
	_check(hud._address.text == "Hexagone 5 · niveau -2", "set_address met l'adresse à jour")
	_check(not hud._widget.visible, "sans quête, pas d'encart")

	hud.start_quest(QuestScript.from_address({"hexagon": "8", "level": "-2", "wall": 0, "shelf": 1, "book": 2, "page": 3}, "Essai", "Moi"))
	_check(hud._widget.visible and hud._quest_hall.text == "couloir : 3 galeries vers +Z" and hud._quest_level.text == "étages : ici", "encart : %s / %s" % [hud._quest_hall.text, hud._quest_level.text])
	_check(hud._quest_title.text == "Essai — Moi" and hud._quest_book.text.ends_with("page 4"), "encart : titre, auteur, cote et page")
	hud.set_address(8, -2)
	_check(hud._quest_hall.text == "couloir : ici", "l'encart suit set_address")
	_check(hud._arrow.mode == "ici" and hud._quest_glyph.text == "ici", "encart : galerie atteinte, « ici »")
	hud.set_address(8, 0)
	_check(hud._arrow.mode == "bas" and hud._quest_glyph.text.is_empty(), "encart : cible deux niveaux plus bas, flèche vers le bas")
	hud.set_address(7, -2)
	_check(hud._arrow.mode == "plat", "encart : même étage, flèche couchée")
	hud.set_address(8, -2)

	# Adresse à 917 000 chiffres : forme « display » du service (signe, 4 premiers…4 derniers, nombre
	# de chiffres) ; un pas avance les derniers chiffres et le guidage sans relire la coordonnée.
	var huge: String = QuestScript.load_catalogue()[0].address.hexagon
	var deep := "-" + huge
	hud.set_address(huge, deep)
	var shown := hud._address.text
	var summary := BookTextScript.coordinate_summary(huge)
	_check(shown == "Hexagone %s · niveau %s" % [BookTextScript.summary_text(summary), BookTextScript.summary_text(BookTextScript.coordinate_summary(deep))]
		and shown.contains("…") and shown.contains("(9170") and shown.contains("niveau -"), "grande adresse affichée en abrégé : %s" % shown)
	_check(hud._quest_hall.text.begins_with("couloir : ≈ 10^917") and hud._quest_hall.text.ends_with("vers −Z"), "encart : distance en ordre de grandeur (%s)" % hud._quest_hall.text)
	var worst := 0
	var h := huge
	var l := deep
	for step in [Vector2i(1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(-1, 0), Vector2i(0, 1)]:
		h = BookTextScript.b25_add_small(h, step.x)
		l = BookTextScript.b25_add_small(l, step.y)
		var t := Time.get_ticks_usec()
		hud.set_address(h, l, step)
		worst = maxi(worst, Time.get_ticks_usec() - t)
	var after := hud._address.text
	var recomputed := "Hexagone %s · niveau %s" % [BookTextScript.summary_text(BookTextScript.coordinate_summary(h)), BookTextScript.summary_text(BookTextScript.coordinate_summary(l))]
	_check(after == recomputed and after != shown, "cinq pas : l'adresse affichée suit (%s), comme la relecture par le service" % after)
	_check(worst < 8000, "un pas de l'encart à 917 000 chiffres : %.2f ms au pire (budget 8 ms)" % (worst / 1000.0))
	hud.set_address(8, -2)

	# Carnet : touche cachée, mot écrit dans l'alphabet, invocation à l'espace.
	var carnet := hud.carnet
	# Sans fenêtre, le mode effectif reste VISIBLE : on vérifie le mode retenu et le mode demandé.
	var mouse_start := Input.mouse_mode
	_check(_key(hud, CarnetScript.CARNET_KEY, true) and carnet.is_open(), "la touche du carnet l'ouvre")
	_check(carnet._mouse_before == mouse_start and carnet.mouse_mode_requested == Input.MOUSE_MODE_VISIBLE, "le carnet retient le mode de souris et demande la souris libre")
	carnet._mouse_before = Input.MOUSE_MODE_CAPTURED   # comme si le bibliothécaire marchait, souris capturée
	_check(_type(hud, "aleph ") and _jumps == ["couloir"] and not carnet.is_open(), "« aleph␠ » émet « couloir » une fois et ferme le carnet")
	_check(carnet.mouse_mode_requested == Input.MOUSE_MODE_CAPTURED, "le carnet fermé redemande le mode retenu (capturé)")
	_jumps.clear()
	_key(hud, CarnetScript.CARNET_KEY, true)
	_type(hud, "Tlön")
	_check(carnet.word == "tlon", "« Tlön » s'écrit « tlon » (lu : %s)" % carnet.word)
	_type(hud, " ")
	_check(_jumps == ["galerie"], "« Tlön␠ » émet « galerie »")
	_jumps.clear()
	_key(hud, CarnetScript.CARNET_KEY, true)
	_type(hud, "babel ")
	_check(_jumps.is_empty() and carnet.word.is_empty() and carnet.is_open(), "« babel␠ » n'émet rien, efface le mot, le carnet reste ouvert")
	_type(hud, "Kyw,Q1é!Æ")
	_check(carnet.word == "civ,ceae", "symboles normalisés, autres ignorés (lu : %s)" % carnet.word)
	_type(hud, "\b\b\b")
	_check(carnet.word == "civ,c", "retour arrière efface (lu : %s)" % carnet.word)
	_type(hud, "\b\b\b\b\bZAHIR\n")
	_check(_jumps == ["puits"] and not carnet.is_open(), "« ZAHIR » puis Entrée émet « puits »")
	_jumps.clear()
	_key(hud, CarnetScript.CARNET_KEY, true)
	_check(_key(hud, KEY_E, true, "e") and _key(hud, KEY_E, false, "e") and carnet.word == "e", "E tapé dans le carnet est consommé (aucun livre ne s'ouvre)")
	_check(_mouse(hud), "carnet ouvert : un clic est consommé")
	_check(_key(hud, KEY_ESCAPE, true) and not carnet.is_open() and carnet.mouse_mode_requested == mouse_start and _jumps.is_empty(), "Échap ferme le carnet sans invocation et rend le mode retenu")
	_check(not _key(hud, KEY_E, true, "e"), "carnet fermé : E reste au jeu")
	_key(hud, CarnetScript.CARNET_KEY, true)
	_check(_key(hud, CarnetScript.CARNET_KEY, true) and not carnet.is_open(), "la même touche referme le carnet")
	texts = _texts(hud)
	_check(not texts.any(func(t: String) -> bool: return t.contains("²") or t.contains("`") or t.contains("carnet")), "aucune mention du carnet à l'écran")

	# Panneau : touche de quête, puis Échap ; aucune touche nommée à l'écran.
	var mouse_before := Input.mouse_mode
	_check(_key(hud, HudScript.QUEST_KEY, true) and hud.is_panel_open(), "la touche de quête ouvre le panneau")
	_check(hud._mouse_before == mouse_before and hud.mouse_mode_requested == Input.MOUSE_MODE_VISIBLE, "le panneau retient le mode de souris et demande la souris libre")
	_check(_key(hud, KEY_E, true, "e") and _key(hud, KEY_W, true, "w") and _key(hud, KEY_SPACE, true, " "), "panneau ouvert : E, W, espace consommés")
	_check(_mouse(hud), "panneau ouvert : un clic est consommé")
	texts = _texts(hud)
	var leaks := texts.filter(func(t: String) -> bool:
		return t.contains("²") or t.contains(HudScript.QUEST_KEY_NAME) or t.contains(HudScript.CLEAR_KEY_NAME))
	_check(leaks.is_empty(), "le panneau ne dévoile aucune touche (lu : %s)" % [leaks])
	_check(texts.any(func(t: String) -> bool: return t.contains("📌 La biblioteca de Babel — Jorge Luis Borges")), "le panneau liste les épingles")
	_check(texts.has(QuestScript.load_catalogue()[1].context), "le contexte s'affiche sous l'entrée")
	_check(texts.has("📌 Registre des livres manquants — anonyme") and texts.has(QuestScript.REGISTER_CONTEXT), "le registre est épinglé, avec son contexte")
	hud._on_pin_pressed(hud.pins[hud.pins.size() - 1])
	texts = _texts(hud)
	_check(hud.quest.title == "Essai" and hud.register_items().all(func(it: Dictionary) -> bool: return texts.has("    " + it.label)),
		"un clic sur le registre déplie ses lignes sans démarrer de quête")
	_check(_key(hud, CarnetScript.CARNET_KEY, true) and not carnet.is_open(), "panneau ouvert : la touche du carnet est consommée, le carnet reste fermé")
	hud._mouse_before = Input.MOUSE_MODE_CAPTURED   # comme si le bibliothécaire marchait, souris capturée
	_check(_key(hud, KEY_ESCAPE, true) and not hud.is_panel_open() and hud.mouse_mode_requested == Input.MOUSE_MODE_CAPTURED, "Échap ferme le panneau et redemande le mode retenu (capturé)")
	_check(not _key(hud, KEY_E, true, "e") and not _mouse(hud), "panneau fermé : E et le clic parviennent au jeu")

	_check(hud.search_typed("la bibliotheque de babel") and hud.quest.title == "texte saisi", "un texte tapé démarre une quête")
	_check(hud.pin_current("babel tapé"), "la recherche s'épingle")
	var stored := FileAccess.get_file_as_string(PINS_TEST_PATH)
	_check(stored.contains("babel tapé") and not stored.contains("la bibliotheque de babel"), "le fichier d'épingles garde le titre, jamais le texte")
	_check(not hud.search_typed("   ") and hud.last_error == "texte vide", "texte vide refusé")
	hud.unpin(hud.pins[0].id)
	_check(hud.pins.size() == 9, "désépingler depuis le Hud")
	hud.restore_pins()
	_check(hud.pins.size() == 10 and hud.pins[9].kind == QuestScript.KIND_REGISTER and hud.pins[0].entry == "borges-biblioteca-de-babel", "rétablir depuis le Hud")
	_check(hud.start_pin(hud.pins[5]) and hud.quest.title == "Mode d'emploi de la Bibliothèque", "un clic sur une épingle démarre sa quête")

	_check(not hud.start_pin(hud.pins[9]) and hud.quest.title == "Mode d'emploi de la Bibliothèque", "le registre lui-même ne démarre rien")
	for item: Dictionary in hud.register_items():
		hud.start_register_item(item)
		var t := hud.quest.address()
		_check(hud.quest.title == item.label and t.hexagon == item.address.hexagon and t.book == item.address.book and t.page == 0 \
			and QuestScript.is_stolen_book(t.hexagon, t.level, t.wall, t.shelf, t.book), "%s : quête vers ce livre" % item.label)
	_check(_key(hud, HudScript.CLEAR_KEY, true) and hud.quest == null and not hud._widget.visible, "la touche d'effacement efface la quête")
	_check(not _key(hud, HudScript.CLEAR_KEY, true), "sans quête, la touche d'effacement reste au jeu")
	hud.queue_free()
	_game.queue_free()
	_game = null
	await process_frame


## Tape un texte, touche après touche (« \b » : retour arrière, « \n » : Entrée) ; vrai si une
## touche au moins est consommée.
func _type(hud: Hud, text: String) -> bool:
	var consumed := false
	for c in text:
		var code := KEY_NONE
		var unicode := c
		match c:
			"\b":
				code = KEY_BACKSPACE
				unicode = ""
			"\n":
				code = KEY_ENTER
				unicode = ""
			" ":
				code = KEY_SPACE
			_:
				var upper := c.to_upper()
				if upper.length() == 1 and upper >= "A" and upper <= "Z":
					code = upper.unicode_at(0) as Key
		consumed = _key(hud, code, true, unicode) or consumed
		_key(hud, code, false, unicode)
	return consumed


## Envoie une touche par la fenêtre (push_input : _input, interface, _unhandled_input) ; vrai si
## elle n'arrive pas au jeu (nœud _game), ou, sans lui, si un nœud l'a consommée.
func _key(_hud: Hud, code: int, pressed: bool, unicode := "") -> bool:
	var event := InputEventKey.new()
	event.physical_keycode = code as Key
	event.keycode = code as Key
	event.unicode = unicode.unicode_at(0) if not unicode.is_empty() else 0
	event.pressed = pressed
	return _push(event)


## Pousse un événement ; vrai s'il n'arrive pas au jeu (sans nœud _game : s'il est consommé).
func _push(event: InputEvent) -> bool:
	_game_events.clear()
	root.push_input(event)
	if _game != null:
		return _game_events.is_empty()
	return root.is_input_handled()


## Un clic gauche (enfoncé puis relâché) au bord de la fenêtre ; vrai si l'enfoncement est consommé.
func _mouse(_hud: Hud) -> bool:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = Vector2(4, 4)
	event.global_position = event.position
	event.pressed = true
	var handled := _push(event)
	var release := event.duplicate() as InputEventMouseButton
	release.pressed = false
	_push(release)
	return handled


# --- Flèche de direction -----------------------------------------------------------------------

func _test_direction_glyph() -> void:
	var camera := Camera3D.new()   # regarde vers −Z, la droite vers +X
	root.add_child(camera)
	var target := {"wall": 0, "shelf": 0, "book": 16}
	var flat := HudScript.direction({"hall": 1, "vert": 0}, target, camera)
	_check(flat.mode == "plat" and flat.glyph == "↓" and is_equal_approx(absf(flat.heading), PI), "même étage, +Z derrière : flèche couchée vers l'arrière (↓)")
	_check(HudScript.direction({"hall": -1, "vert": 0}, target, camera).glyph == "↑", "même étage, −Z devant : ↑")
	var up := HudScript.direction({"hall": 1, "vert": 1}, target, camera)
	var down := HudScript.direction({"hall": 0, "vert": -1}, target, camera)
	_check(up.mode == "haut" and up.glyph == "▲", "cible au-dessus : flèche dressée vers le haut, sans flèche couchée")
	_check(down.mode == "bas" and down.glyph == "▼", "cible au-dessous : flèche dressée vers le bas")
	camera.rotation.y = PI / 2.0   # regarde vers −X : +Z est à gauche
	_check(HudScript.direction({"hall": 1, "vert": 0}, target, camera).glyph == "←", "+Z à gauche après un quart de tour : ←")
	camera.rotation.y = 0.0
	# Mur 0 = côté 1, à 60° de +Z vers +X : derrière à droite pour qui regarde vers −Z.
	var here := HudScript.direction({"hall": 0, "vert": 0}, target, camera)
	_check(here.mode == "ici" and here.glyph == "↘", "galerie atteinte : « ici », flèche couchée vers le livre (↘)")
	_check(HudScript.direction({"hall": 1, "vert": 0}, target, null).glyph == "+Z", "sans caméra : +Z")

	# La flèche dessinée suit les trois états.
	var arrow := HudScript.QuestArrow.new()
	root.add_child(arrow)
	arrow.set_state(flat.mode, flat.heading)
	var tip := arrow.tip_direction()
	_check(absf(tip.y) < 0.5 and tip.y > 0.0, "flèche couchée : pointe aplatie (%.2f, %.2f)" % [tip.x, tip.y])
	arrow.set_state(up.mode, up.heading)
	_check(arrow.tip_direction() == Vector2.UP, "flèche dressée vers le haut")
	arrow.set_state(down.mode, down.heading)
	_check(arrow.tip_direction() == Vector2.DOWN, "flèche dressée vers le bas")
	arrow.queue_free()
	camera.queue_free()


# --- Monde réel : le panneau ouvert garde E pour lui --------------------------------------------

func _test_main_panel() -> void:
	var main: Node3D = load("res://main.tscn").instantiate()
	root.add_child(main)
	for _i in 30:
		await physics_frame
	var player: Player = main.player
	player.rotation.y = PI / 3.0 + PI
	player.camera.rotation.x = -0.2
	player.position = Basis(Vector3.UP, PI / 3.0) * Vector3(0.0, 0.0, 3.4)
	for _i in 3:
		await physics_frame
	_check(not main._target.is_empty(), "monde : un livre est visé")
	_key(null, KEY_E, true, "e")
	_key(null, KEY_E, false, "e")
	_check(main.reader.visible, "monde, contrôle : E ouvre le livre visé")
	_key(null, KEY_E, true, "e")
	_key(null, KEY_E, false, "e")
	_check(not main.reader.visible, "monde : E referme le livre")
	_key(null, HudScript.QUEST_KEY, true)
	_check(main.hud.is_panel_open() and player.frozen, "monde : le panneau s'ouvre, le bibliothécaire s'arrête")
	_key(null, KEY_E, true, "e")
	_key(null, KEY_E, false, "e")
	_mouse(null)
	_check(not main.reader.visible, "monde : E et le clic, panneau ouvert, n'ouvrent pas le livre visé")
	_key(null, KEY_ESCAPE, true)
	_check(not main.hud.is_panel_open() and not player.frozen and main._mouse_captured, "monde : Échap ferme le panneau, le bibliothécaire repart")
	_key(null, CarnetScript.CARNET_KEY, true)
	_key(null, KEY_E, true, "e")
	_key(null, KEY_E, false, "e")
	_check(main.hud.carnet.is_open() and not main.reader.visible, "monde : E dans le carnet n'ouvre pas le livre visé")
	_key(null, KEY_ESCAPE, true)
	_check(not main.hud.carnet.is_open(), "monde : Échap ferme le carnet")
	main.queue_free()
	await process_frame


static func _texts(node: Node) -> Array:
	var texts := []
	for child in node.find_children("*", "", true, false):
		if (child is Label or child is Button) and child.is_visible_in_tree():
			texts.append(child.text)
	return texts


func _check(condition: bool, label: String) -> void:
	print(("  ok    " if condition else "  ÉCHEC ") + label)
	if not condition:
		_failures += 1
