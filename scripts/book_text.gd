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

const BookSpineScript := preload("res://scripts/book_spine.gd")

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
const PROTOCOL := 2
## Quand le service meurt pendant une requête : attente de sa fin, lignes d'erreur reprises.
const STDERR_WAIT_MS := 1000
const STDERR_TAIL_LINES := 5

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
	return BookSpineScript.display_title(BookSpineScript.title(hexagon, level, wall, shelf, book))


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
## Seuls les points de la grille image_grid partent au service (au plus 200 × 256 pixels, quelle
## que soit la taille de l'image) : la ligne de commande `babel.py search-image` lit les mêmes
## points dans le PNG, si bien que la même image donne la même adresse dans le jeu et hors du jeu.
static func search_image(source: Image) -> Dictionary:
	var request := image_request(source)
	if request.is_empty():
		return {}
	return _request(request).get("address", {})


## La requête search_image d'une image : largeur et hauteur d'origine, et ses points de grille
## en RGBA (4 octets par point, ligne de grille après ligne de grille), en base 64.
static func image_request(source: Image) -> Dictionary:
	if source == null or source.is_empty():
		last_error = "image vide"
		push_error(last_error)
		return {}
	var img := source
	if img.is_compressed() or not (img.get_format() in [Image.FORMAT_L8, Image.FORMAT_LA8, Image.FORMAT_RGB8, Image.FORMAT_RGBA8]):
		img = source.duplicate() as Image
		if img.is_compressed():
			img.decompress()
		img.convert(Image.FORMAT_RGBA8)
	var width := img.get_width()
	var height := img.get_height()
	var grid := image_grid(width, height)
	var cols: PackedInt64Array = grid.cols
	var rows: PackedInt64Array = grid.rows
	var data := img.get_data()   # partagé avec l'image (copie à l'écriture), pas recopié
	var format := img.get_format()
	var bpp: int = {Image.FORMAT_L8: 1, Image.FORMAT_LA8: 2, Image.FORMAT_RGB8: 3, Image.FORMAT_RGBA8: 4}[format]
	var samples := PackedByteArray()
	samples.resize(cols.size() * rows.size() * 4)
	var o := 0
	for y in rows:
		var row := y * width
		for x in cols:
			var p := (row + x) * bpp
			match format:
				Image.FORMAT_RGBA8:
					samples[o] = data[p]
					samples[o + 1] = data[p + 1]
					samples[o + 2] = data[p + 2]
					samples[o + 3] = data[p + 3]
				Image.FORMAT_RGB8:
					samples[o] = data[p]
					samples[o + 1] = data[p + 1]
					samples[o + 2] = data[p + 2]
					samples[o + 3] = 255
				Image.FORMAT_LA8:
					samples[o] = data[p]
					samples[o + 1] = data[p]
					samples[o + 2] = data[p]
					samples[o + 3] = data[p + 1]
				_:
					samples[o] = data[p]
					samples[o + 1] = data[p]
					samples[o + 2] = data[p]
					samples[o + 3] = 255
			o += 4
	return {"op": "search_image", "width": width, "height": height, "samples": Marshalls.raw_to_base64(samples)}


## La grille d'échantillonnage d'une image width × height, en arithmétique entière seule, à
## l'identique de image_grid dans python/babel.py : {fit_w, fit_h, cols, rows}. L'image ajustée
## occupe fit_w × fit_h pixels de la page (arrondi moitié vers le haut) ; chaque pixel lit
## step × step points, step = min(4, ⌈côté source / côté ajusté⌉), et le point k d'un axe est
## ⌊(2k + 1)·côté source / (2·step·côté ajusté)⌋.
@warning_ignore("integer_division")
static func image_grid(width: int, height: int) -> Dictionary:
	var fit_w := IMAGE_WIDTH
	var fit_h := IMAGE_HEIGHT
	if IMAGE_WIDTH * height <= IMAGE_HEIGHT * width:
		fit_h = clampi((2 * height * IMAGE_WIDTH + width) / (2 * width), 1, IMAGE_HEIGHT)
	else:
		fit_w = clampi((2 * width * IMAGE_HEIGHT + height) / (2 * height), 1, IMAGE_WIDTH)
	var step_x := mini(4, (width + fit_w - 1) / fit_w)
	var step_y := mini(4, (height + fit_h - 1) / fit_h)
	var cols := PackedInt64Array()
	for k in fit_w * step_x:
		cols.append((2 * k + 1) * width / (2 * step_x * fit_w))
	var rows := PackedInt64Array()
	for k in fit_h * step_y:
		rows.append((2 * k + 1) * height / (2 * step_y * fit_h))
	return {"fit_w": fit_w, "fit_h": fit_h, "cols": cols, "rows": rows}


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
		var tail := _stop_and_read_stderr()
		last_error = "le service Python s'est arrêté pendant la requête « %s »" % request.get("op")
		if not tail.is_empty():
			last_error += " : " + tail
		push_error(last_error)
		return {"error": last_error}
	if response.has("error"):
		last_error = str(response.error)
		push_error("babel.py : " + last_error)
	return response


## Arrête le service et rend les dernières lignes de son erreur standard (une trace Python,
## par exemple), jointes par « | ». Le processus est attendu une seconde au plus, puis tué :
## une fois le processus fini, la lecture du tube atteint sa fin au lieu d'attendre.
static func _stop_and_read_stderr() -> String:
	var err := _stderr
	var pid := _pid
	var waited := 0
	while pid > 0 and OS.is_process_running(pid) and waited < STDERR_WAIT_MS:
		OS.delay_msec(10)
		waited += 10
	if pid > 0 and OS.is_process_running(pid):
		OS.kill(pid)
	_pid = -1
	shutdown()
	if err == null:
		return ""
	var lines := PackedStringArray()
	for _i in 10000:
		var line := err.get_line()
		if line.is_empty() and err.get_error() != OK:
			break
		if not line.strip_edges().is_empty():
			lines.append(line.strip_edges())
	return " | ".join(lines.slice(-STDERR_TAIL_LINES))


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
