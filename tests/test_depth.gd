extends SceneTree
## Vérifie la profondeur du monde : galeries construites sur plus de 50 m dans les
## quatre directions, trompe-l'œil au-delà, lumières et collisionneurs bornés,
## coût d'un pas de vestibule et d'un changement de niveau, et aucune fuite après
## une longue marche.
## godot --headless --path . -s tests/test_depth.gd

const MIN_DEPTH := 50.0          # mètres de vraie géométrie devant le bibliothécaire
const MAX_LIGHTS := 40           # OmniLight3D dans tout le monde
const FULL_GALLERIES := 3        # galeries à collisionneurs : l'origine et ses deux voisines
const SHIFT_BUDGET_USEC := 8000  # un pas (vestibule ou niveau) : moins d'une demi-image à 60 i/s
const CROSSINGS := 16
const LEVEL_SHIFTS := 6

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

	await _steps(2)
	var end := _census(main)
	_check(end == start, "mêmes comptes après la marche (%s)" % ["identiques" if end == start else str(end)])

	# Les livres d'une galerie reprise sont ceux d'une galerie neuve à la même adresse.
	var reused: Gallery = main.get_node("Gallery_%d_%d" % [main.origin_hexagon + 2, main.origin_level])
	var fresh := Gallery.create(reused.hexagon, reused.level, Gallery.Detail.LIT)
	var same: bool = reused._book_heights == fresh._book_heights and not fresh._book_heights.is_empty() \
		and reused.book_transform(3, 4, 31) == fresh.book_transform(3, 4, 31)
	_check(same, "galerie reprise : mêmes livres qu'une galerie neuve à son adresse")
	fresh.free()

	# Le tampon des livres, rempli d'un bloc, place chaque livre là où book_transform le dit.
	var template := Gallery._book_template()
	var gallery: Gallery = main.get_node("Gallery_%d_%d" % [main.origin_hexagon, main.origin_level])
	var off := 0
	for i in Gallery.WALLS * Gallery.SHELVES * Gallery.BOOKS_PER_SHELF:
		var h := gallery._book_heights[i]
		var o := i * 16
		var built := Transform3D(
			Basis(Vector3(template[o], template[o + 4], template[o + 8]),
				Vector3(template[o + 1], h, template[o + 9]),
				Vector3(template[o + 2], template[o + 6], template[o + 10])),
			Vector3(template[o + 3], template[o + 7] + h * 0.5, template[o + 11]))
		var wall := i / (Gallery.SHELVES * Gallery.BOOKS_PER_SHELF)
		var shelf := (i / Gallery.BOOKS_PER_SHELF) % Gallery.SHELVES
		var book := i % Gallery.BOOKS_PER_SHELF
		if not built.is_equal_approx(gallery.book_transform(wall, shelf, book)):
			off += 1
	_check(off == 0, "tampon des livres conforme à book_transform (écarts : %d)" % off)

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
