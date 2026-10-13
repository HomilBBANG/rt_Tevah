extends CharacterBody2D
## 탐험 중 적. 정해진 경로를 왕복 순찰하다가 시야(벽 너머 제외)에 플레이어가 들어오면 추격.
## 순찰 경로는 매 회차 같다 — 플레이어가 외워서 피할 수 있게 (기획서 §6).
## 상태: patrol / chase / return. grace > 0 이면 도주 직후라 쫓지도 덤비지도 않는다.

var field: Node          # field.gd
var data := {}           # FieldObjects 행 + x, y
var radius := 25.0
var patrol_speed := 96.0
var chase_speed := 154.0
var sight := 240.0
var lose_sight := 384.0

var state := "patrol"
var grace := 0.0
var _points: Array[Vector2] = []
var _target_i := 0


func setup_patrol(origin: Vector2, step: Vector2, count: int) -> void:
	_points = [origin]
	if count > 0:
		_points.append(origin + step * count)
	_target_i = 1 if _points.size() > 1 else 0


func _physics_process(delta: float) -> void:
	if field.frozen:
		velocity = Vector2.ZERO
		return
	grace = maxf(0.0, grace - delta)
	var player: Node2D = field.player
	var dist := global_position.distance_to(player.global_position)
	match state:
		"patrol", "return":
			if grace == 0.0 and dist <= sight and _can_see(player.global_position):
				state = "chase"
			else:
				_move_toward(_points[_target_i], patrol_speed)
				if global_position.distance_to(_points[_target_i]) < 3.0:
					state = "patrol"
					_target_i = (_target_i + 1) % _points.size()
		"chase":
			if grace > 0.0 or dist > lose_sight:
				state = "return"
				_target_i = _nearest_point()
			else:
				_move_toward(player.global_position, chase_speed)
	queue_redraw()


func _move_toward(target: Vector2, speed: float) -> void:
	var to := target - global_position
	velocity = to.normalized() * minf(speed, to.length() * 60.0) if to.length() > 0.5 else Vector2.ZERO
	move_and_slide()


func _can_see(target: Vector2) -> bool:
	var q := PhysicsRayQueryParameters2D.create(global_position, target, 1)   # 1 = 벽
	return get_world_2d().direct_space_state.intersect_ray(q).is_empty()


func _nearest_point() -> int:
	var best := 0
	for i in _points.size():
		if global_position.distance_to(_points[i]) < global_position.distance_to(_points[best]):
			best = i
	return best


func _draw() -> void:
	# 시야 범위 (외워서 피할 수 있도록 보여 줌)
	if state != "chase":
		draw_circle(Vector2.ZERO, sight, Color(1, 0.3, 0.3, 0.06))
		draw_arc(Vector2.ZERO, sight, 0, TAU, 64, Color(1, 0.3, 0.3, 0.18), 2.0, true)
	var col := Color("b84a4a") if grace == 0.0 else Color("6a5050")
	draw_circle(Vector2.ZERO, radius, col)
	draw_circle(Vector2.ZERO, radius, Color("2a1010"), false, 3.0, true)
	if state == "chase":
		var f := ThemeDB.fallback_font
		draw_string_outline(f, Vector2(-8, -radius - 10), "!", HORIZONTAL_ALIGNMENT_LEFT, -1, 40, 8, Color.BLACK)
		draw_string(f, Vector2(-8, -radius - 10), "!", HORIZONTAL_ALIGNMENT_LEFT, -1, 40, Color("ff6a4a"))
