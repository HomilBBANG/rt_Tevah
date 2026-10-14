extends Node2D
## 탑뷰 탐험 필드 (기획서 §4–6, §11–13). 맵은 data/maps.json (tools/maps/*.txt + FieldObjects 시트).
##
## - 이동 중 게임 시계가 실시간으로 흐르고 생존 파라미터가 줄어든다 (전투·대화·메뉴 중에는 멈춤).
## - 적과 닿으면 턴제 전투(화면 위에 겹쳐 띄움) → 승리: 적 제거 / 도주: 잠시 유예 / 사망: 회차 종료
## - NPC 에게 말을 걸면 대화 화면(scenes/main_play)을 겹쳐 띄우고 필드 대화 진행, EXIT 에서 복귀.
## - 베이스캠프 거점(camp)에서 식사·위생·잠(1시간 단위, 자고 나면 저장).
## - 문(exit): E 로 열고 닫는다. 닫힌 문은 막히고 시야도 가린다. 열린 문 칸으로 걸어 들어가면 그 맵으로 나간다.
## - 맵 칸: '#' 벽, '.' 바닥, ' ' 빈 공간(검은색, 지나갈 수 없음).
## - 저장은 베이스캠프에서만: 잠을 자면 저장되고, 고양이가 와 있으면 고양이에게도 저장할 수 있다(대화 효과 save).
## - NPC 는 FieldObjects.schedule 의 시간대에만 나타난다 (예: 고양이의 하루 루틴). 시계가 흐르면 바로 반영.
## 회차 상태(시계·생존·몸·처치한 적·조사한 곳·소지품)는 GameState 에 있고, 베이스캠프에서만 저장된다.
##
## TODO(기획 미확정): 생존 파라미터가 낮을 때의 효과(§5), 탐험 중 종료 처리(§13.2 — 지금은 마지막 저장에서 이어짐),
##                    사망·부활 연출(§11)

const InputActions = preload("res://core/input_actions.gd")
const Expr = preload("res://core/expr.gd")
const CombatScene = preload("res://scenes/combat.tscn")
const DialogueScene = preload("res://scenes/main_play.tscn")
const ChoiceButton = preload("res://ui/choice_button.gd")
const SlotPicker = preload("res://ui/save_slot_picker.gd")
const NpcScript = preload("res://scenes/field/field_npc.gd")
const PlayerScript = preload("res://scenes/field/field_player.gd")
const EnemyScript = preload("res://scenes/field/field_enemy.gd")

const WALL_LAYER := 1
const ACTOR_LAYER := 2
const NPC_LAYER := 4
const DOOR_LAYER := 8            # 닫힌 문: 플레이어·적 모두 통과 못 하고, 적의 시야도 막는다 (field_enemy._can_see)
const INTERACT_RANGE := 1.1      # 칸
const TOAST_TIME := 3.0

## 테스트·디버그용: 비어 있지 않으면 이 맵으로 시작
static var next_map_id := ""

var map := {}
var tile := 48.0
var frozen := false
var player: CharacterBody2D
var enemies: Array = []
var spots: Array = []            # 상호작용 지점 [{ kind: "spot"/"camp"/"exit", data, pos, done }]
var npcs: Array = []             # NPC [{ kind: "npc", data, pos, node, active }] — active: 지금 시간대에 있음

var _combat_ui: Node
var _dialogue_ui: Node
var _combat_enemy: Node
var _combat_from_dialogue := false   # 대화 선택지(type=combat)로 시작한 전투
var _near_spot := {}
var _collecting := false         # StoryRunner 메시지를 모으는 중 (조사·거점 행동)
var _collected: PackedStringArray = []
var _toast_t := 0.0
var _death_revival := {}        # 사망 패널: 적용된 부활 규칙 (비면 처음부터)
var _sleep_pick := {}            # 잠잘 시간 고르는 중: { action, hours }
var _sleep_value: Label
var _sleep_wake: Label


