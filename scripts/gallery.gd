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
## - DISTANT : façades de livres peintes, globes lumineux ; ni lampe réelle ni collisionneur.
## Les maillages des murs, des étagères, des lampes et des livres sont communs à toutes
## les galeries : seule la graine des livres (tirée de l'adresse) change d'une galerie à
## l'autre, et le nuanceur en tire la hauteur et le cuir de chaque livre.
##
## La lumière : chaque lampe de la Bibliothèque éclaire par deux voies dont la somme
## reste constante. Une vraie OmniLight3D porte la part `real_weight(d)` de son énergie,
## d étant la distance de la lampe à l'œil ; le nuanceur commun à toutes les surfaces
## ajoute, pixel par pixel, la part 1 − real_weight(d) de chacune des lampes du réseau
## (deux par galerie, à chaque niveau), par la formule même de Godot pour une
## OmniLight3D sans ombre. Une galerie lointaine reçoit donc exactement la lumière
## d'une galerie proche ; une vraie lampe naît et meurt à poids nul.

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
const BOOKCASES: Array[String] = ["Bookcase0", "Bookcase1", "Bookcase2", "Bookcase3"]
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
const BOOK_MIN_HEIGHT := 0.28
const BOOK_MAX_HEIGHT := 0.36
const BOOK_MAX_DARKEN := 0.35                # cuir assombri de 0 à 35 %

# La lumière de la Bibliothèque : deux lampes par galerie, et la pénombre ambiante.
const LAMP_X := 3.2
const LAMP_GLOBE_Y := HEIGHT - 0.45
const LAMP_LIGHT_Y := LAMP_GLOBE_Y - 0.2
const LAMP_COLOR := Color(1.0, 0.78, 0.5)
const LAMP_ENERGY := 1.6
const LAMP_RANGE := 8.0
const AMBIENT_COLOR := Color(0.55, 0.42, 0.3)
const AMBIENT_ENERGY := 0.35
# Part réelle d'une lampe : entière jusqu'à REAL_LIGHT_NEAR de l'œil, nulle au-delà de
# REAL_LIGHT_FAR. Toute lampe à moins de REAL_LIGHT_FAR d'un œil placé n'importe où
# dans la galerie d'origine appartient à une galerie éclairée (la plus proche qui ne
# l'est pas est à 7,4 m) : les vraies lampes ne naissent et ne meurent qu'éteintes.
const REAL_LIGHT_NEAR := 3.0
const REAL_LIGHT_FAR := 7.0

# La brume : exponentielle, puis fondue au noir de brume entre FAR_FADE_BEGIN et
# FAR_FADE_END. Les galeries et les anneaux naissent et disparaissent à plus de 95 m
# de l'œil : là, la brume a tout recouvert, et rien ne change à l'image.
const FOG_COLOR := Color(0.05, 0.035, 0.022)
const FOG_DENSITY := 0.04      # reste de lumière : 38 % à 24 m, 15 % à 48 m, 6 % à 70 m
const FAR_FADE_BEGIN := 70.0
const FAR_FADE_END := 90.0

const LEATHER: Array[Color] = [
	Color(0.42, 0.12, 0.08), Color(0.30, 0.18, 0.10), Color(0.16, 0.24, 0.14),
	Color(0.48, 0.34, 0.16), Color(0.20, 0.14, 0.22), Color(0.12, 0.16, 0.26),
	Color(0.55, 0.45, 0.30),
]

