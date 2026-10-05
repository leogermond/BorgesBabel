extends SceneTree
## Vérifie la profondeur du monde : galeries construites sur plus de 50 m dans les
## quatre directions, trompe-l'œil au-delà, lumières et collisionneurs bornés,
## continuité de la lumière vue au passage d'un vestibule ou d'un niveau (voir
## _check_continuity), titres dorés des dos (texture de chaque galerie relue et comparée au
## titre du lecteur, livres d'images, dorure continue à chaque pas), coût d'un pas de vestibule
## et d'un changement de niveau, et aucune fuite après une longue marche.
## godot --headless --path . -s tests/test_depth.gd

const MIN_DEPTH := 50.0          # mètres de vraie géométrie devant le bibliothécaire
const MAX_LIGHTS := 40           # OmniLight3D dans tout le monde
const FULL_GALLERIES := 3        # galeries à collisionneurs : l'origine et ses deux voisines
const SHIFT_BUDGET_USEC := 8000  # un pas (vestibule ou niveau) : moins d'une demi-image à 60 i/s
const CROSSINGS := 16
const LEVEL_SHIFTS := 6
const BookSpineScript := preload("res://scripts/book_spine.gd")
const BookTextScript := preload("res://scripts/book_text.gd")
const AmbientSpeakerScript := preload("res://scripts/ambient_speaker.gd")
const TITLE_SAMPLES := 24          # titres relus par galerie LIT ou FULL
const SETTLE_LIMIT_MSEC := 60000   # attente au plus des titres préparés
const PUMP_BUDGET_USEC := 2000     # travail des titres sur le fil principal, par image
const PUMP_FRAMES := 40            # images par vestibule dans la marche de _check_pump

var _failures := 0


func _initialize() -> void:
	var main: Node3D = load("res://main.tscn").instantiate()
	root.add_child(main)
	await _steps(30)
	var player: CharacterBody3D = main.player

	_check_layout(main, "au départ")
	_check_depth(main, player)
	_check_impostors(main)
	var start := _census(main)
	print("  recensement : %s" % [start])
	_check(start.lights <= MAX_LIGHTS, "au plus %d lampes réelles (lu : %d)" % [MAX_LIGHTS, start.lights])
	_check(start.full == FULL_GALLERIES and start.bodies == FULL_GALLERIES * 5,
		"collisionneurs dans les %d galeries proches seulement (%d galeries complètes, %d corps)" % [FULL_GALLERIES, start.full, start.bodies])
	_check(start.stray_bodies == 0, "aucun collisionneur hors d'une galerie complète (lu : %d)" % start.stray_bodies)

	await _check_titles(main)
	await _check_continuity(main, player)

	var origin_hexagon: int = main.origin_hexagon

	# Longue marche : des pas de vestibule dans un sens puis dans l'autre.
	var times: Array[int] = []
	for step: int in [1, -1]:
		for _i in CROSSINGS:
			var t0 := Time.get_ticks_usec()
			main._shift(step)
			times.append(Time.get_ticks_usec() - t0)
			await _steps(1)
	_report_times("pas de vestibule", times)
	_check(main.origin_hexagon == origin_hexagon, "retour à l'hexagone de départ après %d pas" % (2 * CROSSINGS))
	await _check_pump(main)
	_check_layout(main, "après %d pas de vestibule" % (2 * CROSSINGS))

	# Changements de niveau : le bibliothécaire monté ou descendu d'un niveau d'un coup.
	var origin_level: int = main.origin_level
	times.clear()
	for step: int in [1, 1, 1, -1, -1, -1]:
		var before: int = main.origin_level
		player.position = Vector3(0.0, 0.05 + step * Gallery.LEVEL_PITCH, 3.2)
		player.velocity = Vector3.ZERO
		var t0 := Time.get_ticks_usec()
		main._physics_process(0.0)
		times.append(Time.get_ticks_usec() - t0)
		_check(main.origin_level == before + step and absf(player.position.y - 0.05) < 0.01,
			"le niveau %+d devient l'origine (Δ = %d, y = %.3f)" % [step, main.origin_level - before, player.position.y])
		await _steps(20)
		_check(player.is_on_floor() and absf(player.position.y) < 0.05,
			"le bibliothécaire tient debout sur le nouveau niveau (y = %.3f)" % player.position.y)
	_report_times("changement de niveau", times)
	_check(main.origin_level == origin_level, "retour au niveau de départ")
	_check_layout(main, "après %d changements de niveau" % LEVEL_SHIFTS)
	_check_depth(main, player)

	# Les haut-parleurs du niveau quitté finissent leur fondu de sortie avant le recensement.
	await create_timer(AmbientSpeakerScript.FADE_OUT + 0.3).timeout
	await _steps(2)
	var end := _census(main)
	_check(end == start, "mêmes comptes après la marche (%s)" % ["identiques" if end == start else str(end)])

	# Les livres d'une galerie reprise sont ceux d'une galerie neuve à la même adresse.
	var reused: Gallery = main.get_node("Gallery_%d_%d" % [main.origin_hexagon + 2, main.origin_level])
	var fresh := Gallery.create(reused.hexagon, reused.level, Gallery.Detail.LIT)
	var same: bool = reused.book_heights() == fresh.book_heights() and not fresh.book_heights().is_empty() \
		and reused.book_transform(3, 4, 31) == fresh.book_transform(3, 4, 31) \
		and reused.get_node("Books").material_override.get_shader_parameter("seed") \
			== fresh.get_node("Books").material_override.get_shader_parameter("seed")
	_check(same, "galerie reprise : mêmes livres (hauteurs, graine du nuanceur) qu'une galerie neuve à son adresse")
	await _titles_settled(main)
	fresh.load_titles_now()
	var reused_titles: ImageTexture = reused.get_node("Books").material_override.get_shader_parameter("titles")
	_check(reused.titles_ready() and reused_titles != null
			and reused_titles.get_image().get_data() == fresh.titles_texture().get_image().get_data(),
		"galerie reprise : mêmes titres (texture du matériau) qu'une galerie neuve à son adresse")
	fresh.free()

	# Le MultiMesh commun, avec la hauteur que le nuanceur donne à chaque livre (la boîte
	# unité centrée passe de y à (y + 0,5) × h), place chaque livre là où book_transform le dit.
	var gallery: Gallery = main.get_node("Gallery_%d_%d" % [main.origin_hexagon, main.origin_level])
	var multimesh: MultiMesh = gallery.get_node("Books").multimesh
	var places := Gallery._book_places()
	var off := 0
	for i in Gallery.WALLS * Gallery.SHELVES * Gallery.BOOKS_PER_SHELF:
		var h := gallery.book_heights()[i]
		var o := i * 12
		var place := Transform3D(
			Basis(Vector3(places[o], places[o + 4], places[o + 8]), Vector3(places[o + 1], places[o + 5], places[o + 9]),
				Vector3(places[o + 2], places[o + 6], places[o + 10])),
			Vector3(places[o + 3], places[o + 7], places[o + 11]))
		var built := place * Transform3D(Basis.from_scale(Vector3(1.0, h, 1.0)), Vector3(0.0, h * 0.5, 0.0))
		var wall := i / (Gallery.SHELVES * Gallery.BOOKS_PER_SHELF)
		var shelf := (i / Gallery.BOOKS_PER_SHELF) % Gallery.SHELVES
		var book := i % Gallery.BOOKS_PER_SHELF
		if not built.is_equal_approx(gallery.book_transform(wall, shelf, book)):
			off += 1
	_check(off == 0 and multimesh.instance_count == Gallery.WALLS * Gallery.SHELVES * Gallery.BOOKS_PER_SHELF
			and multimesh == Gallery._shared_book_multimesh(),
		"places des livres conformes à book_transform (écarts : %d)" % off)

	_check_shaders(main)

	_check(await AmbientSpeakerScript.silence_all(self), "sortie : les haut-parleurs se taisent, le serveur audio rend leurs lectures")
	print("test_depth : %s" % ("OK" if _failures == 0 else "%d échec(s)" % _failures))
	quit(1 if _failures else 0)


