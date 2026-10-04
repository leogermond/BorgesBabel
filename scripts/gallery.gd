class_name Gallery
extends Node3D
## Une galerie hexagonale de la Bibliothèque, construite à partir de son adresse.
##
## Repère local : le sol est à y = 0, le centre du puits d'aération à l'origine.
## Les six côtés ont pour normales sortantes les directions à i × 60° de +Z.
## Les côtés 0 (+Z) et 3 (−Z) s'ouvrent sur le vestibule qui mène aux galeries
## voisines ; la galerie porte le vestibule de son côté +Z. Les côtés 1, 2, 4, 5
## portent les étagères : ce sont les murs de livres 0 à 3.
## Chaque mur porte 5 étagères (0 en haut) de 32 livres (0 à gauche face au mur).
##
## Trois degrés de détail, selon la distance au bibliothécaire :
## - FULL : tout, avec les collisionneurs (galerie où il marche, et ses voisines) ;
## - LIT : livres un à un et vraies lampes, sans collisionneur ;
## - DISTANT : un seul maillage partagé, lumière des lampes cuite dans les sommets,
##   façades de livres peintes, globes lumineux ; aucune lumière, aucun collisionneur.
## Les maillages des murs, des étagères et des lampes sont communs à toutes les
## galeries : seuls les livres dépendent de l'adresse.

enum Detail { DISTANT, LIT, FULL }

const SQRT3 := 1.7320508075688772

const APOTHEM := 5.0                         # centre → face intérieure d'un mur
const SIDE := 2.0 * APOTHEM / SQRT3          # longueur d'un côté
const HEIGHT := 3.0                          # hauteur sous plafond
const SLAB := 0.4                            # épaisseur du plancher entre deux niveaux
const LEVEL_PITCH := HEIGHT + SLAB           # écart vertical entre deux niveaux
const WALL_THICK := 0.3
const HALL_LENGTH := 2.0
const HALL_WIDTH := 1.6
const PITCH := 2.0 * APOTHEM + HALL_LENGTH   # écart entre deux galeries voisines (axe Z)
const SHAFT_APOTHEM := 1.6
const RAIL_APOTHEM := 1.7
const RAIL_HEIGHT := 0.85        # « barandas bajísimas »
const RING_APOTHEM := 3.0        # bord extérieur de l'anneau de plancher vu par le puits

const WALLS := 4
const SHELVES := 5
const BOOKS_PER_SHELF := 32
const BOOK_SIDES: Array[int] = [1, 2, 4, 5]
const SHELF_WIDTH := 4.8
const BOOK_SLOT := SHELF_WIDTH / BOOKS_PER_SHELF
const CASE_DEPTH := 0.3
const BOARD_BASE := 0.12                     # dessus de la planche la plus basse
const BOARD_PITCH := 0.42
const BOARD_THICK := 0.03
const CASE_TOP := BOARD_BASE + SHELVES * BOARD_PITCH
const BOOK_THICK := 0.13
const BOOK_DEPTH := 0.22
const BOOK_FRONT := APOTHEM - CASE_DEPTH + 0.03   # dos des livres, côté salle

# La lumière de la Bibliothèque : deux lampes par galerie, et la pénombre ambiante.
const LAMP_X := 3.2
const LAMP_GLOBE_Y := HEIGHT - 0.45
const LAMP_LIGHT_Y := LAMP_GLOBE_Y - 0.2
const LAMP_COLOR := Color(1.0, 0.78, 0.5)
const LAMP_ENERGY := 1.6
const LAMP_RANGE := 8.0
const AMBIENT_COLOR := Color(0.55, 0.42, 0.3)
const AMBIENT_ENERGY := 0.35
# Les couleurs de sommet tiennent sur 8 bits (0 à 1) : la lumière cuite y entre
# divisée par 2, et les matériaux lointains rendent ce facteur à l'albédo.
const BAKE_SCALE := 0.5

const LEATHER: Array[Color] = [
	Color(0.42, 0.12, 0.08), Color(0.30, 0.18, 0.10), Color(0.16, 0.24, 0.14),
	Color(0.48, 0.34, 0.16), Color(0.20, 0.14, 0.22), Color(0.12, 0.16, 0.26),
	Color(0.55, 0.45, 0.30),
]