## Nuanceur de toutes les surfaces de la Bibliothèque. Variantes : SURFACE (albédo
## uni), BOOKS (MultiMesh des livres : hauteur et cuir tirés de la graine et du
## numéro de l'instance), FACES (façade peinte des livres lointains : les mêmes livres,
## tirés de la même façon, dessinés à plat). Les constantes {…} viennent de ce script.
const LIBRARY_SHADER := """
shader_type spatial;
render_mode diffuse_lambert, specular_disabled;

#define {VARIANT}

const float PITCH = {PITCH};
const float LEVEL_PITCH = {LEVEL_PITCH};
const float LAMP_X = {LAMP_X};
const float LAMP_Y = {LAMP_Y};
const float LAMP_RANGE = {LAMP_RANGE};
const vec3 LAMP_LIGHT = {LAMP_LIGHT};   // couleur linéaire × énergie d'une lampe
const float REAL_NEAR = {REAL_NEAR};
const float REAL_FAR = {REAL_FAR};
const vec3 FOG_LINEAR = {FOG_LINEAR};
const float FOG_DENSITY = {FOG_DENSITY};
const float FAR_FADE_BEGIN = {FAR_FADE_BEGIN};
const float FAR_FADE_END = {FAR_FADE_END};

uniform vec3 albedo_linear = vec3(1.0);
uniform vec3 emission_linear = vec3(0.0);
uniform int seed = 0;

#if defined(BOOKS) || defined(FACES)
const int SHELVES = {SHELVES};
const int BOOKS_PER_SHELF = {BOOKS_PER_SHELF};
const float BOARD_BASE = {BOARD_BASE};
const float BOARD_PITCH = {BOARD_PITCH};
const float CASE_TOP = {CASE_TOP};
const float BOOK_SLOT = {BOOK_SLOT};
const float BOOK_THICK = {BOOK_THICK};
const float BOOK_MIN_HEIGHT = {BOOK_MIN_HEIGHT};
const float BOOK_MAX_HEIGHT = {BOOK_MAX_HEIGHT};
const float BOOK_MAX_DARKEN = {BOOK_MAX_DARKEN};
const vec3 WOOD_LINEAR = {WOOD_LINEAR};
const vec3 LEATHER[7] = vec3[7]({LEATHER});

// Hachage entier « lowbias32 » ; Gallery.lowbias32 en est le jumeau.
uint lowbias32(uint x) {
	x ^= x >> 16u;
	x *= 0x7feb352du;
	x ^= x >> 15u;
	x *= 0x846ca68bu;
	x ^= x >> 16u;
	return x;
}

uint book_hash(int book, uint draw) {
	return lowbias32(uint(seed) ^ lowbias32(uint(book) * 4u + draw));
}

float unit_float(uint h) {
	return float(h >> 8u) * (1.0 / 16777216.0);
}

float book_height(int book) {
	return BOOK_MIN_HEIGHT + (BOOK_MAX_HEIGHT - BOOK_MIN_HEIGHT) * unit_float(book_hash(book, 0u));
}

// Le cuir est pris tel quel comme albédo linéaire, comme les couleurs d'instance d'avant.
vec3 book_color(int book) {
	return LEATHER[book_hash(book, 1u) % 7u] * (1.0 - BOOK_MAX_DARKEN * unit_float(book_hash(book, 2u)));
}
#endif

#ifdef BOOKS
varying flat vec3 book_albedo;
#endif

#ifdef FACES
// UV.x = 2 × mur + u (u de 0 à 1 le long de l'étagère), UV.y de 0 (haut) à 1 (bas).
vec3 painted(vec2 uv) {
	float wall = floor(uv.x * 0.5);
	float slot = (uv.x - 2.0 * wall) * float(BOOKS_PER_SHELF);
	int book = clamp(int(floor(slot)), 0, BOOKS_PER_SHELF - 1);
	float y = mix(CASE_TOP, BOARD_BASE, uv.y);
	int board = clamp(int(floor((y - BOARD_BASE) / BOARD_PITCH)), 0, SHELVES - 1);
	int index = (int(wall) * SHELVES + SHELVES - 1 - board) * BOOKS_PER_SHELF + book;
	float across = abs(fract(slot) - 0.5) * BOOK_SLOT;
	float above = y - BOARD_BASE - float(board) * BOARD_PITCH;
	return (across < BOOK_THICK * 0.5 && above < book_height(index)) ? book_color(index) : WOOD_LINEAR;
}
#endif

void vertex() {
#ifdef BOOKS
	// Boîte unité ; l'instance la pose sur sa planche, sa hauteur vient de la graine.
	VERTEX.y = (VERTEX.y + 0.5) * book_height(INSTANCE_ID);
	book_albedo = book_color(INSTANCE_ID);
#endif
}

float real_weight(float d) {
	return 1.0 - smoothstep(REAL_NEAR, REAL_FAR, d);
}

// Part des lampes du réseau que les vraies OmniLight3D ne portent pas : Σ (1 − poids
// réel) × (1 − (d/portée)⁴)² / d × max(N·L, 0). Les lampes à moins de LAMP_RANGE du
// point sont au plus à une galerie et à trois niveaux de lui.
float virtual_light(vec3 p, vec3 n, vec3 eye) {
	float n0 = round(p.z / PITCH);
	float k0 = floor((p.y - LAMP_Y) / LEVEL_PITCH);
	float sum = 0.0;
	for (int iz = -1; iz <= 1; iz++) {
		float z = (n0 + float(iz)) * PITCH;
		for (int iy = -2; iy <= 3; iy++) {
			float y = LAMP_Y + (k0 + float(iy)) * LEVEL_PITCH;
			for (int side = 0; side < 2; side++) {
				vec3 lamp = vec3(side == 0 ? -LAMP_X : LAMP_X, y, z);
				vec3 to = lamp - p;
				float d = length(to);
				if (d < LAMP_RANGE && d > 0.0001) {
					float nd = d / LAMP_RANGE;
					nd = 1.0 - nd * nd * nd * nd;
					sum += nd * nd / d * max(dot(n, to) / d, 0.0) * (1.0 - real_weight(distance(lamp, eye)));
				}
			}
		}
	}
	return sum;
}

// Le rendu Compatibilité tient ALBEDO et EMISSION pour du sRGB et les linéarise ensuite.
vec3 encoded(vec3 c) {
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	return mix(1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, c * 12.92, lessThan(c, vec3(0.0031308)));
#else
	return c;
#endif
}

void fragment() {
	vec3 albedo = albedo_linear;
#ifdef BOOKS
	albedo = book_albedo;
#endif
#ifdef FACES
	albedo = painted(UV);
#endif
	vec3 world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 normal = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	ALBEDO = encoded(albedo);
	// Lumière des lampes en partie virtuelles : ajoutée comme l'est la lumière diffuse.
	EMISSION = encoded(albedo * LAMP_LIGHT * virtual_light(world, normal, CAMERA_POSITION_WORLD) + emission_linear);
	float d = length(VERTEX);
	FOG = vec4(FOG_LINEAR, 1.0 - exp(-FOG_DENSITY * d) * (1.0 - smoothstep(FAR_FADE_BEGIN, FAR_FADE_END, d)));
}
"""

