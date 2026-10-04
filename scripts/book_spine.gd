class_name BookSpine
extends RefCounted
## Dos des livres : titre court en lettres dorées, composé en Lora.
##
## Le titre se tire de l'adresse du livre seule (hexagone, niveau, mur, étagère, livre), jamais
## de son contenu : SHA-256 de l'adresse, puis un tirage simple d'octets parmi les 25 symboles.
## Le même livre porte donc toujours le même titre, sur toute machine.
##
## Affichage : un seul matériau partagé (material()) dessine le titre sur la face du dos dans le
## shader, à partir d'un atlas des 25 glyphes de Lora rendu une fois sur le processeur. Une galerie
## n'écrit que 4 flottants par livre dans la donnée personnalisée de son MultiMesh (encode_title).
##
## Branchement dans gallery.gd :
##   _book_mesh.material = BookSpine.material()          # au lieu de _material("book")
##   multimesh.use_custom_data = true                     # tampon : 20 flottants par livre
##   var codes := BookSpine.gallery_codes(hexagon, level, image_flags)   # 640 Color, ordre (mur·5 + étagère)·32 + livre
##   buffer[o + 16] = codes[i].r ; buffer[o + 17] = codes[i].g ; buffer[o + 18] = codes[i].b ; buffer[o + 19] = codes[i].a
## Le titre exige des flottants 32 bits par instance : Forward+ et Mobile. Le moteur Compatibility
## (OpenGL) range la donnée personnalisée en demi-flottants ; le shader le reconnaît et montre
## alors le cuir nu, sans titre.

## Les 25 symboles de Borges, dans l'ordre de BookText.ALPHABET.
const ALPHABET := "abcdefghijlmnoprstuvxz ,."
const SPACE := 22                        # rang de l'espace dans ALPHABET
const MIN_LENGTH := 6
const MAX_LENGTH := 16
const SYMBOL_BITS := 5
const SYMBOLS_PER_CHANNEL := 4
const IMAGE_BIT := 20                    # drapeau « livre d'images », dans la composante r
## Chaque composante vaut MARK + charge utile : entier exact en flottant 32 bits (< 2^24),
## et un zéro (donnée absente) se distingue d'un titre.
const MARK := 8388608                    # 2^23
const WALLS := 4
const SHELVES := 5
const BOOKS := 32

const FONT_PATH := "res://fonts/Lora-VariableFont_wght.ttf"
const SHADER_PATH := "res://shaders/book_spine.gdshader"
const FONT_WEIGHT := 600                 # Lora variable : 400 à 700 ; demi-gras pour la dorure
const FONT_PX := 64                      # corps du rendu de l'atlas : 1 em = 64 pixels
const CELL_PX := 96                      # case carrée par glyphe
const ATLAS_COLUMNS := 5                 # 5 × 5 cases : 480 × 480 pixels
const PEN_PX := Vector2i(16, 70)         # point de chasse (origine de la ligne de base) dans la case

static var _material: ShaderMaterial
static var _atlas: Image
static var _advances := PackedFloat32Array()


# --- Titres ---------------------------------------------------------------------------------

## Le titre du livre désigné : 6 à 16 symboles, ni espace en tête ni en queue.
static func title(hexagon: int, level: int, wall: int, shelf: int, book: int) -> String:
	return _spell(_indices("dos|%d|%d|%d|%d|%d" % [hexagon, level, wall, shelf, book]))


## Même titre, depuis une adresse au format de BookText.address() (hexagone et niveau en
## décimal, de toute longueur) ; la page est ignorée.
static func title_at(target: Dictionary) -> String:
	return _spell(_indices("dos|%s|%s|%d|%d|%d" % [
		str(target.hexagon), str(target.level), target.wall, target.shelf, target.book]))


