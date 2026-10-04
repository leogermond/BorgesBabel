extends SceneTree
## Vérifie le texte des livres : déterminisme, forme des pages, alphabet, diversité.
## godot --headless --path . -s tests/test_book_text.gd

const BookTextScript := preload("res://scripts/book_text.gd")

var _failures := 0


func _init() -> void:
	var hexagon := 4611686018427387903   # 2^62 − 1 : une adresse lointaine
	var page := BookTextScript.page_lines(hexagon, -7, 2, 4, 31, 409)

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

	print("test_book_text : %s" % ("OK" if _failures == 0 else "%d échec(s)" % _failures))
	quit(1 if _failures else 0)


func _check(condition: bool, label: String) -> void:
	print(("  ok    " if condition else "  ÉCHEC ") + label)
	if not condition:
		_failures += 1
