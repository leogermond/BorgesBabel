extends SceneTree
## Vérifie le texte des livres à travers le client BookText et le vrai service Python :
## déterminisme, forme des pages, alphabet, diversité, recherche de texte, page d'image.
## godot --headless --path . -s tests/test_book_text.gd

const BookTextScript := preload("res://scripts/book_text.gd")

var _failures := 0


func _init() -> void:
	var hexagon := 4611686018427387903   # 2^62 − 1 : une adresse lointaine
	var page := BookTextScript.page_lines(hexagon, -7, 2, 4, 31, 409)
	_check(BookTextScript.last_error.is_empty(), "le service Python répond (%s)" % BookTextScript.last_error)

	_check(page == BookTextScript.page_lines(hexagon, -7, 2, 4, 31, 409), "même adresse → même page")
	_check(BookTextScript.title(hexagon, -7, 2, 4, 31) == BookTextScript.title(hexagon, -7, 2, 4, 31), "même adresse → même titre")

	_check(page.size() == 40, "40 lignes par page (lu : %d)" % page.size())
	var widths := {}
	for line in page:
		widths[line.length()] = true
	_check(widths.keys() == [80], "80 caractères par ligne (lu : %s)" % [widths.keys()])

	_check(BookTextScript.ALPHABET.length() == 25, "alphabet de 25 symboles")
	var seen := {}
	for p in [0, 1, 205, 409]:
		for line in BookTextScript.page_lines(0, 0, 0, 0, 0, p):
			for c in line:
				seen[c] = true
	for line in page:
		for c in line:
			seen[c] = true
	var foreign := seen.keys().filter(func(c: String) -> bool: return not BookTextScript.ALPHABET.contains(c))
	_check(foreign.is_empty(), "seuls les 25 symboles apparaissent (intrus : %s)" % [foreign])
	_check(seen.size() == 25, "les 25 symboles apparaissent tous sur 5 pages (vus : %d)" % seen.size())
	for letter in "kqwy":
		_check(not seen.has(letter), "la lettre %s est absente" % letter)

	var base := BookTextScript.page_lines(1, 1, 1, 1, 1, 1)
	var neighbours := {
		"autre hexagone": BookTextScript.page_lines(2, 1, 1, 1, 1, 1),
		"autre niveau": BookTextScript.page_lines(1, 2, 1, 1, 1, 1),
		"autre mur": BookTextScript.page_lines(1, 1, 2, 1, 1, 1),
		"autre étagère": BookTextScript.page_lines(1, 1, 1, 2, 1, 1),
		"autre livre": BookTextScript.page_lines(1, 1, 1, 1, 2, 1),
		"autre page": BookTextScript.page_lines(1, 1, 1, 1, 1, 2),
	}
	for label in neighbours:
		_check(neighbours[label] != base, "%s → texte différent" % label)

	# Recherche inverse : le texte normalisé se lit en tête de la page trouvée.
	var found := BookTextScript.search_text("La Bibliothèque de Babel, Kafka et Wittgenstein.")
	_check(not found.is_empty() and found.hexagon.length() > 100, "search_text rend une adresse lointaine (%d chiffres)" % str(found.get("hexagon", "")).length())
	var lines := BookTextScript.page_lines_at(found)
	_check(lines[0] == "la bibliothecue de babel, cafca et vittgenstein.".rpad(80), "la page trouvée montre le texte normalisé : « %s »" % lines[0])
	_check("".join(lines.slice(1)).strip_edges().is_empty(), "le reste de la page est blanc")
	_check(not BookTextScript.image_books([found])[0], "search_text tombe dans un livre de texte")
	_check(BookTextScript.display(found).begins_with("hexagone "), "forme courte : %s" % BookTextScript.display(found))

	# Livres d'images : un sur 50 environ ; leurs pages se lisent comme des images.
	var flags := BookTextScript.gallery_image_books(0, 0)
	_check(flags.size() == 640, "gallery_image_books rend 640 genres (lu : %d)" % flags.size())
	var index := flags.find(true)
	_check(index >= 0, "la galerie (0, 0) contient au moins un livre d'images")
	if index >= 0:
		@warning_ignore("integer_division")
		var wall := index / 160
		@warning_ignore("integer_division")
		var shelf := (index / 32) % 5
		var book := index % 32
		_check(BookTextScript.is_image_book(0, 0, wall, shelf, book), "is_image_book confirme le livre %d" % index)
		var img := BookTextScript.page_image(0, 0, wall, shelf, book, 0)
		_check(img != null and img.get_width() == 50 and img.get_height() == 64, "une page d'image se décode en Image 50 × 64")
		if img != null:
			_check(_inks_only(img), "chaque pixel prend une des 25 encres")

	print("test_book_text : %s" % ("OK" if _failures == 0 else "%d échec(s)" % _failures))
	BookTextScript.shutdown()
	quit(1 if _failures else 0)


func _inks_only(img: Image) -> bool:
	var inks := {}
	var palette := BookTextScript._ink_bytes()
	for i in 25:
		inks[Color8(palette[i * 3], palette[i * 3 + 1], palette[i * 3 + 2]).to_html(false)] = true
	for y in img.get_height():
		for x in img.get_width():
			if not inks.has(img.get_pixel(x, y).to_html(false)):
				return false
	return true


func _check(condition: bool, label: String) -> void:
	print(("  ok    " if condition else "  ÉCHEC ") + label)
	if not condition:
		_failures += 1