static var _shaders: Dictionary = {}     # variante → Shader
static var _materials: Dictionary = {}
static var _book_mesh: BoxMesh
static var _book_multimesh: MultiMesh    # les 640 places de livres, hauteur unité
static var _book_buffer := PackedFloat32Array()
static var _interior_mesh: ArrayMesh     # murs, étagères, sol, plafond, lampes
static var _faces_mesh: ArrayMesh        # façades des quatre murs de livres, à plat
static var _ring_mesh: ArrayMesh         # l'anneau du puits d'un niveau lointain
static var _structure_boxes: Array = []  # [Transform3D, Vector3] : collisionneurs des murs et du sol
static var _pool: Dictionary = {}        # nom d'enfant → enfants détachés, prêts à resservir

var hexagon: int
var level: int
var detail: Detail = Detail.DISTANT
var _book_heights := PackedFloat32Array()   # calculées à la demande (book_heights)
var _book_material: ShaderMaterial          # livres un à un : graine de l'adresse
var _face_material: ShaderMaterial          # façades peintes : même graine
var _parts: Dictionary = {}                 # nom → enfant présent (voir _keep)


static func create(p_hexagon: int, p_level: int, p_detail: Detail = Detail.FULL) -> Gallery:
	var gallery := Gallery.new()
	gallery.hexagon = p_hexagon
	gallery.level = p_level
	gallery.name = _node_name(p_hexagon, p_level)
	gallery.set_detail(p_detail)
	return gallery


## Donne à la galerie une nouvelle adresse et un degré de détail : seule la graine
## des livres change, les maillages partagés restent.
func readdress(p_hexagon: int, p_level: int, p_detail: Detail) -> void:
	if p_hexagon != hexagon or p_level != level:
		hexagon = p_hexagon
		level = p_level
		name = _node_name(p_hexagon, p_level)
		_book_heights = PackedFloat32Array()
		var shader_seed := _signed32(book_seed())
		if _book_material != null:
			_book_material.set_shader_parameter("seed", shader_seed)
		if _face_material != null:
			_face_material.set_shader_parameter("seed", shader_seed)
	set_detail(p_detail)


## Ajoute ou retire les éléments pour atteindre le degré de détail demandé.
func set_detail(p_detail: Detail) -> void:
	detail = p_detail
	_keep("Interior", true, _new_interior)
	_keep("Faces", detail == Detail.DISTANT, _new_faces)
	_keep("Books", detail >= Detail.LIT, _new_books)
	_keep("Lights", detail >= Detail.LIT, _new_lights)
	var full := detail == Detail.FULL
	if _parts.has("Structure") != full:
		_keep("Structure", full, _new_structure)
		for wall in WALLS:
			_keep(BOOKCASES[wall], full, _new_bookcase.bind(wall))