static var _materials: Dictionary = {}
static var _book_mesh: BoxMesh
static var _book_buffer := PackedFloat32Array()
static var _interior_mesh: ArrayMesh     # murs, étagères, lampes : éclairés par les vraies lampes
static var _distant_mesh: ArrayMesh      # la même galerie, lumière cuite, façades de livres peintes
static var _ring_mesh: ArrayMesh         # l'anneau du puits d'un niveau lointain
static var _structure_boxes: Array = []  # [Transform3D, Vector3] : collisionneurs des murs et du sol

var hexagon: int
var level: int
var detail: Detail = Detail.DISTANT
var _book_heights := PackedFloat32Array()


static func create(p_hexagon: int, p_level: int, p_detail: Detail = Detail.FULL) -> Gallery:
	var gallery := Gallery.new()
	gallery.hexagon = p_hexagon
	gallery.level = p_level
	gallery.name = _node_name(p_hexagon, p_level)
	gallery.set_detail(p_detail)
	return gallery


## Donne à la galerie une nouvelle adresse et un degré de détail : ses livres se
## refont pour la nouvelle adresse, les maillages partagés restent.
func readdress(p_hexagon: int, p_level: int, p_detail: Detail) -> void:
	if p_hexagon != hexagon or p_level != level:
		hexagon = p_hexagon
		level = p_level
		name = _node_name(p_hexagon, p_level)
		_book_heights = PackedFloat32Array()
		_keep("Books", false, Callable())
	set_detail(p_detail)


## Ajoute ou retire les éléments pour atteindre le degré de détail demandé.
func set_detail(p_detail: Detail) -> void:
	detail = p_detail
	_keep("Distant", detail == Detail.DISTANT, _new_distant)
	_keep("Interior", detail >= Detail.LIT, _new_interior)
	_keep("Books", detail >= Detail.LIT, _new_books)
	_keep("Lights", detail >= Detail.LIT, _new_lights)
	_keep("Structure", detail == Detail.FULL, _new_structure)
	for wall in WALLS:
		_keep("Bookcase%d" % wall, detail == Detail.FULL, _new_bookcase.bind(wall))


## Le livre sous le point `world_pos` de la façade d'une bibliothèque, ou {} entre deux étagères.
func locate_book(bookcase: StaticBody3D, world_pos: Vector3) -> Dictionary:
	var local := bookcase.to_local(world_pos)
	var slot := floori((SHELF_WIDTH * 0.5 - local.x) / BOOK_SLOT)
	var board := floori((local.y - BOARD_BASE) / BOARD_PITCH)
	if slot < 0 or slot >= BOOKS_PER_SHELF or board < 0 or board >= SHELVES:
		return {}
	return {
		"gallery": self, "hexagon": hexagon, "level": level,
		"wall": int(bookcase.get_meta("book_wall")), "shelf": SHELVES - 1 - board, "book": slot,
	}


## Position, orientation et dimensions d'un livre, dans le repère de la galerie.
func book_transform(wall: int, shelf: int, book: int) -> Transform3D:
	var height := _book_heights[(wall * SHELVES + shelf) * BOOKS_PER_SHELF + book]
	var board := SHELVES - 1 - shelf
	var local := Vector3(
		SHELF_WIDTH * 0.5 - (book + 0.5) * BOOK_SLOT,
		BOARD_BASE + board * BOARD_PITCH + height * 0.5,
		BOOK_FRONT + BOOK_DEPTH * 0.5)
	var side := _side_basis(BOOK_SIDES[wall])
	return Transform3D(side * Basis.from_scale(Vector3(BOOK_THICK, height, BOOK_DEPTH)), side * local)


## Maillage partagé de l'anneau du puits d'un niveau : plancher autour du trou, bord
## du trou, plafond du dessous, balustrade et lampes, lumière cuite dans les sommets.
static func ring_mesh() -> ArrayMesh:
	if _ring_mesh == null:
		var plaster := _begin()
		var floor_st := _begin()
		_build_floor_and_ceiling(floor_st, plaster, RING_APOTHEM)
		_build_railing(plaster, [])
		_ring_mesh = ArrayMesh.new()
		_add_surface(_ring_mesh, _baked(plaster.commit_to_arrays()), "plaster_far")
		_add_surface(_ring_mesh, _baked(floor_st.commit_to_arrays()), "floor_far")
		_add_lamp_surfaces(_ring_mesh, true)
	return _ring_mesh


