extends SceneTree
## Vérifie les dos de livres : titres (déterminisme, alphabet, longueurs, répartition), codage
## pour le nuanceur (aller-retour, texture des titres d'une galerie), capitales d'affichage, atlas
## de Lora et mise en page sur le dos, nuanceur des livres de Gallery (constantes de BookSpine).
## godot --headless --path . -s tests/test_book_spine.gd
## Le nuanceur se compile ici par l'analyseur du moteur sans écran ; aucune image n'est rendue.
## Les titres dans le monde (galeries, texture relue) : test_depth.

const BookSpineScript := preload("res://scripts/book_spine.gd")
const BookTextScript := preload("res://scripts/book_text.gd")
const GalleryScript := preload("res://scripts/gallery.gd")
const SAMPLES := 10000
const INT_MIN := -9223372036854775807 - 1
const INT_MAX := 9223372036854775807

var _failures := 0


func _initialize() -> void:
	_check_titles()
	_check_encoding()
	_check_capitals()
	_check_atlas()
	_check_layout()
	_check_shader()
	_check_gallery_bytes()
	_check_flag_retry()
	BookTextScript.shutdown()
	print("test_book_spine : %s" % ("OK" if _failures == 0 else "%d échec(s)" % _failures))
	quit(1 if _failures else 0)


func _check_titles() -> void:
	_check(BookSpineScript.ALPHABET == BookTextScript.ALPHABET, "alphabet identique à BookText.ALPHABET")
	var far := BookSpineScript.title(_key(INT_MAX, INT_MIN), 3, 4, 31)
	_check(far == BookSpineScript.title(_key(INT_MAX, INT_MIN), 3, 4, 31), "même adresse → même titre (« %s »)" % far)
	_check(BookSpineScript.display_title(BookSpineScript.title(_key(7, -2), 1, 3, 12)) == BookTextScript.title_at(BookTextScript.address(7, -2, 1, 3, 12, 99)),
		"BookSpine.title et BookText.title_at s'accordent (la page est ignorée)")
	_check(_key(7, -2) == BookTextScript.gallery_key("7", "-2") and _key(INT_MAX, 3) == BookTextScript.gallery_key(BookTextScript.b25(INT_MAX), "3")
			and _key(0, 1) != _key(1, 0) and _key(0, 0) != _key(152587890624, 0) and _key(1, 0) != _key(-1, 0),
		"clé de galerie : la même pour un int et sa chaîne base 25, distincte d'une galerie voisine")
	# Valeurs figées : le titre ne dépend que de SHA-256, identique sur toute machine.
	print("    titres de référence : « %s », « %s »" % [BookSpineScript.title(_key(0, 0), 0, 0, 0), BookSpineScript.title(_key(1, 1), 1, 1, 1)])
	var oracle_rng := RandomNumberGenerator.new()
	oracle_rng.seed = 1899   # naissance de Borges
	var mismatches := 0
	for n in 2000:
		var parts := [oracle_rng.randi() << 32 | oracle_rng.randi(), oracle_rng.randi_range(-99999, 99999),
			oracle_rng.randi_range(0, 3), oracle_rng.randi_range(0, 4), oracle_rng.randi_range(0, 31)]
		if n == 0:
			parts = [0, 0, 0, 0, 0]
		var key := "dos|%s|%d|%d|%d" % [_key(parts[0], parts[1]), parts[2], parts[3], parts[4]]
		if BookSpineScript.title(_key(parts[0], parts[1]), parts[2], parts[3], parts[4]) != _expected_title(key):
			mismatches += 1
	_check(mismatches == 0, "titres recalculés indépendamment depuis le condensat, 2000 adresses (écarts : %d)" % mismatches)

	var rng := RandomNumberGenerator.new()
	rng.seed = 1941
	var counts := {}
	var ends := {}
	var lengths := {}
	var foreign := 0
	var stripped := 0
	var distinct := {}
	var interior := 0
	var extremes := [0, 1, -1, INT_MIN, INT_MAX, 4611686018427387903, -4611686018427387904]
	var t0 := Time.get_ticks_usec()
	for n in SAMPLES:
		var hexagon: int = extremes[n] if n < extremes.size() else rng.randi() << 32 | rng.randi()
		var level: int = extremes[n % extremes.size()] if n % 97 == 0 else rng.randi_range(-1000000, 1000000)
		var text := BookSpineScript.title(_key(hexagon, level), rng.randi_range(0, 3), rng.randi_range(0, 4), rng.randi_range(0, 31))
		distinct[text] = true
		lengths[text.length()] = lengths.get(text.length(), 0) + 1
		if text != text.strip_edges():
			stripped += 1
		for i in text.length():
			var c := text[i]
			if not BookSpineScript.ALPHABET.contains(c):
				foreign += 1
			elif i == 0 or i == text.length() - 1:
				ends[c] = ends.get(c, 0) + 1
			else:
				counts[c] = counts.get(c, 0) + 1
				interior += 1
	var elapsed := (Time.get_ticks_usec() - t0) / 1000.0
	print("    %d titres en %.1f ms" % [SAMPLES, elapsed])
	_check(foreign == 0, "seuls les 25 symboles apparaissent (intrus : %d)" % foreign)
	_check(stripped == 0, "aucun espace en tête ni en queue")
	var keys := lengths.keys()
	keys.sort()
	_check(keys == range(6, 17), "longueurs de 6 à 16, toutes présentes (lues : %s)" % [keys])
	_check(distinct.size() > SAMPLES * 0.99, "titres presque tous distincts (%d sur %d)" % [distinct.size(), SAMPLES])
	_check(counts.size() == 25, "les 25 symboles apparaissent à l'intérieur des titres")
	_check(not ends.has(" ") and ends.size() == 24, "24 symboles en tête et en queue, jamais l'espace")
	# Khi-deux à 24 degrés de liberté : 51,2 au seuil de 0,001.
	var chi_interior := _chi_square(counts, interior, 25)
	var chi_ends := _chi_square(ends, 2 * SAMPLES, 24)
	_check(chi_interior < 51.2, "répartition uniforme des 25 symboles (khi-deux %.1f sur %d tirages)" % [chi_interior, interior])
	_check(chi_ends < 49.7, "répartition uniforme des 24 symboles d'extrémité (khi-deux %.1f, 23 ddl)" % chi_ends)
	var chi_lengths := _chi_square(lengths, SAMPLES, 11)
	_check(chi_lengths < 29.6, "longueurs uniformes (khi-deux %.1f, 10 ddl)" % chi_lengths)