## Règle la part réelle de chaque lampe de la galerie pour un œil en `eye` (repère du monde).
func update_lights(eye: Vector3) -> void:
	var lights: Node = _parts.get("Lights")
	if lights == null:
		return
	for light: OmniLight3D in lights.get_children():
		var weight := real_weight((position + light.position).distance_to(eye))
		light.light_energy = LAMP_ENERGY * weight
		light.visible = weight > 0.0


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
	var height := book_heights()[(wall * SHELVES + shelf) * BOOKS_PER_SHELF + book]
	var board := SHELVES - 1 - shelf
	var local := Vector3(
		SHELF_WIDTH * 0.5 - (book + 0.5) * BOOK_SLOT,
		BOARD_BASE + board * BOARD_PITCH + height * 0.5,
		BOOK_FRONT + BOOK_DEPTH * 0.5)
	var side := _side_basis(BOOK_SIDES[wall])
	return Transform3D(side * Basis.from_scale(Vector3(BOOK_THICK, height, BOOK_DEPTH)), side * local)


## Hauteur de chaque livre (numéro (mur × 5 + étagère) × 32 + livre), tirée comme le
## fait le nuanceur des livres et des façades.
func book_heights() -> PackedFloat32Array:
	if _book_heights.is_empty():
		var book_seed_value := book_seed()
		_book_heights.resize(WALLS * SHELVES * BOOKS_PER_SHELF)
		for i in _book_heights.size():
			_book_heights[i] = book_height(book_seed_value, i)
	return _book_heights


## Graine des livres de la galerie, sur 32 bits.
func book_seed() -> int:
	return hash([hexagon, level]) & 0xFFFFFFFF


## Hauteur du livre `book` pour la graine `book_seed_value` (jumeau de book_height du nuanceur).
static func book_height(book_seed_value: int, book: int) -> float:
	return BOOK_MIN_HEIGHT + (BOOK_MAX_HEIGHT - BOOK_MIN_HEIGHT) * _unit_float(_book_hash(book_seed_value, book, 0))


## Cuir du livre `book` (jumeau de book_color du nuanceur), en albédo linéaire.
static func book_color(book_seed_value: int, book: int) -> Color:
	var leather := LEATHER[_book_hash(book_seed_value, book, 1) % LEATHER.size()]
	return leather * (1.0 - BOOK_MAX_DARKEN * _unit_float(_book_hash(book_seed_value, book, 2)))


## Hachage entier « lowbias32 » de Chris Wellons, sur 32 bits.
static func lowbias32(x: int) -> int:
	x &= 0xFFFFFFFF
	x ^= x >> 16
	x = _mul32(x, 0x7feb352d)
	x ^= x >> 15
	x = _mul32(x, 0x846ca68b)
	x ^= x >> 16
	return x


## Part réelle d'une lampe à la distance `d` de l'œil (jumeau de real_weight du nuanceur).
static func real_weight(d: float) -> float:
	return 1.0 - smoothstep(REAL_LIGHT_NEAR, REAL_LIGHT_FAR, d)


## Reste de lumière au-delà de la brume exponentielle : 1 jusqu'à FAR_FADE_BEGIN, 0 après FAR_FADE_END.
static func far_fade(d: float) -> float:
	return 1.0 - smoothstep(FAR_FADE_BEGIN, FAR_FADE_END, d)


## Jumeau de virtual_light du nuanceur, en unités d'énergie de lampe : la lumière que
## le nuanceur ajoute au point `p` de normale `n`, pour un œil en `eye`.
static func virtual_light(p: Vector3, n: Vector3, eye: Vector3) -> float:
	var n0 := roundf(p.z / PITCH)
	var k0 := floorf((p.y - LAMP_LIGHT_Y) / LEVEL_PITCH)
	var sum := 0.0
	for iz in range(-1, 2):
		var z := (n0 + iz) * PITCH
		for iy in range(-2, 4):
			var y := LAMP_LIGHT_Y + (k0 + iy) * LEVEL_PITCH
			for dir: float in [-1.0, 1.0]:
				var lamp := Vector3(dir * LAMP_X, y, z)
				var to := lamp - p
				var d := to.length()
				if d < LAMP_RANGE and d > 0.0001:
					var nd := d / LAMP_RANGE
					nd = 1.0 - nd * nd * nd * nd
					sum += nd * nd / d * maxf(n.dot(to) / d, 0.0) * (1.0 - real_weight(lamp.distance_to(eye)))
	return LAMP_ENERGY * sum


