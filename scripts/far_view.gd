class_name FarView
extends Node3D
## Au-delà des galeries construites, la vue continue.
##
## - Le puits : de niveau en niveau, l'anneau de plancher, la balustrade et les
##   lampes, sans le reste de la galerie (seul l'anneau se voit par le puits : vu à
##   travers cinq dalles percées ou plus, le regard ne dépasse pas 2,7 m de l'axe). Un
##   seul MultiMesh ; ses niveaux sont relatifs à l'origine et ne bougent jamais. Ses
##   surfaces ont le nuanceur et les matériaux des galeries : même lumière.
## - Quatre trompe-l'œil ferment la vue : un à chaque bout du vestibule, un en haut
##   et un en bas du puits. Chacun peint, pour chaque pixel, le point du couloir
##   infini (ou du puits infini) que le regard atteindrait au-delà : la même suite
##   de galeries et de niveaux, de plus en plus petite, noyée dans le même brouillard
##   que la géométrie. À l'endroit du trompe-l'œil, le couloir peint prolonge donc
##   le vrai, et s'assombrit jusqu'au noir à l'infini. Comme la géométrie, il se
##   fond entièrement dans la brume au-delà de Gallery.FAR_FADE_END : posé à plus de
##   95 m de l'œil, il ne montre que la brume, et son saut d'une galerie (ou d'un
##   niveau) à chaque pas ne se voit pas.
##
## Repère : celui du monde (le nœud reste à l'origine) ; galerie d'origine au centre.

const FarViewScript := preload("res://scripts/far_view.gd")
const GalleryScript := preload("res://scripts/gallery.gd")

const IMPOSTOR_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, fog_disabled;

