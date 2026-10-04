extends SceneTree
## Vérifie les dos de livres : titres (déterminisme, alphabet, longueurs, répartition), codage
## pour le shader (aller-retour), atlas de Lora, compilation du shader, MultiMesh de démonstration.
## godot --headless --path . -s tests/test_book_spine.gd
## Le shader se compile ici par l'analyseur du moteur sans écran ; aucune image n'est rendue.

const BookSpineScript := preload("res://scripts/book_spine.gd")
const BookTextScript := preload("res://scripts/book_text.gd")
const SAMPLES := 10000
const INT_MIN := -9223372036854775807 - 1
const INT_MAX := 9223372036854775807

var _failures := 0


func _initialize() -> void:
	_check_titles()
	_check_encoding()
	_check_atlas()
	_check_shader()
	await _check_multimesh()
	print("test_book_spine : %s" % ("OK" if _failures == 0 else "%d échec(s)" % _failures))
	quit(1 if _failures else 0)


func _check_titles() -> void:
	_check(BookSpineScript.ALPHABET == BookTextScript.ALPHABET, "alphabet identique à BookText.ALPHABET")
	var far := BookSpineScript.title(INT_MAX, INT_MIN, 3, 4, 31)
	_check(far == BookSpineScript.title(INT_MAX, INT_MIN, 3, 4, 31), "même adresse → même titre (« %s »)" % far)
	_check(BookSpineScript.title(7, -2, 1, 3, 12) == BookSpineScript.title_at(BookTextScript.address(7, -2, 1, 3, 12, 99)),
		"title et title_at s'accordent (la page est ignorée)")
	# Valeurs figées : le titre ne dépend que de SHA-256, identique sur toute machine.
	print("    titres de référence : « %s », « %s »" % [BookSpineScript.title(0, 0, 0, 0, 0), BookSpineScript.title(1, 1, 1, 1, 1)])
	_check(BookSpineScript.title(0, 0, 0, 0, 0) == _expected_title("dos|0|0|0|0|0"), "titre recalculé indépendamment depuis le condensat")

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
		var text := BookSpineScript.title(hexagon, level, rng.randi_range(0, 3), rng.randi_range(0, 4), rng.randi_range(0, 31))
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
					if BookSpineScript.decode_title(code) != text or BookSpineScript.decode_image_flag(code) != image:
						failures += 1
					for value in [code.r, code.g, code.b, code.a]:
						if value != floorf(value) or value < 8388608.0 or value >= 16777216.0 or float(int(value)) != value:
							failures += 1
	_check(failures == 0, "aller-retour encode/decode exact pour 0 à 16 symboles, chaque symbole à chaque place, drapeau d'image (%d écart(s))" % failures)
	var code := BookSpineScript.encode_title("abcdefghijlmnoprstuvxz ,.")
	_check(BookSpineScript.decode_title(code) == "abcdefghijlmnopr", "au-delà de 16 symboles, le titre est tronqué")
	_check(BookSpineScript.decode_title(Color(0, 0, 0, 0)) == "" and not BookSpineScript.decode_image_flag(Color(0, 0, 0, 0)),
		"donnée nulle → ni titre ni drapeau")
	_check(BookSpineScript.decode_title(Color(INF, INF, 0, 0)) == "", "demi-flottants débordés (Compatibility) → pas de titre")
	var packed := PackedFloat32Array([code.r, code.g, code.b, code.a])
	var back := Color(packed[0], packed[1], packed[2], packed[3])
	_check(back == code and BookSpineScript.decode_title(back) == "abcdefghijlmnopr", "le codage survit au passage en flottants 32 bits")


func _check_atlas() -> void:
	var t0 := Time.get_ticks_usec()
	var atlas := BookSpineScript.glyph_atlas()
	var elapsed := (Time.get_ticks_usec() - t0) / 1000.0
	var cell := BookSpineScript.CELL_PX
	_check(atlas != null and atlas.get_size() == Vector2i(5 * cell, 5 * cell), "atlas de 5 × 5 cases (%s, rendu en %.1f ms)" % [atlas.get_size(), elapsed])
	_check(atlas.has_mipmaps(), "atlas avec mipmaps")
	var inked := 0
	var empty := []
	for k in 25:
		var rect := Rect2i(Vector2i(k % 5, k / 5) * cell, Vector2i(cell, cell))
		var region := atlas.get_region(rect)
		region.convert(Image.FORMAT_RGBA8)
		var used := region.get_used_rect()
		if used.size.x > 0 and used.size.y > 0:
			inked += 1
			# Aucune encre sur le bord de la case : rien ne déborde chez la voisine.
			if used.position.x == 0 or used.position.y == 0 or used.end.x == cell or used.end.y == cell:
				empty.append("bord:" + BookSpineScript.ALPHABET[k])
		else:
			empty.append(BookSpineScript.ALPHABET[k])
	_check(inked == 24 and empty == [" "], "24 glyphes encrés, l'espace seul vide (vides ou au bord : %s)" % [empty])
	var advances := BookSpineScript.glyph_advances()
	var positive := Array(advances).all(func(a: float) -> bool: return a > 0.1 and a < 1.2)
	_check(advances.size() == 25 and positive, "25 chasses entre 0,1 et 1,2 em (m : %.2f, i : %.2f, espace : %.2f)" % [advances[11], advances[8], advances[22]])
	atlas.save_png("res://.foreman/scratch/book_spine_atlas.png")


