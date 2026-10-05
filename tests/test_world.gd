extends SceneTree
## Vérifie le monde en marche : apparition, galeries entretenues, livre visé,
## lecture, et traversée d'un vestibule vers la galerie voisine.
## godot --headless --path . -s tests/test_world.gd

const GalleryScript := preload("res://scripts/gallery.gd")
const BookTextScript := preload("res://scripts/book_text.gd")
const QuestScript := preload("res://scripts/quest.gd")
const BookSpineScript := preload("res://scripts/book_spine.gd")
const AmbientSpeakerScript := preload("res://scripts/ambient_speaker.gd")
const HudScript := preload("res://scripts/hud.gd")
const MainScript := preload("res://scripts/main.gd")
const CarnetScript := preload("res://scripts/carnet.gd")
## Dossier des fichiers du joueur pendant le test (jamais ceux du jeu) ; et celui de la sortie.
const USER_TEST_DIR := "user://essai_test_world"
const USER_EXIT_DIR := "user://essai_test_world_sortie"
## Une aide de commande à l'écran nommerait une touche ou un geste.
const HINT_WORDS: Array[String] = ["Échap", "Esc", "Tab", "Suppr", "touche", "clic", "souris", "tourner la page",
	"refermer", "← →", "ZQSD", "WASD", "E :", "²", "carnet", "aleph", "zahir", "tlon", "sator", "golem"]
## Budget d'un pas (vestibule ou niveau), celui de test_depth : moins d'une demi-image à 60 i/s.
const SHIFT_BUDGET_USEC := 8000
# 17 galeries sur 3 niveaux le long du vestibule, 6 niveaux du puits en galeries entières,
# et de chaque côté les diagonales vues par les puits voisins (|dz| − 1 ≤ |dy| ≤ |dz| + 1,
# hors des trois rangées) : 2 cases à |dz| = 1, 4 à |dz| = 2, 6 de |dz| = 3 à 8.
const GALLERIES := 17 * 3 + 6 + 2 * (2 + 4 + 6 * 6)

var _failures := 0


func _initialize() -> void:
	QuestScript.user_dir = USER_TEST_DIR
	_clear_dir(USER_TEST_DIR)
	_clear_dir(USER_EXIT_DIR)
	var main: Node3D = load("res://main.tscn").instantiate()
	root.add_child(main)
	await _steps(30)
	_check(main.hud.quest != null and main.hud.quest.entry_id == QuestScript.FIRST_QUEST,
		"premier lancement (dossier du joueur vide) : la quête en cours est « %s »" % (main.hud.quest.title if main.hud.quest != null else "aucune"))

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
	await _test_focus_and_hints(main)
	await _test_invocations(main)
	await _test_overlays_during_travel(main)
	await _test_missing_books(main)
	main = await _test_restart(main)
	await _test_exit_errors()
	_clear_dir(USER_TEST_DIR)

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
		main.player.position = Vector3(0.0, 0.05, 3.2)   # au milieu de la galerie : aucun pas pendant les mesures
		main.player.velocity = Vector3.ZERO
		main.place_origin(route[1], route[2])
		# Le pire cas : le premier pas juste après le saut, sans attendre une image (la retenue préparée
		# sur un fil peut n'être pas finie, les titres de toutes les galeries attendent leur calcul).
		var worst := 0
		for _i in absi(moves.x):
			var t := Time.get_ticks_usec()
			main._shift(signi(moves.x))
			worst = maxi(worst, Time.get_ticks_usec() - t)
		for _i in absi(moves.y):
			var t := Time.get_ticks_usec()
			main._shift_level(signi(moves.y))
			worst = maxi(worst, Time.get_ticks_usec() - t)
		print("  %s : pire pas juste après le saut %.2f ms" % [label, worst / 1000.0])
		_check(worst <= SHIFT_BUDGET_USEC, "%s : chaque pas en moins de %.0f ms, le premier juste après le saut (pire : %.2f ms)" % [label, SHIFT_BUDGET_USEC / 1000.0, worst / 1000.0])
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
	main.player.position = Vector3(0.0, 0.05, 3.2)
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


