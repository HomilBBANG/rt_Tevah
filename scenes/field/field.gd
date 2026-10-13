extends Node2D
## 탑뷰 탐험 필드 (기획서 §6, §17.2 2단계). 맵은 data/maps.json (tools/maps/*.txt + FieldObjects 시트).
##
## 이동 → 적과 닿으면 턴제 전투(화면 위에 겹쳐 띄움) → 승리: 적 제거 / 도주: 잠시 유예 / 사망: 처음부터
## NPC 에게 말을 걸면 대화 화면(scenes/main_play)을 겹쳐 띄우고 필드 대화를 진행, EXIT 에서 복귀.
## 플레이어 신체 상태(부상·절단)는 전투 사이에 이어진다 (한 회차 동안).
##
## TODO(다음 단계): 시간 흐름(§4), 생존 파라미터(§5), 맵 이동, 베이스캠프·회차 저장(§11–13)

const Combat = preload("res://core/combat/combat.gd")
const InputActions = preload("res://core/input_actions.gd")
const CombatScene = preload("res://scenes/combat.tscn")
const DialogueScene = preload("res://scenes/main_play.tscn")
const NpcScript = preload("res://scenes/field/field_npc.gd")
const PlayerScript = preload("res://scenes/field/field_player.gd")
const EnemyScript = preload("res://scenes/field/field_enemy.gd")

const WALL_LAYER := 1
const ACTOR_LAYER := 2
const NPC_LAYER := 4
const INTERACT_RANGE := 1.1      # 칸

## 다음에 열 맵 (비어 있으면 첫 번째 맵)
static var next_map_id := ""

var map := {}
var tile := 48.0
var frozen := false
var player: CharacterBody2D
var enemies: Array = []
var spots: Array = []            # 조사 지점 [{ kind: "spot", data, pos, done }]
var npcs: Array = []             # NPC [{ kind: "npc", data, pos, node }]
var player_body := {}            # 전투 사이에 이어지는 부위 상태

var _combat_ui: Node
var _dialogue_ui: Node
var _combat_enemy: Node
var _near_spot := {}


func _ready() -> void:
	InputActions.ensure()
	GameState.reset_run()
	player_body = Combat.fresh_player_parts()
	var map_id: String = next_map_id
	if map_id == "" and not DataLoader.map_order.is_empty():
		map_id = DataLoader.map_order[0]
	map = DataLoader.maps.get(map_id, {})
	if map.is_empty():
		%Message.text = "[오류] 맵 데이터가 없습니다. tools/xlsx_to_json.py 를 실행했는지 확인하세요."
		%MessagePanel.visible = true
		frozen = true
		return
	tile = float(DataLoader.config.get("field_tile", 48))
	_build_walls()
	_build_actors()
	%MapView.tiles = map.tiles
	%MapView.tile = tile
	%MapView.spots = spots
	%MapView.queue_redraw()
	%TitleButton.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/title.tscn"))
	%RestartButton.pressed.connect(func(): get_tree().reload_current_scene())
	GameState.inventory_changed.connect(_update_hud)
	_update_hud()


# ---------------------------------------------------------------- 맵 만들기
func _build_walls() -> void:
	var body := StaticBody2D.new()
	body.collision_layer = WALL_LAYER
	body.collision_mask = 0
	add_child(body)
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
	add_child(player)

	var dirs := {"up": Vector2.UP, "down": Vector2.DOWN, "left": Vector2.LEFT, "right": Vector2.RIGHT}
	for o in map.objects:
		var pos := _tile_center(o.x, o.y)
		match o.type:
			"enemy":
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
				add_child(e)
				enemies.append(e)
			"investigate":
				spots.append({"kind": "spot", "data": o, "pos": pos, "done": false})
			"npc":
				var n := StaticBody2D.new()
				n.set_script(NpcScript)
				n.radius = tile * 0.3
				n.display_name = o.name
				n.collision_layer = NPC_LAYER
				n.collision_mask = 0
				n.position = pos
				_add_circle_shape(n, n.radius)
				add_child(n)
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
func _physics_process(_delta: float) -> void:
	if frozen or player == null:
		return
	for e in enemies:
		if e.grace == 0.0 and e.global_position.distance_to(player.global_position) < player.radius + e.radius:
			_start_combat(e)
			return
	_update_near_spot()


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("interact"):
		return
	if %MessagePanel.visible and not %DeathPanel.visible:
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
		if best.is_empty():
			pass
		elif best.kind == "npc":
			%Prompt.text = "[E / Space]  대화: %s" % best.data.name
		else:
			%Prompt.text = "[E / Space]  조사: %s%s" % [best.data.name, "  (조사함)" if best.done else ""]