func _check_encoding() -> void:
	var failures := 0
	var symbols := BookSpineScript.ALPHABET
	# Toutes les longueurs, tous les symboles à toutes les places, avec et sans drapeau.
	for length in range(0, 17):
		for s in symbols.length():
			for at in maxi(length, 1):
				var text := ""
				for i in length:
					text += symbols[(s + i * 7) % symbols.length()] if i != at else symbols[s]
				for image in [false, true]:
					var code := BookSpineScript.encode_title(text, image)
					if code.size() != BookSpineScript.BYTES_PER_BOOK or BookSpineScript.decode_title(code) != text \
							or BookSpineScript.decode_image_flag(code) != image:
						failures += 1
	_check(failures == 0, "aller-retour encode/decode exact pour 0 à 16 symboles, chaque symbole à chaque place, drapeau d'image (%d écart(s))" % failures)
	var code := BookSpineScript.encode_title("abcdefghijlmnoprstuvxz ,.")
	_check(BookSpineScript.decode_title(code) == "abcdefghijlmnopr", "au-delà de 16 symboles, le titre est tronqué")
	var zero := PackedByteArray()
	zero.resize(BookSpineScript.BYTES_PER_BOOK)
	_check(BookSpineScript.decode_title(zero) == "" and not BookSpineScript.decode_image_flag(zero),
		"octets nuls (texture absente : hint_default_black) → ni titre ni drapeau")
	_check(BookSpineScript.decode_title(PackedByteArray([1, 2, 3])) == "", "tampon trop court → pas de titre")
	# 12 octets = 3 texels RGBA8 ; « z » (rang 21, code 22) partout : mots de 20 bits 22·(1 + 2⁵ + 2¹⁰ + 2¹⁵),
	# le drapeau au bit 20 du premier ; valeurs calculées à part.
	var full := BookSpineScript.encode_title("zzzzzzzzzzzzzzzz", true)
	_check(full == PackedByteArray([214, 90, 27, 214, 90, 11, 214, 90, 11, 214, 90, 11]),
		"octets petit-boutistes, 3 par mot, drapeau au bit 20 du premier mot (lu : %s)" % [full])