func _ready() -> void:
	InputActions.ensure()
	if GameState.current_map == "":
		SaveManager.begin_run()          # 타이틀을 거치지 않고 바로 열었을 때
	if next_map_id != "":
		GameState.current_map = next_map_id
		next_map_id = ""
	StoryRunner.enter_field()
	StoryRunner.message.connect(_on_story_message)
	StoryRunner.inventory_full.connect(_on_inventory_full)
	StoryRunner.save_slot_requested.connect(_on_save_slot_requested)
	StoryRunner.combat_requested.connect(_on_dialogue_combat)
	GameState.survival_changed.connect(_update_hud)
	GameState.clock_changed.connect(_update_hud)
	GameState.clock_changed.connect(_refresh_presence)
	GameState.inventory_changed.connect(_update_hud)
	GameState.body_changed.connect(_update_hud)
	%TitleButton.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/title.tscn"))
	%InventoryButton.pressed.connect(_open_inventory)
	%NewRunButton.pressed.connect(_new_run)
	%CampClose.pressed.connect(_close_camp)
	%Inventory.visibility_changed.connect(func(): _set_frozen_by_overlay())
	load_map(GameState.current_map)


func _exit_tree() -> void:
	for pair in [[StoryRunner.message, _on_story_message], [StoryRunner.inventory_full, _on_inventory_full],
			[StoryRunner.save_slot_requested, _on_save_slot_requested], [StoryRunner.combat_requested, _on_dialogue_combat]]:
		if pair[0].is_connected(pair[1]):
			pair[0].disconnect(pair[1])


# ---------------------------------------------------------------- 맵 만들기
## 맵을 (다시) 만든다. 처치한 적·조사한 곳은 GameState.field_state 에서 빠진다.
func load_map(map_id: String) -> void:
	for c in %World.get_children():
		c.queue_free()
	enemies.clear()
	spots.clear()
	npcs.clear()
	_near_spot = {}
	%Prompt.visible = false
	map = DataLoader.maps.get(map_id, {})
	if map.is_empty():
		%Message.text = "[오류] 맵 '%s' 데이터가 없습니다. tools/xlsx_to_json.py 를 실행했는지 확인하세요." % map_id
		%MessagePanel.visible = true
		frozen = true
		return
	GameState.current_map = map_id
	tile = float(DataLoader.config.get("field_tile", 48))
	_build_walls()
	_build_actors()
	%MapView.tiles = map.tiles
	%MapView.tile = tile
	%MapView.spots = spots
	%MapView.queue_redraw()
	frozen = false
	_update_hud()


## 지나갈 수 없는 칸: 벽(#)과 빈 공간(공백)
static func _is_solid(ch: String) -> bool:
	return ch != "."


func _build_walls() -> void:
	var body := StaticBody2D.new()
	body.collision_layer = WALL_LAYER
	body.collision_mask = 0
	%World.add_child(body)
	# 가로로 이어진 벽을 하나의 사각형으로 합친다
	for y in map.tiles.size():
		var row: String = map.tiles[y]
		var x := 0
		while x < row.length():
			if not _is_solid(row[x]):
				x += 1
				continue
			var start := x
			while x < row.length() and _is_solid(row[x]):
				x += 1
			var shape := CollisionShape2D.new()
			var rect := RectangleShape2D.new()
			rect.size = Vector2((x - start) * tile, tile)
			shape.shape = rect
			shape.position = Vector2((start + x) * tile / 2.0, (y + 0.5) * tile)
			body.add_child(shape)


