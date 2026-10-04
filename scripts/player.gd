class_name Player
extends CharacterBody3D
## Bibliothécaire à la première personne : marche, gravité, regard à la souris,
## et repérage du livre visé par un rayon partant de la caméra.

const GalleryScript := preload("res://scripts/gallery.gd")

const SPEED := 3.0
const MOUSE_SENSITIVITY := 0.0025
const REACH := 2.5
const EYE_HEIGHT := 1.6
const RADIUS := 0.3
const BODY_HEIGHT := 1.75

## Vrai pendant la lecture : le bibliothécaire reste immobile.
var frozen := false
## Livre visé : {gallery, hexagon, level, wall, shelf, book}, vide si aucun.
var target: Dictionary = {}
var camera: Camera3D

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")


func _ready() -> void:
	var capsule := CapsuleShape3D.new()
	capsule.radius = RADIUS
	capsule.height = BODY_HEIGHT
	var shape := CollisionShape3D.new()
	shape.shape = capsule
	shape.position.y = BODY_HEIGHT * 0.5
	add_child(shape)

	camera = Camera3D.new()
	camera.position.y = EYE_HEIGHT
	camera.fov = 75.0
	camera.near = 0.05
	add_child(camera)


## Tourne le regard selon un déplacement relatif de la souris.
func look(relative: Vector2) -> void:
	rotate_y(-relative.x * MOUSE_SENSITIVITY)
	camera.rotation.x = clampf(camera.rotation.x - relative.y * MOUSE_SENSITIVITY, -1.45, 1.45)


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= _gravity * delta
	var input := Vector2.ZERO
	if not frozen:
		input = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var direction := transform.basis * Vector3(input.x, 0.0, input.y)
	velocity.x = direction.x * SPEED
	velocity.z = direction.z * SPEED
	move_and_slide()
	target = _find_target()


func _find_target() -> Dictionary:
	var from := camera.global_position
	var to := from - camera.global_basis.z * REACH
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty() or not hit.collider.has_meta("book_wall"):
		return {}
	var gallery := hit.collider.get_parent() as GalleryScript
	return gallery.locate_book(hit.collider, hit.position)