## Chaque galerie est à la place que lui donne son adresse, au détail que lui donne sa case.
func _check_layout(main: Node, when: String) -> void:
	var cells: Dictionary = main.gallery_cells()
	var misplaced := 0
	var seen := {}
	for gallery in _galleries(main):
		var cell := Vector2i(gallery.hexagon - main.origin_hexagon, gallery.level - main.origin_level)
		var spot := Vector3(0.0, cell.y * Gallery.LEVEL_PITCH, cell.x * Gallery.PITCH)
		if not cells.has(cell) or cells[cell] != gallery.detail or not gallery.position.is_equal_approx(spot):
			misplaced += 1
		seen[cell] = true
	_check(misplaced == 0 and seen.size() == cells.size(),
		"%s : %d galeries, chacune à sa place et à son détail (écarts : %d)" % [when, seen.size(), misplaced])


## Vraie géométrie la plus lointaine, depuis le bibliothécaire, dans les quatre directions.
func _check_depth(main: Node, player: Node3D) -> void:
	var eye := player.position
	var ahead := 0.0
	var behind := 0.0
	var above := 0.0
	var below := 0.0
	for gallery in _galleries(main):
		var offset := gallery.position - eye
		if is_zero_approx(gallery.position.y):
			ahead = maxf(ahead, offset.z)
			behind = maxf(behind, -offset.z)
		if is_zero_approx(gallery.position.z):
			above = maxf(above, offset.y)
			below = maxf(below, -offset.y)
	var far: FarView = main.far_view
	_check(far.get_node("ShaftRings").multimesh.instance_count == far.ring_levels.size(),
		"un anneau du puits par niveau lointain (%d)" % far.ring_levels.size())
	for ring in far.ring_levels:
		var y := ring * Gallery.LEVEL_PITCH - eye.y
		above = maxf(above, y)
		below = maxf(below, -y)
	print("  géométrie la plus lointaine : +Z %.1f m, −Z %.1f m, haut %.1f m, bas %.1f m" % [ahead, behind, above, below])
	_check(ahead >= MIN_DEPTH and behind >= MIN_DEPTH, "galeries à plus de %d m des deux côtés du vestibule" % MIN_DEPTH)
	_check(above >= MIN_DEPTH and below >= MIN_DEPTH, "niveaux à plus de %d m au-dessus et au-dessous" % MIN_DEPTH)


## Un trompe-l'œil à chacun des quatre bouts, au-delà de la vraie géométrie, tourné vers l'origine.
func _check_impostors(main: Node) -> void:
	var far: FarView = main.far_view
	var hall_end: float = main.REACH_ALONG_HALL * Gallery.PITCH + Gallery.APOTHEM + Gallery.WALL_THICK
	var shaft_top: float = main.REACH_VERTICAL * Gallery.LEVEL_PITCH + Gallery.HEIGHT
	var shaft_bottom: float = main.REACH_VERTICAL * Gallery.LEVEL_PITCH + Gallery.SLAB
	var ends := {
		"HallEndPlus": hall_end, "HallEndMinus": hall_end,
		"ShaftTop": shaft_top, "ShaftBottom": shaft_bottom,
	}
	for impostor_name: String in ends:
		var impostor: MeshInstance3D = far.impostors.get(impostor_name)
		if impostor == null:
			_check(false, "trompe-l'œil %s présent" % impostor_name)
			continue
		var axis: Vector3 = impostor.get_meta("axis")
		var along := impostor.global_position.dot(axis)
		var facing := impostor.global_basis.z.dot(-axis)
		var shader: Shader = impostor.material_override.shader
		var uniforms := shader.get_shader_uniform_list().size()
		_check(along > ends[impostor_name] and absf(facing) > 0.999 and uniforms > 0,
			"trompe-l'œil %s à %.1f m, au-delà de la géométrie (%.1f m), face à l'origine, nuanceur compilé (%d uniformes)"
				% [impostor_name, along, ends[impostor_name], uniforms])