# --- Éléments d'une galerie ------------------------------------------------

## Garde l'enfant `child` présent ou absent ; `factory` le fabrique au besoin.
func _keep(child: String, wanted: bool, factory: Callable) -> void:
	var node := get_node_or_null(child)
	if wanted and node == null:
		node = factory.call()
		node.name = child
		add_child(node)
	elif not wanted and node != null:
		remove_child(node)
		node.queue_free()


func _new_distant() -> Node:
	_ensure_shared()
	var instance := MeshInstance3D.new()
	instance.mesh = _distant_mesh
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return instance


func _new_interior() -> Node:
	_ensure_shared()
	var instance := MeshInstance3D.new()
	instance.mesh = _interior_mesh
	return instance


func _new_structure() -> Node:
	_ensure_shared()
	var body := StaticBody3D.new()
	for box in _structure_boxes:
		_add_shape(body, box[0], box[1])
	return body


## Un seul collisionneur par mur : le livre visé se déduit du point d'impact.
func _new_bookcase(wall: int) -> Node:
	var bookcase := StaticBody3D.new()
	bookcase.basis = _side_basis(BOOK_SIDES[wall])
	bookcase.set_meta("book_wall", wall)
	_add_shape(bookcase, Transform3D(Basis(), Vector3(0.0, CASE_TOP * 0.5, APOTHEM - CASE_DEPTH * 0.5)),
		Vector3(SHELF_WIDTH + 0.08, CASE_TOP, CASE_DEPTH))
	return bookcase


func _new_books() -> Node:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([hexagon, level])
	var count := WALLS * SHELVES * BOOKS_PER_SHELF
	_book_heights.resize(count)
	# Tampon du MultiMesh, rempli d'un bloc : seules la hauteur, l'altitude et la
	# couleur de chaque livre changent d'une galerie à l'autre (voir _book_template).
	var buffer := _book_template().duplicate()
	for i in count:
		var height := rng.randf_range(0.28, 0.36)
		var color := LEATHER[rng.randi() % LEATHER.size()].darkened(rng.randf_range(0.0, 0.35))
		_book_heights[i] = height
		var o := i * 16
		buffer[o + 5] = height
		buffer[o + 7] += height * 0.5
		buffer[o + 12] = color.r
		buffer[o + 13] = color.g
		buffer[o + 14] = color.b

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.mesh = _shared_book_mesh()
	multimesh.instance_count = count
	multimesh.buffer = buffer
	var instance := MultiMeshInstance3D.new()
	instance.multimesh = multimesh
	return instance


## Tampon des livres d'une galerie, hauteur et couleur mises à part : par livre,
## 12 flottants de transformation (3 lignes de 4) puis 4 de couleur. Les murs
## tournent autour de Y, donc la hauteur d'un livre n'occupe que l'élément 5 (échelle
## en Y) et s'ajoute pour moitié à l'élément 7 (altitude du centre).
static func _book_template() -> PackedFloat32Array:
	if not _book_buffer.is_empty():
		return _book_buffer
	_book_buffer.resize(WALLS * SHELVES * BOOKS_PER_SHELF * 16)
	for wall in WALLS:
		var side := _side_basis(BOOK_SIDES[wall])
		var b := side * Basis.from_scale(Vector3(BOOK_THICK, 0.0, BOOK_DEPTH))
		for shelf in SHELVES:
			for book in BOOKS_PER_SHELF:
				var origin := side * Vector3(
					SHELF_WIDTH * 0.5 - (book + 0.5) * BOOK_SLOT,
					BOARD_BASE + (SHELVES - 1 - shelf) * BOARD_PITCH,
					BOOK_FRONT + BOOK_DEPTH * 0.5)
				var o := ((wall * SHELVES + shelf) * BOOKS_PER_SHELF + book) * 16
				var row := [b.x.x, b.y.x, b.z.x, origin.x, b.x.y, b.y.y, b.z.y, origin.y,
					b.x.z, b.y.z, b.z.z, origin.z, 0.0, 0.0, 0.0, 1.0]
				for k in 16:
					_book_buffer[o + k] = row[k]
	return _book_buffer