## Maillage partagé de l'anneau du puits d'un niveau : plancher autour du trou, bord
## du trou, plafond du dessous, balustrade et lampes.
static func ring_mesh() -> ArrayMesh:
	if _ring_mesh == null:
		var plaster := _begin()
		var floor_st := _begin()
		_build_floor_and_ceiling(floor_st, plaster, RING_APOTHEM)
		_build_railing(plaster, [])
		_ring_mesh = ArrayMesh.new()
		_add_surface(_ring_mesh, plaster.commit_to_arrays(), "plaster")
		_add_surface(_ring_mesh, floor_st.commit_to_arrays(), "floor")
		_add_lamp_surfaces(_ring_mesh)
	return _ring_mesh


# --- Éléments d'une galerie ------------------------------------------------

## Garde l'enfant `child` présent ou absent. Un enfant retiré attend dans la réserve
## commune à toutes les galeries ; un enfant voulu en sort, ou `factory` le fabrique :
## un pas ne construit ni ne détruit presque rien (collisionneurs compris).
func _keep(child: String, wanted: bool, factory: Callable) -> void:
	var node: Node = _parts.get(child)
	if wanted and node == null:
		var pool: Array = _pool.get(child, [])
		node = pool.pop_back() if not pool.is_empty() else factory.call()
		node.name = child
		_fit(node)
		add_child(node)
		_parts[child] = node
	elif not wanted and node != null:
		remove_child(node)
		_parts.erase(child)
		if child == "Lights":
			for light: OmniLight3D in node.get_children():
				light.light_energy = 0.0
				light.visible = false
		if not _pool.has(child):
			_pool[child] = []
		_pool[child].append(node)


## Donne à un enfant ce qui tient à la galerie : le matériau à sa graine.
func _fit(node: Node) -> void:
	if node is MultiMeshInstance3D:
		if _book_material == null:
			_book_material = _seeded_material("BOOKS")
		node.material_override = _book_material
	elif node.name == "Faces":
		if _face_material == null:
			_face_material = _seeded_material("FACES")
		node.material_override = _face_material


## Libère la réserve d'enfants détachés (à la sortie du monde).
static func release_pool() -> void:
	for pool: Array in _pool.values():
		for node: Node in pool:
			node.free()
	_pool.clear()


func _new_interior() -> Node:
	_ensure_shared()
	var instance := MeshInstance3D.new()
	instance.mesh = _interior_mesh
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return instance


## Façades peintes des quatre murs : les livres de la galerie, à plat.
func _new_faces() -> Node:
	_ensure_shared()
	var instance := MeshInstance3D.new()
	instance.mesh = _faces_mesh
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
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


## Les 640 livres : un MultiMesh commun à toutes les galeries ; le matériau de la
## galerie porte sa graine, d'où le nuanceur tire hauteur et cuir.
func _new_books() -> Node:
	var instance := MultiMeshInstance3D.new()
	instance.multimesh = _shared_book_multimesh()
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return instance


func _seeded_material(variant: String) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = _shader(variant)
	material.set_shader_parameter("seed", _signed32(book_seed()))
	return material


## MultiMesh commun des livres, rempli d'un bloc par _book_places.
static func _shared_book_multimesh() -> MultiMesh:
	if _book_multimesh == null:
		_book_mesh = BoxMesh.new()
		_book_mesh.size = Vector3.ONE
		_book_multimesh = MultiMesh.new()
		_book_multimesh.transform_format = MultiMesh.TRANSFORM_3D
		_book_multimesh.mesh = _book_mesh
		_book_multimesh.instance_count = WALLS * SHELVES * BOOKS_PER_SHELF
		_book_multimesh.buffer = _book_places()
	return _book_multimesh


