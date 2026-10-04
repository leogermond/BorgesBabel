class_name BookSpine
extends RefCounted
## Dos des livres : titre court en lettres dorées, composé en Lora.
##
## Le titre se tire de l'adresse du livre seule (hexagone, niveau, mur, étagère, livre), jamais
## de son contenu : SHA-256 de l'adresse, puis un tirage simple d'octets parmi les 25 symboles.
## Le même livre porte donc toujours le même titre, sur toute machine.
##
## Affichage : le nuanceur des livres de gallery.gd (variante BOOKS de Gallery.LIBRARY_SHADER)
## dessine le titre sur la face du dos, à partir d'un atlas des 47 glyphes de Lora rendu une fois
## sur le processeur (glyph_atlas). Les titres d'une galerie arrivent par une petite texture de
## données propre à la galerie (gallery_title_bytes) : RGBA8, TEXTURE_WIDTH × TEXTURE_HEIGHT
## texels, 3 texels (12 octets) par livre, lue au texel près par texelFetch(INSTANCE_ID) ; elle
## vaut sous Forward+, Mobile et Compatibility (aucune donnée personnalisée de MultiMesh).
##
## Affiché, le titre prend une capitale à sa première lettre et à la première lettre après chaque
## point (display_title) ; le nuanceur applique la même règle en lisant les symboles. Le titre codé,
## lui, reste en 25 symboles minuscules.

## Les 25 symboles de Borges, dans l'ordre de BookText.ALPHABET.
const ALPHABET := "abcdefghijlmnoprstuvxz ,."
const SPACE := 22                        # rang de l'espace dans ALPHABET
const PERIOD := 24                       # rang du point
const LETTERS := 22                      # rangs 0 à 21 : les lettres
## Les glyphes de l'atlas : les 25 symboles, puis les capitales des 22 lettres (rang + 25).
const GLYPHS := ALPHABET + "ABCDEFGHIJLMNOPRSTUVXZ"
const MIN_LENGTH := 6
const MAX_LENGTH := 16
const SYMBOL_BITS := 5
const SYMBOLS_PER_CHANNEL := 4           # 4 symboles de 5 bits par mot de 20 bits
const CHANNELS := 4                      # 4 mots par titre : 16 symboles
const IMAGE_BIT := 20                    # drapeau « livre d'images », au bit 20 du premier mot
const WALLS := 4
const SHELVES := 5
const BOOKS := 32
## Texture des titres d'une galerie : chaque mot tient en 3 octets (petit-boutiste), un titre en
## 12 octets, soit 3 texels RGBA8. Ligne = mur·5 + étagère, colonne = livre·3 : le livre de rang
## i = (mur·5 + étagère)·32 + livre (INSTANCE_ID du MultiMesh) commence à l'octet 12·i.
const BYTES_PER_BOOK := 12
const TEXELS_PER_BOOK := 3
const TEXTURE_WIDTH := BOOKS * TEXELS_PER_BOOK     # 96
const TEXTURE_HEIGHT := WALLS * SHELVES            # 20

const FONT_PATH := "res://fonts/Lora-VariableFont_wght.ttf"
const FONT_WEIGHT := 600                 # Lora variable : 400 à 700 ; demi-gras pour la dorure
const FONT_PX := 64                      # corps du rendu de l'atlas : 1 em = 64 pixels
const CELL_PX := 96                      # case carrée par glyphe
const ATLAS_COLUMNS := 7                 # 7 × 7 cases (47 occupées) : 672 × 672 pixels
const PEN_PX := Vector2i(16, 70)         # point de chasse (origine de la ligne de base) dans la case
## Mise en page du titre, écrite dans le nuanceur des livres (Gallery) et reprise par title_layout().
const TRACKING_EM := 0.06                # espace ajouté entre deux lettres
const TITLE_MARGIN := 0.035              # réserve en tête et en pied du dos, en mètres
const TITLE_SIZE_FRACTION := 0.42        # corps maximal (1 em) rapporté à l'épaisseur du dos
const TITLE_CENTER_EM := 0.25            # milieu de l'œil des minuscules, au-dessus de la ligne de base

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


## Le titre tel qu'il s'affiche : capitale à la première lettre, et à la première lettre qui
## suit chaque point (espaces, virgules et points intermédiaires sautés).
static func display_title(text: String) -> String:
	var shown := ""
	var capital := true
	for c in text:
		var index := ALPHABET.find(c.to_lower())
		shown += GLYPHS[_glyph(index, capital)] if index >= 0 else c
		if index >= 0:
			capital = (capital and index >= LETTERS) or index == PERIOD
	return shown


## Rang dans GLYPHS du symbole de rang `index`, selon que la règle demande une capitale.
static func _glyph(index: int, capital: bool) -> int:
	return index + ALPHABET.length() if capital and index < LETTERS else index


## Les glyphes d'un titre (rangs dans GLYPHS), à l'identique du shader.
static func title_glyphs(text: String) -> PackedInt32Array:
	var glyphs := PackedInt32Array()
	var capital := true
	for c in text:
		var index := ALPHABET.find(c.to_lower())
		if index < 0:
			continue
		glyphs.append(_glyph(index, capital))
		capital = (capital and index >= LETTERS) or index == PERIOD
	return glyphs