## Retour du focus (FOCUS_IN) : la souris n'est pas recapturée sous le panneau de quête ni sous le
## carnet ; aucune aide de commande dans les textes du Hud et du lecteur.
func _test_focus_and_hints(main: Node3D) -> void:
	var hud: Hud = main.hud
	main._capture_mouse()   # le bibliothécaire marche, souris capturée
	_check(main._mouse_captured and main.mouse_mode_requested == Input.MOUSE_MODE_CAPTURED, "contrôle : souris capturée en marchant")
	_key(HudScript.QUEST_KEY, true)
	_check(hud.is_panel_open(), "le panneau de quête s'ouvre")
	main.mouse_mode_requested = -1
	main.notification(NOTIFICATION_APPLICATION_FOCUS_IN)
	_check(main.mouse_mode_requested == -1, "retour du focus, panneau ouvert : la souris n'est pas recapturée")
	var texts := _all_texts(hud) + _all_texts(main.reader, main.reader._text)
	_key(KEY_ESCAPE, true)
	_key(CarnetScript.CARNET_KEY, true)
	_check(hud.carnet.is_open(), "le carnet s'ouvre")
	main.notification(NOTIFICATION_APPLICATION_FOCUS_IN)
	_check(main.mouse_mode_requested == -1, "retour du focus, carnet ouvert : la souris n'est pas recapturée")
	_key(KEY_ESCAPE, true)
	main.notification(NOTIFICATION_APPLICATION_FOCUS_IN)
	_check(main.mouse_mode_requested == Input.MOUSE_MODE_CAPTURED, "contrôle : retour du focus sans fenêtre, la souris est recapturée")
	main.place_origin(0, 0)
	main._open_address({"hexagon": "0", "level": "0", "wall": 1, "shelf": 2, "book": 3})
	texts += _all_texts(hud) + _all_texts(main.reader, main.reader._text)
	main._close_book()
	var hints := texts.filter(func(t: String) -> bool:
		return HINT_WORDS.any(func(word: String) -> bool: return t.contains(word)))
	_check(hints.is_empty() and texts.size() > 20, "aucune aide de commande ni invocation nommée dans le Hud et le lecteur (%d textes, panneau et livre ouverts ; lu : %s)" % [texts.size(), hints])