## « La luz procede de unas frutas esféricas que llevan el nombre de lámparas.
## Hay dos en cada hexágono: transversales. »
func _new_lights() -> Node:
	var lights := Node3D.new()
	for dir in [-1.0, 1.0]:
		var light := OmniLight3D.new()
		light.position = Vector3(dir * LAMP_X, LAMP_LIGHT_Y, 0.0)
		light.light_color = LAMP_COLOR
		light.light_energy = LAMP_ENERGY
		light.omni_range = LAMP_RANGE
		lights.add_child(light)
	return lights


static func _node_name(p_hexagon: int, p_level: int) -> String:
	return "Gallery_%d_%d" % [p_hexagon, p_level]


# --- Maillages partagés ----------------------------------------------------

static func _ensure_shared() -> void:
	if _interior_mesh != null:
		return
	var plaster := _begin()
	var wood := _begin()
	var floor_st := _begin()
	_structure_boxes = []
	_build_floor_and_ceiling(floor_st, plaster, APOTHEM)
	# Le sol plein sous l'anneau : la balustrade tient le bibliothécaire loin du puits.
	_structure_boxes.append([Transform3D(Basis(), Vector3(0.0, -SLAB * 0.5, 0.0)),
		Vector3(2.0 * SIDE, SLAB, 2.0 * APOTHEM)])
	_build_walls(plaster, _structure_boxes)
	_build_hallway(floor_st, plaster, _structure_boxes)
	_build_railing(plaster, _structure_boxes)
	for wall in WALLS:
		_build_bookcase(wall, wood)
	var arrays := {
		"plaster": plaster.commit_to_arrays(),
		"wood": wood.commit_to_arrays(),
		"floor": floor_st.commit_to_arrays(),
	}

	_interior_mesh = ArrayMesh.new()
	for kind in arrays:
		_add_surface(_interior_mesh, arrays[kind], kind)
	_add_lamp_surfaces(_interior_mesh, false)

	_distant_mesh = ArrayMesh.new()
	for kind in arrays:
		_add_surface(_distant_mesh, _baked(arrays[kind]), kind + "_far")
	var faces := _begin()
	for wall in WALLS:
		_build_book_face(wall, faces)
	_add_surface(_distant_mesh, _baked(faces.commit_to_arrays()), "books_far")
	_add_lamp_surfaces(_distant_mesh, true)


static func _add_surface(mesh: ArrayMesh, arrays: Array, material: String) -> void:
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(mesh.get_surface_count() - 1, _material(material))


## Les deux globes (lumineux par eux-mêmes) et leurs cordons.
static func _add_lamp_surfaces(mesh: ArrayMesh, baked: bool) -> void:
	var sphere := SphereMesh.new()
	sphere.radius = 0.14
	sphere.height = 0.28
	sphere.radial_segments = 24
	sphere.rings = 12
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 0.008
	cylinder.bottom_radius = 0.008
	cylinder.height = 0.32
	cylinder.radial_segments = 8
	cylinder.rings = 1
	var globes := _begin()
	var cords := _begin()
	for dir in [-1.0, 1.0]:
		var at := Vector3(dir * LAMP_X, LAMP_GLOBE_Y, 0.0)
		globes.append_from(sphere, 0, Transform3D(Basis(), at))
		cords.append_from(cylinder, 0, Transform3D(Basis(), at + Vector3.UP * 0.29))
	_add_surface(mesh, globes.commit_to_arrays(), "lamp")
	if baked:
		_add_surface(mesh, _baked(cords.commit_to_arrays()), "wood_far")
	else:
		_add_surface(mesh, cords.commit_to_arrays(), "wood")


## Copie des tableaux d'une surface, avec en couleur de sommet la lumière qu'y
## porteraient les lampes de la galerie et celles des niveaux voisins.
static func _baked(arrays: Array) -> Array:
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var colors := PackedColorArray()
	colors.resize(vertices.size())
	for i in vertices.size():
		colors[i] = _lamp_light(vertices[i], normals[i])
	var baked := arrays.duplicate()
	baked[Mesh.ARRAY_COLOR] = colors
	return baked


