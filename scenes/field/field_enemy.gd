extends CharacterBody2D
## 탐험 중 적. 두 가지 AI:
##   - BT (맵 물체에 bt = BT_ 자산): 몬스터 AI 에디터의 Behavior Tree 로 움직임 (core/ai/bt_runner.gd). 이 노드가 어댑터 —
##     기존 이동·벽 충돌·시야(벽·닫힌 문 너머 안 보임)·전투 진입을 그대로 부른다 (ai_* 함수, bt_tasks.gd 참고).
##   - 예전 AI (bt 가 없거나 자산이 잘못됐을 때): 정해진 경로를 왕복 순찰하다가 시야에 플레이어가 들어오면 추격.
## 순찰 경로는 매 회차 같다 — 플레이어가 외워서 피할 수 있게 (기획서 §6).
## 상태(그림용): patrol / chase / return. grace > 0 이면 도주 직후라 쫓지도 덤비지도 않는다 (BT 도: 그동안 '안 보임', 전투 요청 거절).

const Runner = preload("res://core/ai/bt_runner.gd")

var field: Node          # field.gd
var data := {}           # FieldObjects 행 + x, y
var radius := 25.0
var patrol_speed := 96.0
var chase_speed := 154.0
var sight := 240.0
var lose_sight := 384.0

var state := "patrol"
var grace := 0.0
var bt: Runner = null    # Behavior Tree 로 움직이면 (몬스터마다 따로 — 자산은 공유)
var _points: Array[Vector2] = []
var _target_i := 0
var _origin := Vector2.ZERO
var _path: Array = []            # BT 이동: 남은 길 (칸)
var _path_goal := Vector2i(-9999, -9999)
var _stuck_t := 0.0
var _last_pos := Vector2.ZERO
var _heard := {}                 # 들은 소리 {pos (칸)} — ai_noise 가 한 번 꺼내 감


func setup_patrol(origin: Vector2, step: Vector2, count: int) -> void:
	_origin = origin
	_points = [origin]
	if count > 0:
		_points.append(origin + step * count)
	_target_i = 1 if _points.size() > 1 else 0


## BT 로 움직이게 한다 (overrides = 맵 물체의 bb_overrides — instance_override 인 키만)
func setup_bt(bt_asset: Dictionary, bb_asset: Dictionary, overrides: Dictionary) -> void:
	bt = Runner.new()
	bt.setup(bt_asset, bb_asset, self, overrides)


## 닿으면 바로 전투하나: 맵 물체 touch_battle(on/off, 몬스터마다)이 먼저, 비우면 BT 의 battle_on_contact (기본 켬), 예전 AI 는 켬
func touch_battle() -> bool:
	match str(data.get("touch_battle", "")):
		"on": return true
		"off": return false
	return bt == null or bool(bt.asset.get("battle_on_contact", true))


func _exit_tree() -> void:
	if bt:
		bt.stop("몬스터 제거·맵 이동")   # 실행 중인 Task·Service 정리 (이후 콜백 없음)


func _physics_process(delta: float) -> void:
	if field.frozen:
		velocity = Vector2.ZERO
		return
	if field.ai_paused and not field.ai_stepping:   # 디버거 일시정지
		velocity = Vector2.ZERO
		queue_redraw()
		return
	grace = maxf(0.0, grace - delta)
	if bt:
		if field.ai_stepping:
			bt.step(delta)
		else:
			bt.tick(delta)
		state = "chase" if bt.bb.get_value("HasLineOfSight") else "patrol"
		queue_redraw()
		return
	var player: Node2D = field.player
	var dist := global_position.distance_to(player.global_position)
	match state:
		"patrol", "return":
			if grace == 0.0 and dist <= sight * field.sight_mult() and _can_see(player.global_position):
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
	var q := PhysicsRayQueryParameters2D.create(global_position, target, 1 | 8)   # 1 = 벽, 8 = 닫힌 문
	return get_world_2d().direct_space_state.intersect_ray(q).is_empty()


func _nearest_point() -> int:
	var best := 0
	for i in _points.size():
		if global_position.distance_to(_points[i]) < global_position.distance_to(_points[best]):
			best = i
	return best


# ---------------------------------------------------------------- BT 어댑터 (칸 좌표: 정수 = 칸 가운데)
func _to_tile(p: Vector2) -> Vector2:
	return p / field.tile - Vector2(0.5, 0.5)


func _to_px(t: Vector2) -> Vector2:
	return (t + Vector2(0.5, 0.5)) * field.tile