## Les invocations, tapées dans le carnet du vrai monde (push_input) : « aleph » et « zahir » vers la
## galerie de la quête, « tlon » (un livre emporté au plus), la touche du carnet deux fois pour le
## relire, « sator » face au carré, « golem » effacé tant que sa destination est vide.
func _test_invocations(main: Node3D) -> void:
	var hud: Hud = main.hud
	var player: CharacterBody3D = main.player
	var quest: QuestScript = hud.quest
	main.place_origin(12, -5)
	player.position = Vector3(1.0, 0.05, 2.0)
	player.rotation.y = 0.7
	player.camera.rotation.x = -0.3
	await _steps(3)
	var level: String = main.origin_level_b25
	var place := player.position
	_key(CarnetScript.CARNET_KEY, true)
	_type("aleph ")
	_check(main.traveling() and not hud.carnet.is_open(), "« aleph␠ » : le carnet se ferme, le fondu commence")
	await main.travel_finished
	var aleph_ms: float = main.last_travel_usec / 1000.0
	_check(main.origin_hexagon_b25 == quest.book.hexagon and main.origin_level_b25 == level,
		"« aleph » : l'hexagone du livre de la quête (%d chiffres base 25), le niveau gardé" % quest.book.hexagon.length())
	_check(is_equal_approx(player.rotation.y, 0.7) and is_equal_approx(player.camera.rotation.x, -0.3) and player.position.distance_to(place) < 0.1 and not player.frozen,
		"« aleph » : le bibliothécaire garde sa place, son orientation, et repart")
	_check(hud.guidance().hall == 0 and hud.guidance().vert != 0, "« aleph » : le guidage dit « couloir : ici »")
	_key(CarnetScript.CARNET_KEY, true)
	_type("zahir ")
	await main.travel_finished
	var zahir_ms: float = main.last_travel_usec / 1000.0
	_check(main.origin_hexagon_b25 == quest.book.hexagon and main.origin_level_b25 == quest.book.level and is_equal_approx(player.rotation.y, 0.7),
		"« zahir » : le niveau du livre de la quête, l'hexagone et l'orientation gardés")
	_check(hud.guidance().here, "« zahir » : la galerie de la quête est atteinte")

	# « tlon » sans livre ouvert : effacé.
	_key(CarnetScript.CARNET_KEY, true)
	_type("tlon ")
	_check(hud.carnet.is_open() and main.carried_book.is_empty() and not main.traveling(), "« tlon␠ » sans livre ouvert : effacé, rien n'est emporté")
	_key(KEY_ESCAPE, true)

	# Un livre visé, ouvert par E, emporté par « tlon ».
	player.rotation = Vector3(0.0, PI / 3.0 + PI, 0.0)
	player.camera.rotation.x = -0.2
	player.position = Basis(Vector3.UP, PI / 3.0) * Vector3(0.0, 0.0, 3.4)
	await _steps(3)
	var aimed: Dictionary = main._target_book
	var gallery: Gallery = main._galleries[Vector2i.ZERO]
	_key(KEY_E, true, "e")
	_key(KEY_E, false, "e")
	_check(not aimed.is_empty() and main.reader.visible and main.reader.book == aimed, "E ouvre le livre visé")
	_key(CarnetScript.CARNET_KEY, true)
	_type("tlon")
	var t_steal := Time.get_ticks_usec()
	_type(" ")
	var steal_ms := (Time.get_ticks_usec() - t_steal) / 1000.0
	var saving: bool = main._save_task >= 0
	var first_index := _index(aimed)
	_check(main.carried_book == aimed and main.reader.visible, "« tlon␠ », carnet ouvert sur le lecteur : le livre lu est emporté")
	_check(main._carried_key == BookTextScript.gallery_key(aimed.hexagon, aimed.level),
		"la clé de la galerie du livre emporté, prise à la galerie visée, est celle de ses vraies coordonnées")
	print("  « tlon » à ~917 000 chiffres : %.1f ms sur le fil principal (écriture du livre sur un fil du moteur)" % steal_ms)
	_check(saving and steal_ms < 20.0, "« tlon » : le livre emporté s'écrit sur un fil du moteur (%.1f ms sur le fil principal)" % steal_ms)
	main.flush_carried_save()
	_check(QuestScript.load_carried(main.carried_path) == aimed and not FileAccess.file_exists(main.carried_path + ".partiel"),
		"le livre emporté est enregistré (%s), sans fichier partiel" % main.carried_path.get_file())
	_check(gallery.missing_books() == PackedInt32Array([first_index]) and _missing_flags(gallery) == [first_index],
		"un vide sur l'étagère : le livre emporté est marqué absent dans la texture de sa galerie (rang %d)" % first_index)
	_check(_locate(gallery, aimed).is_empty() and not _locate(gallery, aimed.merged({"book": (aimed.book + 1) % 32}, true)).is_empty(),
		"le vide ne se vise pas ; son voisin, si")
	_key(KEY_ESCAPE, true)
	await _steps(2)
	_check(not main.reader.visible and main._target_book.is_empty(), "le livre refermé, le rayon ne trouve rien à sa place")

	# Un second livre emporté : le premier retourne à sa place.
	var second: Dictionary = aimed.merged({"book": (aimed.book + 1) % 32}, true)
	main._open_address(second)
	_key(CarnetScript.CARNET_KEY, true)
	_type("tlon ")
	_check(main.carried_book == second and gallery.missing_books() == PackedInt32Array([_index(second)]) and _missing_flags(gallery) == [_index(second)]
			and not _locate(gallery, aimed).is_empty(),
		"un second livre emporté : le premier retourne à sa place (un seul vide, celui du second)")
	_key(KEY_ESCAPE, true)

	# La touche du carnet, deux fois : le livre emporté s'ouvre.
	_key(CarnetScript.CARNET_KEY, true)
	_check(hud.carnet.is_open() and not main.reader.visible, "la touche du carnet ouvre le carnet")
	_key(CarnetScript.CARNET_KEY, true)
	_check(not hud.carnet.is_open() and main.reader.visible and main.reader.book == second and player.frozen,
		"la même touche, carnet ouvert : le livre emporté s'ouvre dans le lecteur")
	# Relu, « tlon » le rend à sa place (RETURN_CARRIED_ON_TLON).
	_key(CarnetScript.CARNET_KEY, true)
	_type("tlon ")
	main.flush_carried_save()
	if MainScript.RETURN_CARRIED_ON_TLON:
		_check(main.carried_book.is_empty() and gallery.missing_books().is_empty() and _missing_flags(gallery).is_empty()
				and QuestScript.load_carried(main.carried_path).is_empty(),
			"« tlon␠ » sur le livre emporté relu : il retourne à sa place, le vide se comble")
	_key(KEY_ESCAPE, true)
	_key(CarnetScript.CARNET_KEY, true)
	_key(CarnetScript.CARNET_KEY, true)
	_check(not main.reader.visible and not hud.carnet.is_open(), "sans livre emporté, la touche du carnet deux fois n'ouvre rien")
	main._open_address(second)
	_key(CarnetScript.CARNET_KEY, true)
	_type("tlon ")
	_key(KEY_ESCAPE, true)
	_check(main.carried_book == second, "le second livre de nouveau emporté (pour la relance)")

	# « golem » : sa destination est vide, le mot s'efface.
	_key(CarnetScript.CARNET_KEY, true)
	_type("golem ")
	_check(hud.carnet.is_open() and hud.carnet.word.is_empty() and not main.traveling(), "« golem␠ » : destination vide, effacé comme un autre mot")
	_key(KEY_ESCAPE, true)

	# « sator » : la galerie du carré, face à son mur, le livre ouvert à sa page.
	var sator := QuestScript.destination("sator")
	_key(CarnetScript.CARNET_KEY, true)
	_type("sator ")
	await main.travel_finished
	var sator_ms: float = main.last_travel_usec / 1000.0
	await _steps(2)
	var dest: Dictionary = sator.address
	var book := BookTextScript.book_of(dest)
	_check(main.origin_hexagon_b25 == dest.hexagon and main.origin_level_b25 == dest.level, "« sator » : la galerie du livre du carré (hexagone et niveau)")
	var target: Dictionary = player.target
	_check(not target.is_empty() and target.wall == dest.wall and target.shelf == dest.shelf and target.book == dest.book,
		"« sator » : le bibliothécaire fait face au mur, le regard sur le livre (%s)" % [_brief(target)])
	_check(main.reader.visible and main.reader.book == book and main.reader.page == int(dest.page)
			and main.reader._text.text.replace("\n", "").sha256_text() == sator.sha256,
		"« sator » : le lecteur montre la page du carré (condensat du catalogue)")
	main._close_book()
	print("  invocations à ~917 000 chiffres (fil principal, au noir) : aleph %.1f ms, zahir %.1f ms, sator %.1f ms (livre ouvert compris)" % [aleph_ms, zahir_ms, sator_ms])
	_check(aleph_ms < 1000.0 and zahir_ms < 1000.0 and sator_ms < 2000.0, "coût d'une invocation mesuré, caché par le fondu")


