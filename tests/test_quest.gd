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
const ENTRY_KEYS := ["id", "title", "author", "year", "language", "context", "group", "licence", "protected", "page_count", "pages", "notice_address", "notice_hash"]

var _failures := 0
var _jumps: Array = []


func _initialize() -> void:
	_test_arithmetic()
	_test_guidance()
	_test_catalogue()
	_test_pins()
	await _test_hud()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PINS_TEST_PATH))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(ARITH_CASES_PATH))
	print("test_quest : %s" % ("OK" if _failures == 0 else "%d échec(s)" % _failures))
	BookTextScript.shutdown()
	quit(1 if _failures else 0)


# --- Arithmétique -------------------------------------------------------------------------------

func _test_arithmetic() -> void:
	_check(QuestScript.dec_normalize("+007") == "7", "normalisation de « +007 »")
	_check(QuestScript.dec_normalize("-000") == "0", "« -000 » vaut 0, sans signe")
	_check(QuestScript.dec_add("-5", "3") == "-2", "-5 + 3 = -2")
	_check(QuestScript.dec_sub("3", "5") == "-2", "3 − 5 = -2")
	_check(QuestScript.dec_sub("-7", "-7") == "0", "-7 − (-7) = 0")
	_check(QuestScript.dec_add("999999999999999999999", "1") == "1000000000000000000000", "retenue sur 21 chiffres")
	_check(not QuestScript.dec_valid("12a") and not QuestScript.dec_valid("-") and not QuestScript.dec_valid(""), "chaînes non décimales refusées")

	var rng := RandomNumberGenerator.new()
	rng.seed = 2234
	var big_a := _digits(rng, 2234)
	var big_b := _digits(rng, 2100)
	var pairs := [
		[big_a, big_b], ["-" + big_a, big_b], [big_a, "-" + big_b], ["-" + big_a, "-" + big_b],
		[big_a, big_a], ["-" + big_a, big_a], [big_b, big_a], ["9".repeat(2050), "1"],
		["1" + "0".repeat(2049), "1"], ["0", "-" + big_b], [str(-9223372036854775807 - 1), "9223372036854775807"],
		[big_a, str(-4611686018427387904)], ["+00" + big_b, "-000"],
	]
	for _i in 6:
		pairs.append([("-" if rng.randi() % 2 else "") + _digits(rng, rng.randi_range(1, 2300)),
			("-" if rng.randi() % 2 else "") + _digits(rng, rng.randi_range(1, 2300))])
	var file := FileAccess.open(ARITH_CASES_PATH, FileAccess.WRITE)
	file.store_string(JSON.stringify(pairs))
	file.close()
	var command: Array = BookTextScript._interpreters()[0]
	var args := PackedStringArray(command.slice(1))
	args.append_array([ProjectSettings.globalize_path("res://tests/check_quest_arith.py"), ProjectSettings.globalize_path(ARITH_CASES_PATH)])
	var output := []
	var code := OS.execute(command[0], args, output, true)
	var expected: Variant = JSON.parse_string(output[0] if code == 0 and not output.is_empty() else "")
	_check(expected is Array and expected.size() == pairs.size(), "Python rend la contre-épreuve de %d paires (code %d)" % [pairs.size(), code])
	if not expected is Array or expected.size() != pairs.size():
		return
	var mismatches := 0
	for i in pairs.size():
		var a: String = pairs[i][0]
		var b: String = pairs[i][1]
		var want: Dictionary = expected[i]
		if QuestScript.dec_add(a, b) != want.sum or QuestScript.dec_sub(a, b) != want.diff \
				or QuestScript.dec_compare(a, b) != int(want.cmp) or QuestScript.dec_sign(a) != int(want.sign) \
				or QuestScript.dec_digits(a) != int(want.digits):
			mismatches += 1
			print("    écart sur la paire %d (%d et %d chiffres)" % [i, a.length(), b.length()])
	_check(mismatches == 0, "somme, différence, comparaison, signe, chiffres : identiques à Python sur %d paires de 1 à 2300 chiffres" % pairs.size())