## Les rangs dans ALPHABET des symboles du titre, tirés des octets du condensat SHA-256 de la
## clé, avec rejet pour rester uniforme : la longueur parmi 11 valeurs (octet < 242), le
## premier et le dernier symbole parmi les 24 qui ne sont pas l'espace (octet < 240), les
## autres parmi les 25 (octet < 250). Un condensat épuisé se prolonge par le SHA-256 de son
## écriture hexadécimale.
static func _indices(key: String) -> PackedByteArray:
	var digest := key.sha256_buffer()
	var at := 0
	var length := 0
	var indices := PackedByteArray()
	var i := -1   # −1 : la longueur reste à tirer
	while i < length:
		if at == digest.size():
			digest = digest.hex_encode().sha256_buffer()
			at = 0
		var byte := digest[at]
		at += 1
		if i < 0:
			if byte < 242:
				length = MIN_LENGTH + byte % 11
				indices.resize(length)
				i = 0
		elif i == 0 or i == length - 1:
			if byte < 240:
				indices[i] = byte % 24 + (1 if byte % 24 >= SPACE else 0)
				i += 1
		elif byte < 250:
			indices[i] = byte % 25
			i += 1
	return indices


static func _spell(indices: PackedByteArray) -> String:
	var letters := ALPHABET.to_ascii_buffer()
	var text := PackedByteArray()
	text.resize(indices.size())
	for i in indices.size():
		text[i] = letters[indices[i]]
	return text.get_string_from_ascii().strip_edges()


# --- Codage pour le shader ------------------------------------------------------------------

## Les 4 flottants d'INSTANCE_CUSTOM pour ce titre : 4 symboles de 5 bits par composante
## (0 : fin, 1 à 25 : rang + 1), le drapeau d'image au bit 20 de r, MARK ajouté partout.
## Les symboles hors alphabet sont omis ; au-delà de 16 symboles, le titre est tronqué.
static func encode_title(text: String, image_book := false) -> Color:
	var indices := PackedByteArray()
	for c in text:
		var index := ALPHABET.find(c)
		if index >= 0:
			indices.append(index)
	return _encode(indices, image_book)


static func _encode(indices: PackedByteArray, image_book: bool) -> Color:
	var payload := PackedInt32Array([0, 0, 0, 0])
	for i in mini(indices.size(), MAX_LENGTH):
		payload[i / SYMBOLS_PER_CHANNEL] |= (indices[i] + 1) << (SYMBOL_BITS * (i % SYMBOLS_PER_CHANNEL))
	if image_book:
		payload[0] |= 1 << IMAGE_BIT
	return Color(MARK + payload[0], MARK + payload[1], MARK + payload[2], MARK + payload[3])


## Lecture inverse, à l'identique du shader : chaîne vide si une composante sort de [2^23, 2^24).
static func decode_title(code: Color) -> String:
	var payload := _payload(code)
	var text := ""
	if payload.is_empty():
		return text
	for i in MAX_LENGTH:
		var symbol := (payload[i / SYMBOLS_PER_CHANNEL] >> (SYMBOL_BITS * (i % SYMBOLS_PER_CHANNEL))) & 31
		if symbol == 0:
			break
		text += ALPHABET[symbol - 1] if symbol <= ALPHABET.length() else "?"
	return text


static func decode_image_flag(code: Color) -> bool:
	var payload := _payload(code)
	return not payload.is_empty() and (payload[0] >> IMAGE_BIT) & 1 == 1


static func _payload(code: Color) -> PackedInt32Array:
	var payload := PackedInt32Array()
	for value in [code.r, code.g, code.b, code.a]:
		if not (value >= MARK and value < 2 * MARK):
			return PackedInt32Array()
		payload.append(int(value) - MARK)
	return payload


## Les codes des 640 livres d'une galerie, rangés à l'indice (mur·5 + étagère)·32 + livre,
## comme BookText.gallery_image_books ; `image_books` (même ordre, facultatif) donne le drapeau.
static func gallery_codes(hexagon: int, level: int, image_books: Array = []) -> PackedColorArray:
	var codes := PackedColorArray()
	codes.resize(WALLS * SHELVES * BOOKS)
	var prefix := "dos|%d|%d|" % [hexagon, level]
	var i := 0
	for wall in WALLS:
		for shelf in SHELVES:
			for book in BOOKS:
				var image := i < image_books.size() and bool(image_books[i])
				codes[i] = _encode(_indices(prefix + "%d|%d|%d" % [wall, shelf, book]), image)
				i += 1
	return codes