func _check_atlas() -> void:
	var t0 := Time.get_ticks_usec()
	var atlas := BookSpineScript.glyph_atlas()
	var elapsed := (Time.get_ticks_usec() - t0) / 1000.0
	var cell := BookSpineScript.CELL_PX
	_check(atlas != null and atlas.get_size() == Vector2i(7 * cell, 7 * cell), "atlas de 7 × 7 cases (%s, rendu en %.1f ms)" % [atlas.get_size(), elapsed])
	_check(atlas.has_mipmaps(), "atlas avec mipmaps")
	var inked := 0
	var empty := []
	_check(BookSpineScript.GLYPHS.length() == 47 and BookSpineScript.GLYPHS.substr(25) == BookSpineScript.ALPHABET.substr(0, 22).to_upper(),
		"47 glyphes : les 25 symboles puis les 22 capitales, dans le même ordre")
	for k in 47:
		var used := _ink_rect(atlas, k)
		if used.size.x > 0 and used.size.y > 0:
			inked += 1
			# Aucune encre sur le bord de la case : rien ne déborde chez la voisine.
			if used.position.x == 0 or used.position.y == 0 or used.end.x == cell or used.end.y == cell:
				empty.append("bord:" + BookSpineScript.GLYPHS[k])
		else:
			empty.append(BookSpineScript.GLYPHS[k])
	_check(inked == 46 and empty == [" "], "46 glyphes encrés, l'espace seul vide (vides ou au bord : %s)" % [empty])
	var advances := BookSpineScript.glyph_advances()
	var positive := Array(advances).all(func(a: float) -> bool: return a > 0.1 and a < 1.2)
	_check(advances.size() == 47 and positive, "47 chasses entre 0,1 et 1,2 em (m : %.2f, M : %.2f, i : %.2f, espace : %.2f)" % [advances[11], advances[36], advances[8], advances[22]])
	var out := OS.get_cache_dir().path_join("book_spine_atlas.png")
	atlas.save_png(out)
	print("    atlas enregistré : %s" % out)


## Capitales : première lettre, et première lettre après chaque point.
func _check_capitals() -> void:
	var cases := {
		"ab. cd": "Ab. Cd", "a..b": "A..B", "ab., ,c d.": "Ab., ,C d.", ",.a b": ",.A b",
		" ,x": " ,X", "zz.zz.": "Zz.Zz.", "abc": "Abc", "a,b.c": "A,b.C", "...": "...",
	}
	for title in cases:
		var shown := BookSpineScript.display_title(title)
		_check(shown == cases[title], "capitales : « %s » → « %s » (lu : « %s »)" % [title, cases[title], shown])
	var rng := RandomNumberGenerator.new()
	rng.seed = 1986   # mort de Borges
	var bad := 0
	var same_text := 0
	for n in 2000:
		var parts := [rng.randi() << 32 | rng.randi(), rng.randi_range(-99999, 99999), rng.randi_range(0, 3), rng.randi_range(0, 4), rng.randi_range(0, 31)]
		var raw := BookSpineScript.title(_key(parts[0], parts[1]), parts[2], parts[3], parts[4])
		var shown := BookSpineScript.display_title(raw)
		var spelled := ""
		for g in BookSpineScript.title_glyphs(raw):
			spelled += BookSpineScript.GLYPHS[g]
		if shown.to_lower() != raw or spelled != shown or shown[0] != shown[0].to_upper():
			bad += 1
		if BookTextScript.title(parts[0], parts[1], parts[2], parts[3], parts[4]) == shown:
			same_text += 1
	_check(bad == 0, "2000 titres : capitale initiale, même texte en minuscules, glyphes du shader identiques (écarts : %d)" % bad)
	_check(same_text == 2000, "BookText.title == display_title(BookSpine.title) sur 2000 adresses (%d)" % same_text)
	_check(BookSpineScript.encode_title("ab.cd") == BookSpineScript.encode_title("Ab.Cd"),
		"le codage ignore la casse : les capitales ne se décident qu'à l'affichage")