## Éclairement linéaire en un point, au plus près du calcul de Godot pour une
## OmniLight3D sans ombre (atténuation (1 − (d/portée)⁴)² / d, diffus lambertien).
static func _lamp_light(at: Vector3, normal: Vector3) -> Color:
	var lamp := LAMP_COLOR.srgb_to_linear() * LAMP_ENERGY
	var light := AMBIENT_COLOR.srgb_to_linear() * AMBIENT_ENERGY
	for dy: float in [-LEVEL_PITCH, 0.0, LEVEL_PITCH]:
		for dir: float in [-1.0, 1.0]:
			var to := Vector3(dir * LAMP_X, LAMP_LIGHT_Y + dy, 0.0) - at
			var d := to.length()
			if d >= LAMP_RANGE or d < 0.001:
				continue
			var fade := 1.0 - pow(d / LAMP_RANGE, 4.0)
			var lambert := maxf(normal.dot(to / d), 0.0)
			light += lamp * (fade * fade / d * lambert)
	light *= BAKE_SCALE
	light.a = 1.0
	return light


# --- Construction ----------------------------------------------------------

## Plancher (anneau autour du puits jusqu'à l'apothème `outer`), bord du trou, et
## plafond. L'anneau se découpe en bandes pour que la lumière cuite y ait des sommets.
static func _build_floor_and_ceiling(floor_st: SurfaceTool, plaster: SurfaceTool, outer: float) -> void:
	var bands := 3
	for k in 6:
		for band in bands:
			var a0 := lerpf(SHAFT_APOTHEM, outer, float(band) / bands)
			var a1 := lerpf(SHAFT_APOTHEM, outer, float(band + 1) / bands)
			var o0 := _hex_vertex(a1, k)
			var o1 := _hex_vertex(a1, k + 1)
			var i0 := _hex_vertex(a0, k)
			var i1 := _hex_vertex(a0, k + 1)
			var up := Vector3.UP * HEIGHT
			_add_quad(floor_st, o0, o1, i1, i0, Vector3.UP)
			_add_quad(plaster, o0 + up, o1 + up, i1 + up, i0 + up, Vector3.DOWN)
		var e0 := _hex_vertex(SHAFT_APOTHEM, k)
		var e1 := _hex_vertex(SHAFT_APOTHEM, k + 1)
		var down := Vector3.DOWN * SLAB
		_add_quad(floor_st, e0, e1, e1 + down, e0 + down, -_side_basis(k + 1).z)


static func _build_walls(plaster: SurfaceTool, boxes: Array) -> void:
	var z := APOTHEM + WALL_THICK * 0.5
	for side in 6:
		var basis := _side_basis(side)
		if side == 0 or side == 3:
			var length := SIDE * 0.5 - HALL_WIDTH * 0.5 + 0.2
			for dir in [-1.0, 1.0]:
				var x: float = dir * (HALL_WIDTH * 0.5 + length * 0.5)
				_solid(plaster, boxes, Transform3D(basis, basis * Vector3(x, HEIGHT * 0.5, z)),
					Vector3(length, HEIGHT, WALL_THICK))
		else:
			_solid(plaster, boxes, Transform3D(basis, basis * Vector3(0.0, HEIGHT * 0.5, z)),
				Vector3(SIDE + 0.4, HEIGHT, WALL_THICK))


static func _build_hallway(floor_st: SurfaceTool, plaster: SurfaceTool, boxes: Array) -> void:
	var w := HALL_WIDTH * 0.5
	var z0 := APOTHEM
	var z1 := APOTHEM + HALL_LENGTH
	_add_quad(floor_st, Vector3(-w, 0, z0), Vector3(w, 0, z0), Vector3(w, 0, z1), Vector3(-w, 0, z1), Vector3.UP)
	_add_quad(plaster, Vector3(-w, HEIGHT, z0), Vector3(w, HEIGHT, z0), Vector3(w, HEIGHT, z1),
		Vector3(-w, HEIGHT, z1), Vector3.DOWN)
	var zc := APOTHEM + HALL_LENGTH * 0.5
	boxes.append([Transform3D(Basis(), Vector3(0.0, -SLAB * 0.5, zc)),
		Vector3(HALL_WIDTH + 2.0 * WALL_THICK, SLAB, HALL_LENGTH)])
	for dir in [-1.0, 1.0]:
		var x: float = dir * (w + WALL_THICK * 0.5)
		_solid(plaster, boxes, Transform3D(Basis(), Vector3(x, HEIGHT * 0.5, zc)),
			Vector3(WALL_THICK, HEIGHT, HALL_LENGTH))


