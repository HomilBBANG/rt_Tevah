extends CharacterBody2D
## 탐험 중 플레이어 (아트 전 placeholder: 원 + 바라보는 방향 표시)

var field: Node          # field.gd
var radius := 23.0
var speed := 192.0
var facing := Vector2.DOWN


func _physics_process(_delta: float) -> void:
	if field.frozen:
		velocity = Vector2.ZERO
		return
	var dir := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	velocity = dir * speed
	if dir != Vector2.ZERO:
		facing = dir.normalized()
		queue_redraw()
	move_and_slide()


func _draw() -> void:
	draw_circle(Vector2.ZERO, radius, Color("e8dcc8"))
	draw_circle(Vector2.ZERO, radius, Color("3a3a3a"), false, 3.0, true)
	draw_line(Vector2.ZERO, facing * radius * 0.9, Color("3a3a3a"), 5.0, true)