func _build_actors() -> void:
	var cfg := func(key: String, default: float) -> float: return float(DataLoader.config.get(key, default)) * tile

	player = CharacterBody2D.new()
	player.set_script(PlayerScript)
	player.field = self
	player.radius = tile * 0.3
	player.speed = cfg.call("field_player_speed", 4)
	player.collision_layer = ACTOR_LAYER
	player.collision_mask = WALL_LAYER | NPC_LAYER | DOOR_LAYER
	# 새 회차는 맵 한복판(S)에서 깨어나고, 그 밖에는 P(출구로 들어온 곳·베이스캠프에서 깨어나는 곳)
	var spawn: Array = map.get("run_start", map.start) if GameState.wake_at_run_start else map.start
	GameState.wake_at_run_start = false
	player.position = _tile_center(spawn[0], spawn[1])
	_add_circle_shape(player, player.radius)
	var cam := Camera2D.new()
	# 위아래 검은 띠(화면의 10.6%)에 맵 가장자리가 가려지지 않게 그만큼 더 움직이게 둔다
	var bar := int(get_viewport_rect().size.y * 0.106)
	cam.limit_left = 0
	cam.limit_top = -bar
	cam.limit_right = int(map.width * tile)
	cam.limit_bottom = int(map.height * tile) + bar
	cam.position_smoothing_enabled = true
	player.add_child(cam)
	%World.add_child(player)
	cam.make_current()
	cam.reset_smoothing()

	var dirs := {"up": Vector2.UP, "down": Vector2.DOWN, "left": Vector2.LEFT, "right": Vector2.RIGHT}
	for o in map.objects:
		# 조건이 맞을 때만 나타나는 물체 (시간대는 schedule 로 따로 — _refresh_presence)
		if o.get("condition", "") != "" and not Expr.evaluate(o.condition, GameState):
			continue
		var pos := _tile_center(o.x, o.y)
		match o.type:
			"enemy":
				if GameState.field_has(map.map_id, "removed", o.object_id):
					continue
				var e := CharacterBody2D.new()
				e.set_script(EnemyScript)
				e.field = self
				e.data = o
				e.radius = tile * 0.32
				e.patrol_speed = cfg.call("field_enemy_speed", 2)
				e.chase_speed = cfg.call("field_enemy_chase_speed", 3.2)
				e.sight = cfg.call("field_enemy_sight", 5)
				e.lose_sight = cfg.call("field_enemy_lose_sight", 8)
				e.collision_layer = 0
				e.collision_mask = WALL_LAYER | DOOR_LAYER
				e.position = pos
				e.setup_patrol(pos, dirs.get(o.patrol_dir, Vector2.ZERO) * tile, int(o.patrol_len))
				_add_circle_shape(e, e.radius * 0.8)
				%World.add_child(e)
				enemies.append(e)
			"investigate", "camp", "exit":
				var kind: String = "spot" if o.type == "investigate" else o.type
				spots.append({"kind": kind, "data": o, "pos": pos,
					"done": GameState.field_has(map.map_id, "done", o.object_id)})
				if o.type == "exit":
					spots.back().open = false
					spots.back().body = _add_door_body(pos)
			"npc":
				var n := StaticBody2D.new()
				n.set_script(NpcScript)
				n.radius = tile * 0.3
				n.display_name = o.name
				n.collision_layer = NPC_LAYER
				n.collision_mask = 0
				n.position = pos
				_add_circle_shape(n, n.radius)
				%World.add_child(n)
				npcs.append({"kind": "npc", "data": o, "pos": pos, "node": n, "active": true})
	_refresh_presence()


## 시간대(schedule)에 맞춰 NPC 를 보이거나 숨긴다. 숨은 NPC 는 부딪히지도, 말을 걸 수도 없다.
func _refresh_presence() -> void:
	var minute := GameState.minute_of_day()
	for n in npcs:
		var here := in_schedule(n.data.get("schedule", []), minute)
		if here != n.active:
			n.active = here
			n.node.visible = here
			n.node.collision_layer = NPC_LAYER if here else 0
			if not here and _near_spot == n:
				_near_spot = {}
				%Prompt.visible = false


## schedule: [[시작분, 끝분], ...] (하루 중 분). 비어 있으면 항상. 끝 < 시작이면 자정을 넘는 범위.
static func in_schedule(schedule: Array, minute: int) -> bool:
	if schedule.is_empty():
		return true
	for r in schedule:
		var start := int(r[0])
		var end := int(r[1])
		if (start < end and minute >= start and minute < end) or (start > end and (minute >= start or minute < end)):
			return true
	return false


## 닫힌 문 칸을 막는 충돌체 (열면 꺼진다)
func _add_door_body(pos: Vector2) -> StaticBody2D:
	var body := StaticBody2D.new()
	body.collision_layer = DOOR_LAYER
	body.collision_mask = 0
	body.position = pos
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(tile, tile)
	shape.shape = rect
	body.add_child(shape)
	%World.add_child(body)
	return body