func _check_shader() -> void:
	var shader: Shader = load(BookSpineScript.SHADER_PATH)
	var uniforms := shader.get_shader_uniform_list().map(func(u: Dictionary) -> String: return u.name)
	_check(not uniforms.is_empty(), "le shader se compile (uniformes : %d)" % uniforms.size())
	for name in ["glyph_atlas", "glyph_advance", "gold", "leather_roughness", "gold_roughness"]:
		_check(uniforms.has(name), "uniforme %s présent" % name)
	var material := BookSpineScript.material()
	_check(material == BookSpineScript.material(), "matériau partagé")
	_check(material.get_shader_parameter("glyph_atlas") is Texture2D, "atlas branché sur le matériau")
	_check((material.get_shader_parameter("glyph_advance") as PackedFloat32Array).size() == 25, "chasses branchées sur le matériau")


func _check_multimesh() -> void:
	var t0 := Time.get_ticks_usec()
	var codes := BookSpineScript.gallery_codes(INT_MAX, -3)
	var elapsed := (Time.get_ticks_usec() - t0) / 1000.0
	print("    codes des 640 livres d'une galerie : %.2f ms" % elapsed)
	_check(codes.size() == 640, "640 codes par galerie")
	_check(BookSpineScript.decode_title(codes[(2 * 5 + 3) * 32 + 17]) == BookSpineScript.title(INT_MAX, -3, 2, 3, 17), "rang (mur·5 + étagère)·32 + livre")
	var flags := []
	flags.resize(640)
	flags.fill(false)
	flags[50] = true
	var flagged := BookSpineScript.gallery_codes(INT_MAX, -3, flags)
	_check(BookSpineScript.decode_image_flag(flagged[50]) and not BookSpineScript.decode_image_flag(flagged[49]), "drapeau d'image transmis au bon livre")

	t0 = Time.get_ticks_usec()
	var buffer := PackedFloat32Array()
	buffer.resize(640 * 20)
	for i in 640:
		var o := i * 20
		buffer[o + 16] = codes[i].r
		buffer[o + 17] = codes[i].g
		buffer[o + 18] = codes[i].b
		buffer[o + 19] = codes[i].a
	print("    écriture des 640 codes dans un tampon de MultiMesh : %.2f ms" % ((Time.get_ticks_usec() - t0) / 1000.0))

	# Démonstration : une étagère de 32 livres, tampon rempli d'un bloc comme dans gallery.gd
	# (12 flottants de transformation, 4 de couleur, 4 de titre).
	var shelf := PackedFloat32Array()
	shelf.resize(32 * 20)
	for book in 32:
		var height := 0.28 + 0.0025 * book
		var xform := Transform3D(Basis.from_scale(Vector3(0.13, height, 0.22)), Vector3(0.15 * book, height * 0.5, 0.0))
		var row := [xform.basis.x.x, xform.basis.y.x, xform.basis.z.x, xform.origin.x,
			xform.basis.x.y, xform.basis.y.y, xform.basis.z.y, xform.origin.y,
			xform.basis.x.z, xform.basis.y.z, xform.basis.z.z, xform.origin.z,
			0.42, 0.12, 0.08, 1.0, codes[book].r, codes[book].g, codes[book].b, codes[book].a]
		for k in 20:
			shelf[book * 20 + k] = row[k]
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE
	mesh.material = BookSpineScript.material()
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.use_custom_data = true
	multimesh.mesh = mesh
	multimesh.instance_count = 32
	multimesh.buffer = shelf
	var instance := MultiMeshInstance3D.new()
	instance.multimesh = multimesh
	root.add_child(instance)
	await process_frame
	_check(instance.is_inside_tree() and multimesh.instance_count == 32, "MultiMesh de 32 livres titrés construit et ajouté à la scène")
	var stored := multimesh.buffer
	var read := Color(stored[31 * 20 + 16], stored[31 * 20 + 17], stored[31 * 20 + 18], stored[31 * 20 + 19])
	_check(stored.size() == 640 and BookSpineScript.decode_title(read) == BookSpineScript.title(INT_MAX, -3, 0, 0, 31),
		"titre relu intact dans le tampon du MultiMesh (« %s »)" % BookSpineScript.decode_title(read))
	instance.queue_free()


## Titre recalculé à part : mêmes règles que BookSpine._title_from_key, écrites autrement.
func _expected_title(key: String) -> String:
	var bytes := PackedByteArray()
	var digest := key.sha256_buffer()
	for _round in 8:
		bytes.append_array(digest)
		digest = digest.hex_encode().sha256_buffer()
	var at := 0
	var picks := []
	for count in [11]:
		while bytes[at] >= 256 - 256 % count:
			at += 1
		picks.append(bytes[at] % count)
		at += 1
	var length: int = 6 + picks[0]
	var text := ""
	var no_space := "abcdefghijlmnoprstuvxz,."
	for i in length:
		var pool := no_space if i == 0 or i == length - 1 else BookSpineScript.ALPHABET
		while bytes[at] >= 256 - 256 % pool.length():
			at += 1
		text += pool[bytes[at] % pool.length()]
		at += 1
	return text


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