static func _build_railing(plaster: SurfaceTool, boxes: Array) -> void:
	var length := 2.0 * RAIL_APOTHEM / SQRT3
	for side in 6:
		var basis := _side_basis(side)
		_solid(plaster, boxes, Transform3D(basis, basis * Vector3(0.0, RAIL_HEIGHT * 0.5, RAIL_APOTHEM)),
			Vector3(length + 0.05, RAIL_HEIGHT, 0.08))


static func _build_bookcase(wall: int, wood: SurfaceTool) -> void:
	var basis := _side_basis(BOOK_SIDES[wall])
	var zc := APOTHEM - CASE_DEPTH * 0.5
	var boxes: Array = [
		[Vector3(0.0, BOARD_BASE * 0.5, zc), Vector3(SHELF_WIDTH, BOARD_BASE, CASE_DEPTH)],
		[Vector3(0.0, CASE_TOP * 0.5, APOTHEM - 0.01), Vector3(SHELF_WIDTH, CASE_TOP, 0.02)],
	]
	for board in SHELVES + 1:
		var top := BOARD_BASE + board * BOARD_PITCH
		boxes.append([Vector3(0.0, top - BOARD_THICK * 0.5, zc), Vector3(SHELF_WIDTH, BOARD_THICK, CASE_DEPTH)])
	for dir in [-1.0, 1.0]:
		boxes.append([Vector3(dir * (SHELF_WIDTH * 0.5 + 0.02), CASE_TOP * 0.5, zc), Vector3(0.04, CASE_TOP, CASE_DEPTH)])
	for box in boxes:
		_add_box(wood, Transform3D(basis, basis * box[0]), box[1])


## Façade peinte d'un mur de livres, au ras des dos, découpée en grille pour la lumière cuite.
static func _build_book_face(wall: int, st: SurfaceTool) -> void:
	var basis := _side_basis(BOOK_SIDES[wall])
	var normal := basis * Vector3.FORWARD   # vers le centre de la galerie
	var columns := 4
	var rows := SHELVES
	for col in columns:
		for row in rows:
			var u0 := float(col) / columns
			var u1 := float(col + 1) / columns
			var v0 := float(row) / rows
			var v1 := float(row + 1) / rows
			var corner := func(u: float, v: float) -> Vector3:
				return basis * Vector3(SHELF_WIDTH * (0.5 - u), lerpf(CASE_TOP, BOARD_BASE, v), BOOK_FRONT)
			_add_tri_uv(st, [corner.call(u0, v0), corner.call(u1, v0), corner.call(u1, v1)],
				[Vector2(u0, v0), Vector2(u1, v0), Vector2(u1, v1)], normal)
			_add_tri_uv(st, [corner.call(u0, v0), corner.call(u1, v1), corner.call(u0, v1)],
				[Vector2(u0, v0), Vector2(u1, v1), Vector2(u0, v1)], normal)


# --- Géométrie -------------------------------------------------------------

## Repère d'un côté : son +Z local est la normale sortante du côté.
static func _side_basis(side: int) -> Basis:
	return Basis(Vector3.UP, side * PI / 3.0)


## Sommet k de l'hexagone d'apothème donné (entre les côtés k et k + 1), au sol.
static func _hex_vertex(apothem: float, k: int) -> Vector3:
	var angle := deg_to_rad(30.0 + 60.0 * k)
	var radius := 2.0 * apothem / SQRT3
	return Vector3(radius * sin(angle), 0.0, radius * cos(angle))


static func _begin() -> SurfaceTool:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	return st


## Triangle tourné vers `normal` (Godot dessine les faces avant dans le sens horaire).
static func _add_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, normal: Vector3) -> void:
	st.set_normal(normal)
	st.add_vertex(a)
	if (b - a).cross(c - a).dot(normal) > 0.0:
		st.add_vertex(c)
		st.add_vertex(b)
	else:
		st.add_vertex(b)
		st.add_vertex(c)


## Triangle texturé tourné vers `normal` : chaque sommet garde sa coordonnée de texture.
static func _add_tri_uv(st: SurfaceTool, corners: Array, uvs: Array, normal: Vector3) -> void:
	var order := [0, 1, 2]
	var a: Vector3 = corners[0]
	var b: Vector3 = corners[1]
	var c: Vector3 = corners[2]
	if (b - a).cross(c - a).dot(normal) > 0.0:
		order = [0, 2, 1]
	for i in order:
		st.set_normal(normal)
		st.set_uv(uvs[i])
		st.add_vertex(corners[i])


