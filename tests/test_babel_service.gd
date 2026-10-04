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

	var words_path := OS.get_cache_dir().path_join("babel_test_texte.txt")
	var words := FileAccess.open(words_path, FileAccess.WRITE)
	words.store_string("Le monde, Ô lecteur.")
	words.close()
	var from_text := BookTextScript.search_text_file(words_path)
	_check(BookTextScript.page_lines_at(from_text)[0].begins_with("le monde, o lecteur."), "search_text_file lit le fichier")
	DirAccess.remove_absolute(words_path)

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


func _ms(since: int) -> float:
	return (Time.get_ticks_usec() - since) / 1000.0


func _check(condition: bool, label: String) -> void:
	print(("  ok    " if condition else "  ÉCHEC ") + label)
	if not condition:
		_failures += 1