## Mise en page du titre sur un dos de `thickness` × `height` mètres, à l'identique du vertex
## shader : x, le corps (mètres par em) ; y, la longueur du titre (em).
static func title_layout(text: String, thickness: float, height: float) -> Vector2:
	var advances := glyph_advances()
	var width := 0.0
	for glyph in title_glyphs(text):
		width += advances[glyph] + TRACKING_EM
	width = maxf(width - TRACKING_EM, 0.0)
	var room := maxf(height - 2.0 * TITLE_MARGIN, 0.0)
	return Vector2(minf(thickness * TITLE_SIZE_FRACTION, room / maxf(width, 0.001)), width)


# --- Codage pour le nuanceur ----------------------------------------------------------------

## Les 12 octets du titre dans la texture : 4 mots de 20 bits, 4 symboles de 5 bits chacun
## (0 : fin, 1 à 25 : rang + 1), le drapeau d'image au bit 20 du premier mot. La casse est
## ignorée (un titre affiché donne le même code), les symboles hors alphabet sont omis ; au-delà
## de 16 symboles, le titre est tronqué.
static func encode_title(text: String, image_book := false) -> PackedByteArray:
	var indices := PackedByteArray()
	for c in text:
		var index := ALPHABET.find(c.to_lower())
		if index >= 0:
			indices.append(index)
	var bytes := PackedByteArray()
	bytes.resize(BYTES_PER_BOOK)
	_encode(indices, image_book, bytes, 0)
	return bytes


## Écrit le titre de rangs `indices` dans `bytes` à partir de l'octet `at`.
static func _encode(indices: PackedByteArray, image_book: bool, bytes: PackedByteArray, at: int) -> void:
	var words := PackedInt32Array([0, 0, 0, 0])
	for i in mini(indices.size(), MAX_LENGTH):
		words[i / SYMBOLS_PER_CHANNEL] |= (indices[i] + 1) << (SYMBOL_BITS * (i % SYMBOLS_PER_CHANNEL))
	if image_book:
		words[0] |= 1 << IMAGE_BIT
	for c in CHANNELS:
		bytes[at + 3 * c] = words[c] & 0xFF
		bytes[at + 3 * c + 1] = (words[c] >> 8) & 0xFF
		bytes[at + 3 * c + 2] = (words[c] >> 16) & 0xFF


## Lecture inverse, à l'identique du nuanceur : le titre du livre de rang `book` d'un tampon de
## galerie (ou du seul titre de encode_title, book = 0). Les codes 26 à 31 finissent le titre.
static func decode_title(bytes: PackedByteArray, book := 0) -> String:
	var words := _words(bytes, book)
	var text := ""
	for i in MAX_LENGTH:
		var symbol := (words[i / SYMBOLS_PER_CHANNEL] >> (SYMBOL_BITS * (i % SYMBOLS_PER_CHANNEL))) & 31
		if symbol == 0 or symbol > ALPHABET.length():
			break
		text += ALPHABET[symbol - 1]
	return text


static func decode_image_flag(bytes: PackedByteArray, book := 0) -> bool:
	return (_words(bytes, book)[0] >> IMAGE_BIT) & 1 == 1


static func _words(bytes: PackedByteArray, book: int) -> PackedInt32Array:
	var words := PackedInt32Array([0, 0, 0, 0])
	var at := book * BYTES_PER_BOOK
	if at < 0 or at + BYTES_PER_BOOK > bytes.size():
		return words
	for c in CHANNELS:
		words[c] = bytes[at + 3 * c] | bytes[at + 3 * c + 1] << 8 | bytes[at + 3 * c + 2] << 16
	return words


## Les octets de la texture des titres d'une galerie (TEXTURE_WIDTH × TEXTURE_HEIGHT texels
## RGBA8), livre de rang (mur·5 + étagère)·32 + livre à l'octet 12 × rang, comme
## BookText.gallery_image_books ; `image_books` (même ordre, facultatif) donne le drapeau.
## Hexagone et niveau : entiers, ou décimaux en chaîne (même titre que title_at).
## Sans état partagé : se calcule aussi bien sur un fil de WorkerThreadPool.
static func gallery_title_bytes(hexagon: Variant, level: Variant, image_books: Array = []) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(WALLS * SHELVES * BOOKS * BYTES_PER_BOOK)
	var prefix := "dos|%s|%s|" % [str(hexagon), str(level)]
	var i := 0
	for wall in WALLS:
		for shelf in SHELVES:
			for book in BOOKS:
				var image := i < image_books.size() and bool(image_books[i])
				_encode(_indices(prefix + "%d|%d|%d" % [wall, shelf, book]), image, bytes, i * BYTES_PER_BOOK)
				i += 1
	return bytes


# --- Atlas ---------------------------------------------------------------------------------

## Chasse de chaque glyphe de GLYPHS, en em.
static func glyph_advances() -> PackedFloat32Array:
	glyph_atlas()
	return _advances


## L'atlas des 47 glyphes de GLYPHS, blanc sur fond transparent (la couverture est dans l'alpha) :
## le glyphe de rang k occupe la case (k % 7, k / 7), son point de chasse en PEN_PX.
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
	_advances.resize(GLYPHS.length())
	for k in GLYPHS.length():
		var glyph := server.font_get_glyph_index(rid, FONT_PX, GLYPHS.unicode_at(k), 0)
		server.font_render_glyph(rid, size, glyph)
		_advances[k] = server.font_get_glyph_advance(rid, FONT_PX, glyph).x / FONT_PX
		glyphs.append(glyph)
	var caches := {}
	for k in GLYPHS.length():
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
			"glyphe hors de sa case : %s" % GLYPHS[k])
		atlas.blit_rect(caches[texture], source, at)
	atlas.generate_mipmaps()
	_atlas = atlas
	return _atlas
