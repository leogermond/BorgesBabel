class_name BookText
extends RefCounted
## Texte des livres de la Bibliothèque, au format décrit par Borges :
## 410 pages, 40 lignes par page, 80 caractères par ligne, 25 symboles.
##
## Les pages viennent du service Python `python/babel.py serve` : une bijection entre adresse
## et page, dans les deux sens, si bien que tout texte (ou toute image) se retrouve à son adresse.
## Ce script en est le client : il lance le service au premier appel, lui écrit une requête JSON
## par ligne et lit la réponse sur la ligne suivante, de façon synchrone.
##
## Une adresse est un Dictionary {hexagon: String, level: String, wall, shelf, book, page: int} :
## hexagone et niveau sont des entiers relatifs décimaux, de plusieurs milliers de chiffres pour
## une adresse trouvée par la recherche. BookText.address() en fabrique une à partir d'entiers.
##
## Interpréteur : le réglage de projet `babel/python_command` (par exemple `py -3` ou un chemin
## entre guillemets) ; à défaut `py -3`, `python`, puis `python3` sous Windows, `python3` ailleurs.
## Sans Python, les pages affichent le message d'erreur et le journal le reprend.

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
const PROTOCOL := 1
## Côté le plus long envoyé au service par search_image : l'image se réduit d'abord dans Godot.
const MAX_SENT_SIDE := 8 * IMAGE_HEIGHT

## Dernière erreur du service (vide quand tout va bien).
static var last_error := ""
static var _stdio: FileAccess
static var _stderr: FileAccess
static var _pid := -1
static var _unavailable := false
static var _palette := PackedByteArray()


# --- Adresses -------------------------------------------------------------------------------

## L'adresse d'une page à partir d'entiers.
static func address(hexagon: int, level: int, wall: int, shelf: int, book: int, page: int) -> Dictionary:
	return {"hexagon": str(hexagon), "level": str(level), "wall": wall, "shelf": shelf, "book": book, "page": page}


## Forme courte d'une adresse pour l'écran (grands nombres abrégés, mur, étagère, livre, page comptés depuis 1).
static func display(target: Dictionary) -> String:
	var response := _request({"op": "display", "address": target})
	return response.get("short", _describe_error(response))


## Forme complète « hexagone:niveau:mur:étagère:livre:page », relue par `python babel.py page`.
static func full_form(target: Dictionary) -> String:
	return "%s:%s:%d:%d:%d:%d" % [target.hexagon, target.level, target.wall, target.shelf, target.book, target.page]


# --- Pages ----------------------------------------------------------------------------------

## Les 40 lignes de la page `page` (0 à 409) du livre désigné.
static func page_lines(hexagon: int, level: int, wall: int, shelf: int, book: int, page: int) -> PackedStringArray:
	assert(page >= 0 and page < PAGES, "page hors du livre : %d" % page)
	return page_lines_at(address(hexagon, level, wall, shelf, book, page))


## Les 40 lignes de la page à l'adresse donnée ; en cas d'erreur, le message occupe la page.
static func page_lines_at(target: Dictionary) -> PackedStringArray:
	var response := _request({"op": "page", "address": target})
	if response.has("error"):
		return _error_lines(_describe_error(response))
	return PackedStringArray(response.lines)


## La page à l'adresse donnée lue comme une image de 50 × 64 pixels aux encres de la palette
## (quel que soit le genre du livre) ; null en cas d'erreur (voir last_error).
static func page_image_at(target: Dictionary) -> Image:
	var palette := _ink_bytes()
	if palette.is_empty():
		return null
	var response := _request({"op": "page", "address": target, "as_image": true})
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


static func page_image(hexagon: int, level: int, wall: int, shelf: int, book: int, page: int) -> Image:
	return page_image_at(address(hexagon, level, wall, shelf, book, page))


## Vrai pour un livre d'images (un sur 50 environ) : toutes ses pages se lisent comme des images.
static func is_image_book(hexagon: int, level: int, wall: int, shelf: int, book: int) -> bool:
	var flags := image_books([address(hexagon, level, wall, shelf, book, 0)])
	return not flags.is_empty() and flags[0]


## Le genre de chaque livre de la liste d'adresses (la page est ignorée), en une seule requête ;
## tableau vide en cas d'erreur.
static func image_books(books: Array) -> Array:
	var response := _request({"op": "is_image_book", "books": books})
	return response.get("is_image", [])


## Les 640 livres d'une galerie, rangés à l'indice (mur·5 + étagère)·32 + livre : vrai pour un livre d'images.
static func gallery_image_books(hexagon: int, level: int) -> Array:
	var books := []
	for wall in WALLS:
		for shelf in SHELVES:
			for book in BOOKS:
				books.append(address(hexagon, level, wall, shelf, book, 0))
	return image_books(books)


