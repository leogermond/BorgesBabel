extends SceneTree
## Mesure le service Python à travers BookText et vérifie la recherche d'image et l'absence de Python.
## godot --headless --path . -s tests/test_babel_service.gd
## La dernière vérification provoque volontairement des erreurs « Python introuvable » dans le journal.

const BookTextScript := preload("res://scripts/book_text.gd")
const QuestScript := preload("res://scripts/quest.gd")
const PAGE_LATENCY_TARGET_MS := 50.0
## Délai réduit pendant l'essai du service muet.
const SHORT_TIMEOUT_MS := 800

var _failures := 0


func _init() -> void:
	var start := Time.get_ticks_usec()
	BookTextScript.page_lines(0, 0, 0, 0, 0, 0)
	print("  lancement du service et première page : %.1f ms" % _ms(start))

	start = Time.get_ticks_usec()
	for p in 50:
		BookTextScript.page_lines(123456, -42 - p, p % 4, p % 5, p % 32, 0)
	var page_ms := _ms(start) / 50.0
	_check(page_ms < PAGE_LATENCY_TARGET_MS, "page 1 de 50 livres jamais ouverts : %.2f ms la page (cible < %.0f ms)" % [page_ms, PAGE_LATENCY_TARGET_MS])
	start = Time.get_ticks_usec()
	for p in 50:
		BookTextScript.page_lines(123456, -42, 1, 2, 3, p)
	var turn_ms := _ms(start) / 50.0
	_check(turn_ms < PAGE_LATENCY_TARGET_MS, "pages 1 à 50 d'un même livre, tournées une à une : %.2f ms la page (cible < %.0f ms)" % [turn_ms, PAGE_LATENCY_TARGET_MS])
	start = Time.get_ticks_usec()
	var deep := BookTextScript.page_lines(123456, -41, 0, 0, 0, 409)
	var deep_ms := _ms(start)
	_check(deep.size() == 40 and BookTextScript.last_error.is_empty() and deep_ms < BookTextScript.timeout_ms,
		"page 410 d'un livre jamais ouvert (chaîne des 410 pages) : %.0f ms, sous le délai de %d ms" % [deep_ms, BookTextScript.timeout_ms])

	start = Time.get_ticks_usec()
	var far := BookTextScript.search_text("loin")
	print("  search_text d'un mot : %.1f ms (adresse de %d + %d chiffres base 25)" % [_ms(start), far.hexagon.length(), far.level.length()])
	start = Time.get_ticks_usec()
	for p in 20:
		BookTextScript.page_lines_at(far, p)
	var far_ms := _ms(start) / 20.0
	_check(far_ms < PAGE_LATENCY_TARGET_MS, "pages 0 à 19 d'un livre trouvé, par sa clé : %.2f ms la page (cible < %.0f ms)" % [far_ms, PAGE_LATENCY_TARGET_MS])

	# Un livre du catalogue jamais ouvert (service relancé : rien en cache) : page 1, puis page 3.
	var entry: Dictionary = QuestScript.load_catalogue()[0]
	BookTextScript.restart()
	BookTextScript.page_lines(0, 0, 0, 0, 0, 0)
	start = Time.get_ticks_usec()
	var first := BookTextScript.page_lines_at(entry.address, 0)
	var first_ms := _ms(start)
	start = Time.get_ticks_usec()
	var third := BookTextScript.page_lines_at(entry.address, 2)
	var third_ms := _ms(start)
	print("  %s, jamais ouvert : page 1 en %.1f ms (adresse envoyée), page 3 en %.1f ms (par la clé)" % [entry.title, first_ms, third_ms])
	_check(first.size() == 40 and third.size() == 40 and first_ms < 1000.0 and third_ms < 1000.0, "livre du catalogue : pages 1 et 3 en moins d'une seconde")

	start = Time.get_ticks_usec()
	var flags := BookTextScript.gallery_image_books(17, -3)
	print("  640 genres de livres en une requête (galerie proche) : %.1f ms" % _ms(start))
	_check(flags.size() == 640, "640 genres rendus")
	start = Time.get_ticks_usec()
	var far_flags := BookTextScript.gallery_image_books(far.hexagon, far.level)
	print("  640 genres de livres en une requête (galerie à 917 000 chiffres) : %.1f ms" % _ms(start))
	_check(far_flags.size() == 640, "640 genres rendus pour une galerie lointaine")

	var text := ""
	for i in 3200:
		text += BookTextScript.ALPHABET[(i * 7919) % 25]
	start = Time.get_ticks_usec()
	var found := BookTextScript.search_text(text)
	print("  search_text sur une page pleine : %.1f ms" % _ms(start))
	_check("".join(BookTextScript.page_lines_at(found)) == text, "search_text d'une page pleine : aller-retour exact")

	var img := Image.create(512, 512, false, Image.FORMAT_RGBA8)
	for y in 512:
		for x in 512:
			img.set_pixel(x, y, Color(x / 511.0, y / 511.0, 0.5 + 0.5 * sin(x * 0.05)))
	start = Time.get_ticks_usec()
	var spot := BookTextScript.search_image(img)
	print("  search_image sur 512 × 512 : %.1f ms" % _ms(start))
	_check(not spot.is_empty() and BookTextScript.image_books([spot])[0], "search_image tombe dans un livre d'images")
	var page := BookTextScript.page_image_at(spot)
	_check(page != null and page.get_size() == Vector2i(50, 64), "la page trouvée se décode en Image 50 × 64")
	_check(page != null and page.get_data() == BookTextScript.page_image_at(spot).get_data(), "même adresse → même image")

	var path := OS.get_cache_dir().path_join("babel_test_degrade.png")
	img.save_png(path)
	var from_file := BookTextScript.search_image_file(path)
	_check(from_file == spot, "search_image_file sur le même PNG → même adresse")
	DirAccess.remove_absolute(path)

	_check_image_parity()

	var words_path := OS.get_cache_dir().path_join("babel_test_texte.txt")
	var words := FileAccess.open(words_path, FileAccess.WRITE)
	words.store_string("Le monde, Ô lecteur.")
	words.close()
	var from_text := BookTextScript.search_text_file(words_path)
	_check(BookTextScript.page_lines_at(from_text)[0].begins_with("le monde, o lecteur."), "search_text_file lit le fichier")
	DirAccess.remove_absolute(words_path)

	# Service qui meurt pendant une requête : sa trace Python (erreur standard) rejoint last_error.
	print("  (erreurs attendues ci-dessous : service volontairement arrêté par une exception)")
	var dying := "import sys,json;sys.stdin.readline();print(json.dumps(dict(protocol=%d)),flush=True);sys.stdin.readline();raise RuntimeError('panne volontaire')" % BookTextScript.PROTOCOL
	ProjectSettings.set_setting(BookTextScript.PYTHON_SETTING, "python3 -c \"%s\"" % dying)
	BookTextScript.restart()
	start = Time.get_ticks_usec()
	var dead_lines := BookTextScript.page_lines(0, 0, 0, 0, 0, 0)
	print("  service mort pendant la requête, erreur relue en %.1f ms" % _ms(start))
	_check(dead_lines[0].begins_with("Bibliothèque indisponible"), "service mort : la page dit l'erreur")
	_check(BookTextScript.last_error.contains("RuntimeError: panne volontaire"), "service mort : la trace Python rejoint last_error : « %s »" % BookTextScript.last_error)

	# Service muet : il répond au ping, puis dort ; le délai l'arrête, l'appel rend une erreur
	# claire au lieu de figer le jeu, et le service est relancé à la requête suivante.
	print("  (erreurs attendues ci-dessous : service volontairement muet)")
	var asleep := "import sys,json,time;sys.stdin.readline();print(json.dumps(dict(protocol=%d)),flush=True);sys.stdin.readline();time.sleep(60)" % BookTextScript.PROTOCOL
	ProjectSettings.set_setting(BookTextScript.PYTHON_SETTING, "python3 -c \"%s\"" % asleep)
	BookTextScript.restart()
	var saved_timeouts := [BookTextScript.timeout_ms, BookTextScript.search_timeout_ms]
	BookTextScript.timeout_ms = SHORT_TIMEOUT_MS
	BookTextScript.search_timeout_ms = SHORT_TIMEOUT_MS * 2
	start = Time.get_ticks_usec()
	var mute_lines := BookTextScript.page_lines(0, 0, 0, 0, 0, 0)
	var mute_ms := _ms(start)
	print("  service muet : page rendue en %.0f ms (délai %d ms)" % [mute_ms, SHORT_TIMEOUT_MS])
	_check(mute_ms >= SHORT_TIMEOUT_MS and mute_ms < SHORT_TIMEOUT_MS + 1500, "service muet : la lecture rend la main après le délai (%.0f ms)" % mute_ms)
	_check(mute_lines.size() == 40 and mute_lines[0].begins_with("Bibliothèque indisponible"), "service muet : la page dit l'erreur")
	_check(BookTextScript.last_error.contains("n'a pas répondu") and BookTextScript.last_error.contains("page"),
		"service muet : last_error le dit : « %s »" % BookTextScript.last_error)
	_check(BookTextScript._pid == -1 and BookTextScript._stdio == null, "service muet : arrêté")
	start = Time.get_ticks_usec()
	var mute_search := BookTextScript.search_text("x")
	var mute_search_ms := _ms(start)
	_check(mute_search.is_empty() and mute_search_ms >= SHORT_TIMEOUT_MS * 2 and mute_search_ms < SHORT_TIMEOUT_MS * 2 + 1500,
		"service muet relancé : la recherche s'arrête au délai des recherches (%.0f ms)" % mute_search_ms)
	BookTextScript.timeout_ms = saved_timeouts[0]
	BookTextScript.search_timeout_ms = saved_timeouts[1]
	ProjectSettings.set_setting(BookTextScript.PYTHON_SETTING, "")
	BookTextScript.restart()
	_check(BookTextScript.page_lines(0, 0, 0, 0, 0, 0)[0].length() == 80 and BookTextScript.last_error.is_empty(), "après le service muet, le vrai service revient")

	_check_launchers()
	_check_background()

	# Sans Python : la page affiche l'erreur, le jeu continue.
	print("  (erreurs attendues ci-dessous : interpréteur volontairement introuvable)")
	ProjectSettings.set_setting(BookTextScript.PYTHON_SETTING, "/chemin/introuvable/python3")
	BookTextScript.restart()
	var lines := BookTextScript.page_lines(0, 0, 0, 0, 0, 0)
	_check(lines.size() == 40 and lines[0].begins_with("Bibliothèque indisponible"), "sans Python, la page dit l'erreur : « %s »" % lines[0])
	_check(BookTextScript.search_text("x").is_empty(), "sans Python, search_text rend {}")
	ProjectSettings.set_setting(BookTextScript.PYTHON_SETTING, "")
	BookTextScript.restart()
	_check(BookTextScript.page_lines(0, 0, 0, 0, 0, 0)[0].length() == 80, "après restart(), le service revient")

	print("test_babel_service : %s" % ("OK" if _failures == 0 else "%d échec(s)" % _failures))
	BookTextScript.shutdown()
	quit(1 if _failures else 0)