## Mise en page : le titre, capitales comprises, reste centré et dans le dos du livre.
func _check_layout() -> void:
	var atlas := BookSpineScript.glyph_atlas()
	var advances := BookSpineScript.glyph_advances()
	var font_px := float(BookSpineScript.FONT_PX)
	var pen := Vector2(BookSpineScript.PEN_PX)
	var ink := []   # par glyphe : gauche, droite (depuis le point de chasse), haut, bas (depuis la ligne de base), en em
	for k in 47:
		var used := _ink_rect(atlas, k)
		ink.append(Vector4((used.position.x - pen.x) / font_px, (used.end.x - pen.x) / font_px,
			(pen.y - used.position.y) / font_px, (pen.y - used.end.y) / font_px) if used.size.x > 0 else Vector4.ZERO)
	var titles := ["m.m.m.m.m.m.m.mm", "mmmmmmmmmmmmmmmm", "j.j.j.j.j.j.j.jj", "i,i", ".......j", "abcdef"]
	var rng := RandomNumberGenerator.new()
	rng.seed = 2026
	for n in 3000:
		titles.append(BookSpineScript.title(_key(rng.randi(), rng.randi()), rng.randi_range(0, 3), rng.randi_range(0, 4), rng.randi_range(0, 31)))
	var worst_along := 0.0
	var worst_across := 0.0
	var worst_offset := 0.0
	var outside := 0
	for title in titles:
		for height in [0.28, 0.36]:
			var thickness := 0.13
			var layout := BookSpineScript.title_layout(title, thickness, height)
			var em := layout.x
			var x := 0.0
			var lo := INF
			var hi := -INF
			var top := -INF
			var bottom := INF
			for g in BookSpineScript.title_glyphs(title):
				var box: Vector4 = ink[g]
				if box != Vector4.ZERO:
					lo = minf(lo, x + box.x)
					hi = maxf(hi, x + box.y)
					top = maxf(top, box.z)
					bottom = minf(bottom, box.w)
				x += advances[g] + BookSpineScript.TRACKING_EM
			# Mètres depuis le centre du dos : le long (pied → tête) et en travers.
			var along := maxf(absf((lo - 0.5 * layout.y) * em), absf((hi - 0.5 * layout.y) * em))
			var across := maxf((top - BookSpineScript.TITLE_CENTER_EM) * em, (BookSpineScript.TITLE_CENTER_EM - bottom) * em)
			var offset := absf(0.5 * (lo + hi) - 0.5 * layout.y) * em
			worst_along = maxf(worst_along, along / (0.5 * height))
			worst_across = maxf(worst_across, across / (0.5 * thickness))
			worst_offset = maxf(worst_offset, offset)
			# Encre à plus de 25 mm des extrémités (les filets s'arrêtent à 24,5 mm), à 1 cm des arêtes.
			if along > 0.5 * height - 0.025 or across > 0.5 * thickness - 0.01:
				outside += 1
	_check(outside == 0, "encre dans le dos sur %d titres × 2 hauteurs : au plus %.0f %% de la demi-hauteur, %.0f %% de la demi-épaisseur" % [titles.size(), 100.0 * worst_along, 100.0 * worst_across])
	_check(worst_offset < 0.004, "titre centré le long du dos (écart maximal %.1f mm)" % (1000.0 * worst_offset))