## Fenêtres ouvertes pendant le fondu d'un saut : le bibliothécaire est immobile exactement tant
## qu'un saut, le lecteur, le panneau ou le carnet le retient, dans tous les ordres de fermeture ;
## deux invocations tapées à la suite s'enchaînent (la seconde part de la galerie d'arrivée).
func _test_overlays_during_travel(main: Node3D) -> void:
	var hud: Hud = main.hud
	var player: CharacterBody3D = main.player
	var quest: QuestScript = hud.quest
	main.place_origin(12, -5)
	await _steps(2)
	_check(not player.frozen and player.holds().is_empty(), "au départ, rien ne retient le bibliothécaire")

	# « aleph » puis « zahir » à la suite ; Tab pendant le fondu, panneau refermé après les sauts.
	_key(CarnetScript.CARNET_KEY, true)
	_type("aleph ")
	_key(CarnetScript.CARNET_KEY, true)
	_type("zahir ")
	var during: bool = player.frozen and main.traveling() and not hud.carnet.is_open()
	_key(HudScript.QUEST_KEY, true)
	_check(during and hud.is_panel_open() and player.holds().size() == 2, "pendant le fondu : saut et panneau retiennent le bibliothécaire (%s)" % [player.holds()])
	await _until_landed(main)
	_check(main.origin_hexagon_b25 == quest.book.hexagon and main.origin_level_b25 == quest.book.level,
		"« aleph » puis « zahir » tapés à la suite : les deux sauts s'enchaînent jusqu'à la galerie de la quête")
	_check(player.frozen and player.holds() == ["panneau"], "sauts finis, panneau ouvert : toujours immobile (%s)" % [player.holds()])
	_key(KEY_ESCAPE, true)
	_check(not player.frozen, "panneau refermé : le bibliothécaire repart")

	# Carnet ouvert pendant le fondu, refermé avant la fin du saut.
	main.place_origin(12, -5)
	_key(CarnetScript.CARNET_KEY, true)
	_type("aleph ")
	_key(CarnetScript.CARNET_KEY, true)
	_check(hud.carnet.is_open() and player.holds().size() == 2, "carnet ouvert pendant le fondu (%s)" % [player.holds()])
	_key(KEY_ESCAPE, true)
	_check(player.frozen and main.traveling(), "carnet refermé pendant le saut : immobile jusqu'à la fin du saut")
	await _until_landed(main)
	_check(not player.frozen and player.holds().is_empty(), "saut fini, carnet refermé avant : le bibliothécaire repart")

	# Carnet ouvert pendant le fondu, refermé après la fin du saut.
	main.place_origin(12, -5)
	_key(CarnetScript.CARNET_KEY, true)
	_type("aleph ")
	_key(CarnetScript.CARNET_KEY, true)
	await _until_landed(main)
	_check(player.frozen and hud.carnet.is_open() and player.holds() == ["carnet"], "saut fini, carnet encore ouvert : immobile (%s)" % [player.holds()])
	_key(KEY_ESCAPE, true)
	_check(not player.frozen, "carnet refermé après le saut : le bibliothécaire repart")

	# Panneau ouvert pendant le fondu, refermé avant la fin ; puis « sator » : le lecteur retient.
	main.place_origin(12, -5)
	_key(CarnetScript.CARNET_KEY, true)
	_type("aleph ")
	_key(HudScript.QUEST_KEY, true)
	_key(KEY_ESCAPE, true)
	_check(player.frozen and not hud.is_panel_open() and player.holds() == ["saut"], "panneau ouvert et refermé pendant le fondu : le saut seul retient")
	await _until_landed(main)
	_check(not player.frozen, "saut fini : le bibliothécaire repart")
	_key(CarnetScript.CARNET_KEY, true)
	_type("sator ")
	_key(CarnetScript.CARNET_KEY, true)
	await _until_landed(main)
	_check(main.reader.visible and hud.carnet.is_open() and player.holds().size() == 2, "« sator » avec le carnet ouvert pendant le fondu : lecteur et carnet retiennent (%s)" % [player.holds()])
	_key(KEY_ESCAPE, true)
	_check(player.frozen and main.reader.visible, "carnet refermé : le lecteur retient encore")
	_key(KEY_ESCAPE, true)
	_check(not player.frozen and player.holds().is_empty() and not main.reader.visible, "lecteur refermé : le bibliothécaire repart")

	# « aleph », « zahir », « sator » tapés pendant un fondu, puis Suppr (quête effacée) : « zahir »
	# ne vaut plus et s'oublie, « sator » part aussitôt ; un « sator » tapé ensuite atterrit une fois.
	var landings := [0]
	var count := func() -> void: landings[0] += 1
	main.travel_finished.connect(count)
	main.place_origin(12, -5)
	for word: String in ["aleph ", "zahir ", "sator "]:
		_key(CarnetScript.CARNET_KEY, true)
		_type(word)
	_check(main.traveling() and main._queued == ["puits", "sator"], "pendant le fondu : « zahir » et « sator » en file (%s)" % [main._queued])
	_key(HudScript.CLEAR_KEY, true)
	_check(hud.quest == null, "Suppr pendant le fondu efface la quête")
	await _until_landed(main)
	var sator := QuestScript.destination("sator")
	_check(landings[0] == 2 and main.origin_hexagon_b25 == sator.address.hexagon and main.reader.visible,
		"« zahir » sans quête s'oublie, « sator » part ensuite : deux atterrissages (lu : %d)" % landings[0])
	_key(KEY_ESCAPE, true)
	landings[0] = 0
	_key(CarnetScript.CARNET_KEY, true)
	_type("sator ")
	await _until_landed(main)
	await _steps(30)   # le temps d'un second saut, s'il y en avait un
	_check(landings[0] == 1 and not main.traveling() and main._queued.is_empty(), "un « sator » tapé : un seul atterrissage (lu : %d)" % landings[0])
	main.travel_finished.disconnect(count)
	main._close_book()
	hud.start_quest(QuestScript.from_entry(QuestScript.catalogue_entry(hud.catalogue, QuestScript.FIRST_QUEST)))
	main.place_origin(0, 0)