func ai_tile() -> Vector2:
	return _to_tile(global_position)


## 한 tick 이동. 곧장 보이면 바로, 아니면 벽을 돌아가는 길(field.path_grid). 0.6초 동안 거의 못 움직이면 막힘.
func ai_move(to: Vector2, run: bool, delta: float) -> String:
	var goal_px := _to_px(to)
	if global_position.distance_to(goal_px) < 3.0:
		return "arrived"
	var aim := goal_px
	if not _can_see(goal_px):
		var goal := Vector2i(roundi(to.x), roundi(to.y))
		var here := Vector2i(roundi(ai_tile().x), roundi(ai_tile().y))
		if goal != _path_goal or _path.is_empty():
			_path_goal = goal
			_path = field.find_path(here, goal)
			if _path.is_empty():
				return "blocked"
		while not _path.is_empty() and global_position.distance_to(_to_px(Vector2(_path[0]))) < 4.0:
			_path.pop_front()
		if not _path.is_empty():
			aim = _to_px(Vector2(_path[0]))
	else:
		_path.clear()
	_move_toward(aim, chase_speed if run else patrol_speed)
	if global_position.distance_to(_last_pos) < 0.5:
		_stuck_t += delta
		if _stuck_t > 0.6:
			_stuck_t = 0.0
			return "blocked"
	else:
		_stuck_t = 0.0
	_last_pos = global_position
	return "moving"


func ai_stop() -> void:
	velocity = Vector2.ZERO
	_path.clear()
	_path_goal = Vector2i(-9999, -9999)
	_stuck_t = 0.0


func ai_patrol_points() -> Array:
	return _points.map(func(p): return _to_tile(p))


func ai_origin() -> Vector2:
	return _to_tile(_origin)


## 시야: VisionRange 칸 안 + 벽·닫힌 문에 안 가림. 도주 직후 유예(grace) 동안은 안 보임
func ai_perceive(range_tiles: float) -> Dictionary:
	var p: Node2D = field.player
	var dist: float = global_position.distance_to(p.global_position) / field.tile
	var vis: bool = grace == 0.0 and dist <= range_tiles * field.sight_mult() and _can_see(p.global_position)   # 손전등을 들면 더 멀리서
	return {"visible": vis, "id": "player", "pos": _to_tile(p.global_position), "distance": dist}


func ai_entity_tile(id: String) -> Variant:
	return _to_tile(field.player.global_position) if id == "player" else null


## 들은 소리를 꺼내 감 (UpdateNoise Service) — 달리기·문 여닫기 (field.make_noise)
func ai_noise() -> Dictionary:
	var n := _heard
	_heard = {}
	return n


func hear(tile_pos: Vector2) -> void:
	_heard = {"pos": tile_pos}


func ai_request_battle() -> bool:
	if grace > 0.0 or field.frozen:
		return false
	return field.request_battle(self)


func _draw() -> void:
	# 시야 범위 (외워서 피할 수 있도록 보여 줌)
	var r := sight
	if bt and bt.bb.has_key("VisionRange"):
		r = float(bt.bb.get_value("VisionRange")) * field.tile
	if state != "chase":
		draw_circle(Vector2.ZERO, r, Color(1, 0.3, 0.3, 0.06))
		draw_arc(Vector2.ZERO, r, 0, TAU, 64, Color(1, 0.3, 0.3, 0.18), 2.0, true)
	var col := Color("b84a4a") if grace == 0.0 else Color("6a5050")
	draw_circle(Vector2.ZERO, radius, col)
	draw_circle(Vector2.ZERO, radius, Color("2a1010"), false, 3.0, true)
	if bt and field.ai_debug:   # F9: 지금 Task·Blackboard 요약 (개발용)
		var f2 := ThemeDB.fallback_font
		var t := "%s %s" % [bt.task_node if bt.task_node != "" else "-", bt.last_result.get(bt.task_node, "")]
		draw_string_outline(f2, Vector2(-radius * 2, radius + 26), t, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, 6, Color.BLACK)
		draw_string(f2, Vector2(-radius * 2, radius + 26), t, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color("ffd27a"))
	if state == "chase":
		var f := ThemeDB.fallback_font
		draw_string_outline(f, Vector2(-8, -radius - 10), "!", HORIZONTAL_ALIGNMENT_LEFT, -1, 40, 8, Color.BLACK)
		draw_string(f, Vector2(-8, -radius - 10), "!", HORIZONTAL_ALIGNMENT_LEFT, -1, 40, Color("ff6a4a"))
