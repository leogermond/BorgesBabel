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

const LEATHER: Array[Color] = [
	Color(0.42, 0.12, 0.08), Color(0.30, 0.18, 0.10), Color(0.16, 0.24, 0.14),
	Color(0.48, 0.34, 0.16), Color(0.20, 0.14, 0.22), Color(0.12, 0.16, 0.26),
	Color(0.55, 0.45, 0.30),
]

static var _materials: Dictionary = {}
static var _book_mesh: BoxMesh

var hexagon: int
var level: int
var _book_heights := PackedFloat32Array()


static func create(p_hexagon: int, p_level: int) -> Gallery:
	var gallery := Gallery.new()
	gallery.hexagon = p_hexagon
	gallery.level = p_level
	gallery.name = "Gallery_%d_%d" % [p_hexagon, p_level]
	return gallery


func _ready() -> void:
	var plaster := _begin()
	var wood := _begin()
	var floor_st := _begin()
	var structure := StaticBody3D.new()
	structure.name = "Structure"
	add_child(structure)

	_build_floor_and_ceiling(floor_st, plaster, structure)
	_build_walls(plaster, structure)
	_build_hallway(floor_st, plaster, structure)
	_build_railing(plaster, structure)
	for wall in WALLS:
		_build_bookcase(wall, wood)
	_build_books()
	_build_lamps()

	_finish(plaster, "plaster")
	_finish(wood, "wood")
	_finish(floor_st, "floor")


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
		APOTHEM - CASE_DEPTH + 0.03 + BOOK_DEPTH * 0.5)
	var side := _side_basis(BOOK_SIDES[wall])
	return Transform3D(side * Basis.from_scale(Vector3(BOOK_THICK, height, BOOK_DEPTH)), side * local)


# --- Construction ----------------------------------------------------------

func _build_floor_and_ceiling(floor_st: SurfaceTool, plaster: SurfaceTool, body: StaticBody3D) -> void:
	for k in 6:
		var o0 := _hex_vertex(APOTHEM, k)
		var o1 := _hex_vertex(APOTHEM, k + 1)
		var i0 := _hex_vertex(SHAFT_APOTHEM, k)
		var i1 := _hex_vertex(SHAFT_APOTHEM, k + 1)
		var up := Vector3.UP * HEIGHT
		var down := Vector3.DOWN * SLAB
		_add_quad(floor_st, o0, o1, i1, i0, Vector3.UP)
		_add_quad(floor_st, i0, i1, i1 + down, i0 + down, -_side_basis(k + 1).z)
		_add_quad(plaster, o0 + up, o1 + up, i1 + up, i0 + up, Vector3.DOWN)
	# Le sol plein sous l'anneau : la balustrade tient le bibliothécaire loin du puits.
	_add_shape(body, Transform3D(Basis(), Vector3(0.0, -SLAB * 0.5, 0.0)),
		Vector3(2.0 * SIDE, SLAB, 2.0 * APOTHEM))


func _build_walls(plaster: SurfaceTool, body: StaticBody3D) -> void:
	var z := APOTHEM + WALL_THICK * 0.5
	for side in 6:
		var basis := _side_basis(side)
		if side == 0 or side == 3:
			var length := SIDE * 0.5 - HALL_WIDTH * 0.5 + 0.2
			for dir in [-1.0, 1.0]:
				var x: float = dir * (HALL_WIDTH * 0.5 + length * 0.5)
				_solid(plaster, body, Transform3D(basis, basis * Vector3(x, HEIGHT * 0.5, z)),
					Vector3(length, HEIGHT, WALL_THICK))
		else:
			_solid(plaster, body, Transform3D(basis, basis * Vector3(0.0, HEIGHT * 0.5, z)),
				Vector3(SIDE + 0.4, HEIGHT, WALL_THICK))