## 문 열기·닫기. 문 칸 위에 서 있으면 닫지 않는다.
func toggle_door(s: Dictionary) -> void:
	if s.open and Rect2(s.pos - Vector2(tile, tile) / 2.0, Vector2(tile, tile)).grow(player.radius).has_point(player.global_position):
		return
	s.open = not s.open
	s.body.collision_layer = 0 if s.open else DOOR_LAYER
	%MapView.queue_redraw()
	_near_spot = {}   # 안내 문구 다시 쓰기


func _tile_center(x: float, y: float) -> Vector2:
	return Vector2((x + 0.5) * tile, (y + 0.5) * tile)


func _add_circle_shape(body: Node, r: float) -> void:
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = r
	shape.shape = circle
	body.add_child(shape)


# ---------------------------------------------------------------- 매 프레임
func _physics_process(delta: float) -> void:
	if _toast_t > 0.0:
		_toast_t -= delta
		%Toast.visible = _toast_t > 0.0
	if frozen or player == null or map.is_empty():
		return
	# 탐험 중에는 시간이 실시간으로 흐른다 (§4)
	GameState.advance_time(delta * float(DataLoader.config.get("time_scale", 1)))
	for e in enemies:
		if e.grace == 0.0 and e.global_position.distance_to(player.global_position) < player.radius + e.radius:
			_start_combat(e)
			return
	for s in spots:
		if s.kind == "exit" and s.open and Rect2(s.pos - Vector2(tile, tile) / 2.0, Vector2(tile, tile)).has_point(player.global_position):
			load_map(s.data.ref)
			return
	_update_near_spot()


func _unhandled_input(event: InputEvent) -> void:
	if not _sleep_pick.is_empty():
		_sleep_picker_input(event)
		return
	if event.is_action_pressed("inventory") and not frozen:
		_open_inventory()
	elif not event.is_action_pressed("interact"):
		return
	elif %MessagePanel.visible and not %DeathPanel.visible:
		close_message()
	elif not frozen and not _near_spot.is_empty():
		interact()
	else:
		return
	get_viewport().set_input_as_handled()


func _update_near_spot() -> void:
	var best := {}
	var best_d := INF
	for s in spots + npcs.filter(func(n): return n.active):
		var d: float = s.pos.distance_to(player.global_position)
		if d <= INTERACT_RANGE * tile and d < best_d:
			best = s
			best_d = d
	if best != _near_spot:
		_near_spot = best
		%Prompt.visible = not best.is_empty()
		if not best.is_empty():
			var verb: String = {"npc": "대화", "camp": "거점", "exit": "문 열기", "spot": "조사"}[best.kind]
			var extra := "  (조사함)" if best.kind == "spot" and best.done else ""
			if best.kind == "exit" and best.open:
				verb = "문 닫기"
				extra = "   —   열린 문으로 걸어가면 나감"
			%Prompt.text = "[E / Space]  %s: %s%s" % [verb, best.data.name, extra]


# ---------------------------------------------------------------- 상호작용
func interact() -> void:
	if _near_spot.is_empty():
		return
	var s := _near_spot
	match s.kind:
		"npc": _start_dialogue(s)
		"camp": _open_camp()
		"exit": toggle_door(s)
		"spot": await _investigate(s)


## 조사: 텍스트 + (처음 한 번) Loot 굴림. 시간은 Loot 의 time_cost 만큼 흐른다.
func _investigate(s: Dictionary) -> void:
	frozen = true
	var lines := PackedStringArray([s.data.text])
	if not s.done and s.data.ref != "":
		var got := await _run_effects("loot:" + s.data.ref)
		lines.append("")
		lines.append_array(got)
	s.done = true
	GameState.field_mark(map.map_id, "done", s.data.object_id)
	%MapView.queue_redraw()
	_near_spot = {}
	show_message("\n".join(lines))


## StoryRunner 로 효과를 실행하고 그동안 나온 메시지를 돌려준다 (가득 차면 버릴 칸 고르기 포함)
func _run_effects(text: String) -> PackedStringArray:
	_collecting = true
	_collected = []
	await StoryRunner.run_effects(text)
	_collecting = false
	return _collected