## Les places des livres, chacun d'une hauteur unité posé sur sa planche : par livre,
## 12 flottants (3 lignes de 4) : la base du mur mise à l'échelle (épaisseur, 1,
## profondeur), et le pied du dos. La boîte unité, centrée, dépasse d'un demi-mètre
## de part et d'autre de la planche : la boîte englobante couvre toutes les hauteurs.
static func _book_places() -> PackedFloat32Array:
	if not _book_buffer.is_empty():
		return _book_buffer
	_book_buffer.resize(WALLS * SHELVES * BOOKS_PER_SHELF * 12)
	for wall in WALLS:
		var side := _side_basis(BOOK_SIDES[wall])
		var b := side * Basis.from_scale(Vector3(BOOK_THICK, 1.0, BOOK_DEPTH))
		for shelf in SHELVES:
			for book in BOOKS_PER_SHELF:
				var origin := side * Vector3(
					SHELF_WIDTH * 0.5 - (book + 0.5) * BOOK_SLOT,
					BOARD_BASE + (SHELVES - 1 - shelf) * BOARD_PITCH,
					BOOK_FRONT + BOOK_DEPTH * 0.5)
				var o := ((wall * SHELVES + shelf) * BOOKS_PER_SHELF + book) * 12
				var row := [b.x.x, b.y.x, b.z.x, origin.x, b.x.y, b.y.y, b.z.y, origin.y,
					b.x.z, b.y.z, b.z.z, origin.z]
				for k in 12:
					_book_buffer[o + k] = row[k]
	return _book_buffer


## « La luz procede de unas frutas esféricas que llevan el nombre de lámparas.
## Hay dos en cada hexágono: transversales. » Éteintes à la naissance :
## update_lights leur donne leur part.
func _new_lights() -> Node:
	var lights := Node3D.new()
	for dir in [-1.0, 1.0]:
		var light := OmniLight3D.new()
		light.position = Vector3(dir * LAMP_X, LAMP_LIGHT_Y, 0.0)
		light.light_color = LAMP_COLOR
		light.light_energy = 0.0
		light.light_specular = 0.0
		light.omni_range = LAMP_RANGE
		light.visible = false
		lights.add_child(light)
	return lights


static func _node_name(p_hexagon: int, p_level: int) -> String:
	return "Gallery_%d_%d" % [p_hexagon, p_level]


static func _book_hash(book_seed_value: int, book: int, draw: int) -> int:
	return lowbias32(book_seed_value ^ lowbias32(book * 4 + draw))


static func _unit_float(h: int) -> float:
	return float(h >> 8) / 16777216.0


## Produit sur 32 bits, en morceaux de 16 bits pour rester loin du dépassement de 64 bits.
static func _mul32(a: int, b: int) -> int:
	return (a * (b & 0xFFFF) + (((a * (b >> 16)) & 0xFFFF) << 16)) & 0xFFFFFFFF


## Entier de 32 bits sans signe vu comme un int signé de nuanceur (mêmes bits).
static func _signed32(x: int) -> int:
	return x - 0x100000000 if x >= 0x80000000 else x


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

	_interior_mesh = ArrayMesh.new()
	_add_surface(_interior_mesh, plaster.commit_to_arrays(), "plaster")
	_add_surface(_interior_mesh, wood.commit_to_arrays(), "wood")
	_add_surface(_interior_mesh, floor_st.commit_to_arrays(), "floor")
	_add_lamp_surfaces(_interior_mesh)

	var faces := _begin()
	for wall in WALLS:
		_build_book_face(wall, faces)
	_faces_mesh = ArrayMesh.new()
	_faces_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, faces.commit_to_arrays())


static func _add_surface(mesh: ArrayMesh, arrays: Array, material: String) -> void:
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(mesh.get_surface_count() - 1, _material(material))


## Les deux globes (lumineux par eux-mêmes) et leurs cordons.
static func _add_lamp_surfaces(mesh: ArrayMesh) -> void:
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
	_add_surface(mesh, cords.commit_to_arrays(), "wood")


# --- Construction ----------------------------------------------------------

## Plancher (anneau autour du puits jusqu'à l'apothème `outer`), bord du trou, et
## plafond, en bandes concentriques.
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