static func _digits(rng: RandomNumberGenerator, count: int) -> String:
	var text := str(rng.randi_range(1, 9))
	for _i in count - 1:
		text += str(rng.randi_range(0, 9))
	return text


# --- Guidage ------------------------------------------------------------------------------------

func _test_guidance() -> void:
	var quest := QuestScript.from_address({"hexagon": "105", "level": "-3", "wall": 1, "shelf": 2, "book": 16, "page": 204}, "Titre", "Auteur")
	_check(quest != null and quest.label() == "Titre — Auteur", "quête sur une adresse, « titre — auteur »")
	var g := quest.guidance(100, 0)
	_check(g.dz == "5" and g.dy == "-3" and g.hall == 1 and g.vert == -1 and not g.here, "différences signées depuis (100, 0) : +5, -3")
	_check(g.hall_text == "couloir : 5 galeries vers +Z", "couloir : %s" % g.hall_text)
	_check(g.level_text == "étages : 3 niveaux vers le bas", "étages : %s" % g.level_text)
	_check(g.book_text == "dans la galerie : mur 2 · étagère 3 · livre 17 · page 205", "cote : %s" % g.book_text)
	g = quest.guidance(106, -4)
	_check(g.hall_text == "couloir : 1 galerie vers −Z" and g.level_text == "étages : 1 niveau vers le haut", "singulier et sens inverses : %s / %s" % [g.hall_text, g.level_text])
	g = quest.guidance(105, -3)
	_check(g.here and g.hall_text == "couloir : ici" and g.level_text == "étages : ici", "dans la galerie visée : ici")
	_check(quest.target_in_gallery(105, -3) == {"wall": 1, "shelf": 2, "book": 16, "page": 204}, "livre visé dans la galerie")
	_check(quest.target_in_gallery(105, -2).is_empty(), "aucun livre visé ailleurs")

	var far := QuestScript.from_address({"hexagon": "1" + "0".repeat(2233), "level": "-" + "4".repeat(2234), "wall": 0, "shelf": 0, "book": 0, "page": 0})
	g = far.guidance(-12, 7)
	_check(g.hall_text == "couloir : ≈ 10^2233 galeries vers +Z", "grande distance : %s" % g.hall_text)
	_check(g.level_text == "étages : ≈ 10^2233 niveaux vers le bas", "grande hauteur : %s" % g.level_text)
	_check(QuestScript.magnitude_text("-999999999999999") == "999999999999999", "15 chiffres : valeur exacte")
	_check(QuestScript.magnitude_text("1000000000000000") == "≈ 10^15", "16 chiffres : ordre de grandeur")
	_check(QuestScript.from_address({"hexagon": "1", "level": "x", "wall": 0, "shelf": 0, "book": 0, "page": 0}) == null, "adresse mal formée refusée")
	_check(QuestScript.from_address({"hexagon": "1", "level": "2", "wall": 4, "shelf": 0, "book": 0, "page": 0}) == null, "mur hors de la galerie refusé")


# --- Catalogue ----------------------------------------------------------------------------------