static func _add_quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, normal: Vector3) -> void:
	_add_tri(st, a, b, c, normal)
	_add_tri(st, a, c, d, normal)


static func _add_box(st: SurfaceTool, xform: Transform3D, size: Vector3) -> void:
	var half := size * 0.5
	for axis in 3:
		var u_axis := (axis + 1) % 3
		var v_axis := (axis + 2) % 3
		for dir in [-1.0, 1.0]:
			var normal := Vector3.ZERO
			normal[axis] = dir
			var center := normal * half[axis]
			var du := Vector3.ZERO
			du[u_axis] = half[u_axis]
			var dv := Vector3.ZERO
			dv[v_axis] = half[v_axis]
			_add_quad(st, xform * (center - du - dv), xform * (center + du - dv),
				xform * (center + du + dv), xform * (center - du + dv), (xform.basis * normal).normalized())


static func _add_shape(body: StaticBody3D, xform: Transform3D, size: Vector3) -> void:
	var box := BoxShape3D.new()
	box.size = size
	var shape := CollisionShape3D.new()
	shape.shape = box
	shape.transform = xform
	body.add_child(shape)


## Boîte visible, dont le collisionneur rejoint la liste `boxes`.
static func _solid(st: SurfaceTool, boxes: Array, xform: Transform3D, size: Vector3) -> void:
	_add_box(st, xform, size)
	boxes.append([xform, size])


# --- Matériaux partagés ----------------------------------------------------

static func _material(kind: String) -> StandardMaterial3D:
	if _materials.has(kind):
		return _materials[kind]
	var material := StandardMaterial3D.new()
	match kind:
		"plaster":
			material.albedo_color = Color(0.72, 0.64, 0.50)
			material.roughness = 0.95
		"wood":
			material.albedo_color = Color(0.30, 0.19, 0.11)
			material.roughness = 0.7
		"floor":
			material.albedo_color = Color(0.36, 0.30, 0.24)
			material.roughness = 0.85
		"book":
			material.vertex_color_use_as_albedo = true
			material.roughness = 0.8
		"lamp":
			material.albedo_color = Color(1.0, 0.85, 0.6)
			material.emission_enabled = true
			material.emission = Color(1.0, 0.8, 0.5)
			material.emission_energy_multiplier = 3.0
		"plaster_far", "wood_far", "floor_far":
			# Même teinte que de près ; la couleur de sommet porte la lumière cuite.
			material.albedo_color = _unbaked(_material(kind.trim_suffix("_far")).albedo_color)
			material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			material.vertex_color_use_as_albedo = true
		"books_far":
			material.albedo_texture = _book_face_texture()
			material.albedo_color = _unbaked(Color.WHITE)
			material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			material.vertex_color_use_as_albedo = true
	_materials[kind] = material
	return material


## Albédo multiplié par 1 / BAKE_SCALE en lumière linéaire, réexprimé en sRGB.
static func _unbaked(albedo: Color) -> Color:
	var linear := albedo.srgb_to_linear() / BAKE_SCALE
	linear.a = 1.0
	return linear.linear_to_srgb()


static func _shared_book_mesh() -> BoxMesh:
	if _book_mesh == null:
		_book_mesh = BoxMesh.new()
		_book_mesh.size = Vector3.ONE
		_book_mesh.material = _material("book")
	return _book_mesh


## Dos de livres peints : 5 rangées de 32 livres de cuir, chacun de sa hauteur,
## sur le fond sombre de la bibliothèque. Sert de façade aux galeries lointaines.
static func _book_face_texture() -> ImageTexture:
	var slot_px := 8
	var row_px := 32
	var image := Image.create(BOOKS_PER_SHELF * slot_px, SHELVES * row_px, false, Image.FORMAT_RGB8)
	image.fill(_material("wood").albedo_color.darkened(0.6))
	var rng := RandomNumberGenerator.new()
	rng.seed = 1941   # « La biblioteca de Babel », 1941
	for row in SHELVES:
		for book in BOOKS_PER_SHELF:
			var height := int(row_px * rng.randf_range(0.28, 0.36) / BOARD_PITCH)
			var color := LEATHER[rng.randi() % LEATHER.size()].darkened(rng.randf_range(0.0, 0.35))
			var bottom := (row + 1) * row_px - 2
			image.fill_rect(Rect2i(book * slot_px, bottom - height, slot_px - 1, height), color)
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)
