extends CharacterBody3D

var player = null

const SPEED = 3.0
const TURN_SPEED = 8.0

@export var player_path : NodePath
@onready var nav_agent = $NavigationAgent3D

func _ready() -> void:
	player = get_node(player_path)
	
func _physics_process(delta: float) -> void:
	velocity = Vector3.ZERO
	nav_agent.set_target_position(player.global_position)
	var next_nav_point = nav_agent.get_next_path_position()
	var direction = (next_nav_point - global_position)
	direction.y = 0
	direction = direction.normalized()
	velocity = direction * SPEED
	if direction.length() > 0.01:
		var target_angle = atan2(direction.x, direction.z)
		rotation.y = lerp_angle(rotation.y, target_angle, TURN_SPEED * delta)
	move_and_slide()