## Même image → même adresse dans le jeu (points de grille envoyés au service) et hors du jeu
## (image complète, ou `babel.py search-image` sur le PNG) ; requête bornée pour une grande photo.
func _check_image_parity() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 2024
	for size: Vector2i in [Vector2i(1, 1), Vector2i(3, 40), Vector2i(513, 200), Vector2i(64, 50), Vector2i(7, 3000)]:
		var bytes := PackedByteArray()
		bytes.resize(size.x * size.y * 4)
		for i in bytes.size():
			bytes[i] = rng.randi() & 0xFF
		var img := Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBA8, bytes)
		var game := BookTextScript.search_image(img)
		var full: Dictionary = BookTextScript._request({"op": "search_image", "width": size.x, "height": size.y,
			"rgba": Marshalls.raw_to_base64(bytes)}).get("address", {})
		_check(not game.is_empty() and game == BookTextScript.book_of(full), "%d × %d : points de grille du jeu → même adresse que l'image complète" % [size.x, size.y])

	var script := ProjectSettings.globalize_path(BookTextScript.SCRIPT_PATH)
	for case in [[Vector2i(1024, 1024), Image.FORMAT_RGBA8], [Vector2i(3000, 200), Image.FORMAT_RGB8]]:
		var size: Vector2i = case[0]
		var img := _pattern(size, case[1])
		var path := OS.get_cache_dir().path_join("babel_test_parite_%dx%d.png" % [size.x, size.y])
		img.save_png(path)
		var start := Time.get_ticks_usec()
		var in_game := BookTextScript.search_image_file(path)
		var game_ms := _ms(start)
		start = Time.get_ticks_usec()
		var output := []
		var code := OS.execute("python3", ["-X", "utf8", script, "search-image", path, "--json"], output)
		var cli_ms := _ms(start)
		var parsed: Variant = JSON.parse_string(output[0] if code == 0 and not output.is_empty() else "")
		var cli: Dictionary = parsed.get("address", {}) if parsed is Dictionary else {}
		print("  %d × %d PNG : search_image_file %.1f ms dans le jeu, %.1f ms en ligne de commande" % [size.x, size.y, game_ms, cli_ms])
		_check(code == 0 and not in_game.is_empty() and not cli.is_empty() and in_game == BookTextScript.book_of(cli),
			"%d × %d PNG : même adresse dans le jeu et par `babel.py search-image` (code %d)" % [size.x, size.y, code])
		DirAccess.remove_absolute(path)

	var photo := _pattern(Vector2i(6000, 4000), Image.FORMAT_RGBA8)
	var start := Time.get_ticks_usec()
	var request := BookTextScript.image_request(photo)
	var request_ms := _ms(start)
	var payload := JSON.stringify(request).length()
	start = Time.get_ticks_usec()
	var spot := BookTextScript.search_image(photo)
	print("  6000 × 4000 : requête de %d octets préparée en %.1f ms, search_image %.1f ms" % [payload, request_ms, _ms(start)])
	_check(payload < 300_000, "6000 × 4000 : requête bornée (%d octets < 300 000)" % payload)
	_check(not spot.is_empty() and BookTextScript.image_books([spot])[0], "6000 × 4000 : adresse dans un livre d'images")


