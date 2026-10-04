extends SceneTree
## Démonstration à écouter (pas dans la suite automatique) : une caméra longe cinq haut-parleurs espacés de 12 m
## (le pas des galeries) à 1,6 m/s, aller-retour. Le volume monte sous chaque haut-parleur et retombe entre eux.
## À lancer avec une vraie carte son : godot --path . -s tests/demo_ambient.gd
## Touches : M sourdine, flèches haut/bas volume du bus Ambiance, Échap quitte.

const Speaker := preload("res://scripts/ambient_speaker.gd")
const COUNT := 5
const SPEED := 1.6
const MARGIN := 14.0

var _camera: Camera3D
var _label: Label
var _speakers: Array[AmbientSpeaker] = []
var _t := 0.0
var _span := 0.0
var _held := {}


func _initialize() -> void:
	var scene := Node3D.new()
	root.add_child(scene)
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(6.0, COUNT * 12.0 + 2.0 * MARGIN)
	floor_mesh.mesh = plane
	floor_mesh.position = Vector3(0.0, 0.0, (COUNT - 1) * 6.0)
	scene.add_child(floor_mesh)
	scene.add_child(_sun())

	for i in COUNT:
		var speaker := Speaker.create()
		speaker.position = Vector3(0.0, Speaker.HEIGHT, i * 12.0)     # un haut-parleur par couloir, tous les 12 m
		scene.add_child(speaker)
		_speakers.append(speaker)
		var marker := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 0.15
		sphere.height = 0.3
		marker.mesh = sphere
		marker.position = speaker.position
		scene.add_child(marker)

	_camera = Camera3D.new()
	_camera.position = Vector3(0.0, 1.6, -MARGIN)
	scene.add_child(_camera)
	_camera.current = true
	_span = (COUNT - 1) * 12.0 + 2.0 * MARGIN

	var layer := CanvasLayer.new()
	_label = Label.new()
	_label.position = Vector2(16.0, 16.0)
	layer.add_child(_label)
	root.add_child(layer)
	print("démo : %d haut-parleurs, durée du morceau %.0f s, flux %s" % [COUNT, Speaker.music_length(), Speaker.stream_path()])


func _process(delta: float) -> bool:
	_t += delta
	var travel := fposmod(_t * SPEED, 2.0 * _span)
	var along := travel if travel < _span else 2.0 * _span - travel
	_camera.position.z = -MARGIN + along
	var nearest := 1.0e9
	var total := 0.0
	for speaker in _speakers:
		var d := _camera.global_position.distance_to(speaker.global_position)
		nearest = minf(nearest, d)
		total += Speaker.gain_at(d)
	_label.text = "z = %5.1f m   haut-parleur le plus proche : %4.1f m   gain cumulé : %.3f (%.1f dB)\nmusique à %s   [M] sourdine   [haut/bas] volume   [Échap] quitter" % [
		_camera.position.z, nearest, total, linear_to_db(maxf(total, 1e-6)), _clock()]
	_keys()
	if Input.is_key_pressed(KEY_ESCAPE):
		quit()
	return false


func _keys() -> void:
	for key: int in [KEY_M, KEY_UP, KEY_DOWN]:
		var down := Input.is_key_pressed(key)
		if down and not _held.get(key, false):
			match key:
				KEY_M:
					Speaker.set_bus_muted(not Speaker.bus_muted())
				KEY_UP:
					Speaker.set_bus_volume(minf(Speaker.bus_volume() + 3.0, 6.0))
				KEY_DOWN:
					Speaker.set_bus_volume(maxf(Speaker.bus_volume() - 3.0, -40.0))
		_held[key] = down


func _clock() -> String:
	var p := int(Speaker.music_position())
	return "%d:%02d" % [p / 60, p % 60]


func _sun() -> DirectionalLight3D:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, 30.0, 0.0)
	return sun
