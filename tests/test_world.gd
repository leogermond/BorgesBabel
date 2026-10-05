extends SceneTree
## Vérifie le monde en marche : apparition, galeries entretenues, livre visé,
## lecture, et traversée d'un vestibule vers la galerie voisine.
## godot --headless --path . -s tests/test_world.gd

const GalleryScript := preload("res://scripts/gallery.gd")
const BookTextScript := preload("res://scripts/book_text.gd")
const QuestScript := preload("res://scripts/quest.gd")
## Budget d'un pas (vestibule ou niveau), celui de test_depth : moins d'une demi-image à 60 i/s.
const SHIFT_BUDGET_USEC := 8000
# 17 galeries sur 3 niveaux le long du vestibule, 6 niveaux du puits en galeries entières,
# et de chaque côté les diagonales vues par les puits voisins (|dz| − 1 ≤ |dy| ≤ |dz| + 1,
# hors des trois rangées) : 2 cases à |dz| = 1, 4 à |dz| = 2, 6 de |dz| = 3 à 8.
const GALLERIES := 17 * 3 + 6 + 2 * (2 + 4 + 6 * 6)

var _failures := 0


func _initialize() -> void:
	var main: Node3D = load("res://main.tscn").instantiate()
	root.add_child(main)
	await _steps(30)

	var player: CharacterBody3D = main.player
	var start: int = main.origin_hexagon
	_check(player.is_on_floor() and absf(player.position.y) < 0.05, "le bibliothécaire tient debout (y = %.3f)" % player.position.y)
	_check(_gallery_count(main) == GALLERIES, "%d galeries entretenues (lu : %d)" % [GALLERIES, _gallery_count(main)])

	# Chaque livre se retrouve à partir d'un point de la façade devant lui.
	var gallery: Gallery = main.get_node("Gallery_%d_%d" % [start, main.origin_level])
	var mismatches := 0
	for wall in GalleryScript.WALLS:
		var bookcase: StaticBody3D = gallery.get_node("Bookcase%d" % wall)
		for shelf in GalleryScript.SHELVES:
			for book in GalleryScript.BOOKS_PER_SHELF:
				var local := bookcase.basis.inverse() * gallery.book_transform(wall, shelf, book).origin
				local.z = GalleryScript.APOTHEM - GalleryScript.CASE_DEPTH
				var found := gallery.locate_book(bookcase, bookcase.global_transform * local)
				if found.get("wall") != wall or found.get("shelf") != shelf or found.get("book") != book:
					mismatches += 1
	_check(mismatches == 0, "les 640 livres se retrouvent depuis la façade (écarts : %d)" % mismatches)

	# Face au mur de livres 0 (côté 1), le rayon trouve un livre.
	player.rotation.y = PI / 3.0 + PI
	player.camera.rotation.x = -0.2
	player.position = Basis(Vector3.UP, PI / 3.0) * Vector3(0.0, 0.0, 3.4)
	await _steps(3)
	_check(not player.target.is_empty() and player.target.wall == 0, "le livre visé est sur le mur 0 (%s)" % [_brief(player.target)])

	if not player.target.is_empty():
		main._open_book()
		var reader: Reader = main.reader
		_check(reader.visible and player.frozen, "le livre s'ouvre, le bibliothécaire s'arrête")
		var first := reader._text.text
		reader.turn(1)
		_check(reader.page == 1 and reader._text.text != first, "la page suivante s'affiche")
		reader.turn(-5)
		_check(reader.page == 0, "la première page arrête le retour en arrière")
		var lines := first.split("\n")
		_check(lines.size() == 40 and lines[0].length() == 80, "la page affichée fait 40 × 80")
		main._close_book()
		_check(not reader.visible and not player.frozen, "le livre se referme")

	# Traversée du vestibule +Z jusqu'à la galerie voisine, puis retour.
	player.position = Vector3(0.0, 0.0, 3.2)
	player.rotation.y = PI
	player.camera.rotation.x = 0.0
	Input.action_press("move_forward")
	await _steps(75)
	Input.action_release("move_forward")
	_check(main.origin_hexagon == start + 1 and main.origin_hexagon_b25 == BookTextScript.b25(start + 1), "la galerie voisine devient l'origine, en int et en base 25 (Δ = %d)" % (main.origin_hexagon - start))
	_check(player.position.y > -0.05 and player.position.z < 0.0, "le bibliothécaire arrive dans la galerie voisine (%s)" % player.position)
	_check(_gallery_count(main) == GALLERIES, "toujours %d galeries après le décalage (lu : %d)" % [GALLERIES, _gallery_count(main)])

	player.rotation.y = 0.0
	Input.action_press("move_forward")
	await _steps(75)
	Input.action_release("move_forward")
	_check(main.origin_hexagon == start, "retour à la galerie de départ")

	# Le puits : marcher vers le centre bute sur la balustrade.
	player.position = Vector3(0.0, 0.0, 3.2)
	player.rotation.y = 0.0
	Input.action_press("move_forward")
	await _steps(120)
	Input.action_release("move_forward")
	_check(player.position.z > GalleryScript.RAIL_APOTHEM and player.position.y > -0.05,
		"la balustrade arrête le bibliothécaire (z = %.2f)" % player.position.z)

	await _test_far_walk(main, player)

	print("test_world : %s" % ("OK" if _failures == 0 else "%d échec(s)" % _failures))
	BookTextScript.shutdown()
	quit(1 if _failures else 0)