## Continuité de la lumière vue, au passage d'un vestibule et d'un niveau.
##
## Indicateur : en chaque point fixe P de la Bibliothèque (repéré par son hexagone et
## son niveau absolus, donc le même avant et après le décalage de l'origine), de
## normale N, la lumière des lampes que la surface y renvoie vers l'œil :
##   vu(P) = [Σ vraies lampes énergie × atténuation(d) × max(N·L, 0)
##            + lumière des lampes que le nuanceur ajoute (ou cuite dans les sommets)]
##           × reste de brume(|P − œil|)
## et 0 quand rien n'est dessiné en P (galerie absente : le trompe-l'œil n'est compté
## pour rien). La couleur des lampes et l'albédo étant communs, cette somme suit la
## luminance. L'œil reste au même point absolu pendant le décalage : un écart entre
## avant et après est un saut de lumière que le bibliothécaire verrait.
## Tolérance : |après − avant| ≤ 1 % de la plus grande des deux valeurs + 1e-4 (une
## lampe à 3 m donne environ 0,3 ; le dixième de la lumière vue à 90 m vaut 1e-3).
const CONTINUITY_RELATIVE := 0.01
const CONTINUITY_ABSOLUTE := 1e-4

var _continuity_origin_hexagon := 0
var _continuity_origin_level := 0


func _check_continuity(main: Node, player: CharacterBody3D) -> void:
	var gallery_script: Script = Gallery
	var shaded := gallery_script.has_method("virtual_light")   # faux sur la version d'avant : lumière cuite
	print("  continuité : modèle de lumière %s" % ("nuanceur + vraies lampes" if shaded else "cuite + vraies lampes"))
	var h0: int = main.origin_hexagon
	var l0: int = main.origin_level
	_continuity_origin_hexagon = h0
	_continuity_origin_level = l0
	var points := _continuity_points()
	# [nom, pas (vestibule) ou pas de niveau, position du bibliothécaire juste au seuil]
	var crossings := [
		["vestibule +Z", Vector2i(1, 0), Vector3(0.0, 0.0, Gallery.PITCH * 0.5)],
		["vestibule +Z, au bord", Vector2i(1, 0), Vector3(0.45, 0.0, Gallery.PITCH * 0.5)],
		["vestibule −Z", Vector2i(-1, 0), Vector3(0.0, 0.0, -Gallery.PITCH * 0.5)],
	]
	# Un niveau se franchit par le puits : l'œil y reste dans le vide, hors des dalles.
	for spot: Vector2 in [Vector2(0.6, 0.4), Vector2(-1.0, 0.8), Vector2(0.0, -1.3), Vector2(1.2, -0.5)]:
		for step: int in [1, -1]:
			crossings.append(["niveau %+d par (%.1f, %.1f)" % [step, spot.x, spot.y], Vector2i(0, step),
				Vector3(spot.x, step * Gallery.LEVEL_PITCH * 0.5, spot.y)])
	var all_ok := true
	var nearest_changes: Array[float] = []
	var exposed_changes := 0
	var gold_jumps := 0
	var gold_pending := 0
	var fade_end: float = gallery_script.get_script_constant_map().get("FAR_FADE_END", INF)
	for crossing: Array in crossings:
		var step: Vector2i = crossing[1]
		# Titres du pas suivant préparés (un pas prend au moins 4 s à pied ; ici quelques images).
		player.position = Vector3(0.0, 0.05, 3.2)
		player.velocity = Vector3.ZERO
		await _titles_settled(main)
		player.position = crossing[2]
		player.velocity = Vector3.ZERO
		_refresh_lamps(main)
		var eye: Vector3 = player.camera.global_position
		var before := _seen_all(main, points, h0, l0, eye, shaded)
		var built_before := _built(main)
		var gilt_before := _gilt(main)
		if step.x != 0:
			main._shift(step.x)
		else:
			main._shift_level(step.y)
		# Galeries et anneaux nés ou disparus : point le plus proche de l'œil, et points
		# de leurs surfaces en vue en deçà du fondu dans la brume.
		var built_after := _built(main)
		var gilt_after := _gilt(main)
		var gold := _gold_jumps(eye, gilt_before, gilt_after)
		gold_jumps += gold.jumps
		gold_pending += gold.pending
		print("    %s : dorure, %d galeries gagnent ou perdent leurs titres (la plus proche à %.1f m), %d points de dos en vue en deçà de %.0f m, %d galeries sans titres prêts"
			% [crossing[0], gold.cells, gold.nearest, gold.jumps, Gallery.TITLE_FADE_END, gold.pending])
		var changed := {}
		for key: Vector2i in built_before:
			if not built_after.has(key) or built_after[key] != built_before[key]:
				changed[key] = true
		for key: Vector2i in built_after:
			if not built_before.has(key) or built_after[key] != built_before[key]:
				changed[key] = true
		var nearest_change := INF
		var exposed := 0
		for key: Vector2i in changed:
			nearest_change = minf(nearest_change, _distance_to_cell(eye, key, true))
			# Anneau devenu galerie (ou l'inverse) : seul compte ce qui dépasse de l'anneau.
			var swap: bool = built_before.has(key) and built_after.has(key)
			var cell_exposed := _exposed_points(eye, key, fade_end, swap)
			if cell_exposed > 0:
				print("      case %s en vue (%d points), avant %s, après %s" % [key, cell_exposed, built_before.get(key, "rien"), built_after.get(key, "rien")])
			exposed += cell_exposed
		nearest_changes.append(nearest_change)
		exposed_changes += exposed
		print("    %s : %d cases nées ou disparues, la plus proche à %.1f m, %d de leurs points en vue en deçà de %.0f m"
			% [crossing[0], changed.size(), nearest_change, exposed, fade_end])
		_refresh_lamps(main)
		var eye_after: Vector3 = player.camera.global_position
		var moved := (eye_after - eye) - Vector3(0.0, -step.y * Gallery.LEVEL_PITCH, -step.x * Gallery.PITCH)
		var after := _seen_all(main, points, h0, l0, eye_after, shaded)
		var worst_excess := -INF   # écart moins tolérance : positif = saut
		var worst_at := 0
		var jumps := 0
		var hidden := 0
		for i in points.size():
			var delta := absf(after[i] - before[i])
			var excess := delta - (CONTINUITY_RELATIVE * maxf(after[i], before[i]) + CONTINUITY_ABSOLUTE)
			if excess > 0.0:
				# Chaque passage part de l'origine de départ : `eye` et le point sont dans son repère.
				if not _in_sight(eye, _absolute(points[i], Vector2i.ZERO)):
					hidden += 1   # caché par les murs ou les dalles : aucun saut visible
					continue
				jumps += 1
			if excess > worst_excess:
				worst_excess = excess
				worst_at = i
		var p: Array = points[worst_at]
		print("    %s : %d points, %d sauts visibles, %d cachés ; pire écart visible %.5f (%.5f → %.5f, %+.1f %%) en galerie %+d, niveau %+d, %s" % [
			crossing[0], points.size(), jumps, hidden, absf(after[worst_at] - before[worst_at]), before[worst_at], after[worst_at],
			100.0 * (after[worst_at] - before[worst_at]) / maxf(before[worst_at], 1e-9), p[0].x, p[0].y, p[3]])
		all_ok = all_ok and jumps == 0 and moved.length() < 1e-4
		# Retour à l'origine de départ, pour le passage suivant.
		if step.x != 0:
			main._shift(-step.x)
		else:
			main._shift_level(-step.y)
	player.position = Vector3(0.0, 0.05, 3.2)
	player.velocity = Vector3.ZERO
	_refresh_lamps(main)
	_check(all_ok, "lumière vue continue au passage d'un vestibule et d'un niveau (écart ≤ %d %% + %.4f en chaque point visible)"
		% [int(CONTINUITY_RELATIVE * 100.0), CONTINUITY_ABSOLUTE])
	_check(main.origin_hexagon == h0 and main.origin_level == l0, "retour à l'origine après les passages")
	_check(exposed_changes == 0, "galeries et anneaux naissent et disparaissent hors de vue ou au-delà du fondu dans la brume (%d points en vue)"
		% exposed_changes)
	# Témoin : le même relevé voit bien la dorure de la galerie d'origine, et celle d'une voisine du
	# niveau au-dessus par le puits, si elles perdaient leurs titres.
	player.position = Vector3(0.0, 0.05, 3.2)
	var witness_eye: Vector3 = player.camera.global_position
	var witness: int = _gold_jumps(witness_eye, {Vector2i(0, 0): 1.0}, {}).jumps
	var witness_up: int = _gold_jumps(Vector3(-1.2, 3.3, 0.0), {Vector2i(0, 1): 1.0}, {}).jumps
	_check(witness > 0 and witness_up > 0, "témoin : le relevé de la dorure voit les dos de la galerie d'origine (%d points) et du niveau au-dessus par le puits (%d)"
		% [witness, witness_up])
	_check(gold_pending == 0, "après chaque pas, toute galerie LIT ou FULL a déjà ses titres (préparés d'avance : %d en attente)" % gold_pending)
	_check(gold_jumps == 0, "dorure continue au passage d'un vestibule et d'un niveau : aucun dos en vue à moins de %.0f m ne gagne ni ne perd ses titres (%d points)"
		% [Gallery.TITLE_FADE_END, gold_jumps])
	if shaded:
		_check_real_lamps(main, player)