func _build_hallway(floor_st: SurfaceTool, plaster: SurfaceTool, body: StaticBody3D) -> void:
	var w := HALL_WIDTH * 0.5
	var z0 := APOTHEM
	var z1 := APOTHEM + HALL_LENGTH
	_add_quad(floor_st, Vector3(-w, 0, z0), Vector3(w, 0, z0), Vector3(w, 0, z1), Vector3(-w, 0, z1), Vector3.UP)
	_add_quad(plaster, Vector3(-w, HEIGHT, z0), Vector3(w, HEIGHT, z0), Vector3(w, HEIGHT, z1),
		Vector3(-w, HEIGHT, z1), Vector3.DOWN)
	var zc := APOTHEM + HALL_LENGTH * 0.5
	_add_shape(body, Transform3D(Basis(), Vector3(0.0, -SLAB * 0.5, zc)),
		Vector3(HALL_WIDTH + 2.0 * WALL_THICK, SLAB, HALL_LENGTH))
	for dir in [-1.0, 1.0]:
		var x: float = dir * (w + WALL_THICK * 0.5)
		_solid(plaster, body, Transform3D(Basis(), Vector3(x, HEIGHT * 0.5, zc)),
			Vector3(WALL_THICK, HEIGHT, HALL_LENGTH))


func _build_railing(plaster: SurfaceTool, body: StaticBody3D) -> void:
	var length := 2.0 * RAIL_APOTHEM / SQRT3
	for side in 6:
		var basis := _side_basis(side)
		_solid(plaster, body, Transform3D(basis, basis * Vector3(0.0, RAIL_HEIGHT * 0.5, RAIL_APOTHEM)),
			Vector3(length + 0.05, RAIL_HEIGHT, 0.08))


func _build_bookcase(wall: int, wood: SurfaceTool) -> void:
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

	# Un seul collisionneur par mur : le livre visé se déduit du point d'impact.
	var bookcase := StaticBody3D.new()
	bookcase.name = "Bookcase%d" % wall
	bookcase.basis = basis
	bookcase.set_meta("book_wall", wall)
	add_child(bookcase)
	_add_shape(bookcase, Transform3D(Basis(), Vector3(0.0, CASE_TOP * 0.5, zc)),
		Vector3(SHELF_WIDTH + 0.08, CASE_TOP, CASE_DEPTH))


func _build_books() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([hexagon, level])
	var count := WALLS * SHELVES * BOOKS_PER_SHELF
	_book_heights.resize(count)
	var colors := PackedColorArray()
	colors.resize(count)
	for i in count:
		_book_heights[i] = rng.randf_range(0.28, 0.36)
		colors[i] = LEATHER[rng.randi() % LEATHER.size()].darkened(rng.randf_range(0.0, 0.35))

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.mesh = _shared_book_mesh()
	multimesh.instance_count = count
	for wall in WALLS:
		for shelf in SHELVES:
			for book in BOOKS_PER_SHELF:
				var i := (wall * SHELVES + shelf) * BOOKS_PER_SHELF + book
				multimesh.set_instance_transform(i, book_transform(wall, shelf, book))
				multimesh.set_instance_color(i, colors[i])
	var instance := MultiMeshInstance3D.new()
	instance.name = "Books"
	instance.multimesh = multimesh
	add_child(instance)


func _build_lamps() -> void:
	# « La luz procede de unas frutas esféricas que llevan el nombre de lámparas.
	# Hay dos en cada hexágono: transversales. »
	for dir in [-1.0, 1.0]:
		var at := Vector3(dir * 3.2, HEIGHT - 0.45, 0.0)
		var globe := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 0.14
		sphere.height = 0.28
		globe.mesh = sphere
		globe.material_override = _material("lamp")
		globe.position = at
		globe.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(globe)

		var cord := MeshInstance3D.new()
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = 0.008
		cylinder.bottom_radius = 0.008
		cylinder.height = 0.32
		cord.mesh = cylinder
		cord.material_override = _material("wood")
		cord.position = at + Vector3.UP * 0.29
		add_child(cord)

		var light := OmniLight3D.new()
		light.position = at + Vector3.DOWN * 0.2
		light.light_color = Color(1.0, 0.78, 0.5)
		light.light_energy = 1.6
		light.omni_range = 8.0
		add_child(light)


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


func _finish(st: SurfaceTool, material: String) -> void:
	var instance := MeshInstance3D.new()
	instance.name = material.capitalize()
	instance.mesh = st.commit()
	instance.material_override = _material(material)
	add_child(instance)


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


## Boîte visible et solide à la fois.
static func _solid(st: SurfaceTool, body: StaticBody3D, xform: Transform3D, size: Vector3) -> void:
	_add_box(st, xform, size)
	_add_shape(body, xform, size)


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
	_materials[kind] = material
	return material


static func _shared_book_mesh() -> BoxMesh:
	if _book_mesh == null:
		_book_mesh = BoxMesh.new()
		_book_mesh.size = Vector3.ONE
		_book_mesh.material = _material("book")
	return _book_mesh