// Section du tunnel : plans n·q = d dans le repère (cross_u, cross_v) centré sur axis_point.
uniform vec3 axis_point;
uniform vec3 cross_u;
uniform vec3 cross_v;
uniform int plane_count;
uniform vec3 planes[6];
uniform float plane_tint[6];
// Motif répété le long de l'axe : une période (une galerie, un niveau) dans `profile`.
uniform vec3 phase_axis;
uniform float pitch;
uniform sampler2D profile : source_color, filter_linear, repeat_enable;
uniform vec3 profile_mean : source_color;
// Brouillard exponentiel, le même que celui de l'environnement, sur toute la distance.
uniform vec3 fog_color : source_color;
uniform float fog_density;
// Fondu au noir de brume au loin, le même que celui du nuanceur des galeries.
uniform float fade_begin;
uniform float fade_end;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 eye = CAMERA_POSITION_WORLD;
	vec3 ray = world_pos - eye;
	vec2 e = vec2(dot(eye - axis_point, cross_u), dot(eye - axis_point, cross_v));
	vec2 r = vec2(dot(ray, cross_u), dot(ray, cross_v));
	// Le regard prolongé sort de la section par le premier plan qu'il franchit.
	float reach = 1.0e6;
	int hit = 0;
	for (int i = 0; i < plane_count; i++) {
		float k = dot(planes[i].xy, r);
		if (k > 1.0e-6) {
			float l = (planes[i].z - dot(planes[i].xy, e)) / k;
			if (l < reach) {
				reach = l;
				hit = i;
			}
		}
	}
	reach = max(reach, 1.0);
	vec3 wall = eye + ray * reach;
	float s = dot(wall, phase_axis) / pitch;
	// Un motif plus fin qu'un pixel prend sa couleur moyenne : pas de moiré au loin.
	float blur = clamp(fwidth(s) * 2.0 - 0.5, 0.0, 1.0);
	vec3 base = mix(texture(profile, vec2(s, 0.5)).rgb, profile_mean, blur) * plane_tint[hit];
	float distance_to_wall = reach * length(ray);
	float fade = 1.0 - smoothstep(fade_begin, fade_end, distance_to_wall);
	ALBEDO = mix(fog_color, base, exp(-fog_density * distance_to_wall) * fade);
}
"""

## Les quatre trompe-l'œil : nom → nœud. Chacun porte en méta `axis` (direction
## vers l'infini) et `reach` (distance de l'origine au trompe-l'œil le long de l'axe).
var impostors: Dictionary = {}
## Niveaux (relatifs à l'origine) des anneaux du puits.
var ring_levels: Array[int] = []


## `hall_reach` : galeries construites de chaque côté ; `first_ring`..`last_ring` :
## niveaux du puits réduits à leur anneau, au-dessus et au-dessous.
static func create(hall_reach: int, first_ring: int, last_ring: int, fog_color: Color, fog_density: float) -> FarViewScript:
	var view := FarViewScript.new()
	view.name = "FarView"
	view._build_rings(first_ring, last_ring)
	var shader := Shader.new()
	shader.code = IMPOSTOR_SHADER

	# Bouts du vestibule : au milieu du vestibule qui suivrait la dernière galerie.
	var hall_end := hall_reach * GalleryScript.PITCH + GalleryScript.APOTHEM + GalleryScript.HALL_LENGTH * 0.5
	var w := GalleryScript.HALL_WIDTH * 0.5
	var hall_planes := [
		Vector3(1.0, 0.0, w), Vector3(-1.0, 0.0, w),
		Vector3(0.0, 1.0, GalleryScript.HEIGHT), Vector3(0.0, -1.0, 0.0),
	]
	var hall_tints := [1.0, 1.0, 0.7, 0.85]   # murs, plafond, sol
	var hall_size := Vector2(GalleryScript.HALL_WIDTH + 2.0 * GalleryScript.WALL_THICK, GalleryScript.HEIGHT + 0.6)
	for dir: float in [1.0, -1.0]:
		var axis := Vector3(0.0, 0.0, dir)
		var material := _material(shader, Vector3(0.0, 0.0, hall_end * dir), Vector3.RIGHT, Vector3.UP,
			hall_planes, hall_tints, Vector3.BACK, GalleryScript.PITCH, _hall_profile(), fog_color, fog_density)
		var spot := Transform3D(Basis(Vector3.UP, PI if dir > 0.0 else 0.0),
			Vector3(0.0, GalleryScript.HEIGHT * 0.5, hall_end * dir))
		view._add_impostor("HallEnd" + ("Plus" if dir > 0.0 else "Minus"), hall_size, spot, material, axis, hall_end)

	# Haut et bas du puits : au milieu de la dalle qui suivrait le dernier anneau.
	var shaft_planes := []
	var shaft_tints := []
	for side in 6:
		var angle := side * PI / 3.0
		shaft_planes.append(Vector3(sin(angle), cos(angle), GalleryScript.SHAFT_APOTHEM))
		shaft_tints.append(1.0)
	var top := (last_ring + 1) * GalleryScript.LEVEL_PITCH - GalleryScript.SLAB * 0.5
	var bottom := last_ring * GalleryScript.LEVEL_PITCH + GalleryScript.SLAB + 0.2
	var shaft_size := Vector2(4.0, 4.0)
	for dir: float in [1.0, -1.0]:
		var reach: float = top if dir > 0.0 else bottom
		var axis := Vector3(0.0, dir, 0.0)
		var material := _material(shader, Vector3(0.0, reach * dir, 0.0), Vector3.RIGHT, Vector3.BACK,
			shaft_planes, shaft_tints, Vector3.UP, GalleryScript.LEVEL_PITCH, _shaft_profile(), fog_color, fog_density)
		var spot := Transform3D(Basis(Vector3.RIGHT, PI * 0.5 * dir), Vector3(0.0, reach * dir, 0.0))
		view._add_impostor("Shaft" + ("Top" if dir > 0.0 else "Bottom"), shaft_size, spot, material, axis, reach)
	return view


func _build_rings(first_ring: int, last_ring: int) -> void:
	for level in range(first_ring, last_ring + 1):
		ring_levels.append(level)
		ring_levels.append(-level)
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = GalleryScript.ring_mesh()
	multimesh.instance_count = ring_levels.size()
	for i in ring_levels.size():
		multimesh.set_instance_transform(i, Transform3D(Basis(), Vector3.UP * ring_levels[i] * GalleryScript.LEVEL_PITCH))
	var rings := MultiMeshInstance3D.new()
	rings.name = "ShaftRings"
	rings.multimesh = multimesh
	rings.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(rings)


static func _material(shader: Shader, axis_point: Vector3, cross_u: Vector3, cross_v: Vector3, planes: Array,
		tints: Array, phase_axis: Vector3, pitch: float, profile: GradientTexture1D,
		fog_color: Color, fog_density: float) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("axis_point", axis_point)
	material.set_shader_parameter("cross_u", cross_u)
	material.set_shader_parameter("cross_v", cross_v)
	var padded_planes := PackedVector3Array(planes)
	var padded_tints := PackedFloat32Array(tints)
	padded_planes.resize(6)
	padded_tints.resize(6)
	material.set_shader_parameter("plane_count", planes.size())
	material.set_shader_parameter("planes", padded_planes)
	material.set_shader_parameter("plane_tint", padded_tints)
	material.set_shader_parameter("phase_axis", phase_axis)
	material.set_shader_parameter("pitch", pitch)
	material.set_shader_parameter("profile", profile)
	material.set_shader_parameter("profile_mean", _mean(profile.gradient))
	material.set_shader_parameter("fog_color", fog_color)
	material.set_shader_parameter("fog_density", fog_density)
	material.set_shader_parameter("fade_begin", GalleryScript.FAR_FADE_BEGIN)
	material.set_shader_parameter("fade_end", GalleryScript.FAR_FADE_END)
	return material


func _add_impostor(impostor_name: String, size: Vector2, spot: Transform3D, material: ShaderMaterial,
		axis: Vector3, reach: float) -> void:
	var quad := QuadMesh.new()
	quad.size = size
	var impostor := MeshInstance3D.new()
	impostor.name = impostor_name
	impostor.mesh = quad
	impostor.material_override = material
	impostor.transform = spot
	impostor.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	impostor.set_meta("axis", axis)
	impostor.set_meta("reach", reach)
	add_child(impostor)
	impostors[impostor_name] = impostor


## Une galerie le long du vestibule, du centre (0) au centre suivant (1) : les lampes
## au centre, les murs éclairés de part et d'autre, le vestibule sombre au milieu.
static func _hall_profile() -> GradientTexture1D:
	var lamp := Color(0.62, 0.48, 0.32)
	var wall := Color(0.42, 0.33, 0.23)
	var dusk := Color(0.30, 0.23, 0.16)
	var hall := Color(0.14, 0.10, 0.07)
	return _profile([
		[0.0, lamp], [0.30, dusk], [0.40, wall], [0.43, hall],
		[0.57, hall], [0.60, wall], [0.70, dusk], [1.0, lamp],
	])


## Un niveau du puits, du plancher (0) au plancher suivant (1) : balustrade claire,
## galerie entrevue avec la lueur des lampes, puis le chant de la dalle.
static func _shaft_profile() -> GradientTexture1D:
	var rail := Color(0.48, 0.40, 0.29)
	var room := Color(0.20, 0.15, 0.10)
	var lamp := Color(0.55, 0.42, 0.28)
	var slab := Color(0.30, 0.25, 0.20)
	return _profile([
		[0.0, rail], [0.25, rail], [0.30, room], [0.69, lamp],
		[0.86, room], [0.88, slab], [1.0, slab],
	])


static func _profile(stops: Array) -> GradientTexture1D:
	var gradient := Gradient.new()
	var offsets := PackedFloat32Array()
	var colors := PackedColorArray()
	for stop in stops:
		offsets.append(stop[0])
		colors.append(stop[1])
	gradient.offsets = offsets
	gradient.colors = colors
	var texture := GradientTexture1D.new()
	texture.gradient = gradient
	texture.width = 256
	return texture


## Couleur moyenne d'un profil sur sa période, moyennée en lumière linéaire.
static func _mean(gradient: Gradient) -> Color:
	var sum := Color(0.0, 0.0, 0.0)
	var samples := 64
	for i in samples:
		sum += gradient.sample((i + 0.5) / samples).srgb_to_linear()
	sum = sum / samples
	sum.a = 1.0
	return sum.linear_to_srgb()