func _on_story_message(text: String) -> void:
	if _dialogue_ui != null or _combat_ui != null:   # 대화·전투 화면이 직접 보여준다
		return
	if _collecting:
		_collected.append(text)
	else:
		_toast(text)


func _on_inventory_full(item_id: String, amount: int) -> void:
	if _dialogue_ui == null:
		%Inventory.open_discard(item_id, amount)


func _open_inventory() -> void:
	if not frozen:
		%Inventory.open_browse()


func _set_frozen_by_overlay() -> void:
	if %Inventory.visible:
		frozen = true
	elif not _collecting and not %MessagePanel.visible and not %CampPanel.visible and _combat_ui == null and _dialogue_ui == null:
		frozen = false


func show_message(text: String) -> void:
	%Message.text = text
	%MessagePanel.visible = true
	%Prompt.visible = false
	frozen = true


func close_message() -> void:
	%MessagePanel.visible = false
	frozen = false


func _toast(text: String) -> void:
	%Toast.text = text if not %Toast.visible else "%s\n%s" % [%Toast.text, text]
	%Toast.visible = true
	_toast_t = TOAST_TIME


# ---------------------------------------------------------------- 베이스캠프 (§12)
func _open_camp() -> void:
	frozen = true
	%Prompt.visible = false
	%CampResult.text = ""
	_build_camp_buttons()
	%CampPanel.visible = true


func _build_camp_buttons() -> void:
	for c in %CampActions.get_children():
		%CampActions.remove_child(c)
		c.queue_free()
	for a in DataLoader.camp_actions:
		var b := ChoiceButton.new()
		var mins := int(a.minutes)
		var dur := "" if mins == 0 else ("  (%d시간%s)" % [mins / 60, "" if mins % 60 == 0 else " %d분" % (mins % 60)] if mins >= 60 else "  (%d분)" % mins)
		b.text = a.name + ("  (1시간 단위)" if a.kind == "sleep" else dur)
		b.disabled = not Expr.evaluate(a.condition, GameState)
		b.pressed.connect(_do_camp_action.bind(a))
		%CampActions.add_child(b)


func _do_camp_action(a: Dictionary) -> void:
	if a.kind == "sleep":
		_show_sleep_picker(a)
		return
	GameState.advance_time(float(a.minutes))
	var got := await _run_effects(a.effects)
	%CampResult.text = "%s 완료.%s" % [a.name, "" if got.is_empty() else "  " + "  ·  ".join(got)]
	_build_camp_buttons()


## 잠: 1시간 단위로 고른다
func _show_sleep_picker(a: Dictionary) -> void:
	for c in %CampActions.get_children():
		%CampActions.remove_child(c)
		c.queue_free()
	var max_h := DataLoader.get_config_int("sleep_max_hours", 12)
	_sleep_pick = {"action": a, "hours": clampi(DataLoader.get_config_int("sleep_default_hours", 8), 1, max_h)}
	var q := Label.new()
	q.text = "몇 시간 잘까?"
	%CampActions.add_child(q)
	# ◀  8시간  ▶
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 27)
	row.add_child(_picker_button("◀", _change_sleep.bind(-1), 90))
	_sleep_value = Label.new()
	_sleep_value.custom_minimum_size.x = 260
	_sleep_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_sleep_value.add_theme_font_size_override("font_size", 53)
	row.add_child(_sleep_value)
	row.add_child(_picker_button("▶", _change_sleep.bind(1), 90))
	%CampActions.add_child(row)
	_sleep_wake = Label.new()
	_sleep_wake.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_sleep_wake.add_theme_color_override("font_color", Color("bbbbbb"))
	%CampActions.add_child(_sleep_wake)
	var hint := Label.new()
	hint.text = "← → 시간 조절    E / Space 잠들기    Esc 취소"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 22)
	hint.add_theme_color_override("font_color", Color("888888"))
	%CampActions.add_child(hint)
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 13)
	var go := _picker_button("잠들기", _confirm_sleep, 0)
	go.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var cancel := _picker_button("취소", _cancel_sleep, 0)
	cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buttons.add_child(go)
	buttons.add_child(cancel)
	%CampActions.add_child(buttons)
	_refresh_sleep_picker()