## Façade peinte d'un mur de livres, au ras des dos. UV.x = 2 × mur + u : le nuanceur
## y retrouve le mur, l'étagère et le livre de chaque pixel.
static func _build_book_face(wall: int, st: SurfaceTool) -> void:
	var basis := _side_basis(BOOK_SIDES[wall])
	var normal := basis * Vector3.FORWARD   # vers le centre de la galerie
	var columns := 4
	var rows := SHELVES
	var offset := 2.0 * wall
	for col in columns:
		for row in rows:
			var u0 := float(col) / columns
			var u1 := float(col + 1) / columns
			var v0 := float(row) / rows
			var v1 := float(row + 1) / rows
			var corner := func(u: float, v: float) -> Vector3:
				return basis * Vector3(SHELF_WIDTH * (0.5 - u), lerpf(CASE_TOP, BOARD_BASE, v), BOOK_FRONT)
			_add_tri_uv(st, [corner.call(u0, v0), corner.call(u1, v0), corner.call(u1, v1)],
				[Vector2(offset + u0, v0), Vector2(offset + u1, v0), Vector2(offset + u1, v1)], normal)
			_add_tri_uv(st, [corner.call(u0, v0), corner.call(u1, v1), corner.call(u0, v1)],
				[Vector2(offset + u0, v0), Vector2(offset + u1, v1), Vector2(offset + u0, v1)], normal)


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

## Albédos (sRGB, comme dans un StandardMaterial3D) et émission des globes.
const ALBEDO := {
	"plaster": Color(0.72, 0.64, 0.50),
	"wood": Color(0.30, 0.19, 0.11),
	"floor": Color(0.36, 0.30, 0.24),
	"lamp": Color(1.0, 0.85, 0.6),
}
const LAMP_EMISSION := Color(1.0, 0.8, 0.5)
const LAMP_EMISSION_ENERGY := 3.0


static func _material(kind: String) -> ShaderMaterial:
	if _materials.has(kind):
		return _materials[kind]
	var material := ShaderMaterial.new()
	material.shader = _shader("SURFACE")
	material.set_shader_parameter("albedo_linear", _linear(ALBEDO[kind]))
	if kind == "lamp":
		material.set_shader_parameter("emission_linear", _linear(LAMP_EMISSION) * LAMP_EMISSION_ENERGY)
	_materials[kind] = material
	return material


## Le nuanceur de la Bibliothèque pour une variante (SURFACE, BOOKS, FACES).
static func _shader(variant: String) -> Shader:
	if _shaders.has(variant):
		return _shaders[variant]
	var lamp := _linear(LAMP_COLOR) * LAMP_ENERGY
	var leather := PackedStringArray()
	for color in LEATHER:
		leather.append(_vec3(Vector3(color.r, color.g, color.b)))
	var shader := Shader.new()
	shader.code = LIBRARY_SHADER.format({
		"VARIANT": variant,
		"PITCH": _float(PITCH), "LEVEL_PITCH": _float(LEVEL_PITCH),
		"LAMP_X": _float(LAMP_X), "LAMP_Y": _float(LAMP_LIGHT_Y), "LAMP_RANGE": _float(LAMP_RANGE),
		"LAMP_LIGHT": _vec3(lamp),
		"REAL_NEAR": _float(REAL_LIGHT_NEAR), "REAL_FAR": _float(REAL_LIGHT_FAR),
		"FOG_LINEAR": _vec3(_linear(FOG_COLOR)), "FOG_DENSITY": _float(FOG_DENSITY),
		"FAR_FADE_BEGIN": _float(FAR_FADE_BEGIN), "FAR_FADE_END": _float(FAR_FADE_END),
		"SHELVES": str(SHELVES), "BOOKS_PER_SHELF": str(BOOKS_PER_SHELF),
		"BOARD_BASE": _float(BOARD_BASE), "BOARD_PITCH": _float(BOARD_PITCH), "CASE_TOP": _float(CASE_TOP),
		"BOOK_SLOT": _float(BOOK_SLOT), "BOOK_THICK": _float(BOOK_THICK),
		"BOOK_MIN_HEIGHT": _float(BOOK_MIN_HEIGHT), "BOOK_MAX_HEIGHT": _float(BOOK_MAX_HEIGHT),
		"BOOK_MAX_DARKEN": _float(BOOK_MAX_DARKEN),
		"WOOD_LINEAR": _vec3(_linear(ALBEDO["wood"])),
		"LEATHER": ", ".join(leather),
	})
	_shaders[variant] = shader
	return shader


## Couleur sRGB en lumière linéaire.
static func _linear(color: Color) -> Vector3:
	var linear := color.srgb_to_linear()
	return Vector3(linear.r, linear.g, linear.b)


static func _float(x: float) -> String:
	return "%.8f" % x


static func _vec3(v: Vector3) -> String:
	return "vec3(%s, %s, %s)" % [_float(v.x), _float(v.y), _float(v.z)]
