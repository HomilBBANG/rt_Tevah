extends Node2D
## 탑뷰 탐험 필드 (기획서 §4–6, §11–13). 맵은 data/maps.json (tools/maps/*.txt + FieldObjects 시트).
##
## - 이동 중 게임 시계가 실시간으로 흐르고 생존 파라미터가 줄어든다 (전투·대화·메뉴 중에는 멈춤).
## - 적과 닿으면 턴제 전투(화면 위에 겹쳐 띄움) → 승리: 적 제거 / 도주: 잠시 유예 / 사망: 회차 종료
## - NPC 에게 말을 걸면 대화 화면(scenes/main_play)을 겹쳐 띄우고 필드 대화 진행, EXIT 에서 복귀.
## - 베이스캠프 거점(camp)에서 식사·위생·잠(1시간 단위, 자고 나면 저장). 출구(exit)로 맵 이동.
## - 저장은 베이스캠프에서만: 고양이가 와 있으면 고양이에게(대화 효과 save), 없으면 잠을 자야 저장된다.
## 회차 상태(시계·생존·몸·처치한 적·조사한 곳·소지품)는 GameState 에 있고, 베이스캠프에서만 저장된다.
##
## TODO(기획 미확정): 생존 파라미터가 낮을 때의 효과(§5), 탐험 중 종료 처리(§13.2 — 지금은 마지막 저장에서 이어짐),
##                    사망·부활 연출(§11)

const InputActions = preload("res://core/input_actions.gd")
const Expr = preload("res://core/expr.gd")
const CombatScene = preload("res://scenes/combat.tscn")
const DialogueScene = preload("res://scenes/main_play.tscn")
const ChoiceButton = preload("res://ui/choice_button.gd")
const NpcScript = preload("res://scenes/field/field_npc.gd")
const PlayerScript = preload("res://scenes/field/field_player.gd")
const EnemyScript = preload("res://scenes/field/field_enemy.gd")

const WALL_LAYER := 1
const ACTOR_LAYER := 2
const NPC_LAYER := 4
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
var npcs: Array = []             # NPC [{ kind: "npc", data, pos, node }]

var _combat_ui: Node
var _dialogue_ui: Node
var _combat_enemy: Node
var _near_spot := {}
var _collecting := false         # StoryRunner 메시지를 모으는 중 (조사·거점 행동)
var _collected: PackedStringArray = []
var _toast_t := 0.0


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
	GameState.survival_changed.connect(_update_hud)
	GameState.clock_changed.connect(_update_hud)
	GameState.inventory_changed.connect(_update_hud)
	%TitleButton.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/title.tscn"))
	%InventoryButton.pressed.connect(_open_inventory)
	%NewRunButton.pressed.connect(_new_run)
	%CampClose.pressed.connect(_close_camp)
	%Inventory.visibility_changed.connect(func(): _set_frozen_by_overlay())
	load_map(GameState.current_map)


func _exit_tree() -> void:
	for pair in [[StoryRunner.message, _on_story_message], [StoryRunner.inventory_full, _on_inventory_full]]:
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
			if row[x] != "#":
				x += 1
				continue
			var start := x
			while x < row.length() and row[x] == "#":
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
	player.collision_mask = WALL_LAYER | NPC_LAYER
	player.position = _tile_center(map.start[0], map.start[1])
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
		# 조건이 맞을 때만 나타나는 물체 (예: 베이스캠프에 찾아온 고양이)
		# TODO(기획 확인): 고양이가 오는 조건(시간대·날짜·확률 등)은 미정 — FieldObjects.condition 으로 조정
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
				e.collision_mask = WALL_LAYER
				e.position = pos
				e.setup_patrol(pos, dirs.get(o.patrol_dir, Vector2.ZERO) * tile, int(o.patrol_len))
				_add_circle_shape(e, e.radius * 0.8)
				%World.add_child(e)
				enemies.append(e)
			"investigate", "camp", "exit":
				var kind: String = "spot" if o.type == "investigate" else o.type
				spots.append({"kind": kind, "data": o, "pos": pos,
					"done": GameState.field_has(map.map_id, "done", o.object_id)})
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
				npcs.append({"kind": "npc", "data": o, "pos": pos, "node": n})


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
	_update_near_spot()


func _unhandled_input(event: InputEvent) -> void:
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
	for s in spots + npcs:
		var d: float = s.pos.distance_to(player.global_position)
		if d <= INTERACT_RANGE * tile and d < best_d:
			best = s
			best_d = d
	if best != _near_spot:
		_near_spot = best
		%Prompt.visible = not best.is_empty()
		if not best.is_empty():
			var verb: String = {"npc": "대화", "camp": "거점", "exit": "이동", "spot": "조사"}[best.kind]
			%Prompt.text = "[E / Space]  %s: %s%s" % [verb, best.data.name, "  (조사함)" if best.kind == "spot" and best.done else ""]


# ---------------------------------------------------------------- 상호작용
func interact() -> void:
	if _near_spot.is_empty():
		return
	var s := _near_spot
	match s.kind:
		"npc": _start_dialogue(s)
		"camp": _open_camp()
		"exit": load_map(s.data.ref)
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
	if _dialogue_ui != null:
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
		b.text = a.name + dur
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
	var q := Label.new()
	q.text = "몇 시간 잘까?  (지금 %d일차 %s)" % [GameState.day(), GameState.clock_text()]
	%CampActions.add_child(q)
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	for h in range(1, DataLoader.get_config_int("sleep_max_hours", 12) + 1):
		var b := ChoiceButton.new()
		b.text = "%d시간" % h
		b.alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(sleep_hours.bind(a, h))
		grid.add_child(b)
	%CampActions.add_child(grid)
	var cancel := ChoiceButton.new()
	cancel.text = "취소"
	cancel.pressed.connect(_build_camp_buttons)
	%CampActions.add_child(cancel)


## hours 시간 잔다: 1시간마다 시간이 흐르고 effects 적용. 자고 나면 저장 (베이스캠프 §13).
## TODO(기획 확인): 고양이가 있어도 잠으로 저장되게 둠 (고양이는 잠 없이 저장하는 추가 수단).
func sleep_hours(a: Dictionary, hours: int) -> void:
	for i in hours:
		GameState.advance_time(60)
		await _run_effects(a.effects)
	var result := "%d시간 잤다.  %d일차 %s" % [hours, GameState.day(), GameState.clock_text()]
	if SaveManager.can_save_run():
		SaveManager.save_run()
		result += "  —  저장했다."
	%CampResult.text = result
	_build_camp_buttons()


func _close_camp() -> void:
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
	%Prompt.visible = false
	_combat_ui = CombatScene.instantiate()
	_combat_ui.embedded = true
	_combat_ui.enemy_id_override = enemy.data.ref
	_combat_ui.player_state = GameState.player_body
	_combat_ui.finished.connect(_on_combat_finished)
	%Overlay.add_child(_combat_ui)


func _on_combat_finished(outcome: String) -> void:
	GameState.player_body = _combat_ui.combat.player_parts.duplicate(true)
	_combat_ui.queue_free()
	_combat_ui = null
	_update_hud()
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
			# 사망: 회차 종료. 저장은 지워져 되돌릴 수 없다 (§11, §13). TODO: 사망·부활 연출
			SaveManager.end_run()
			%DeathText.text = "사망\n%d번째 회차가 끝났다." % GameState.run_count
			%DeathPanel.visible = true
	_combat_enemy = null


func _new_run() -> void:
	SaveManager.begin_run()
	%DeathPanel.visible = false
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
