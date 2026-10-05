extends SceneTree
## Vérifie le monde en marche : apparition, galeries entretenues, livre visé,
## lecture, et traversée d'un vestibule vers la galerie voisine.
## godot --headless --path . -s tests/test_world.gd

const GalleryScript := preload("res://scripts/gallery.gd")
const BookTextScript := preload("res://scripts/book_text.gd")
const QuestScript := preload("res://scripts/quest.gd")
const BookSpineScript := preload("res://scripts/book_spine.gd")
const AmbientSpeakerScript := preload("res://scripts/ambient_speaker.gd")
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
	await _test_same_gallery(main)

	_check(await AmbientSpeakerScript.silence_all(self), "sortie : les haut-parleurs se taisent, le serveur audio rend leurs lectures")
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
	player.position = Vector3(0.0, 0.05, 3.2)   # au milieu de la nouvelle galerie : aucun pas pendant l'attente
	var t_wait := Time.get_ticks_msec()
	while main.hud.address_pending() and Time.get_ticks_msec() - t_wait < 20000:
		await process_frame
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


## Une galerie a le même aspect quel que soit le chemin qui y mène : atteinte à pied (pas de
## vestibule et de niveau) ou d'un saut (place_origin), ses livres ont la même graine (hauteurs,
## cuirs) et les mêmes titres — de part et d'autre de 2^62, à 917 000 chiffres, et à travers une
## retenue sur toute la coordonnée.
func _test_same_gallery(main: Node3D) -> void:
	var far: Dictionary = QuestScript.load_catalogue()[0].address
	var limit := BookTextScript.b25_from_int(1 << 62)
	var carry := "1" + "o".repeat(655998)       # +1 : « 2000… », retenue sur 655 998 chiffres
	var routes := [
		["2^62", BookTextScript.b25_add_small(limit, -2), BookTextScript.b25_add_small("-" + limit, 2), Vector2i(4, -3)],
		["917 000 chiffres", far.hexagon, far.level, Vector2i(3, 2)],
		["retenue", carry, BookTextScript.b25_neg(carry), Vector2i(1, -1)],
	]
	for route: Array in routes:
		var label: String = route[0]
		var moves: Vector2i = route[3]
		main.place_origin(route[1], route[2])
		var worst := 0
		for _i in absi(moves.x):
			var t := Time.get_ticks_usec()
			main._shift(signi(moves.x))
			worst = maxi(worst, Time.get_ticks_usec() - t)
		for _i in absi(moves.y):
			var t := Time.get_ticks_usec()
			main._shift_level(signi(moves.y))
			worst = maxi(worst, Time.get_ticks_usec() - t)
		_check(worst <= SHIFT_BUDGET_USEC, "%s : chaque pas en moins de %.0f ms (pire : %.2f ms)" % [label, SHIFT_BUDGET_USEC / 1000.0, worst / 1000.0])
		var walked := _looks(main)
		var h := BookTextScript.b25_add_small(route[1], moves.x)
		var l := BookTextScript.b25_add_small(route[2], moves.y)
		_check(main.origin_hexagon_b25 == h and main.origin_level_b25 == l, "%s : la marche arrive à la galerie visée" % label)
		main.place_origin(h, l)
		var jumped := _looks(main)
		var same := 0
		for cell: Vector2i in walked:
			if walked[cell] == jumped.get(cell):
				same += 1
		_check(same == walked.size() and walked.size() == 7,
			"%s : %d galeries sur %d identiques à pied et d'un saut (clé, graine du nuanceur, hauteurs, cuirs, titres)" % [label, same, walked.size()])
		var origin: Gallery = main._galleries[Vector2i.ZERO]
		origin.load_titles_now()
		var bytes := origin.titles_texture().get_image().get_data()
		var book: Dictionary = main.target_address({"hexagon": origin.hexagon, "level": origin.level, "wall": 2, "shelf": 1, "book": 9})
		_check(BookSpineScript.display_title(BookSpineScript.decode_title(bytes, (2 * 5 + 1) * 32 + 9)) == BookTextScript.title_at(book),
			"%s : le titre du dos est celui du lecteur (BookText.title_at de la vraie adresse)" % label)
	await _test_empty_region(main)
	main.place_origin(0, 0)


## Au-delà de la région habitée, les emplacements sont vides : le service rend null pour leur genre.
## Les galeries s'y construisent et reçoivent leurs titres sans erreur (null : pas de livre d'images).
func _test_empty_region(main: Node3D) -> void:
	var hexagon := "1" + "o".repeat(656000)
	var level := "-1" + "0".repeat(656000)
	_check(main.place_origin(hexagon, level), "l'origine se place hors de la région habitée")
	var flags := BookTextScript.gallery_image_books(hexagon, level)
	_check(flags.size() == 640 and flags.all(func(f: Variant) -> bool: return f == null), "le service y rend 640 emplacements vides (null)")
	var t0 := Time.get_ticks_msec()
	var ready := false
	while Time.get_ticks_msec() - t0 < 60000 and not ready:
		await process_frame
		ready = GalleryScript.titles_idle() and main._galleries.values().all(func(g: Gallery) -> bool:
			return g.detail < GalleryScript.Detail.LIT or g.titles_ready())
	var origin: Gallery = main._galleries[Vector2i.ZERO]
	var bytes := origin.titles_texture().get_image().get_data() if origin.titles_ready() else PackedByteArray()
	var flagged := 0
	for i in 640:
		flagged += int(BookSpineScript.decode_image_flag(bytes, i))
	_check(ready and bytes.size() == 640 * 12 and flagged == 0 and GalleryScript.flags_pending().is_empty(),
		"hors de la région habitée : titres posés sans erreur, aucun filet de livre d'images, aucun genre à redemander")


## Aspect des galeries proches de l'origine : case → [clé, graine du nuanceur, hauteurs, cuirs, titres].
func _looks(main: Node3D) -> Dictionary:
	var looks := {}
	for cell: Vector2i in [Vector2i.ZERO, Vector2i(1, 0), Vector2i(-1, 0), Vector2i(2, 0), Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, 1)]:
		var gallery: Gallery = main._galleries[cell]
		var material: ShaderMaterial = gallery.get_node("Books").material_override
		var seed: int = gallery.book_seed()
		var colors := []
		for i in 640:
			colors.append(GalleryScript.book_color(seed, i))
		var titles := []
		for book in 640:
			titles.append(BookSpineScript.title(gallery.place.key, book / 160, (book / 32) % 5, book % 32))
		looks[cell] = [gallery.place.key, material.get_shader_parameter("seed"), gallery.book_heights(), colors, titles]
	return looks


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
