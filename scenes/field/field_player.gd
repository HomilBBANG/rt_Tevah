extends CharacterBody2D
## 탐험 중 플레이어 (아트 전 placeholder: 원 + 바라보는 방향 표시)

var field: Node          # field.gd
var radius := 23.0
var speed := 192.0        # 걷기 (픽셀/초)
var run_speed := 288.0    # 달리기: run 액션(Shift)을 누르는 동안
var facing := Vector2.DOWN


func _physics_process(_delta: float) -> void:
	if field.frozen:
		velocity = Vector2.ZERO
		return
	var dir := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	# 무게: 무거우면 느려지고 최대 무게면 못 움직인다 (GameState.carry_speed_mult)
	velocity = dir * (run_speed if Input.is_action_pressed("run") else speed) * GameState.carry_speed_mult()
	if dir != Vector2.ZERO:
		facing = dir.normalized()
		queue_redraw()
	move_and_slide()


func _draw() -> void:
	draw_circle(Vector2.ZERO, radius, Color("e8dcc8"))
	draw_circle(Vector2.ZERO, radius, Color("3a3a3a"), false, 3.0, true)
	draw_line(Vector2.ZERO, facing * radius * 0.9, Color("3a3a3a"), 5.0, true)