## Lanceurs : un interpréteur lancé par un lanceur (comme `py -3` sous Windows, `uv run` ailleurs)
## est un enfant qui tient le même tube. Le chien de garde arrête toute la famille : la lecture
## bloquée rend la main au délai, au lancement comme pendant une requête. Un lancement trop lent
## se réessaie après un délai (et le message le dit) ; ce n'est pas « Python introuvable ».
func _check_launchers() -> void:
	var saved := [BookTextScript.timeout_ms, BookTextScript.start_timeout_ms, BookTextScript.start_retry_ms]
	BookTextScript.timeout_ms = SHORT_TIMEOUT_MS
	BookTextScript.start_timeout_ms = SHORT_TIMEOUT_MS
	BookTextScript.start_retry_ms = 300

	# Lanceur qui ne lance rien de bon : un enfant tient la sortie et dort.
	print("  (erreurs attendues ci-dessous : lanceur volontairement muet au lancement)")
	var slow := _launcher("babel_lanceur_lent.sh", "sleep 47.31 &\nwait\n")
	ProjectSettings.set_setting(BookTextScript.PYTHON_SETTING, "\"%s\"" % slow)
	BookTextScript.restart()
	var start := Time.get_ticks_usec()
	var lines := BookTextScript.page_lines(0, 0, 0, 0, 0, 0)
	var start_ms := _ms(start)
	print("  lanceur muet au lancement : page rendue en %.0f ms (délai %d ms)" % [start_ms, SHORT_TIMEOUT_MS])
	_check(start_ms >= SHORT_TIMEOUT_MS and start_ms < SHORT_TIMEOUT_MS + 1500 and lines[0].begins_with("Bibliothèque indisponible"),
		"lanceur dont l'enfant tient le tube : le lancement rend la main au délai (%.0f ms)" % start_ms)
	_check(not _running("sleep 47.31"), "lanceur muet : l'enfant est arrêté avec lui")
	_check(BookTextScript.last_error.contains("ne s'est pas lancé") and not BookTextScript.last_error.contains("introuvable"),
		"lancement trop lent : le message le dit, sans parler de Python introuvable : « %s »" % BookTextScript.last_error)
	start = Time.get_ticks_usec()
	BookTextScript.page_lines(0, 0, 0, 0, 0, 0)
	_check(_ms(start) < 100.0 and BookTextScript.last_error.contains("nouvel essai") and not BookTextScript.last_error.contains("introuvable"),
		"pendant le délai de relance : échec immédiat (%.0f ms), « nouvel essai » : « %s »" % [_ms(start), BookTextScript.last_error])
	# Le vrai Python revient sans restart() : la requête suivante, après le délai, relance le service.
	ProjectSettings.set_setting(BookTextScript.PYTHON_SETTING, "")
	OS.delay_msec(BookTextScript.start_retry_ms + 100)
	_check(BookTextScript.page_lines(0, 0, 0, 0, 0, 0)[0].length() == 80 and BookTextScript.last_error.is_empty(),
		"après un lancement trop lent, le service se relance de lui-même (sans restart)")

	# Lanceur dont l'enfant est le service : il répond au ping, puis dort pendant une requête.
	print("  (erreurs attendues ci-dessous : service muet derrière un lanceur)")
	var asleep := "import sys,json,time;sys.stdin.readline();print(json.dumps(dict(protocol=%d)),flush=True);sys.stdin.readline();time.sleep(53.17)" % BookTextScript.PROTOCOL
	var child := _launcher("babel_lanceur_enfant.sh", "python3 -c '%s' &\nwait\n" % asleep)
	ProjectSettings.set_setting(BookTextScript.PYTHON_SETTING, "\"%s\"" % child)
	BookTextScript.restart()
	start = Time.get_ticks_usec()
	lines = BookTextScript.page_lines(0, 0, 0, 0, 0, 0)
	var mute_ms := _ms(start)
	print("  service muet derrière un lanceur : page rendue en %.0f ms (délai %d ms)" % [mute_ms, SHORT_TIMEOUT_MS])
	_check(mute_ms >= SHORT_TIMEOUT_MS and mute_ms < SHORT_TIMEOUT_MS + 1500 and BookTextScript.last_error.contains("n'a pas répondu"),
		"service muet derrière un lanceur : la lecture rend la main au délai (%.0f ms)" % mute_ms)
	_check(not _running("time.sleep(53.17)"), "service muet derrière un lanceur : l'interpréteur enfant est arrêté")
	_check(BookTextScript.descendants(OS.get_process_id()).size() >= 0 and BookTextScript.launcher_selector("-3")
			and BookTextScript.launcher_selector("-3.12-64") and BookTextScript.launcher_selector("-V:3.12")
			and not BookTextScript.launcher_selector("-u") and not BookTextScript.launcher_selector("-X"),
		"sélecteurs de version du lanceur `py` reconnus (retirés de la commande directe)")

	BookTextScript.timeout_ms = saved[0]
	BookTextScript.start_timeout_ms = saved[1]
	BookTextScript.start_retry_ms = saved[2]
	ProjectSettings.set_setting(BookTextScript.PYTHON_SETTING, "")
	BookTextScript.restart()
	DirAccess.remove_absolute(slow)
	DirAccess.remove_absolute(child)