## Marche à une adresse de ~917 000 chiffres décimaux (la galerie du livre de « La biblioteca de
## Babel ») : ±1 galerie et ±1 niveau, temps d'un pas, adresse affichée, traversée à pied, et
## lecture du livre du catalogue à son adresse.
func _test_far_walk(main: Node3D, player: CharacterBody3D) -> void:
	var entry: Dictionary = QuestScript.load_catalogue()[0]
	var target: Dictionary = entry.address
	var near := _measure_steps(main, player)
	_check(main.place_origin(target.hexagon, target.level), "l'origine se place sur la galerie d'un livre du catalogue (%d chiffres base 25)" % target.hexagon.length())
	player.position = Vector3(0.0, 0.05, 3.2)
	await _steps(5)
	_check(main.origin_hexagon_b25 == target.hexagon and main.origin_level_b25 == target.level and _gallery_count(main) == GALLERIES,
		"%d galeries entretenues autour de l'origine lointaine" % GALLERIES)
	var shown: String = main.hud._address.text
	_check(shown.contains("…") and shown.contains("chiffres)"), "adresse lointaine affichée en abrégé : %s" % shown)

	var far := _measure_steps(main, player)
	_check(main.origin_hexagon_b25 == target.hexagon and main.origin_level_b25 == target.level, "pas aller et retour : l'origine revient exactement")
	print("  pas de vestibule : pire %.2f ms près de 0, %.2f ms à 917 000 chiffres ; niveau : %.2f ms / %.2f ms (médianes %.2f / %.2f ms)" % [
		near.hall / 1000.0, far.hall / 1000.0, near.level / 1000.0, far.level / 1000.0, near.median / 1000.0, far.median / 1000.0])
	_check(far.hall <= SHIFT_BUDGET_USEC, "pas de vestibule à 917 000 chiffres en moins de %.0f ms (pire : %.2f ms)" % [SHIFT_BUDGET_USEC / 1000.0, far.hall / 1000.0])
	_check(far.level <= SHIFT_BUDGET_USEC, "changement de niveau à 917 000 chiffres en moins de %.0f ms (pire : %.2f ms)" % [SHIFT_BUDGET_USEC / 1000.0, far.level / 1000.0])
	main._shift(1)
	main._shift_level(-1)
	var h := BookTextScript.b25_add_small(target.hexagon, 1)
	var l := BookTextScript.b25_add_small(target.level, -1)
	_check(main.origin_hexagon_b25 == h and main.origin_level_b25 == l, "un pas +1 galerie, −1 niveau : l'adresse suit exactement")
	var expected := "Hexagone %s · niveau %s" % [BookTextScript.summary_text(BookTextScript.coordinate_summary(h)), BookTextScript.summary_text(BookTextScript.coordinate_summary(l))]
	_check(main.hud._address.text == expected, "l'adresse affichée suit les pas, comme la relecture par le service : %s" % main.hud._address.text)
	main._shift(-1)
	main._shift_level(1)

	# À pied : traversée du vestibule +Z jusqu'à la galerie voisine.
	player.position = Vector3(0.0, 0.05, 3.2)
	player.rotation.y = PI
	player.camera.rotation.x = 0.0
	await _steps(3)
	Input.action_press("move_forward")
	await _steps(75)
	Input.action_release("move_forward")
	_check(main.origin_hexagon_b25 == h and main.origin_level_b25 == target.level, "à pied, la galerie voisine de la galerie lointaine devient l'origine")
	main._shift(-1)

	# Le livre du catalogue, lu à son adresse depuis la galerie : sa première page a le condensat du catalogue.
	var local := {"hexagon": main.origin_hexagon, "level": main.origin_level, "wall": target.wall, "shelf": target.shelf, "book": target.book}
	var book: Dictionary = main.target_address(local)
	_check(book == target, "le livre visé dans la galerie lointaine a l'adresse du catalogue")
	main.reader.open(book)
	var text: String = main.reader._text.text.replace("\n", "")
	_check(text.sha256_text() == entry.pages[0].sha256, "le lecteur montre la page 1 du livre de « %s »" % entry.title)
	_check(main.reader._heading.text.contains("chiffres"), "en-tête du lecteur abrégé : %s" % main.reader._heading.text.left(140))
	main.reader.turn(1)
	_check(main.reader._text.text.replace("\n", "").sha256_text() == entry.pages[1].sha256, "page 2 : le texte continue")
	main.reader.close()


## Pas de vestibule et de niveau, aller et retour : {hall, level : pires temps, median : médiane}, en µs.
func _measure_steps(main: Node3D, player: CharacterBody3D) -> Dictionary:
	var times := []
	var worst := {"hall": 0, "level": 0}
	for step in [Vector2i(1, 0), Vector2i(1, 0), Vector2i(-1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1), Vector2i(0, -1), Vector2i(0, 1)]:
		var t := Time.get_ticks_usec()
		if step.x != 0:
			main._shift(step.x)
		else:
			main._shift_level(step.y)
		var spent := Time.get_ticks_usec() - t
		times.append(spent)
		var axis := "hall" if step.x != 0 else "level"
		worst[axis] = maxi(worst[axis], spent)
		player.position = Vector3(0.0, 0.05, 3.2)
	times.sort()
	@warning_ignore("integer_division")
	worst.median = times[times.size() / 2]
	return worst


func _steps(count: int) -> void:
	for _i in count:
		await physics_frame


func _gallery_count(main: Node) -> int:
	return main.get_children().filter(func(n: Node) -> bool: return n is Gallery and not n.is_queued_for_deletion()).size()


func _brief(target: Dictionary) -> String:
	if target.is_empty():
		return "aucun"
	return "mur %d, étagère %d, livre %d" % [target.wall, target.shelf, target.book]


func _check(condition: bool, label: String) -> void:
	print(("  ok    " if condition else "  ÉCHEC ") + label)
	if not condition:
		_failures += 1