# --- Matériau et atlas ----------------------------------------------------------------------

## Le matériau partagé des livres : cuir de la couleur d'instance, titre doré sur le dos.
static func material() -> ShaderMaterial:
	if _material != null:
		return _material
	_material = ShaderMaterial.new()
	_material.shader = load(SHADER_PATH)
	_material.set_shader_parameter("glyph_atlas", ImageTexture.create_from_image(glyph_atlas()))
	_material.set_shader_parameter("glyph_advance", glyph_advances())
	_material.set_shader_parameter("atlas_cell_em", float(CELL_PX) / FONT_PX)
	_material.set_shader_parameter("atlas_origin_em", Vector2(PEN_PX) / FONT_PX)
	_material.set_shader_parameter("atlas_columns", ATLAS_COLUMNS)
	return _material


## Chasse de chaque symbole de ALPHABET, en em.
static func glyph_advances() -> PackedFloat32Array:
	glyph_atlas()
	return _advances


## L'atlas des 25 symboles, blanc sur fond transparent (la couverture est dans l'alpha) :
## le symbole de rang k occupe la case (k % 5, k / 5), son point de chasse en PEN_PX.
## Rendu par FreeType via le TextServer, donc sans carte graphique, une fois par exécution.
static func glyph_atlas() -> Image:
	if _atlas != null:
		return _atlas
	var server := TextServerManager.get_primary_interface()
	var font := FontFile.new()
	if ResourceLoader.exists(FONT_PATH):
		font.data = (load(FONT_PATH) as FontFile).data
	else:
		font.load_dynamic_font(FONT_PATH)   # dépôt pas encore importé : le fichier TTF brut
	font.hinting = TextServer.HINTING_NONE
	font.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
	font.generate_mipmaps = false
	var rid: RID = font.get_rids()[0]
	server.font_set_variation_coordinates(rid, {server.name_to_tag("wght"): FONT_WEIGHT})
	var size := Vector2i(FONT_PX, 0)

	var side := ATLAS_COLUMNS * CELL_PX
	var atlas := Image.create(side, side, false, Image.FORMAT_RGBA8)
	atlas.fill(Color(1.0, 1.0, 1.0, 0.0))
	# Tous les glyphes d'abord : le cache du TextServer grandit à chaque rendu.
	var glyphs := PackedInt32Array()
	_advances.resize(ALPHABET.length())
	for k in ALPHABET.length():
		var glyph := server.font_get_glyph_index(rid, FONT_PX, ALPHABET.unicode_at(k), 0)
		server.font_render_glyph(rid, size, glyph)
		_advances[k] = server.font_get_glyph_advance(rid, FONT_PX, glyph).x / FONT_PX
		glyphs.append(glyph)
	var caches := {}
	for k in ALPHABET.length():
		var glyph := glyphs[k]
		var texture := server.font_get_glyph_texture_idx(rid, size, glyph)
		if texture < 0:
			continue   # l'espace : une chasse, aucun dessin
		if not caches.has(texture):
			var cache := server.font_get_texture_image(rid, size, texture).duplicate() as Image
			cache.convert(Image.FORMAT_RGBA8)
			caches[texture] = cache
		var source := Rect2i(server.font_get_glyph_uv_rect(rid, size, glyph))
		var cell := Vector2i(k % ATLAS_COLUMNS, k / ATLAS_COLUMNS) * CELL_PX
		var at := cell + PEN_PX + Vector2i(server.font_get_glyph_offset(rid, size, glyph))
		assert(Rect2i(cell, Vector2i(CELL_PX, CELL_PX)).encloses(Rect2i(at, source.size)),
			"glyphe hors de sa case : %s" % ALPHABET[k])
		atlas.blit_rect(caches[texture], source, at)
	atlas.generate_mipmaps()
	_atlas = atlas
	return _atlas