## Le nuanceur des livres de Gallery porte la mise en page de BookSpine et se compile, sous les
## deux rendus ; son matériau reçoit l'atlas des glyphes et la texture des titres.
func _check_shader() -> void:
	var gallery := GalleryScript.create(1941, 0, GalleryScript.Detail.LIT)
	var material: ShaderMaterial = gallery.get_node("Books").material_override
	var shader := material.shader
	var uniforms := shader.get_shader_uniform_list().map(func(u: Dictionary) -> String: return u.name)
	_check(not uniforms.is_empty(), "le nuanceur des livres se compile (uniformes : %d)" % uniforms.size())
	for name in ["titles", "glyph_atlas", "glyph_halo", "titles_alpha", "seed"]:
		_check(uniforms.has(name), "uniforme %s présent" % name)
	# Halo des lettres (liseré sombre sur les cuirs clairs) : il couvre chaque glyphe, et déborde autour.
	var atlas := BookSpineScript.glyph_atlas()
	var halo := BookSpineScript.glyph_halo()
	var inside := 0
	var covered := 0
	var wider := 0
	for y in range(0, atlas.get_height(), 3):
		for x in range(0, atlas.get_width(), 3):
			var a := atlas.get_pixel(x, y).a
			var h := halo.get_pixel(x, y).a
			if a > 0.5:
				inside += 1
				covered += int(h >= a - 0.01)
			elif h > 0.5:
				wider += 1
	_check(inside > 0 and covered == inside and wider > inside / 4 and material.get_shader_parameter("glyph_halo") is Texture2D,
		"halo des glyphes : couvre les %d points encrés, déborde sur %d autres, branché sur le matériau" % [inside, wider])
	var forced := Shader.new()
	forced.code = shader.code.replace("#if CURRENT_RENDERER == RENDERER_COMPATIBILITY", "#if 1")
	_check(forced.code != shader.code and forced.get_shader_uniform_list().size() == uniforms.size(),
		"la branche du rendu Compatibilité se compile aussi")
	var advances := BookSpineScript.glyph_advances()
	_check(shader.code.contains("float[47](%s, " % ("%.8f" % advances[0])) and shader.code.contains("%.8f" % advances[46]),
		"les 47 chasses de l'atlas sont écrites dans le nuanceur")
	_check(shader.code.contains("const float TRACKING_EM = %.8f;" % BookSpineScript.TRACKING_EM)
			and shader.code.contains("const int ATLAS_COLUMNS = %d;" % BookSpineScript.ATLAS_COLUMNS),
		"mise en page du nuanceur réglée depuis BookSpine")
	_check(material.get_shader_parameter("glyph_atlas") is Texture2D, "atlas branché sur le matériau")
	_check(not shader.code.contains("INSTANCE_CUSTOM") and not shader.code.contains("textureLod(titles"),
		"titres lus au texel près (texelFetch), sans donnée personnalisée de MultiMesh")
	gallery.load_titles_now()
	var texture := gallery.titles_texture()
	_check(texture != null and material.get_shader_parameter("titles") == texture and gallery.titles_alpha() == 1.0,
		"texture des titres branchée, opacité 1 une fois chargée")
	_check(texture != null and texture.get_width() == BookSpineScript.TEXTURE_WIDTH and texture.get_height() == BookSpineScript.TEXTURE_HEIGHT,
		"texture de %d × %d texels" % [BookSpineScript.TEXTURE_WIDTH, BookSpineScript.TEXTURE_HEIGHT])
	var code := BookSpineScript.encode_title("abc")
	code[1] |= 26 << 7   # quatrième symbole (bits 15 à 19 du mot 0) : code 26, hors alphabet
	_check(BookSpineScript.decode_title(code) == "abc", "codes 26 à 31 : fin du titre, comme dans le nuanceur")
	gallery.free()


func _check_gallery_bytes() -> void:
	var t0 := Time.get_ticks_usec()
	var bytes := BookSpineScript.gallery_title_bytes(_key(INT_MAX, -3))
	var elapsed := (Time.get_ticks_usec() - t0) / 1000.0
	print("    titres des 640 livres d'une galerie : %.2f ms" % elapsed)
	_check(bytes.size() == 640 * BookSpineScript.BYTES_PER_BOOK
			and bytes.size() == BookSpineScript.TEXTURE_WIDTH * BookSpineScript.TEXTURE_HEIGHT * 4,
		"640 titres de 12 octets : une texture RGBA8 de 96 × 20")
	_check(BookSpineScript.decode_title(bytes, (2 * 5 + 3) * 32 + 17) == BookSpineScript.title(_key(INT_MAX, -3), 2, 3, 17), "rang (mur·5 + étagère)·32 + livre")
	var flags := []
	flags.resize(640)
	flags.fill(false)
	flags[50] = true
	var flagged := BookSpineScript.gallery_title_bytes(_key(INT_MAX, -3), flags)
	var patched := bytes.duplicate()
	BookSpineScript.set_image_flags(patched, flags)
	_check(patched == flagged, "set_image_flags sur des titres déjà calculés = titres calculés avec les drapeaux")
	_check(BookSpineScript.decode_image_flag(flagged, 50) and not BookSpineScript.decode_image_flag(flagged, 49)
			and BookSpineScript.decode_title(flagged, 50) == BookSpineScript.decode_title(bytes, 50),
		"drapeau d'image transmis au bon livre, titre intact")
	# Même calcul sur un fil du moteur (comme Gallery.pump_titles).
	var out := {}
	var task := WorkerThreadPool.add_task(func() -> void: out["bytes"] = BookSpineScript.gallery_title_bytes(_key(INT_MAX, -3)))
	WorkerThreadPool.wait_for_task_completion(task)
	_check(out.get("bytes") == bytes, "calcul identique sur un fil de WorkerThreadPool")