func _test_catalogue() -> void:
	var entries := QuestScript.load_catalogue()
	var titles := entries.map(func(e: Dictionary) -> String: return e.title)
	_check(titles == ["La biblioteca de Babel", "El Aleph", "El Zahir", "Tlön, Uqbar, Orbis Tertius", "El Golem",
		"Mode d'emploi de la Bibliothèque", "Sur la vertu", "Sur l'humour"], "catalogue : 8 entrées dans l'ordre (lu : %s)" % [titles])
	var raw: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(QuestScript.CATALOGUE_PATH))
	var extra := []
	for entry: Dictionary in raw.entries:
		for key: String in entry:
			if not key in ENTRY_KEYS:
				extra.append(key)
		for page: Dictionary in entry.pages:
			if page.keys().size() != 2:
				extra.append("pages")
	_check(extra.is_empty(), "le catalogue ne porte que des métadonnées, des adresses et des condensats (en trop : %s)" % [extra])
	var borges := entries.filter(func(e: Dictionary) -> bool: return e.author == "Jorge Luis Borges")
	_check(borges.size() == 5 and borges.all(func(e: Dictionary) -> bool: return e.protected and e.pages.size() == 1 and e.page_count == 1),
		"5 entrées protégées de Borges, une page chacune")
	var claude := entries.filter(func(e: Dictionary) -> bool: return e.author == "Claude")
	_check(claude.size() == 3 and claude.all(func(e: Dictionary) -> bool: return e.licence == "texte original écrit pour le jeu" and e.pages.size() == 1),
		"3 textes de Claude, une page chacun, « texte original écrit pour le jeu »")
	for entry: Dictionary in entries:
		_check(not entry.author.strip_edges().is_empty() and not entry.context.strip_edges().is_empty(), "%s : auteur et contexte présents" % entry.title)
	var checked := {}
	for entry: Dictionary in entries:
		for page: Dictionary in entry.pages:
			var key := BookTextScript.full_form(page.address)
			if checked.has(key):
				_check(checked[key] == page.sha256, "%s : même page, même condensat" % entry.title)
				continue
			var lines := BookTextScript.page_lines_at(page.address)
			var text := "".join(lines)
			_check(text.length() == 3200 and text.sha256_text() == page.sha256, "%s : la page relue au service a le condensat du catalogue" % entry.title)
			var flags := BookTextScript.image_books([page.address])
			_check(flags.size() == 1 and not flags[0], "%s : l'adresse est un livre de texte" % entry.title)
			checked[key] = page.sha256
	# Notices : chaque notice est une page d'un livre volé à la Bibliothèque.
	for entry: Dictionary in entries:
		var notice := "\n".join([entry.title, entry.author, entry.context])
		var expected := CarnetScript.normalize(notice).rpad(3200)
		_check(expected.length() == 3200 and expected.sha256_text() == entry.notice_hash, "%s : la notice normalisée a le condensat du catalogue" % entry.title)
		var a: Dictionary = entry.get("notice_address", {})
		_check(not a.is_empty() and "".join(BookTextScript.page_lines_at(a)).sha256_text() == entry.notice_hash, "%s : la page de la notice relue au service a ce condensat" % entry.title)
		if a.is_empty():
			continue
		_check(QuestScript.is_stolen_book(a.hexagon, a.level, a.wall, a.shelf, a.book), "%s : le livre de la notice est volé" % entry.title)
		_check(not QuestScript.is_stolen_book(a.hexagon, a.level, a.wall, a.shelf, (a.book + 1) % 32), "%s : le livre voisin est en place" % entry.title)
	_check(raw.stolen_books.size() == entries.size(), "stolen_books : un livre par notice (%d)" % raw.stolen_books.size())
	_check(not QuestScript.is_stolen_book("0", "0", 0, 0, 0), "le livre (0, 0, 0, 0, 0) est en place")

	var quest := QuestScript.from_entry(entries[0])
	_check(quest != null and quest.pages.size() == 1 and quest.author == "Jorge Luis Borges", "quête d'une entrée du catalogue")
	var tool := FileAccess.get_file_as_string("res://tools/make_catalogue.py")
	_check(tool.contains("KEY_NAMES = {\"QUETE\": \"%s\", \"EFFACER\": \"%s\"}" % [HudScript.QUEST_KEY_NAME, HudScript.CLEAR_KEY_NAME]),
		"le mode d'emploi reçoit les noms des touches du Hud (%s, %s)" % [HudScript.QUEST_KEY_NAME, HudScript.CLEAR_KEY_NAME])
	_check(QuestScript.load_catalogue("res://absent.json").is_empty(), "catalogue absent → aucune entrée")