## Attend la fin des sauts en cours et en attente.
## Sans saut en cours, la file doit être vide : sinon elle est bloquée (échec aussitôt, sans attente).
func _until_landed(main: Node3D) -> void:
	var t0 := Time.get_ticks_msec()
	while main.traveling() and Time.get_ticks_msec() - t0 < 5000:
		await process_frame
	_check(not main.traveling() and main._queued.is_empty(),
		"les sauts finissent, la file des invocations est vide (en cours : %s, en file : %s)" % [main.traveling(), main._queued])


## Les livres volés du catalogue : un vide sur leur étagère (texture des galeries LIT et FULL,
## façades peintes au loin), rien à viser.
func _test_missing_books(main: Node3D) -> void:
	var stolen: Dictionary = QuestScript.stolen_books()[0]
	main.place_origin(stolen.hexagon, stolen.level)
	var gallery: Gallery = main._galleries[Vector2i.ZERO]
	var index := _index(stolen)
	_check(gallery.missing_books() == PackedInt32Array([index]) and _missing_flags(gallery) == [index],
		"livre volé du catalogue : marqué absent dans la texture de sa galerie, et lui seul")
	_check(_locate(gallery, stolen).is_empty(), "livre volé du catalogue : rien à viser à sa place")
	gallery.load_titles_now()
	_check(gallery.titles_ready() and _missing_flags(gallery) == [index], "titres arrivés : le livre volé reste absent")
	var neighbour: Gallery = main._galleries[Vector2i(1, 0)]
	_check(neighbour.missing_books().is_empty() and _missing_flags(neighbour).is_empty(), "la galerie voisine n'a pas de vide")
	main.place_origin(BookTextScript.b25_add_small(stolen.hexagon, -6), stolen.level)
	var far: Gallery = main._galleries[Vector2i(6, 0)]
	var faces: ShaderMaterial = far.get_node("Faces").material_override
	_check(far.detail == GalleryScript.Detail.DISTANT and faces.get_shader_parameter("missing") == Vector4i(index, -1, -1, -1),
		"au loin (galerie peinte) : le livre volé manque aussi à la façade")
	var other: ShaderMaterial = main._galleries[Vector2i(5, 0)].get_node("Faces").material_override
	var none: Variant = other.get_shader_parameter("missing")   # null : jamais posé, l'uniforme garde ivec4(-1)
	_check(none == null or none == Vector4i(-1, -1, -1, -1), "une autre façade peinte n'a pas de vide (%s)" % [none])
	main.place_origin(BookTextScript.b25_add_small(stolen.hexagon, -12), stolen.level)
	# Toutes les galeries resservent après un saut : celle qui portait le vide a une autre adresse.
	_check(is_instance_valid(far) and not far.is_queued_for_deletion() and far.missing_books().is_empty()
			and faces.get_shader_parameter("missing") == Vector4i(-1, -1, -1, -1),
		"la galerie peinte qui portait le vide, readressée ailleurs, n'en a plus")
	main.place_origin(0, 0)