## Genres des livres manquants (service absent) : les titres se posent sans filets, puis, le
## service revenu, les genres se redemandent et complètent la texture déjà posée.
func _check_flag_retry() -> void:
	var saved_retry := GalleryScript.flag_retry_ms
	GalleryScript.flag_retry_ms = 200
	print("  (erreurs attendues ci-dessous : interpréteur volontairement introuvable)")
	ProjectSettings.set_setting(BookTextScript.PYTHON_SETTING, "/chemin/introuvable/python3")
	BookTextScript.restart()
	var gallery := GalleryScript.create(17, -3, GalleryScript.Detail.LIT)
	_pump_until(func() -> bool: return gallery.titles_ready(), 10000)
	var key: String = gallery.place.key
	var bytes := gallery.titles_texture().get_image().get_data() if gallery.titles_ready() else PackedByteArray()
	var flagged := 0
	for i in 640:
		flagged += int(BookSpineScript.decode_image_flag(bytes, i))
	_check(gallery.titles_ready() and flagged == 0 and GalleryScript.flags_pending().has(key),
		"service absent : titres posés sans filets, genres à redemander")
	ProjectSettings.set_setting(BookTextScript.PYTHON_SETTING, "")
	BookTextScript.restart()
	_pump_until(func() -> bool: return GalleryScript.flags_pending().is_empty(), 20000)
	var flags := BookTextScript.gallery_image_books(17, -3)
	bytes = gallery.titles_texture().get_image().get_data()
	var wrong := 0
	flagged = 0
	for i in 640:
		var flag := BookSpineScript.decode_image_flag(bytes, i)
		flagged += int(flag)
		if flag != (i < flags.size() and flags[i] == true):
			wrong += 1
	_check(GalleryScript.flags_pending().is_empty() and flags.size() == 640 and flagged > 0 and wrong == 0,
		"service revenu : les genres redemandés complètent la texture posée (%d livres d'images, écarts : %d)" % [flagged, wrong])
	_check(BookSpineScript.decode_title(bytes, 77) == BookSpineScript.title(key, 0, 2, 13), "les titres restent")
	GalleryScript.flag_retry_ms = saved_retry
	gallery.free()
	GalleryScript.release_pool()


func _pump_until(done: Callable, limit_msec: int) -> void:
	var t0 := Time.get_ticks_msec()
	while not done.call() and Time.get_ticks_msec() - t0 < limit_msec:
		GalleryScript.pump_titles()
		OS.delay_msec(10)


func _key(hexagon: Variant, level: Variant) -> String:
	return BookTextScript.gallery_key(hexagon, level)


## Titre recalculé à part, d'après la règle documentée de BookSpine._indices écrite autrement :
## octets du condensat prolongé, longueur 6 + octet % 11 si octet < 242, extrémités parmi les
## 24 symboles sans l'espace si octet < 240, intérieur parmi les 25 si octet < 250.
func _expected_title(key: String) -> String:
	var bytes := PackedByteArray()
	var digest := key.sha256_buffer()
	for _round in 8:
		bytes.append_array(digest)
		digest = digest.hex_encode().sha256_buffer()
	var at := 0
	while bytes[at] >= 242:
		at += 1
	var length: int = 6 + bytes[at] % 11
	at += 1
	var text := ""
	var no_space := "abcdefghijlmnoprstuvxz,."
	for i in length:
		var edge := i == 0 or i == length - 1
		var pool := no_space if edge else BookSpineScript.ALPHABET
		while bytes[at] >= (240 if edge else 250):
			at += 1
		text += pool[bytes[at] % pool.length()]
		at += 1
	return text


## Rectangle encré de la case du glyphe k dans l'atlas (pixels, relatif à la case).
func _ink_rect(atlas: Image, k: int) -> Rect2i:
	var cell := BookSpineScript.CELL_PX
	var columns := BookSpineScript.ATLAS_COLUMNS
	var region := atlas.get_region(Rect2i(Vector2i(k % columns, k / columns) * cell, Vector2i(cell, cell)))
	region.convert(Image.FORMAT_RGBA8)
	return region.get_used_rect()


func _chi_square(counts: Dictionary, total: int, categories: int) -> float:
	var expected := float(total) / categories
	var chi := 0.0
	for key in counts:
		chi += pow(counts[key] - expected, 2.0) / expected
	chi += (categories - counts.size()) * expected
	return chi


func _check(condition: bool, label: String) -> void:
	print(("  ok    " if condition else "  ÉCHEC ") + label)
	if not condition:
		_failures += 1