# --- Épingles -----------------------------------------------------------------------------------

func _test_pins() -> void:
	var entries := QuestScript.load_catalogue()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PINS_TEST_PATH))
	var pins := QuestScript.load_pins(entries, PINS_TEST_PATH)
	_check(pins.size() == 8 and pins.all(func(p: Dictionary) -> bool: return p.kind == QuestScript.KIND_CATALOGUE), "sans fichier : le catalogue entier est épinglé")

	var target := {"hexagon": "-123456789012345678901234567890", "level": "42", "wall": 3, "shelf": 4, "book": 31, "page": 409}
	pins = QuestScript.remove_pin(pins, "catalogue:borges-el-zahir")
	pins = QuestScript.add_pin(pins, QuestScript.search_pin("ma recherche", target))
	pins = QuestScript.add_pin(pins, QuestScript.search_pin("ma recherche", target))
	_check(pins.size() == 8, "désépingler une entrée, épingler une recherche (une seule fois)")
	_check(QuestScript.save_pins(pins, PINS_TEST_PATH), "épingles enregistrées")
	var again := QuestScript.load_pins(entries, PINS_TEST_PATH)
	_check(again.map(func(p: Dictionary) -> String: return p.id) == pins.map(func(p: Dictionary) -> String: return p.id), "épingles relues à l'identique")
	var stored: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(PINS_TEST_PATH))
	var search_stored: Array = stored.pins.filter(func(p: Dictionary) -> bool: return p.kind == QuestScript.KIND_SEARCH)
	_check(search_stored.size() == 1 and search_stored[0].keys().size() == 3, "une recherche s'enregistre en titre et adresse seuls")
	var restored := QuestScript.restore_catalogue(again, entries)
	_check(restored.size() == 9 and QuestScript.missing_catalogue(restored, entries).is_empty() and restored[2].entry == "borges-el-zahir",
		"rétablir remet l'entrée désépinglée à sa place, la recherche reste")
	var quest := QuestScript.from_pin(restored[8], entries)
	_check(quest != null and quest.title == "ma recherche" and quest.address().hexagon == target.hexagon, "une épingle de recherche rend sa quête")

	for broken in ["{pas du json", "[]", "{\"version\": 99, \"pins\": []}"]:
		_write(PINS_TEST_PATH, broken)
		_check(QuestScript.load_pins(entries, PINS_TEST_PATH).size() == 8, "fichier abîmé (%s) → le catalogue" % broken.left(14))
	_write(PINS_TEST_PATH, JSON.stringify({"version": 1, "pins": [
		{"kind": "catalogue", "entry": "inconnue"}, {"kind": "recherche", "title": "x", "address": {"hexagon": "z"}},
		{"kind": "catalogue", "entry": "claude-sur-l-humour"}, 7, {"kind": "recherche", "title": "y", "address": target}]}))
	var partial := QuestScript.load_pins(entries, PINS_TEST_PATH)
	_check(partial.size() == 2 and partial[0].entry == "claude-sur-l-humour" and partial[1].title == "y", "épingles abîmées écartées une à une")
	_write(PINS_TEST_PATH, JSON.stringify({"version": 1, "pins": []}))
	_check(QuestScript.load_pins(entries, PINS_TEST_PATH).is_empty(), "tout désépinglé reste désépinglé")


static func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


# --- Hud et carnet ------------------------------------------------------------------------------