## Service d'arrière-plan : les genres des livres d'une galerie arrivent par ticket, comme le
## service du fil principal les donne ; le fil principal lit des pages pendant ce temps ; arrêté,
## le service rend une erreur aux requêtes en file.
func _check_background() -> void:
	var start := Time.get_ticks_usec()
	var tickets := [BookTextScript.submit_gallery_flags("h", 0, "-3", 0), BookTextScript.submit_gallery_flags("g", 1, "-2", -1)]
	var submit_ms := _ms(start)
	var lines := BookTextScript.page_lines(5, 5, 0, 0, 0, 0)
	var flags := []
	var deadline := Time.get_ticks_msec() + 20000
	while flags.size() < tickets.size() and Time.get_ticks_msec() < deadline:
		var response: Variant = BookTextScript.take(tickets[flags.size()])
		if response == null:
			OS.delay_msec(5)
		else:
			flags.append(response.get("is_image", []))
	_check(submit_ms < 2.0 and lines[0].length() == 80, "deux requêtes en arrière-plan : %.2f ms sur le fil principal, qui lit une page entre-temps" % submit_ms)
	var expected := BookTextScript.gallery_image_books(17, -3)
	_check(flags.size() == 2 and flags[0] == expected and flags[1] == expected and expected.size() == 640,
		"genres d'une galerie par le service d'arrière-plan = ceux du fil principal (h = 17, coordonnée calculée sur le fil)")
	var held := BookTextScript.submit({"op": "ping"})
	BookTextScript.cancel(held)
	var late := []
	for i in 4:
		late.append(BookTextScript.submit({"op": "is_image_book", "gallery": {"hexagon": str(i), "level": "0"}}))
	BookTextScript.shutdown()
	var stopped := 0
	for ticket: int in late:
		var response: Variant = BookTextScript.take(ticket)
		if response is Dictionary and (response.has("is_image") or response.get("code") == "stopped"):
			stopped += 1
	_check(stopped == late.size() and BookTextScript.take(held) == null and BookTextScript.pending() == 0,
		"arrêt : chaque requête en file a sa réponse ou l'erreur « stopped », un ticket annulé n'en a pas")