func _picker_button(text: String, on_press: Callable, width: int) -> Button:
	var b := ChoiceButton.new()
	b.text = text
	b.alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.focus_mode = Control.FOCUS_NONE   # Space/Enter 는 _sleep_picker_input 이 받는다
	if width > 0:
		b.custom_minimum_size.x = width
	b.pressed.connect(on_press)
	return b


## 잠잘 시간 고르는 중의 키 입력: ← → (A D, 패드 좌우) 조절, E/Space/Enter 잠들기, Esc 취소
func _sleep_picker_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_left", true) or event.is_action_pressed("move_left", true):
		_change_sleep(-1)
	elif event.is_action_pressed("ui_right", true) or event.is_action_pressed("move_right", true):
		_change_sleep(1)
	elif event.is_action_pressed("interact") or event.is_action_pressed("ui_accept"):
		_confirm_sleep()
	elif event.is_action_pressed("ui_cancel"):
		_cancel_sleep()
	else:
		return
	get_viewport().set_input_as_handled()


func _change_sleep(delta: int) -> void:
	if _sleep_pick.is_empty():
		return
	_sleep_pick.hours = clampi(_sleep_pick.hours + delta, 1, DataLoader.get_config_int("sleep_max_hours", 12))
	_refresh_sleep_picker()


func _refresh_sleep_picker() -> void:
	var h: int = _sleep_pick.hours
	_sleep_value.text = "%d시간" % h
	var wake := GameState.clock + h * 60.0
	_sleep_wake.text = "%d일차 %02d:%02d 에 일어남" % [int(wake / 1440.0) + 1, (int(wake) % 1440) / 60, int(wake) % 60]


func _confirm_sleep() -> void:
	if _sleep_pick.is_empty():
		return
	var a: Dictionary = _sleep_pick.action
	var h: int = _sleep_pick.hours
	_sleep_pick = {}
	await sleep_hours(a, h)


func _cancel_sleep() -> void:
	_sleep_pick = {}
	_build_camp_buttons()


## hours 시간 잔다: 1시간마다 시간이 흐르고 effects 적용. 자고 나면 슬롯을 골라 저장 (베이스캠프 §13).
func sleep_hours(a: Dictionary, hours: int) -> void:
	for i in hours:
		GameState.advance_time(60)
		await _run_effects(a.effects)
	var result := "%d시간 잤다.  %d일차 %s" % [hours, GameState.day(), GameState.clock_text()]
	%CampResult.text = result
	if SaveManager.can_save_run():
		var slot := await ask_save_slot()
		if slot > 0:
			SaveManager.save_run(slot)
			result += "  —  슬롯 %d 에 저장했다." % slot
		else:
			result += "  —  저장하지 않았다."
	%CampResult.text = result
	_build_camp_buttons()


## 저장 슬롯 선택 창을 (대화 화면 위에도) 띄우고 고른 슬롯을 돌려준다. -1 = 저장 안 함
func ask_save_slot() -> int:
	var picker := SlotPicker.new()
	%Overlay.add_child(picker)
	picker.open("save")
	var slot: int = await picker.chosen
	picker.queue_free()
	return slot


## 대화 효과 save (고양이 등): 슬롯을 골라 StoryRunner 에 돌려준다
func _on_save_slot_requested() -> void:
	StoryRunner.choose_save_slot(await ask_save_slot())


func _close_camp() -> void:
	_sleep_pick = {}
	%CampPanel.visible = false
	frozen = false


# ---------------------------------------------------------------- NPC 대화
func _start_dialogue(npc: Dictionary) -> void:
	frozen = true
	%Prompt.visible = false
	_near_spot = {}
	_dialogue_ui = DialogueScene.instantiate()
	_dialogue_ui.embedded = true
	_dialogue_ui.finished.connect(_on_dialogue_finished)
	%Overlay.add_child(_dialogue_ui)
	StoryRunner.start_dialogue(npc.data.ref)


func _on_dialogue_finished() -> void:
	_dialogue_ui.queue_free()
	_dialogue_ui = null
	StoryRunner.enter_field()
	frozen = false
	_update_hud()