func _test_hud() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PINS_TEST_PATH))
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

	# Carnet : touche cachée, mot écrit dans l'alphabet, invocation à l'espace.
	var carnet := hud.carnet
	var mouse_start := Input.mouse_mode
	_check(_key(hud, CarnetScript.CARNET_KEY, true) and carnet.is_open(), "la touche du carnet l'ouvre")
	_check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "le carnet libère la souris")
	_check(_type(hud, "aleph ") and _jumps == ["couloir"] and not carnet.is_open(), "« aleph␠ » émet « couloir » une fois et ferme le carnet")
	_check(Input.mouse_mode == mouse_start, "le carnet fermé rend le mode de souris")
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
	_check(_key(hud, KEY_ESCAPE, true) and not carnet.is_open() and Input.mouse_mode == mouse_start and _jumps.is_empty(), "Échap ferme le carnet sans invocation")
	_check(not _key(hud, KEY_E, true, "e"), "carnet fermé : E reste au jeu")
	_key(hud, CarnetScript.CARNET_KEY, true)
	_check(_key(hud, CarnetScript.CARNET_KEY, true) and not carnet.is_open(), "la même touche referme le carnet")
	texts = _texts(hud)
	_check(not texts.any(func(t: String) -> bool: return t.contains("²") or t.contains("`") or t.contains("carnet")), "aucune mention du carnet à l'écran")

	# Panneau : touche de quête, puis Échap ; aucune touche nommée à l'écran.
	var mouse_before := Input.mouse_mode
	_check(_key(hud, HudScript.QUEST_KEY, true) and hud.is_panel_open(), "la touche de quête ouvre le panneau")
	texts = _texts(hud)
	var leaks := texts.filter(func(t: String) -> bool:
		return t.contains("²") or t.contains(HudScript.QUEST_KEY_NAME) or t.contains(HudScript.CLEAR_KEY_NAME))
	_check(leaks.is_empty(), "le panneau ne dévoile aucune touche (lu : %s)" % [leaks])
	_check(texts.any(func(t: String) -> bool: return t.contains("📌 La biblioteca de Babel — Jorge Luis Borges")), "le panneau liste les épingles")
	_check(texts.has(QuestScript.load_catalogue()[1].context), "le contexte s'affiche sous l'entrée")
	_check(not _key(hud, CarnetScript.CARNET_KEY, true) and not carnet.is_open(), "panneau ouvert : le carnet reste fermé")
	_check(_key(hud, KEY_ESCAPE, true) and not hud.is_panel_open() and Input.mouse_mode == mouse_before, "Échap ferme le panneau et rend le mode de souris")

	_check(hud.search_typed("la bibliotheque de babel") and hud.quest.title == "texte saisi", "un texte tapé démarre une quête")
	_check(hud.pin_current("babel tapé"), "la recherche s'épingle")
	var stored := FileAccess.get_file_as_string(PINS_TEST_PATH)
	_check(stored.contains("babel tapé") and not stored.contains("la bibliotheque de babel"), "le fichier d'épingles garde le titre, jamais le texte")
	_check(not hud.search_typed("   ") and hud.last_error == "texte vide", "texte vide refusé")
	hud.unpin(hud.pins[0].id)
	_check(hud.pins.size() == 8, "désépingler depuis le Hud")
	hud.restore_pins()
	_check(hud.pins.size() == 9 and hud.pins[0].entry == "borges-biblioteca-de-babel", "rétablir depuis le Hud")
	_check(hud.start_pin(hud.pins[5]) and hud.quest.title == "Mode d'emploi de la Bibliothèque", "un clic sur une épingle démarre sa quête")

	_check(_key(hud, HudScript.CLEAR_KEY, true) and hud.quest == null and not hud._widget.visible, "la touche d'effacement efface la quête")
	_check(not _key(hud, HudScript.CLEAR_KEY, true), "sans quête, la touche d'effacement reste au jeu")
	hud.queue_free()
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


static func _key(hud: Hud, code: int, pressed: bool, unicode := "") -> bool:
	var event := InputEventKey.new()
	event.physical_keycode = code as Key
	event.keycode = code as Key
	event.unicode = unicode.unicode_at(0) if not unicode.is_empty() else 0
	event.pressed = pressed
	return hud.handle_key(event)


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
