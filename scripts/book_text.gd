class_name BookText
extends RefCounted
## Texte des livres de la Bibliothèque, au format décrit par Borges :
## 410 pages, 40 lignes par page, 80 caractères par ligne, 25 symboles.
##
## Chaque page se calcule à la demande à partir de son adresse complète
## (hexagone, niveau, mur, étagère, livre, page) : l'adresse passe par SHA-256,
## les 8 premiers octets du condensat donnent la graine d'un générateur
## pseudo-aléatoire, qui tire les 3200 caractères. La même adresse donne donc
## toujours la même page.

## 22 lettres (l'alphabet latin privé de k, q, w, y), l'espace, la virgule, le point.
const ALPHABET := "abcdefghijlmnoprstuvxz ,."
const PAGES := 410
const LINES := 40
const CHARS := 80


## Les 40 lignes de la page `page` (0 à 409) du livre désigné.
static func page_lines(hexagon: int, level: int, wall: int, shelf: int, book: int, page: int) -> PackedStringArray:
	assert(page >= 0 and page < PAGES, "page hors du livre : %d" % page)
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed("page", [hexagon, level, wall, shelf, book, page])
	var symbols := ALPHABET.to_ascii_buffer()
	var line := PackedByteArray()
	line.resize(CHARS)
	var lines := PackedStringArray()
	for _l in LINES:
		for c in CHARS:
			line[c] = symbols[rng.randi() % symbols.size()]
		lines.append(line.get_string_from_ascii())
	return lines


## Le titre inscrit sur le dos du livre : quelques lettres tirées de la même façon.
static func title(hexagon: int, level: int, wall: int, shelf: int, book: int) -> String:
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed("titre", [hexagon, level, wall, shelf, book])
	var letters := ALPHABET.substr(0, 22) + " "
	var text := ""
	for _i in rng.randi_range(6, 24):
		text += letters[rng.randi() % letters.length()]
	return text.strip_edges()


static func _seed(kind: String, parts: Array) -> int:
	var words := PackedStringArray([kind])
	for part in parts:
		words.append(str(part))
	return "|".join(words).sha256_buffer().decode_u64(0)