# ---------------------------------------------------------------- 전투
func _start_combat(enemy: Node) -> void:
	frozen = true
	_combat_enemy = enemy
	_open_combat(enemy.data.ref)


## 대화 선택지 type=combat: 대화를 숨기고 전투, 끝나면 결과를 StoryRunner 에 돌려준다 (이기거나 도주하면 대화 계속)
func _on_dialogue_combat(enemy_id: String) -> void:
	frozen = true
	_combat_from_dialogue = true
	if _dialogue_ui != null:
		_dialogue_ui.visible = false
	_open_combat(enemy_id)


func _open_combat(enemy_id: String) -> void:
	%Prompt.visible = false
	_combat_ui = CombatScene.instantiate()
	_combat_ui.embedded = true
	_combat_ui.enemy_id_override = enemy_id
	_combat_ui.player_state = GameState.player_body
	_combat_ui.finished.connect(_on_combat_finished)
	%Overlay.add_child(_combat_ui)


func _on_combat_finished(outcome: String) -> void:
	GameState.player_body = _combat_ui.combat.player_parts.duplicate(true)
	_combat_ui.queue_free()
	_combat_ui = null
	_update_hud()
	if _combat_from_dialogue:
		_combat_from_dialogue = false
		if outcome == "win" or outcome == "fled":
			_dialogue_ui.visible = true
			StoryRunner.finish_combat(outcome)
		else:
			StoryRunner.finish_combat("lose")
			_dialogue_ui.queue_free()
			_dialogue_ui = null
			_on_death()
		return
	match outcome:
		"win":
			GameState.field_mark(map.map_id, "removed", _combat_enemy.data.object_id)
			enemies.erase(_combat_enemy)
			_combat_enemy.queue_free()
			frozen = false
		"fled":
			_combat_enemy.grace = float(DataLoader.config.get("field_flee_grace", 3))
			_combat_enemy.state = "return"
			frozen = false
		_:
			_on_death()
	_combat_enemy = null


## 사망 (§11): 부활 수단(초월체·아이템)이 있으면 모두 유지한 채 베이스캠프에서 깨어나고, 없으면 게임 처음부터.
## TODO: 사망·부활 연출 (지금은 패널 하나)
func _on_death() -> void:
	frozen = true
	var revival := GameState.find_revival()
	if revival.is_empty():
		SaveManager.end_run()
		%DeathMessage.text = ""
		%NewRunButton.text = "처음부터"
		_death_revival = {}
	else:
		await _run_effects(revival.effects)   # 예: 부활 아이템 소모, 보호 플래그 해제
		%DeathMessage.text = revival.text
		%NewRunButton.text = "깨어난다"
		_death_revival = revival
	%DeathPanel.visible = true


func _new_run() -> void:
	%DeathPanel.visible = false
	if _death_revival.is_empty():
		SaveManager.begin_run()
	else:
		SaveManager.revive_run()
		_death_revival = {}
	load_map(GameState.current_map)


# ---------------------------------------------------------------- HUD
func _update_hud() -> void:
	var parts := PackedStringArray()
	for p in DataLoader.survival:
		var v := GameState.get_survival(p.param_id)
		var col := "#e46a6a" if v <= float(p.warn) else "#bbbbbb"
		parts.append("[color=%s]%s %d[/color]" % [col, p.name, roundi(v)])
	%Status.text = "[color=#eeeeee]%d일차 %s[/color]   [color=#888888]·  %d회차[/color]      %s" % [
		GameState.day(), GameState.clock_text(), GameState.run_count, "   ".join(parts)]
	var hurt := PackedStringArray()
	for p in GameState.player_body.values():
		if p.broken:
			hurt.append("%s 절단" % p.name if not p.vital else "%s 파괴" % p.name)
		elif p.hp < p.max_hp:
			hurt.append("%s %d/%d" % [p.name, p.hp, p.max_hp])
	%Body.text = "부상: " + ("없음" if hurt.is_empty() else "  ·  ".join(hurt))
	%InventoryButton.text = "소지품 %d/%d" % [GameState.inventory.size(), GameState.slot_count()]
