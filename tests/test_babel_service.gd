extends SceneTree
## Mesure le service Python à travers BookText et vérifie la recherche d'image et l'absence de Python.
## godot --headless --path . -s tests/test_babel_service.gd
## La dernière vérification provoque volontairement des erreurs « Python introuvable » dans le journal.

const BookTextScript := preload("res://scripts/book_text.gd")
const PAGE_LATENCY_TARGET_MS := 50.0

var _failures := 0


func _init() -> void:
	var start := Time.get_ticks_usec()
	BookTextScript.page_lines(0, 0, 0, 0, 0, 0)
	print("  lancement du service et première page : %.1f ms" % _ms(start))

	start = Time.get_ticks_usec()
	for p in 50:
		BookTextScript.page_lines(123456, -42, p % 4, p % 5, p % 32, p)
	var page_ms := _ms(start) / 50.0
	_check(page_ms < PAGE_LATENCY_TARGET_MS, "page à travers le service : %.2f ms (cible < %.0f ms)" % [page_ms, PAGE_LATENCY_TARGET_MS])

	var far := BookTextScript.search_text("loin")
	start = Time.get_ticks_usec()
	for p in 20:
		far.page = p
		BookTextScript.page_lines_at(far)
	print("  page d'une adresse trouvée (hexagone de %d chiffres) : %.2f ms" % [far.hexagon.length(), _ms(start) / 20.0])

	start = Time.get_ticks_usec()
	var flags := BookTextScript.gallery_image_books(17, -3)
	print("  640 genres de livres en une requête : %.1f ms" % _ms(start))
	_check(flags.size() == 640, "640 genres rendus")

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
		_check(not game.is_empty() and game == full, "%d × %d : points de grille du jeu → même adresse que l'image complète" % [size.x, size.y])

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
		_check(code == 0 and not in_game.is_empty() and in_game == cli,
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