func _launcher(file_name: String, body: String) -> String:
	var path := OS.get_cache_dir().path_join(file_name)
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string("#!/bin/sh\n" + body)
	file.close()
	OS.execute("chmod", ["+x", path])
	return path


## Vrai si un processus dont la ligne de commande contient `marker` tourne encore.
func _running(marker: String) -> bool:
	OS.delay_msec(100)
	var output := []
	var pattern := "[%s]%s" % [marker[0], marker.substr(1)]   # ne se reconnaît pas lui-même (sh -c)
	OS.execute("pgrep", ["-f", pattern], output)
	if not "".join(output).strip_edges().is_empty():
		var listing := []
		OS.execute("pgrep", ["-af", pattern], listing)
		print("    encore là : %s" % "".join(listing).strip_edges().replace("\n", " / "))
	return not "".join(output).strip_edges().is_empty()


## Une image de test : bandes de couleur et rectangles semi-transparents (remplissages rapides).
@warning_ignore("integer_division")
func _pattern(size: Vector2i, format: Image.Format) -> Image:
	var img := Image.create(size.x, size.y, false, format)
	img.fill(Color8(30, 60, 90, 255))
	var rng := RandomNumberGenerator.new()
	rng.seed = size.x * 7919 + size.y
	for i in 120:
		var rect := Rect2i(rng.randi_range(0, size.x - 1), rng.randi_range(0, size.y - 1),
			rng.randi_range(1, maxi(1, size.x / 3)), rng.randi_range(1, maxi(1, size.y / 3)))
		img.fill_rect(rect, Color8(rng.randi() & 0xFF, rng.randi() & 0xFF, rng.randi() & 0xFF, rng.randi_range(0, 255)))
	for x in range(0, size.x, 7):
		img.fill_rect(Rect2i(x, 0, 1, size.y), Color8((x * 13) & 0xFF, 200, (x * 5) & 0xFF, 255))
	return img


func _ms(since: int) -> float:
	return (Time.get_ticks_usec() - since) / 1000.0


func _check(condition: bool, label: String) -> void:
	print(("  ok    " if condition else "  ÉCHEC ") + label)
	if not condition:
		_failures += 1