## Relance du jeu sur les mêmes fichiers : le livre emporté et son vide, la quête en cours ; puis
## la quête effacée (Suppr) le reste à la relance suivante, et « aleph » s'efface sans quête.
func _test_restart(main: Node3D) -> Node3D:
	var carried: Dictionary = main.carried_book
	var path: String = main.carried_path
	main.queue_free()
	await process_frame
	# Une écriture abandonnée (jeu tué pendant l'écriture du livre emporté) : ignorée et retirée.
	var partial := FileAccess.open(path + QuestScript.PARTIAL_SUFFIX, FileAccess.WRITE)
	partial.store_string("BCAT tronqué")
	partial.close()
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await _steps(5)
	_check(not FileAccess.file_exists(path + QuestScript.PARTIAL_SUFFIX) and main.carried_book == carried,
		"relance : l'écriture abandonnée (.partiel) est retirée, le livre emporté relu intact")
	_check(main.carried_book == carried and main.hud.quest != null and main.hud.quest.entry_id == QuestScript.FIRST_QUEST,
		"relance : le livre emporté et la quête en cours sont gardés")
	main.place_origin(carried.hexagon, carried.level)
	var gallery: Gallery = main._galleries[Vector2i.ZERO]
	_check(gallery.missing_books() == PackedInt32Array([_index(carried)]) and _locate(gallery, carried).is_empty(),
		"relance : le vide du livre emporté est toujours sur son étagère")
	_key(HudScript.CLEAR_KEY, true)
	_check(main.hud.quest == null, "Suppr efface la quête")
	_key(CarnetScript.CARNET_KEY, true)
	_type("aleph ")
	_check(main.hud.carnet.is_open() and not main.traveling(), "sans quête, « aleph␠ » s'efface")
	_key(KEY_ESCAPE, true)
	main.queue_free()
	await process_frame
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await _steps(5)
	_check(main.hud.quest == null and not main.hud._widget.visible, "relance : la quête effacée le reste")
	return main


