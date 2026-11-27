extends Area3D

const SPEED = 55.0
const RANGE = 40.0

var travelled_distance = 0.0


func _ready():
	add_to_group("bullet")


func _physics_process(delta):
	position += -transform.basis.z * SPEED * delta
	travelled_distance += SPEED * delta
	if travelled_distance > RANGE:
		queue_free()


func _on_body_entered(body: Node3D) -> void:
	if body.is_in_group("enemy"):
		body.queue_free()  # atau body.take_damage(1) kalau enemy punya darah
		queue_free()