# ---------------------------------------------------------------- 조사
## 가까운 조사 지점 조사(아이템은 처음 한 번만) 또는 NPC 대화.
func interact() -> void:
	if _near_spot.is_empty():
		return
	if _near_spot.kind == "npc":
		_start_dialogue(_near_spot)
		return
	var s := _near_spot
	var lines := PackedStringArray([s.data.text])
	if not s.done and s.data.ref != "":
		lines.append("")
		lines.append_array(_roll_loot(s.data.ref))
	s.done = true
	%MapView.queue_redraw()
	_near_spot = {}
	show_message("\n".join(lines))


## TODO(기획 확인): 인벤토리가 가득 차면 지금은 남는 아이템을 두고 온다 (버릴 아이템 고르기는 대화 화면에만 있음).
## TODO: Loot 의 time_cost 는 시간 시스템(§4)이 들어오면 적용.
func _roll_loot(spot_id: String) -> PackedStringArray:
	var out := PackedStringArray()
	for r in DataLoader.loot_by_spot.get(spot_id, []):
		if randf() * 100.0 < float(r.chance):
			var left := GameState.add_item(r.item_id, r.amount)
			if r.amount - left > 0:
				out.append("획득: %s x%d" % [DataLoader.item_name(r.item_id), r.amount - left])
			if left > 0:
				out.append("소지품이 가득 차 %s x%d 을(를) 두고 왔다." % [DataLoader.item_name(r.item_id), left])
	if out.is_empty():
		out.append("아무것도 찾지 못했다.")
	return out


func show_message(text: String) -> void:
	%Message.text = text
	%MessagePanel.visible = true
	%Prompt.visible = false
	frozen = true


func close_message() -> void:
	%MessagePanel.visible = false
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
	_combat_ui.player_state = player_body
	_combat_ui.finished.connect(_on_combat_finished)
	%Overlay.add_child(_combat_ui)


func _on_combat_finished(outcome: String) -> void:
	player_body = _combat_ui.combat.player_parts.duplicate(true)
	_combat_ui.queue_free()
	_combat_ui = null
	_update_hud()
	match outcome:
		"win":
			enemies.erase(_combat_enemy)
			_combat_enemy.queue_free()
			frozen = false
		"fled":
			_combat_enemy.grace = float(DataLoader.config.get("field_flee_grace", 3))
			_combat_enemy.state = "return"
			frozen = false
		_:
			# TODO(기획 §11): 회차 종료·부활 연출. 지금은 맵 처음부터 다시.
			%DeathPanel.visible = true
	_combat_enemy = null


# ---------------------------------------------------------------- HUD
func _update_hud() -> void:
	var hurt := PackedStringArray()
	for p in player_body.values():
		if p.broken:
			hurt.append("%s 절단" % p.name if not p.vital else "%s 파괴" % p.name)
		elif p.hp < p.max_hp:
			hurt.append("%s %d/%d" % [p.name, p.hp, p.max_hp])
	%Body.text = "부상: " + ("없음" if hurt.is_empty() else "  ·  ".join(hurt))
	%Items.text = "소지품 %d/%d" % [GameState.inventory.size(), GameState.slot_count()]