## Coût des titres sur le fil principal en marchant : huit vestibules dans un sens puis dans
## l'autre, PUMP_FRAMES images par vestibule (le temps d'une traversée à pied, à peu près) ; à
## chaque image, le temps de Gallery.pump_titles (relevé des calculs et des genres des livres
## arrivés, lancement des suivants). Le service d'arrière-plan et les fils du moteur font le
## reste : aucune image ne doit y passer plus de PUMP_BUDGET_USEC.
func _check_pump(main: Node) -> void:
	await _titles_settled(main)
	var samples: Array[int] = []
	for step: int in [1, -1]:
		for _i in 8:
			main._shift(step)
			for _f in PUMP_FRAMES:
				await process_frame
				samples.append(Gallery.last_pump_usec)
	await _titles_settled(main)
	samples.sort()
	var p99: int = samples[int(samples.size() * 0.99)]
	var worst: int = samples[-1]
	print("  titres en marchant : %d images, pump_titles p99 %.3f ms, pire %.3f ms" % [samples.size(), p99 / 1000.0, worst / 1000.0])
	_check(p99 <= PUMP_BUDGET_USEC and worst <= PUMP_BUDGET_USEC,
		"titres et genres des livres hors du fil principal : pump_titles au plus %.0f ms par image (p99 %.3f ms, pire %.3f ms)" % [PUMP_BUDGET_USEC / 1000.0, p99 / 1000.0, worst / 1000.0])


## Attend que tous les titres soient calculés et posés, fondus d'arrivée compris.
func _titles_settled(main: Node) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < SETTLE_LIMIT_MSEC:
		var waiting := not Gallery.titles_idle()
		for gallery in _galleries(main):
			if gallery.detail >= Gallery.Detail.LIT and (not gallery.titles_ready() or gallery.titles_alpha() < 1.0):
				waiting = true
		if not waiting:
			return
		await process_frame


