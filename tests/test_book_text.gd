extends SceneTree
## Vérifie le texte des livres à travers le client BookText et le vrai service Python (protocole 3) :
## déterminisme, forme des pages, alphabet, diversité, recherche de texte (un texte de plusieurs pages
## occupe les pages consécutives d'un même livre), clés de livres, livres d'images.
## godot --headless --path . -s tests/test_book_text.gd

const BookTextScript := preload("res://scripts/book_text.gd")

var _failures := 0


func _init() -> void:
	var hexagon := 4611686018427387903   # 2^62 − 1 : une adresse lointaine
	var page := BookTextScript.page_lines(hexagon, -7, 2, 4, 31, 409)
	_check(BookTextScript.last_error.is_empty(), "le service Python répond (%s)" % BookTextScript.last_error)

	_check(page == BookTextScript.page_lines(hexagon, -7, 2, 4, 31, 409), "même adresse → même page")
	_check(page == BookTextScript.page_lines(BookTextScript.b25_from_int(hexagon), "-7", 2, 4, 31, 409), "int ou base 25 : même page")
	_check(BookTextScript.title(hexagon, -7, 2, 4, 31) == BookTextScript.title(hexagon, -7, 2, 4, 31), "même adresse → même titre")
	_check(BookTextScript.title(hexagon, -7, 2, 4, 31) == BookTextScript.title_at(BookTextScript.address(hexagon, -7, 2, 4, 31)),
		"titre identique depuis des int ou depuis l'adresse")

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

	# Recherche inverse : le livre trouvé montre le texte normalisé en tête de sa page 0, puis des espaces.
	var found := BookTextScript.search_text("La Bibliothèque de Babel, Kafka et Wittgenstein.")
	_check(found.size() == 5 and found.hexagon.length() > 600000 and found.level.length() > 600000,
		"search_text rend une adresse de livre lointaine (%d chiffres base 25)" % str(found.get("hexagon", "")).length())
	_check(BookTextScript.last_search.get("text_pages") == 1 and BookTextScript.last_search.get("truncated") == false and BookTextScript.last_search.get("is_image") == false,
		"last_search : une page, non tronqué, livre de texte")
	var lines := BookTextScript.page_lines_at(found)
	_check(lines[0] == "la bibliothecue de babel, cafca et vittgenstein.".rpad(80), "la page 0 montre le texte normalisé : « %s »" % lines[0])
	_check("".join(lines.slice(1)).strip_edges().is_empty(), "le reste de la page est blanc")
	_check("".join(BookTextScript.page_lines_at(found, 409)) == " ".repeat(3200), "la dernière page du livre est blanche")
	_check(not BookTextScript.image_books([found])[0], "search_text tombe dans un livre de texte")
	_check(BookTextScript.display(found).begins_with("hexagone "), "forme courte : %s" % BookTextScript.display(found).left(120))
	_check(not BookTextScript.title_at(found).is_empty(), "un livre lointain a un titre")

	# Clés : la page suivante part par la clé ; une clé oubliée par le service est remplacée.
	var book := BookTextScript.book_of(found)
	var key: String = BookTextScript._keys.get(book, "")
	_check(key.length() == 20, "le livre trouvé a une clé de service (%s)" % key)
	BookTextScript._keys[book] = "0123456789abcdef0123"
	var again := BookTextScript.page_lines_at(found, 0)
	_check(again == lines and BookTextScript._keys.get(book) == key, "clé inconnue du service : l'adresse repart, la vraie clé revient")

	# Un texte de plusieurs pages occupe les pages 0, 1, 2 … consécutives d'un même livre.
	var long_text := ""
	for i in 7000:
		long_text += BookTextScript.ALPHABET[(i * 31 + i / 7) % 25]
	var long_book := BookTextScript.search_text(long_text)
	_check(BookTextScript.last_search.get("text_pages") == 3, "texte de 7000 symboles : 3 pages (lu : %s)" % BookTextScript.last_search.get("text_pages"))
	var read_back := ""
	for p in 3:
		read_back += "".join(BookTextScript.page_lines_at(long_book, p))
	_check(read_back == long_text.rpad(9600), "pages 0, 1, 2 du livre trouvé : le texte, coulé de page en page, puis des espaces")
	_check("".join(BookTextScript.page_lines_at(long_book, 3)) == " ".repeat(3200), "page 3 : blanche")
	var marked := BookTextScript.search_text("  ., le livre d'images")
	_check(not marked.is_empty() and BookTextScript.last_search.get("is_image") == true and BookTextScript.last_search.has("notice"),
		"un texte qui commence par deux signes tombe dans un livre d'images, avec un avis")

	# Livres d'images : un sur 144 ; leurs pages se lisent comme des images.
	var flags := BookTextScript.gallery_image_books(0, 0)
	_check(flags.size() == 640, "gallery_image_books rend 640 genres (lu : %d)" % flags.size())
	var gallery := 0
	var index := flags.find(true)
	while index < 0 and gallery < 20:   # (143/144)^640 ≈ 1 % : une galerie peut n'en avoir aucun
		gallery += 1
		flags = BookTextScript.gallery_image_books(gallery, 0)
		index = flags.find(true)
	_check(index >= 0, "la galerie (%d, 0) contient au moins un livre d'images" % gallery)
	var count := 0
	for g in 10:
		count += BookTextScript.gallery_image_books(g, 3).count(true)
	_check(count >= 20 and count <= 80, "6400 livres : %d livres d'images (attendu ~44, un sur 144)" % count)
	if index >= 0:
		@warning_ignore("integer_division")
		var wall := index / 160
		@warning_ignore("integer_division")
		var shelf := (index / 32) % 5
		var slot := index % 32
		_check(BookTextScript.is_image_book(gallery, 0, wall, shelf, slot), "is_image_book confirme le livre %d" % index)
		var img := BookTextScript.page_image(gallery, 0, wall, shelf, slot, 0)
		_check(img != null and img.get_width() == 50 and img.get_height() == 64, "une page d'image se décode en Image 50 × 64")
		if img != null:
			_check(_inks_only(img), "chaque pixel prend une des 25 encres")
	var far_flags := BookTextScript.gallery_image_books(found.hexagon, found.level)
	_check(far_flags.size() == 640 and far_flags[(found.wall * 5 + found.shelf) * 32 + found.book] == false,
		"genres d'une galerie lointaine (forme gallery) : le livre trouvé est un livre de texte")

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