## Le titre inscrit sur le dos du livre : quelques lettres tirées d'un condensat SHA-256 de son adresse.
static func title(hexagon: int, level: int, wall: int, shelf: int, book: int) -> String:
	var rng := RandomNumberGenerator.new()
	var words := PackedStringArray(["titre", str(hexagon), str(level), str(wall), str(shelf), str(book)])
	rng.seed = "|".join(words).sha256_buffer().decode_u64(0)
	var letters := ALPHABET.substr(0, 22) + " "
	var text := ""
	for _i in rng.randi_range(6, 24):
		text += letters[rng.randi() % letters.length()]
	return text.strip_edges()


# --- Recherche inverse ----------------------------------------------------------------------

## L'adresse d'une page de livre de texte qui montre `text` normalisé et complété d'espaces ;
## {} en cas d'erreur (voir last_error).
static func search_text(text: String) -> Dictionary:
	return _request({"op": "search_text", "text": text}).get("address", {})


static func search_text_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		last_error = "fichier introuvable : %s" % path
		push_error(last_error)
		return {}
	return search_text(FileAccess.get_file_as_string(path))


## L'adresse d'une page de livre d'images qui montre l'image, ajustée à 50 × 64 et tramée aux
## encres de la palette par le service ; {} en cas d'erreur (voir last_error).
static func search_image(source: Image) -> Dictionary:
	var img := source.duplicate() as Image
	if img.is_compressed():
		img.decompress()
	var longest := maxi(img.get_width(), img.get_height())
	if longest > MAX_SENT_SIDE:
		var ratio := float(MAX_SENT_SIDE) / longest
		img.resize(maxi(1, roundi(img.get_width() * ratio)), maxi(1, roundi(img.get_height() * ratio)), Image.INTERPOLATE_LANCZOS)
	img.convert(Image.FORMAT_RGBA8)
	return _request({"op": "search_image", "width": img.get_width(), "height": img.get_height(),
		"rgba": Marshalls.raw_to_base64(img.get_data())}).get("address", {})


## Comme search_image, à partir d'un fichier PNG, JPG ou WebP chargé par Godot.
static func search_image_file(path: String) -> Dictionary:
	var img := Image.load_from_file(path)
	if img == null or img.is_empty():
		last_error = "image illisible : %s" % path
		push_error(last_error)
		return {}
	return search_image(img)


# --- Service --------------------------------------------------------------------------------

## Arrête le service (appelé à la fermeture du jeu par l'autoload BabelService).
static func shutdown() -> void:
	if _pid > 0:
		OS.kill(_pid)
	_pid = -1
	_stdio = null
	_stderr = null


## Oublie un échec de lancement : le prochain appel relance la recherche de l'interpréteur.
static func restart() -> void:
	shutdown()
	_unavailable = false


## Une requête au service, sa réponse ; {"error": …} quand le service manque ou refuse.
static func _request(request: Dictionary) -> Dictionary:
	if _stdio == null and not _start():
		return {"error": last_error}
	var response := _exchange(request)
	if response.is_empty():
		shutdown()
		last_error = "le service Python s'est arrêté pendant la requête « %s »" % request.get("op")
		push_error(last_error)
		return {"error": last_error}
	if response.has("error"):
		last_error = str(response.error)
		push_error("babel.py : " + last_error)
	return response


static func _exchange(request: Dictionary) -> Dictionary:
	_stdio.store_line(JSON.stringify(request))
	_stdio.flush()
	var line := _stdio.get_line()
	if line.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(line)
	return parsed if parsed is Dictionary else {"error": "réponse illisible : %s" % line.left(200)}


static func _start() -> bool:
	if _unavailable:
		return false
	var script := ProjectSettings.globalize_path(SCRIPT_PATH)
	var tried := PackedStringArray()
	for command in _interpreters():
		var args := PackedStringArray(command.slice(1))
		args.append_array(["-X", "utf8", "-u", script, "serve"])
		tried.append(" ".join(command))
		var process := OS.execute_with_pipe(command[0], args)
		if process.is_empty():
			continue
		_stdio = process.stdio
		_stderr = process.stderr
		_pid = process.pid
		if _exchange({"op": "ping"}).get("protocol") == PROTOCOL:
			last_error = ""
			return true
		shutdown()
	_unavailable = true
	last_error = "Python 3.10 ou plus est introuvable (essayé : %s). Installer Python, ou indiquer la commande dans le réglage de projet %s." % [", ".join(tried), PYTHON_SETTING]
	push_error(last_error)
	return false


## Les commandes candidates, chacune en tableau [exécutable, arguments…].
static func _interpreters() -> Array:
	var setting := str(ProjectSettings.get_setting(PYTHON_SETTING, "")).strip_edges()
	if not setting.is_empty():
		return [_split_command(setting)]
	if OS.get_name() == "Windows":
		return [["py", "-3"], ["python"], ["python3"]]
	return [["python3"]]


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