## Titres dans le monde : la texture branchée sur le matériau des livres de chaque galerie LIT ou
## FULL, relue sur le processeur, donne pour chaque livre tiré le titre que le lecteur affiche
## (BookText.title = display_title(BookSpine.title)) ; les drapeaux des livres d'images (filets
## dorés du nuanceur) sont ceux du service ; les galeries DISTANT, à façades peintes, n'ont rien.
func _check_titles(main: Node) -> void:
	var t0 := Time.get_ticks_msec()
	await _titles_settled(main)
	print("  titres : posés %d ms après l'attente du départ" % (Time.get_ticks_msec() - t0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 1899
	var galleries := 0
	var unready := 0
	var sampled := 0
	var mismatches := 0
	for gallery in _galleries(main):
		if gallery.detail < Gallery.Detail.LIT:
			continue
		galleries += 1
		var texture: ImageTexture = gallery.get_node("Books").material_override.get_shader_parameter("titles")
		if not gallery.titles_ready() or gallery.titles_alpha() != 1.0 or texture == null or texture != gallery.titles_texture():
			unready += 1
			continue
		var bytes := texture.get_image().get_data()
		for k in TITLE_SAMPLES:
			var i: int = [0, 639][k] if k < 2 else rng.randi_range(0, 639)
			var wall := i / 160
			var shelf := (i / 32) % 5
			var book := i % 32
			var shown := BookSpineScript.display_title(BookSpineScript.decode_title(bytes, i))
			sampled += 1
			if shown.is_empty() or shown != BookTextScript.title(gallery.hexagon, gallery.level, wall, shelf, book):
				mismatches += 1
				if mismatches <= 3:
					print("      %s livre %d : « %s », attendu « %s »" % [gallery.name, i, shown,
						BookTextScript.title(gallery.hexagon, gallery.level, wall, shelf, book)])
	_check(galleries == 19 and unready == 0, "%d galeries LIT ou FULL, chacune avec la texture de ses titres, opacité 1 (en défaut : %d)" % [galleries, unready])
	_check(sampled > 0 and mismatches == 0, "titres relus dans la texture = titre du lecteur, %d livres tirés (écarts : %d)" % [sampled, mismatches])
	var origin: Gallery = main.get_node("Gallery_%d_%d" % [main.origin_hexagon, main.origin_level])
	var flags: Array = BookTextScript.gallery_image_books(origin.hexagon, origin.level)
	var texture: ImageTexture = origin.titles_texture()
	var flagged := 0
	var wrong := 0
	if texture != null:
		var bytes := texture.get_image().get_data()
		for i in 640:
			var flag := BookSpineScript.decode_image_flag(bytes, i)
			flagged += int(flag)
			if flag != (i < flags.size() and bool(flags[i])):
				wrong += 1
	_check(texture != null and flags.size() == 640 and wrong == 0 and flagged > 0,
		"livres d'images de la galerie d'origine : %d drapeaux (filets dorés) dans la texture, comme le service (écarts : %d)" % [flagged, wrong])
	var distant_titled := 0
	for gallery in _galleries(main):
		if gallery.detail == Gallery.Detail.DISTANT and gallery.has_node("Books"):
			distant_titled += 1
	_check(distant_titled == 0, "galeries lointaines sans livres un à un ni titres (façades peintes)")


## Opacité des titres de chaque galerie construite, par case relative à l'origine de départ :
## celle du nuanceur pour une galerie LIT ou FULL dont les titres sont posés, 0 sinon.
func _gilt(main: Node) -> Dictionary:
	var gilt := {}
	for gallery in _galleries(main):
		var cell := Vector2i(gallery.hexagon - _continuity_origin_hexagon, gallery.level - _continuity_origin_level)
		gilt[cell] = gallery.titles_alpha() if gallery.detail >= Gallery.Detail.LIT and gallery.titles_ready() else 0.0
		if gallery.detail >= Gallery.Detail.LIT and not gallery.titles_ready():
			gilt[cell] = -1.0   # en attente : compté à part
	return gilt


## Poids de la dorure en un point de dos = opacité des titres de sa galerie × title_weight(distance à
## l'œil) : l'œil restant au même point absolu, il ne change qu'aux galeries qui gagnent ou perdent
## leurs titres. Compte les points de dos tournés vers l'œil, en vue, où il change de plus de 1e-3.
func _gold_jumps(eye: Vector3, before: Dictionary, after: Dictionary) -> Dictionary:
	var result := {"jumps": 0, "cells": 0, "nearest": INF, "pending": 0}
	var cells := before.duplicate()
	cells.merge(after)
	for cell: Vector2i in cells:
		var a: float = maxf(before.get(cell, 0.0), 0.0)
		var b: float = after.get(cell, 0.0)
		if b < 0.0:
			result.pending += 1
			b = 0.0
		if absf(a - b) <= 1e-3:
			continue
		result.cells += 1
		var origin := Vector3(0.0, cell.y * Gallery.LEVEL_PITCH, cell.x * Gallery.PITCH)
		for spot: Array in _spine_grid():
			var p: Vector3 = origin + spot[0]
			var d := p.distance_to(eye)
			result.nearest = minf(result.nearest, d)
			var w: float = Gallery.title_weight(d)
			if absf(a - b) * w <= 1e-3 or (eye - p).dot(spot[1]) <= 0.0:
				continue
			if _in_sight(eye, p):
				result.jumps += 1
	return result


var _spines: Array = []


## Points des dos des quatre murs de livres (repère de la galerie) et leur normale, vers la salle.
func _spine_grid() -> Array:
	if _spines.is_empty():
		for side: int in Gallery.BOOK_SIDES:
			var basis := Basis(Vector3.UP, side * PI / 3.0)
			for i in range(-6, 7):
				for j in range(Gallery.SHELVES):
					_spines.append([basis * Vector3(i * 0.38, Gallery.BOARD_BASE + 0.15 + j * Gallery.BOARD_PITCH, Gallery.BOOK_FRONT),
						basis * Vector3.FORWARD])
	return _spines


## Points fixes : [case absolue (galerie, niveau) relative à l'origine de départ, point
## dans le repère de la galerie, normale, nom]. Le long du vestibule sur trois niveaux,
## et le long du puits.
func _continuity_points() -> Array:
	var points := []
	var local_points := [
		[Vector3(0.0, 0.0, 3.5), Vector3.UP, "sol"],
		[Vector3(0.0, 0.0, -3.5), Vector3.UP, "sol"],
		[Vector3(3.0, 0.0, 0.0), Vector3.UP, "sol"],
		[Vector3(0.0, 0.0, Gallery.APOTHEM + 1.0), Vector3.UP, "sol du vestibule"],
		[Vector3(0.0, Gallery.HEIGHT, 3.5), Vector3.DOWN, "plafond"],
		[Vector3(Gallery.LAMP_X, Gallery.HEIGHT, -2.0), Vector3.DOWN, "plafond"],
		[Vector3(Gallery.HALL_WIDTH * 0.5, 1.5, Gallery.APOTHEM + 1.0), Vector3.LEFT, "mur du vestibule"],
	]
	for side: int in Gallery.BOOK_SIDES:
		var basis := Basis(Vector3.UP, side * PI / 3.0)
		local_points.append([basis * Vector3(0.0, 1.5, Gallery.BOOK_FRONT), basis * Vector3.FORWARD, "livres, côté %d" % side])
	for dy in range(-6, 7):
		for dz in range(-12, 13):
			if absi(dy) > 1 and absi(dz) > 3:
				continue
			for lp: Array in local_points:
				points.append([Vector2i(dz, dy), lp[0], lp[1], lp[2]])
	var shaft_points := [
		[Vector3(2.3, 0.0, 0.0), Vector3.UP, "sol du puits"],
		[Vector3(-1.2, 0.0, 2.0), Vector3.UP, "sol du puits"],
		[Vector3(2.3, Gallery.HEIGHT, 0.0), Vector3.DOWN, "plafond du puits"],
		[Vector3(0.0, Gallery.RAIL_HEIGHT * 0.5, Gallery.RAIL_APOTHEM - 0.04), Vector3.FORWARD, "balustrade"],
	]
	for dy in range(-34, 35):
		for sp: Array in shaft_points:
			points.append([Vector2i(0, dy), sp[0], sp[1], sp[2]])
	return points


func _seen_all(main: Node, points: Array, h0: int, l0: int, eye: Vector3, shaded: bool) -> PackedFloat32Array:
	var lamps: Array = []   # [position, énergie] des vraies lampes allumées
	var stack: Array[Node] = [main]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node.is_queued_for_deletion():
			continue
		if node is OmniLight3D and node.is_visible_in_tree() and node.light_energy > 0.0:
			lamps.append([node.global_position, node.light_energy, node.omni_range])
		stack.append_array(node.get_children())
	var seen := PackedFloat32Array()
	seen.resize(points.size())
	var shift := Vector2i(main.origin_hexagon - h0, main.origin_level - l0)
	var far: FarView = main.far_view
	var gallery_script: Script = Gallery
	for i in points.size():
		var cell: Vector2i = points[i][0] - shift
		var local: Vector3 = points[i][1]
		var normal: Vector3 = points[i][2]
		var p := _absolute(points[i], shift)
		# Par le nom de la galerie : le test se lit aussi sur la version d'avant.
		var gallery := main.get_node_or_null(Gallery._node_name(main.origin_hexagon + cell.x, main.origin_level + cell.y)) as Gallery
		if gallery != null and gallery.is_queued_for_deletion():
			gallery = null
		var ring := cell.x == 0 and far.ring_levels.has(cell.y) and Vector2(local.x, local.z).length() <= Gallery.RING_APOTHEM
		if gallery == null and not ring:
			seen[i] = 0.0
			continue
		var light := 0.0
		for lamp: Array in lamps:
			light += lamp[1] * _falloff(lamp[0] - p, normal, lamp[2])
		if shaded:
			light += gallery_script.call("virtual_light", p, normal, eye)
		elif gallery == null or gallery.detail == Gallery.Detail.DISTANT:
			# Version d'avant : lumière des lampes de la galerie et des niveaux voisins, cuite.
			for dy: float in [-Gallery.LEVEL_PITCH, 0.0, Gallery.LEVEL_PITCH]:
				for dir: float in [-1.0, 1.0]:
					var lamp_at := Vector3(dir * Gallery.LAMP_X, Gallery.LAMP_LIGHT_Y + dy, 0.0)
					light += Gallery.LAMP_ENERGY * _falloff(lamp_at - local, normal, Gallery.LAMP_RANGE)
		var d := p.distance_to(eye)
		var visible := exp(-main.FOG_DENSITY * d)
		if gallery_script.has_method("far_fade"):
			visible *= gallery_script.call("far_fade", d)
		seen[i] = light * visible
	return seen


## Cases construites, relatives à l'origine de départ (hexagone, niveau) : vrai pour une galerie,
## faux pour un anneau du puits seul.
func _built(main: Node) -> Dictionary:
	var built := {}
	for gallery in _galleries(main):
		built[Vector2i(gallery.hexagon - _continuity_origin_hexagon, gallery.level - _continuity_origin_level)] = true
	for ring: int in main.far_view.ring_levels:
		var cell := Vector2i(main.origin_hexagon - _continuity_origin_hexagon, main.origin_level + ring - _continuity_origin_level)
		if not built.has(cell):
			built[cell] = false
	return built


## Points des surfaces d'une case (galerie entière ou, faute de mieux, son seul anneau,
## tous deux comptés comme galerie entière : le plus strict) en vue de l'œil, à moins
## de `fade_end` de lui. Grille de 0,6 m sur le sol, le plafond, les façades de livres,
## les murs du vestibule.
func _exposed_points(eye: Vector3, cell: Vector2i, fade_end: float, outside_ring: bool) -> int:
	var origin := Vector3(0.0, cell.y * Gallery.LEVEL_PITCH, cell.x * Gallery.PITCH)
	if _distance_to_cell(eye, cell, true) >= fade_end:
		return 0
	var exposed := 0
	for local: Vector3 in _surface_grid():
		if outside_ring and _hex_apothem(local) <= Gallery.RING_APOTHEM:
			continue
		var p := origin + local
		if p.distance_to(eye) < fade_end and _in_sight(eye, p):
			exposed += 1
	return exposed


var _grid: Array[Vector3] = []


func _surface_grid() -> Array[Vector3]:
	if not _grid.is_empty():
		return _grid
	var step := 0.6
	for i in range(-10, 11):
		for j in range(-10, 11):
			var q := Vector3(i * step, 0.0, j * step)
			var apothem := _hex_apothem(q)
			if apothem < Gallery.APOTHEM - 0.05 and apothem > Gallery.SHAFT_APOTHEM + 0.05:
				_grid.append(q)
				_grid.append(q + Vector3.UP * Gallery.HEIGHT)
	for side: int in Gallery.BOOK_SIDES:
		var basis := Basis(Vector3.UP, side * PI / 3.0)
		for i in range(-3, 4):
			for j in range(1, 5):
				_grid.append(basis * Vector3(i * 0.7, j * 0.55, Gallery.BOOK_FRONT))
	for z in [Gallery.APOTHEM + 0.3, Gallery.APOTHEM + 1.0, Gallery.APOTHEM + 1.7]:
		_grid.append(Vector3(0.0, 0.0, z))
		_grid.append(Vector3(0.0, Gallery.HEIGHT, z))
		for x in [-0.8, 0.8]:
			_grid.append(Vector3(x, 1.5, z))
	return _grid


## Distance de l'œil (repère du monde au moment du relevé, origine de départ du passage)
## au point le plus proche d'une galerie (hexagone de 5,8 m de rayon et son vestibule)
## ou d'un anneau (3,5 m de rayon), sur la hauteur d'un niveau.
func _distance_to_cell(eye: Vector3, cell: Vector2i, full: bool) -> float:
	var center := Vector3(0.0, cell.y * Gallery.LEVEL_PITCH, cell.x * Gallery.PITCH)
	var radius := Gallery.APOTHEM + Gallery.HALL_LENGTH + Gallery.WALL_THICK if full else Gallery.RING_APOTHEM * 2.0 / sqrt(3.0)
	var horizontal := maxf(Vector2(eye.x - center.x, eye.z - center.z).length() - radius, 0.0)
	var vertical := maxf(maxf(center.y - Gallery.SLAB - eye.y, eye.y - center.y - Gallery.HEIGHT), 0.0)
	return Vector2(horizontal, vertical).length()


## Position d'un point fixe dans le repère du monde, l'origine décalée de `shift` cases.
static func _absolute(point: Array, shift: Vector2i) -> Vector3:
	var cell: Vector2i = point[0] - shift
	return point[1] + Vector3(0.0, cell.y * Gallery.LEVEL_PITCH, cell.x * Gallery.PITCH)


## Vrai quand le segment œil → point ne traverse aucune paroi de la Bibliothèque entière :
## dalles percées du puits, murs hexagonaux ouverts sur les vestibules, murs des
## vestibules. La balustrade, basse et mince, ne cache rien ici (le test en est plus strict).
static func _in_sight(eye: Vector3, p: Vector3) -> bool:
	var length := eye.distance_to(p)
	var steps := int(length / 0.05)
	for s in range(1, steps - 2):   # le dernier pas touche la surface du point visé
		if not _in_air(eye.lerp(p, float(s) / steps)):
			return false
	return true


## Apothème de l'hexagone de la galerie (normales des côtés à i × 60° de +Z) qui passe par q.
static func _hex_apothem(q: Vector3) -> float:
	var apothem := 0.0
	for k in 3:
		var angle := k * PI / 3.0
		apothem = maxf(apothem, absf(q.x * sin(angle) + q.z * cos(angle)))
	return apothem


static func _in_air(q: Vector3) -> bool:
	var n := roundf(q.z / Gallery.PITCH)
	var x := q.x
	var z := q.z - n * Gallery.PITCH
	var y := q.y - floorf(q.y / Gallery.LEVEL_PITCH) * Gallery.LEVEL_PITCH
	var apothem := _hex_apothem(Vector3(x, 0.0, z))
	if y > Gallery.HEIGHT:
		return apothem < Gallery.SHAFT_APOTHEM
	return apothem < Gallery.APOTHEM or (absf(x) < Gallery.HALL_WIDTH * 0.5 and absf(z) >= Gallery.APOTHEM)


## Atténuation d'une OmniLight3D de Godot, (1 − (d/portée)⁴)² / d, fois le cosinus
## lambertien : `to` va du point éclairé à la lampe.
static func _falloff(to: Vector3, normal: Vector3, light_range: float) -> float:
	var d := to.length()
	if d >= light_range or d < 0.0001:
		return 0.0
	var nd := d / light_range
	nd = 1.0 - nd * nd * nd * nd
	return nd * nd / d * maxf(normal.dot(to / d), 0.0)


func _refresh_lamps(main: Node) -> void:
	if main.has_method("_update_lamps"):
		main._update_lamps()


## Toute lampe du réseau que le nuanceur éteint en partie (poids réel > 0), pour un œil
## n'importe où dans la galerie d'origine, existe en vraie lampe à l'énergie voulue.
func _check_real_lamps(main: Node, player: CharacterBody3D) -> void:
	var gallery_script: Script = Gallery
	var missing := 0
	var wrong := 0
	var tried := 0
	for ex in [-4.5, 0.0, 4.5]:
		for ey in [-1.69, 0.0, 1.69]:
			for ez in [-5.99, -3.0, 0.0, 3.0, 5.99]:
				player.position = Vector3(ex, ey, ez)
				_refresh_lamps(main)
				var eye: Vector3 = player.camera.global_position
				var real := {}
				for gallery in _galleries(main):
					var lights := gallery.get_node_or_null("Lights")
					if lights == null:
						continue
					for light: OmniLight3D in lights.get_children():
						real[Vector3i((light.global_position * 10.0).round())] = light
				for n in range(-3, 4):
					for k in range(-4, 5):
						for dir: float in [-1.0, 1.0]:
							var at := Vector3(dir * Gallery.LAMP_X, Gallery.LAMP_LIGHT_Y + k * Gallery.LEVEL_PITCH, n * Gallery.PITCH)
							var w: float = gallery_script.call("real_weight", at.distance_to(eye))
							if w <= 0.0:
								continue
							tried += 1
							var light: OmniLight3D = real.get(Vector3i((at * 10.0).round()))
							if light == null:
								missing += 1
							elif not light.visible or absf(light.light_energy - Gallery.LAMP_ENERGY * w) > 1e-5:
								wrong += 1
	player.position = Vector3(0.0, 0.05, 3.2)
	_refresh_lamps(main)
	_check(missing == 0 and wrong == 0 and tried > 0,
		"chaque lampe en partie réelle (%d cas) a sa OmniLight3D à l'énergie voulue (manquantes : %d, fausses : %d)" % [tried, missing, wrong])


## Toutes les surfaces des galeries et des anneaux ont le nuanceur de la Bibliothèque,
## compilé ; le hachage des livres de GDScript donne les valeurs de référence de lowbias32.
func _check_shaders(main: Node) -> void:
	var foreign := 0
	var seen_shaders := {}
	var meshes: Array = [main.far_view.get_node("ShaftRings").multimesh.mesh]
	for gallery in _galleries(main):
		for child in gallery.get_children():
			if child is GeometryInstance3D and child.material_override != null:
				var shader: Shader = child.material_override.shader if child.material_override is ShaderMaterial else null
				if shader == null:
					foreign += 1
				else:
					seen_shaders[shader] = true
			elif child is MeshInstance3D:
				meshes.append(child.mesh)
	for mesh: Mesh in meshes:
		for s in mesh.get_surface_count():
			var material := mesh.surface_get_material(s) as ShaderMaterial
			if material == null:
				foreign += 1
			else:
				seen_shaders[material.shader] = true
	var compiled := 0
	for shader: Shader in seen_shaders:
		if shader.code.contains("float virtual_light(") and shader.get_shader_uniform_list().size() >= 3:
			compiled += 1
	# La branche du rendu Compatibilité se compile aussi (forcée ici : le rendu factice
	# de --headless ne la prend pas de lui-même).
	for shader: Shader in seen_shaders:
		var forced := Shader.new()
		forced.code = shader.code.replace("#if CURRENT_RENDERER == RENDERER_COMPATIBILITY", "#if 1")
		if forced.code != shader.code and forced.get_shader_uniform_list().size() >= 3:
			compiled += 1
	_check(foreign == 0 and compiled == 2 * seen_shaders.size() and seen_shaders.size() == 3,
		"un seul nuanceur de lumière pour toutes les surfaces (%d variantes × 2 rendus compilées, %d surfaces étrangères)"
			% [seen_shaders.size(), foreign])
	# Variante BOOKS : titres dorés lus dans la texture de la galerie, sous la même lumière.
	var titled := 0
	for shader: Shader in seen_shaders:
		if (shader.code.contains("#define BOOKS") and shader.code.contains("texelFetch(titles")
				and shader.code.contains("gold_sheen(") and not shader.code.contains("INSTANCE_CUSTOM")):
			titled += 1
	_check(titled == 1, "une variante (BOOKS) dessine les titres, lus au texel près dans la texture de la galerie")
	# Valeurs calculées à part (Python) : lowbias32 de 0, 1, 2, 12345, 2³² − 1.
	var reference := [0, 1753845952, 3507691905, 2435775735, 1734902346]
	var got := []
	for x in [0, 1, 2, 12345, 0xFFFFFFFF]:
		got.append(Gallery.lowbias32(x))
	_check(got == reference, "hachage des livres conforme à lowbias32 (%s)" % [got])


func _census(main: Node) -> Dictionary:
	var census := {
		"galleries": 0, "full": 0, "lit": 0, "distant": 0, "lights": 0, "bodies": 0,
		"shapes": 0, "stray_bodies": 0, "books": 0, "nodes": 0,
	}
	for gallery in _galleries(main):
		census.galleries += 1
		match gallery.detail:
			Gallery.Detail.FULL: census.full += 1
			Gallery.Detail.LIT: census.lit += 1
			Gallery.Detail.DISTANT: census.distant += 1
	var stack: Array[Node] = [main]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is Player or node.is_queued_for_deletion():
			continue
		census.nodes += 1
		if node is OmniLight3D:
			census.lights += 1
		if node is StaticBody3D:
			census.bodies += 1
			var owner_gallery := node.get_parent() as Gallery
			if owner_gallery == null or owner_gallery.detail != Gallery.Detail.FULL:
				census.stray_bodies += 1
		if node is CollisionShape3D:
			census.shapes += 1
		if node is MultiMeshInstance3D and node.name == "Books":
			census.books += node.multimesh.instance_count
		stack.append_array(node.get_children())
	return census


func _report_times(what: String, times: Array[int]) -> void:
	var total := 0
	var worst := 0
	for t in times:
		total += t
		worst = maxi(worst, t)
	print("  %s : %d mesures, moyenne %.2f ms, pire %.2f ms" % [what, times.size(), total / 1000.0 / times.size(), worst / 1000.0])
	_check(worst <= SHIFT_BUDGET_USEC, "%s en moins de %.0f ms (pire : %.2f ms)" % [what, SHIFT_BUDGET_USEC / 1000.0, worst / 1000.0])


func _galleries(main: Node) -> Array[Gallery]:
	var found: Array[Gallery] = []
	for node in main.get_children():
		if node is Gallery and not node.is_queued_for_deletion():
			found.append(node)
	return found


func _steps(count: int) -> void:
	for _i in count:
		await physics_frame


func _check(condition: bool, label: String) -> void:
	print(("  ok    " if condition else "  ÉCHEC ") + label)
	if not condition:
		_failures += 1