## Une sortie normale du jeu (fenêtre fermée) après le lancement des services : aucune ligne
## « ERROR » dans le journal (processus déjà arrêtés interrogés, lectures audio, ressources).
func _test_exit_errors() -> void:
	var output := []
	var started := Time.get_ticks_msec()
	var code := OS.execute(OS.get_executable_path(), ["--headless", "--path", ProjectSettings.globalize_path("res://"),
		"-s", "res://tests/exit_scene.gd", "--", QuestScript.USER_DIR_ARG + USER_EXIT_DIR], output, true)
	var lines := Array("".join(output).split("\n"))
	var errors := lines.filter(func(line: String) -> bool: return line.contains("ERROR"))
	for line: String in errors:
		print("    " + line)
	_check(code == 0 and errors.is_empty() and lines.any(func(line: String) -> bool: return line.contains("sortie : services lancés")),
		"sortie normale du jeu (%.1f s) : code %d, %d ligne(s) ERROR" % [(Time.get_ticks_msec() - started) / 1000.0, code, errors.size()])
	_clear_dir(USER_EXIT_DIR)


## Les rangs des livres marqués absents dans la texture des livres de la galerie.
static func _missing_flags(gallery: Gallery) -> Array:
	var texture := gallery.titles_texture()
	var bytes := texture.get_image().get_data() if texture != null else PackedByteArray()
	var flagged := []
	for i in 640:
		if BookSpineScript.decode_missing_flag(bytes, i):
			flagged.append(i)
	return flagged


## Le livre trouvé par la galerie au point de la façade devant `book` (sa place), ou {}.
static func _locate(gallery: Gallery, book: Dictionary) -> Dictionary:
	var bookcase: StaticBody3D = gallery.get_node("Bookcase%d" % book.wall)
	var local := bookcase.basis.inverse() * gallery.book_transform(book.wall, book.shelf, book.book).origin
	local.z = GalleryScript.APOTHEM - GalleryScript.CASE_DEPTH
	return gallery.locate_book(bookcase, bookcase.global_transform * local)


static func _index(book: Dictionary) -> int:
	return (int(book.wall) * GalleryScript.SHELVES + int(book.shelf)) * GalleryScript.BOOKS_PER_SHELF + int(book.book)


## Tous les textes (étiquettes, boutons) d'un sous-arbre, visibles ou non, sauf `skip` (le texte
## d'une page).
static func _all_texts(node: Node, skip: Node = null) -> Array:
	var texts := []
	for child in node.find_children("*", "", true, false):
		if (child is Label or child is Button) and child != skip:
			texts.append(child.text)
	return texts


## Une touche par la fenêtre (push_input : _input, interface, _unhandled_input).
func _key(code: int, pressed: bool, unicode := "") -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code as Key
	event.keycode = code as Key
	event.unicode = unicode.unicode_at(0) if not unicode.is_empty() else 0
	event.pressed = pressed
	root.push_input(event)


## Tape un texte, touche après touche (lettres et espace).
func _type(text: String) -> void:
	for c in text:
		var code := KEY_SPACE if c == " " else (c.to_upper().unicode_at(0) as Key)
		_key(code, true, c)
		_key(code, false, c)


static func _clear_dir(path: String) -> void:
	var dir := ProjectSettings.globalize_path(path)
	if not DirAccess.dir_exists_absolute(dir):
		return
	for file in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(file))
	DirAccess.remove_absolute(dir)


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
