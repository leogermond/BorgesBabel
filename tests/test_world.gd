extends SceneTree
## Vérifie le monde en marche : apparition, galeries entretenues, livre visé,
## lecture, et traversée d'un vestibule vers la galerie voisine.
## godot --headless --path . -s tests/test_world.gd

const GalleryScript := preload("res://scripts/gallery.gd")
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
	_check(main.origin_hexagon == start + 1, "la galerie voisine devient l'origine (Δ = %d)" % (main.origin_hexagon - start))
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

	print("test_world : %s" % ("OK" if _failures == 0 else "%d échec(s)" % _failures))
	quit(1 if _failures else 0)


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
