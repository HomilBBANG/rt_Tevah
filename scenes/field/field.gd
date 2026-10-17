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
##   나타나는 조건(condition)도 플래그·소지품이 바뀌면 바로 다시 본다 (컷신 중에 플래그를 켜서 NPC 를 등장시키기).
## - 이벤트 칸(event): 밟으면 대화(컷신) 시작. once = 한 번만 (조사한 곳처럼 회차 상태에 기록).
## - 🎬 연출 카드의 필드 단계(walk·camera·vanish·shake)는 여기서 실행 (StoryRunner.field_director = _direct_step).
##   대화 중이므로 플레이어는 조작할 수 없다.
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
const Direction = preload("res://core/direction.gd")
const MapRenderer = preload("res://core/map_renderer.gd")
const VisualData = preload("res://core/visual_data.gd")
const Triggers = preload("res://core/cutscene_triggers.gd")
const AIAssets = preload("res://core/ai/ai_assets.gd")
const DOOR_LAYER := 8            # 닫힌 문: 플레이어·적 모두 통과 못 하고, 적의 시야도 막는다 (field_enemy._can_see)
const INTERACT_RANGE := 1.1      # 칸
const TOAST_TIME := 3.0

## 테스트·디버그용: 비어 있지 않으면 이 맵으로 시작
static var next_map_id := ""

var map := {}
var tile := 48.0
var frozen := false
var events: Array = []          # 이벤트 칸 [{kind:"event", data, pos, tile, done}] — 화면에 안 보임
var _last_tile := Vector2i(-999, -999)   # 이벤트 칸은 '들어설 때' 한 번
var _cam_target: Vector2i = Vector2i(-1, -1)
var _active_tweens: Array = []
var renderer: Node2D             # core/map_renderer.gd — 픽셀아트 타일·조명·그림자 (보이는 모습만)
var _cutscenes: Array = []       # 차례를 기다리는 자동 시작 컷신 (시작 노드) — 새 게임 시작 후, 방 진입 후
var held_light: PointLight2D     # 손에 든 아이템의 빛 (Items.light, 예: 손전등) — 플레이어를 따라가며 바라보는 쪽을 비춤   # 연출 중인 걷기·카메라 (건너뛰기 때 바로 끝냄)
var player: CharacterBody2D
var enemies: Array = []
var spots: Array = []            # 상호작용 지점 [{ kind: "spot"/"camp"/"exit", data, pos, done }]
var npcs: Array = []             # NPC [{ kind: "npc", data, pos, node, active }] — active: 지금 시간대에 있음
var _path_grid: AStarGrid2D      # 벽을 돌아가는 길 찾기 (맵마다 한 번 만듦 — 컷신 걷기·BT 몬스터 이동)
var _arrive_tile := Vector2i.ZERO  # 이 맵에 들어온 칸 (쫓아오는 몬스터가 여기로 들어옴)
var _roof_open := -1             # 지금 열린(플레이어가 아래에 있는) 지붕 묶음
var _follow_queue: Array = []    # 따라 들어올 몬스터 [{data, left(초)}] — Config ai_follow_delay
var _noise_t := 0.0              # 달리는 소리 간격
var ai_paused := false           # 디버거 일시정지 (몬스터만 멈춤)
var ai_stepping := false         # 디버거 '한 단계': 이번 물리 프레임만 진행
var _ai_step_pending := false
var _ai_breakpoints := {}        # 디버거 브레이크포인트 {bt_id: [node id]} (새로 생기는 몬스터에도)

var _combat_ui: Node
var _dialogue_ui: Node
var _combat_enemy: Node
var _combat_group: Array = []    # 함께 싸우는 맵 위 적들 (첫 번째 = 닿은 적, 나머지 = 쫓아오던 몬스터, 최대 Config combat_max_enemies)
var _combat_from_dialogue := false   # 대화 선택지(type=combat)로 시작한 전투
var _near_spot := {}
var _collecting := false         # StoryRunner 메시지를 모으는 중 (조사·거점 행동)
var _collected: PackedStringArray = []
var _toast_t := 0.0
var ai_debug := false            # F9: BT 몬스터 머리 위에 지금 Task 표시 (개발용)
var _ai_send_t := 0.0            # 몬스터 AI 디버거로 상태 보내기 (Godot 에서 실행했을 때만)
const AI_SEND_INTERVAL := 0.25
var _death_revival := {}        # 사망 패널: 적용된 부활 규칙 (비면 처음부터)
var _combat_enemy_name := ""     # 지금 싸우는 상대 이름 (사망 문구 {enemy})
var _sleep_pick := {}            # 잠잘 시간 고르는 중: { action, hours }
var _pending_travel := []          # 대화 중 move 효과 → 대화가 끝나면 [map_id, arrive]
var _travel_lock := Vector2i(-999, -999)   # 도착한 칸: 한 번 벗어나기 전에는 통로·가장자리가 다시 작동하지 않음
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
	StoryRunner.travel_requested.connect(_on_travel_requested)
	GameState.survival_changed.connect(_update_hud)
	GameState.clock_changed.connect(_update_hud)
	GameState.clock_changed.connect(_refresh_presence)
	GameState.clock_changed.connect(func(): if renderer: renderer.set_time(GameState.minute_of_day()))   # 시계가 멈추면 빛도 멈춤
	GameState.flags_changed.connect(_refresh_presence)
	GameState.inventory_changed.connect(_refresh_presence)
	StoryRunner.field_director = _direct_step
	%World.y_sort_enabled = true   # 인물·오브젝트 그림: 아래(발)에 있을수록 앞
	GameState.equipment_changed.connect(_update_held_light)
	GameState.inventory_changed.connect(_update_hud)
	GameState.body_changed.connect(_update_hud)
	%TitleButton.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/title.tscn"))
	%InventoryButton.pressed.connect(_open_inventory)
	%NewRunButton.pressed.connect(_new_run)
	%CampClose.pressed.connect(_close_camp)
	%Inventory.dock = "right"   # 장비창(왼쪽)과 같이 열어 끌어다 놓기
	%Inventory.visibility_changed.connect(func(): _set_frozen_by_overlay())
	%Equipment.visibility_changed.connect(func(): _set_frozen_by_overlay())
	GameState.equipment_changed.connect(_update_hud)
	load_map(GameState.current_map)
	# 새 게임(캐릭터 생성 직후): 자동 시작 '새 게임 시작 후' (+ 예전 방식 Config opening_dialogue) — 방 진입 컷신보다 먼저
	if GameState.opening_pending:
		GameState.opening_pending = false
		var first := []
		var opening := DataLoader.get_config_str("opening_dialogue", "")
		if opening != "" and DataLoader.nodes.has(opening):
			first.append(opening)
		for id in Triggers.take("new_game"):
			if not id in first:
				first.append(id)
		_cutscenes = first + _cutscenes


func _exit_tree() -> void:
	if EngineDebugger.has_capture("monster_ai"):
		EngineDebugger.unregister_message_capture("monster_ai")
	for pair in [[StoryRunner.message, _on_story_message], [StoryRunner.inventory_full, _on_inventory_full],
			[StoryRunner.save_slot_requested, _on_save_slot_requested], [StoryRunner.combat_requested, _on_dialogue_combat],
			[StoryRunner.travel_requested, _on_travel_requested]]:
		if pair[0].is_connected(pair[1]):
			pair[0].disconnect(pair[1])
	if StoryRunner.field_director == Callable(self, "_direct_step"):
		StoryRunner.field_director = Callable()


# ---------------------------------------------------------------- 맵 만들기
## 맵을 (다시) 만든다. 처치한 적·조사한 곳은 GameState.field_state 에서 빠진다.
func load_map(map_id: String) -> void:
	# 바로 빼낸다: queue_free 만 하면 이전 맵의 벽이 한 프레임 남아, 그 자리에 도착한 플레이어를 밀어낸다
	for c in %World.get_children():
		%World.remove_child(c)
		c.queue_free()
	enemies.clear()
	spots.clear()
	npcs.clear()
	events.clear()
	_path_grid = null
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
	_spawn_followers()
	# 그림·조명: 맨 아래에 (그 위에 조사·문 표시, 인물)
	if renderer == null:
		renderer = MapRenderer.new()
		renderer.name = "MapRenderer"
		add_child(renderer)
		move_child(renderer, 0)
	renderer.minutes = GameState.minute_of_day()
	renderer.build(map, tile)
	renderer.build_props(%World)   # 오브젝트 그림은 인물과 같은 Y 정렬 노드에 (발 위치로 앞뒤)
	for s in spots:   # 이미 조사한 곳은 반짝이 없음
		if s.kind == "spot" and s.done:
			renderer.set_spot_done(s.data.object_id, true)
	%MapView.art_ids = renderer.markers
	_roof_open = -1
	_update_roof(true)
	_update_held_light()
	# 자동 시작 '방 진입 후' (이 맵): 지금 대화가 끝나면 차례로
	_cutscenes.append_array(Triggers.take("map_enter", map_id))
	_play_cutscenes.call_deferred()
	%MapView.draw_tiles = false   # 바닥·벽은 renderer 가 그림
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
	# 지나갈 수 없는 오브젝트 (graphics.xlsx Props.solid — 나무 줄기·상자·탁자): 벽처럼 막고 적 시야도 가림
	for c in VisualData.solid_cells(map):
		var shape := CollisionShape2D.new()
		var rect := RectangleShape2D.new()
		rect.size = Vector2(tile, tile)
		shape.shape = rect
		shape.position = _tile_center(c.x, c.y)
		body.add_child(shape)


func _build_actors() -> void:
	var cfg := func(key: String, default: float) -> float: return float(DataLoader.config.get(key, default)) * tile

	player = CharacterBody2D.new()
	player.set_script(PlayerScript)
	player.field = self
	player.radius = tile * 0.3
	# 이동 속도는 주인공(Player 시트)의 walk_speed·run_speed (칸/초)
	var me: Dictionary = DataLoader.characters.get(GameState.protagonist_id, {})
	player.speed = float(me.get("walk_speed", 4)) * tile
	player.run_speed = float(me.get("run_speed", me.get("walk_speed", 4))) * tile
	player.setup_sprite.call_deferred()   # 캐릭터 그림 (Config player_sprite)
	player.collision_layer = ACTOR_LAYER
	player.collision_mask = WALL_LAYER | NPC_LAYER | DOOR_LAYER
	# 새 회차는 맵 한복판(S)에서 깨어나고, 이동해 왔으면 고른 도착 지점(arrive), 그 밖에는 P
	var spawn: Array = map.get("run_start", map.start) if GameState.wake_at_run_start else map.start
	if not GameState.wake_at_run_start:
		# 출발 쪽에서 고른 도착 P(arrive) → 없으면 들어온 곳을 '이어지는 곳'(from)으로 고른 도착 P → 없으면 기본 P
		for o in map.objects:
			if o.type == "arrive" and ((GameState.arrive_at != "" and o.object_id == GameState.arrive_at)
					or (GameState.arrive_at == "" and GameState.arrive_from != "" and GameState.arrive_from in o.get("from", []))):
				spawn = [o.x, o.y]
	GameState.wake_at_run_start = false
	GameState.arrive_at = ""
	GameState.arrive_from = ""
	_travel_lock = Vector2i(int(spawn[0]), int(spawn[1]))
	_arrive_tile = _travel_lock
	player.position = _tile_center(spawn[0], spawn[1])
	_add_circle_shape(player, player.radius)
	var cam := Camera2D.new()
	cam.name = "Camera2D"   # 연출(_camera)이 찾는 이름
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
		# 조건이 맞을 때만 나타나는 물체 (시간대는 schedule 로 따로 — _refresh_presence).
		# NPC 는 만들어 두고 _refresh_presence 가 조건을 다시 본다, 이벤트는 밟을 때 본다
		if not o.type in ["npc", "event"] and o.get("condition", "") != "" and not Expr.evaluate(o.condition, GameState):
			continue
		var pos := _tile_center(o.x, o.y)
		match o.type:
			"enemy":
				if GameState.field_has(map.map_id, "removed", o.object_id) or GameState.field_has(map.map_id, "gone", o.object_id):
					continue   # 처치함 / 플레이어를 쫓아 다른 맵으로 떠남
				_spawn_enemy(o)
			"investigate", "camp", "exit", "passage", "transit":
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
				n.facing = Direction.DIR_VEC.get(o.get("face", ""), Vector2.DOWN)
				n.collision_layer = NPC_LAYER
				n.collision_mask = 0
				n.position = pos
				_add_circle_shape(n, n.radius)
				%World.add_child(n)
				npcs.append({"kind": "npc", "data": o, "pos": pos, "node": n, "active": true, "vanished": false})
			"event":
				events.append({"kind": "event", "data": o, "pos": pos, "tile": Vector2i(int(o.x), int(o.y)),
					"done": GameState.field_has(map.map_id, "done", o.object_id)})
	_refresh_presence()


## 시간대(schedule)에 맞춰 NPC 를 보이거나 숨긴다. 숨은 NPC 는 부딪히지도, 말을 걸 수도 없다.
func _refresh_presence() -> void:
	var minute := GameState.minute_of_day()
	for n in npcs:
		var cond: String = n.data.get("condition", "")
		var here: bool = in_schedule(n.data.get("schedule", []), minute) and not n.vanished \
			and (cond == "" or Expr.evaluate(cond, GameState))
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
	make_noise(s.pos, float(DataLoader.config.get("noise_door_radius", 5)))   # 문 여닫는 소리
	if renderer:
		renderer.set_door_open(s.data.object_id, s.open)   # 열린 문으로 빛이 지나감
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
	ai_stepping = _ai_step_pending   # 디버거 '한 단계' = 이번 프레임만 (몬스터는 필드 다음에 처리됨)
	_ai_step_pending = false
	_tick_followers(delta)
	# 소리: 달리면 일정 간격으로 (Config noise_run_radius 칸, noise_interval 초)
	if Input.is_action_pressed("run") and player.velocity.length() > 1.0:
		_noise_t -= delta
		if _noise_t <= 0.0:
			_noise_t = float(DataLoader.config.get("noise_interval", 0.3))
			make_noise(player.global_position, float(DataLoader.config.get("noise_run_radius", 6)))
	# 생존 수치 0(Survival death_cause)·효과 die: → 사망. 대화·메뉴 중이면 그것이 끝난 뒤 여기서
	var cause := GameState.death_cause_now()
	if cause != "":
		_on_death(cause)
		return
	for e in enemies:
		if e.grace == 0.0 and e.touch_battle() and e.global_position.distance_to(player.global_position) < player.radius + e.radius:
			_start_combat(e)
			return
	# 맵 이동: 열린 문·통로 칸에 들어서거나, 가장자리(edges)가 있는 쪽 맨 끝 칸에 닿으면
	var here := Vector2i(floori(player.global_position.x / tile), floori(player.global_position.y / tile))
	if here != _travel_lock:
		_travel_lock = Vector2i(-999, -999)
		for s in spots:
			if (s.kind == "passage" or (s.kind == "exit" and s.open)) \
					and Rect2(s.pos - Vector2(tile, tile) / 2.0, Vector2(tile, tile)).has_point(player.global_position):
				travel(s.data.ref, s.data.get("arrive", ""), s.data.object_id)
				return
		var edge := _edge_at(here)
		if not edge.is_empty():
			travel(edge.ref, edge.get("arrive", ""), "%s:%s" % [map.map_id, edge.dir])
			return
	if here != _last_tile:
		_last_tile = here
		if _try_event(here):
			return
	_update_near_spot()


## 이벤트 칸을 밟음: 조건이 맞고 (한 번만이면 아직 안 했으면) 그 대화(컷신)를 시작
func _try_event(t: Vector2i) -> bool:
	for e in events:
		if e.tile != t or (e.data.get("once", false) and e.done):
			continue
		var cond: String = e.data.get("condition", "")
		if cond != "" and not Expr.evaluate(cond, GameState):
			continue
		if e.data.get("once", false):
			e.done = true
			GameState.field_mark(map.map_id, "done", e.data.object_id)
		_start_dialogue(e)
		return true
	return false


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F9 and OS.is_debug_build():
		ai_debug = not ai_debug   # 개발용: BT 몬스터 머리 위에 지금 Task
		_toast("AI 디버그 표시 " + ("켬 (F9)" if ai_debug else "끔"))
		return
	if not _sleep_pick.is_empty():
		_sleep_picker_input(event)
		return
	if event.is_action_pressed("inventory") and (not frozen or _bag_open()):
		_toggle_inventory()
	elif event.is_action_pressed("equipment") and (not frozen or _bag_open()):
		if %Equipment.visible:
			%Equipment.hide()
		else:
			%Equipment.open()
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
			var verb: String = {"npc": "대화", "camp": "거점", "exit": "문 열기", "spot": "조사", "transit": "이용",
				"passage": "통로"}[best.kind]
			var extra := "  (조사함)" if best.kind == "spot" and best.done else ""
			if best.kind == "exit" and best.open:
				verb = "문 닫기"
				extra = "   —   열린 문으로 걸어가면 나감"
			if best.kind == "passage":
				extra = "   —   걸어 들어가면 이동"
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
		"transit": travel(s.data.ref, s.data.get("arrive", ""), s.data.object_id)
		"spot": await _investigate(s)


## 맵 이동: map_id 의 도착 P 로. arrive = 출발 쪽에서 고른 도착 P, from = 들어온 곳(도착 P 의 '이어지는 곳'과 맞춤).
## 둘 다 맞는 게 없으면 기본 P.
func travel(map_id: String, arrive := "", from := "") -> void:
	GameState.arrive_at = arrive
	GameState.arrive_from = from
	var chasers := _take_chasers()
	load_map(map_id)
	var delay := float(DataLoader.config.get("ai_follow_delay", 3.0))
	for d in chasers:
		_follow_queue.append({"data": d, "left": delay})


## 가장자리 이동: 플레이어가 맵 맨 끝 칸(edges 가 정해진 쪽)에 있으면 그 edge { ref, arrive, dir }
func _edge_at(t: Vector2i) -> Dictionary:
	var edges: Dictionary = map.get("edges", {})
	for d in edges:
		var hit: bool = (d == "left" and t.x <= 0) or (d == "right" and t.x >= int(map.width) - 1) \
			or (d == "up" and t.y <= 0) or (d == "down" and t.y >= int(map.height) - 1)
		if hit:
			return edges[d].merged({"dir": d})
	return {}


## 효과 move: (대화 중이면 대화가 끝난 뒤) 이동
func _on_travel_requested(map_id: String, arrive: String) -> void:
	if _dialogue_ui != null:
		_pending_travel = [map_id, arrive]
	else:
		travel.call_deferred(map_id, arrive)


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
	if renderer:
		renderer.set_spot_done(s.data.object_id, true)
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
	if not frozen or _bag_open():
		%Inventory.open_browse()


## I: 소지품 열기/닫기
func _toggle_inventory() -> void:
	if %Inventory.visible:
		%Inventory.hide()
	else:
		_open_inventory()


## 소지품·장비창 중 하나라도 열려 있음 (둘은 같이 열 수 있다)
func _bag_open() -> bool:
	return %Inventory.visible or %Equipment.visible


func _set_frozen_by_overlay() -> void:
	if _bag_open():
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
	_camera_follow()   # 컷신에서 옮긴 카메라는 대화가 끝나면 플레이어에게
	StoryRunner.enter_field()
	frozen = false
	_update_hud()
	if not _pending_travel.is_empty():
		var t := _pending_travel
		_pending_travel = []
		travel(t[0], t[1])
	_play_cutscenes.call_deferred()


## 기다리는 자동 시작 컷신을 하나씩 (다른 대화·전투 중이면 그게 끝난 뒤)
func _play_cutscenes() -> void:
	if _dialogue_ui != null or _combat_ui != null or _cutscenes.is_empty() or map.is_empty():
		return
	var id: String = _cutscenes.pop_front()
	if DataLoader.nodes.has(id):
		_start_dialogue({"data": {"ref": id}})
	else:
		_play_cutscenes()


# ---------------------------------------------------------------- 🎬 연출 (필드 단계)
## StoryRunner.field_director: 연출 카드의 필드 단계를 실행한다 (core/direction.gd).
## s._instant (건너뛰기) 이면 바로 끝난 모습으로. {do: "_finish"} = 돌고 있는 걷기·카메라를 바로 끝냄
func _direct_step(s: Dictionary) -> void:
	var instant: bool = s.get("_instant", false)
	match s.get("do", ""):
		"_finish":
			for tw in _active_tweens:
				if tw.is_valid():
					tw.custom_step(1e6)
		"face":
			var who := _actor(str(s.get("who", "")))
			if who:
				who.facing = Direction.DIR_VEC.get(s.get("dir", "down"), Vector2.DOWN)
		"walk":
			var who := _actor(str(s.get("who", "")))
			if who == null:
				push_warning("[연출] 이 맵에 없는 인물: %s" % s.get("who", ""))
				return
			var to: Array = s.get("to", [0, 0])
			var tw := _walk(who, Vector2i(int(to[0]), int(to[1])), float(s.get("speed", 3.0)))
			if instant:
				tw.custom_step(1e6)
			elif tw and s.get("wait", true):
				await tw.finished
		"camera":
			var cam := _camera()
			var who := str(s.get("who", ""))
			var time := float(s.get("time", 1.0))
			if who == "player":
				_camera_follow()
				return
			var target: Vector2
			var actor := _actor(who) if who != "" else null
			if actor:
				target = actor.global_position
			else:
				var to: Array = s.get("to", [0, 0])
				target = _tile_center(int(to[0]), int(to[1]))
			if not cam.top_level:
				var at := cam.get_screen_center_position()
				cam.top_level = true
				cam.global_position = at
			if time <= 0.0 or instant:
				cam.global_position = target
			else:
				var tw := create_tween()
				tw.tween_property(cam, "global_position", target, time).set_trans(Tween.TRANS_SINE)
				_active_tweens.append(tw)
				await tw.finished
				_active_tweens.erase(tw)
		"vanish":
			for n in npcs:
				if n.data.object_id == s.get("who", ""):
					n.vanished = true
			_refresh_presence()
		"shake":
			if instant:
				return
			var cam := _camera()
			var t := 0.0
			var time := float(s.get("time", 0.4))
			while t < time:
				cam.offset = Vector2(randf_range(-1, 1), randf_range(-1, 1)) * tile * 0.12 * float(s.get("power", 1.0))
				await get_tree().process_frame
				t += get_process_delta_time()
			cam.offset = Vector2.ZERO


## 연출 대상: "player" 또는 이 맵의 NPC object_id
func _actor(who: String) -> Node2D:
	if who == "player":
		return player
	for n in npcs:
		if n.data.object_id == who:
			return n.node
	return null


## 벽·막는 오브젝트를 피하는 길 찾기 칸 (맵마다 한 번). 닫힌 문은 몸으로 막히므로 여기엔 없다
func path_grid() -> AStarGrid2D:
	if _path_grid:
		return _path_grid
	var grid := AStarGrid2D.new()
	grid.region = Rect2i(0, 0, int(map.width), int(map.height))
	grid.cell_size = Vector2(tile, tile)
	grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	grid.update()
	for y in map.tiles.size():
		var row: String = map.tiles[y]
		for x in row.length():
			if _is_solid(row[x]):
				grid.set_point_solid(Vector2i(x, y))
	for c in VisualData.solid_cells(map):
		if grid.region.has_point(c):
			grid.set_point_solid(c)
	_path_grid = grid
	return grid


## 칸 from → to 길 (from 다음 칸부터). 길이 없으면 []
func find_path(from: Vector2i, to: Vector2i) -> Array:
	var grid := path_grid()
	if not grid.region.has_point(from) or not grid.region.has_point(to) or grid.is_point_solid(to):
		return []
	var p: Array = grid.get_id_path(from, to, true)
	return p.slice(1)


## BT 몬스터의 EnterTurnBattle: 지금 전투를 시작할 수 있으면 시작하고 true
func request_battle(e: Node) -> bool:
	if frozen or _combat_ui != null or not e in enemies:
		return false
	_start_combat(e)
	return true


## 적 하나 만들기 (맵 물체 또는 쫓아 들어온 몬스터)
func _spawn_enemy(o: Dictionary) -> Node:
	var dirs := {"up": Vector2.UP, "down": Vector2.DOWN, "left": Vector2.LEFT, "right": Vector2.RIGHT}
	var pos := _tile_center(o.x, o.y)
	var e := CharacterBody2D.new()
	e.set_script(EnemyScript)
	e.field = self
	e.data = o
	e.radius = tile * 0.32
	# 순찰 = 걷기, 추격 = 달리기 (Npcs 시트의 walk_speed·run_speed, 칸/초)
	var npc: Dictionary = DataLoader.enemies.get(o.ref, {})
	e.patrol_speed = float(npc.get("walk_speed", 2)) * tile
	e.chase_speed = float(npc.get("run_speed", 3.2)) * tile
	e.sight = float(DataLoader.config.get("field_enemy_sight", 5)) * tile
	e.lose_sight = float(DataLoader.config.get("field_enemy_lose_sight", 8)) * tile
	e.collision_layer = 0
	e.collision_mask = WALL_LAYER | DOOR_LAYER
	e.position = pos
	e.setup_patrol(pos, dirs.get(o.get("patrol_dir", ""), Vector2.ZERO) * tile, int(o.get("patrol_len", 0)))
	_setup_enemy_bt(e, o)
	if e.bt:
		for id in _ai_breakpoints.get(str(o.get("bt", "")), []):
			e.bt.breakpoints[id] = true
	_add_circle_shape(e, e.radius * 0.8)
	%World.add_child(e)
	enemies.append(e)
	return e


## 쫓아 들어온 몬스터들 (이 맵의 field_state followers — 처치하지 않은 것)
func _spawn_followers() -> void:
	for o in GameState.followers(map.map_id):
		if not GameState.field_has(map.map_id, "removed", o.object_id):
			_spawn_enemy(o)


# ---------------------------------------------------------------- 소리·빛 (몬스터 AI 감각, 기획 v2.0 §7.3 확장)
## 소리: 반경(칸) 안의 BT 몬스터가 듣는다 (벽 너머도 들림). 달리기·문 여닫기 (Config noise_*_radius, 임시값 TODO 기획)
func make_noise(at: Vector2, radius_tiles: float) -> void:
	for e in enemies:
		if is_instance_valid(e) and e.bt and e.global_position.distance_to(at) <= radius_tiles * tile:
			e.hear(e._to_tile(at))


## 빛: 플레이어가 손전등(손에 든 빛)을 켜고 있으면 몬스터 시야 × Config ai_flashlight_sight_mult (임시값 TODO 기획)
func sight_mult() -> float:
	return float(DataLoader.config.get("ai_flashlight_sight_mult", 1.5)) if held_light != null and is_instance_valid(held_light) else 1.0


# ---------------------------------------------------------------- 맵 간 추적
## 맵을 떠날 때 쫓던 몬스터들은 Config ai_follow_delay 초 뒤 같은 곳(들어온 칸)으로 따라 들어온다.
## 맵 물체 follow = "off" 면 안 따라옴. 따라온 몬스터는 그 맵의 field_state followers 에 남고(저장됨), 원래 맵에서는 "gone".
func _take_chasers() -> Array:
	var out := []
	for q in _follow_queue:   # 아직 못 들어온 몬스터도 계속 따라옴
		out.append(q.data)
	_follow_queue.clear()
	if not bool(int(DataLoader.config.get("ai_follow_enabled", 1))):
		return out
	var keep := []
	for f in GameState.followers(map.map_id):
		keep.append(f)
	for e in enemies:
		if not is_instance_valid(e) or e.state != "chase" or e.grace > 0.0 or str(e.data.get("follow", "")) == "off":
			continue
		out.append(e.data.duplicate(true))
		keep = keep.filter(func(f): return f.object_id != e.data.object_id)
		GameState.field_mark(map.map_id, "gone", e.data.object_id)
	GameState.set_followers(map.map_id, keep)
	return out


func _tick_followers(delta: float) -> void:
	if _follow_queue.is_empty():
		return
	for q in _follow_queue.duplicate():
		q.left -= delta
		if q.left > 0.0:
			continue
		_follow_queue.erase(q)
		var o: Dictionary = q.data
		o.x = _arrive_tile.x
		o.y = _arrive_tile.y
		o.patrol_dir = ""
		o.patrol_len = 0
		var list := GameState.followers(map.map_id).filter(func(f): return f.object_id != o.object_id)
		list.append(o)
		GameState.set_followers(map.map_id, list)
		GameState.field_state[map.map_id].get("removed", []).erase(o.object_id)
		_spawn_enemy(o)


## 지붕: 플레이어가 서 있는 칸을 덮는 지붕(집)만 열고, 나머지는 덮음 — 집 안에 들어가기 전에는 안이 안 보임
func _update_roof(instant := false) -> void:
	if renderer == null or player == null or renderer.roof_regions.is_empty():
		return
	var r: int = renderer.roof_region_at(Vector2i(floori(player.global_position.x / tile), floori(player.global_position.y / tile)))
	if r == _roof_open and not instant:
		return
	if instant:
		for i in renderer.roof_regions.size():
			renderer.set_roof_open(i, i == r, true)
	else:
		renderer.set_roof_open(_roof_open, false)
		renderer.set_roof_open(r, true)
	_roof_open = r


## 맵 물체 bt = BT_ 자산 → Behavior Tree 로 움직임. 자산이 없거나 잘못되면 예전 AI (경고만)
func _setup_enemy_bt(e: Node, o: Dictionary) -> void:
	var bt_id := str(o.get("bt", ""))
	if bt_id == "":
		return
	var bt: Dictionary = DataLoader.ai_assets.get(bt_id, {})
	var bb: Dictionary = DataLoader.ai_assets.get(str(bt.get("blackboard_id", "")), {})
	var errs := AIAssets.validate_bt(bt, DataLoader.ai_assets) if not bt.is_empty() else [{"msg": "없는 BT (몬스터 AI 탭에서 Compile 또는 변환 필요)"}]
	if not errs.is_empty():
		push_warning("[field] %s 의 BT '%s' 를 쓸 수 없어 예전 AI 로: %s" % [o.object_id, bt_id, errs[0].msg])
		return
	var over := {}
	var allowed := {}
	for k in bb.get("keys", []):
		if k.get("instance_override", false):
			allowed[str(k.name)] = true
	var raw = o.get("bb_overrides", {})
	if raw is Dictionary:
		for k in raw:
			if allowed.has(k):
				over[k] = raw[k]
			else:
				push_warning("[field] %s: Blackboard 키 '%s' 는 개체별 override 가 꺼져 있음" % [o.object_id, k])
	e.setup_bt(bt, bb, over)


## who 를 칸 to 까지 걷게 한다 (벽을 돌아가는 길 찾기). 다 걸으면 끝나는 Tween 을 돌려준다
func _walk(who: Node2D, to: Vector2i, speed: float) -> Tween:
	var grid := path_grid()
	var from := Vector2i(floori(who.global_position.x / tile), floori(who.global_position.y / tile))
	var path: Array = []
	if grid.region.has_point(from) and grid.region.has_point(to) and not grid.is_point_solid(to):
		path = grid.get_id_path(from, to)
	if path.is_empty():
		path = [from, to]   # 길이 없으면 곧장
	var tw := create_tween()
	var at := who.position
	for p in path.slice(1):
		var dest := _tile_center(p.x, p.y)
		var dir := (dest - at).normalized()
		if dir != Vector2.ZERO:
			tw.tween_callback(func(): if is_instance_valid(who): who.facing = dir)   # 가는 쪽을 바라봄
		tw.tween_property(who, "position", dest, at.distance_to(dest) / maxf(0.1, speed * tile))
		at = dest
	if path.size() <= 1:
		tw.tween_interval(0.0)
	_active_tweens.append(tw)
	tw.finished.connect(func():
		_active_tweens.erase(tw)
		if is_instance_valid(who):
			for n in npcs:
				if n.node == who:
					n.pos = who.position   # 대화·상호작용 위치도 옮긴 자리로
			if who == player:
				_last_tile = Vector2i(floori(player.global_position.x / tile), floori(player.global_position.y / tile)))
	return tw


## 손에 든 아이템 중 빛(Items.light)이 있으면 플레이어가 그 빛을 들고 다닌다 (원뿔이면 바라보는 쪽으로)
func _update_held_light() -> void:
	if player == null or not is_instance_valid(player):
		return
	var preset := ""
	for slot in GameState.equipment:
		var item: Dictionary = DataLoader.items.get(GameState.equipment[slot], {})
		var kind: String = DataLoader.equip_slots.filter(func(e): return e.slot_id == slot).map(func(e): return e.kind).front() 			if DataLoader.equip_slots.any(func(e): return e.slot_id == slot) else ""
		if kind == "hand" and str(item.get("light", "")) != "":
			preset = item.light
			break
	if held_light and is_instance_valid(held_light):
		held_light.queue_free()
	held_light = null
	if preset == "":
		return
	var p := VisualData.preset(preset)
	if p.is_empty():
		return
	held_light = MapRenderer.make_light(p, tile)
	held_light.name = "HeldLight"
	player.add_child(held_light)
	held_light.rotation = player.facing.angle()


func _process(delta: float) -> void:
	if held_light and is_instance_valid(held_light) and player:
		held_light.rotation = player.facing.angle()   # 바라보는 쪽을 비춤
	_update_roof()
	# 브레이크포인트에 걸린 몬스터가 있으면 모두 멈춤 (Unreal 처럼)
	if not ai_paused:
		for e in enemies:
			if is_instance_valid(e) and e.bt and e.bt.is_paused():
				ai_paused = true
				break
	# 몬스터 AI 디버거: Godot 에디터에서 실행(F5·맵 테스트 플레이)했으면 BT 몬스터 상태를 '몬스터 AI' 탭으로
	if EngineDebugger.is_active():
		if not EngineDebugger.has_capture("monster_ai"):
			EngineDebugger.register_message_capture("monster_ai", _on_ai_debug_message)
		_ai_send_t -= delta
		if _ai_send_t <= 0.0:
			_ai_send_t = AI_SEND_INTERVAL
			EngineDebugger.send_message("monster_ai:snapshot", [ai_snapshot()])


## 몬스터 AI 디버거에서 오는 명령 (에디터 → 게임): pause [bool] / step [] / breakpoints [{bt_id: [node id]}]
func _on_ai_debug_message(message: String, data: Array) -> bool:
	match message.trim_prefix("monster_ai:"):
		"pause":
			set_ai_paused(bool(data[0]) if not data.is_empty() else true)
		"step":
			_ai_step_pending = true
		"breakpoints":
			_ai_breakpoints = data[0] if not data.is_empty() and data[0] is Dictionary else {}
			for e in enemies:
				if is_instance_valid(e) and e.bt:
					e.bt.breakpoints.clear()
					for id in _ai_breakpoints.get(str(e.data.get("bt", "")), []):
						e.bt.breakpoints[id] = true
		_:
			return false
	return true


func set_ai_paused(v: bool) -> void:
	ai_paused = v
	if not v:
		for e in enemies:
			if is_instance_valid(e) and e.bt:
				e.bt.set_paused(false)


## 이 맵의 BT 몬스터 상태 (디버거용) {map, frozen, monsters: [{id, name, ref, tile, grace, snap}]}
func ai_snapshot() -> Dictionary:
	var list := []
	for e in enemies:
		if is_instance_valid(e) and e.bt:
			var t: Vector2 = e.ai_tile()
			list.append({"id": str(e.data.object_id), "name": str(e.data.get("name", "")), "ref": str(e.data.get("ref", "")),
				"tile": [snappedf(t.x, 0.1), snappedf(t.y, 0.1)], "grace": snappedf(e.grace, 0.1), "snap": e.bt.debug_snapshot()})
	return {"map": str(map.get("map_id", "")), "frozen": frozen, "paused": ai_paused, "monsters": list}


func _camera() -> Camera2D:
	return player.get_node_or_null("Camera2D") if player else null


## 카메라가 다시 플레이어를 따라간다
func _camera_follow() -> void:
	var cam := _camera()
	if cam and cam.top_level:
		cam.top_level = false
		cam.position = Vector2.ZERO
		cam.offset = Vector2.ZERO


# ---------------------------------------------------------------- 전투
func _start_combat(enemy: Node) -> void:
	frozen = true
	_combat_enemy = enemy
	_combat_group = [enemy] + _combat_joiners(enemy)
	_open_combat(_combat_group.map(func(e): return str(e.data.ref)))


## 함께 싸울 몬스터: 닿은 적이 몬스터(Npcs kind=monster)면, 나를 쫓고 있던(추격 중·유예 아님) 다른 몬스터를
## 가까운 순서로 Config combat_max_enemies(3) 마리까지 (반경 Config combat_join_radius 칸, 임시값). NPC 는 끼지 않는다.
func _combat_joiners(first: Node) -> Array:
	if not _is_monster(first):
		return []
	var limit := int(DataLoader.config.get("combat_max_enemies", 3)) - 1
	var radius := float(DataLoader.config.get("combat_join_radius", 8)) * tile
	var list := []
	for e in enemies:
		if is_instance_valid(e) and e != first and _is_monster(e) and e.state == "chase" and e.grace == 0.0 				and e.global_position.distance_to(player.global_position) <= radius:
			list.append(e)
	list.sort_custom(func(a, b): return a.global_position.distance_to(player.global_position) < b.global_position.distance_to(player.global_position))
	return list.slice(0, maxi(0, limit))


func _is_monster(e: Node) -> bool:
	return str(DataLoader.enemies.get(str(e.data.get("ref", "")), {}).get("kind", "npc")) == "monster"


## 대화 선택지 type=combat: 대화를 숨기고 전투, 끝나면 결과를 StoryRunner 에 돌려준다 (이기거나 도주하면 대화 계속)
func _on_dialogue_combat(enemy_id: String) -> void:
	frozen = true
	_combat_from_dialogue = true
	if _dialogue_ui != null:
		_dialogue_ui.visible = false
	_open_combat(enemy_id)


## enemy = 적 하나(enemy_id) 또는 여러 마리 [enemy_id, …]
func _open_combat(enemy: Variant) -> void:
	var ids: Array = enemy if enemy is Array else [enemy]
	_combat_enemy_name = str(DataLoader.enemies.get(str(ids[0]), {}).get("name", ""))
	%Prompt.visible = false
	_combat_ui = CombatScene.instantiate()
	_combat_ui.embedded = true
	_combat_ui.enemy_id_override = str(ids[0])
	_combat_ui.enemy_ids_override = ids
	_combat_ui.player_state = GameState.player_body
	_combat_ui.finished.connect(_on_combat_finished)
	%Overlay.add_child(_combat_ui)


func _on_combat_finished(outcome: String) -> void:
	if _combat_ui == null:
		return   # 이미 끝냄 ('계속' 을 두 번 눌러도 한 번만)
	GameState.player_body = _combat_ui.combat.player_parts.duplicate(true)
	var defeated: Array = _combat_ui.combat.defeated()
	if _combat_ui.combat.killer != "":
		_combat_enemy_name = _combat_ui.combat.killer
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
			_on_death("combat", _combat_enemy_name)
		return
	# 함께 싸운 적마다: 쓰러뜨렸거나 물러난 적은 맵에서 지우고, 나머지는 도주 유예
	var group := _combat_group if not _combat_group.is_empty() else [_combat_enemy]
	match outcome:
		"win", "fled":
			for i in group.size():
				var e: Node = group[i]
				if not is_instance_valid(e):
					continue
				if outcome == "win" or i in defeated:
					GameState.field_mark(map.map_id, "removed", e.data.object_id)
					enemies.erase(e)
					e.queue_free()
				else:
					e.grace = float(DataLoader.config.get("field_flee_grace", 3))
					e.state = "return"
					if e.bt:
						e.bt.notify_battle_end()
			frozen = false
		_:
			_on_death("combat", _combat_enemy_name)
	_combat_enemy = null
	_combat_group = []


## 사망 (§11): 부활 수단(초월체·아이템)이 있으면 모두 유지한 채 베이스캠프에서 깨어나고, 없으면 게임 처음부터.
## 사망 문구 = 원인(content.xlsx DeathCauses)의 text — "굶어 죽었습니다." / 비면 "{name}(으)로 인해 사망했습니다."
## TODO: 사망·부활 연출 (지금은 패널 하나)
func _on_death(cause_id := "unknown", enemy_name := "") -> void:
	frozen = true
	GameState.pending_death = ""
	var why := StoryRunner.death_text(cause_id, enemy_name)
	var revival := GameState.find_revival()
	if revival.is_empty():
		SaveManager.end_run()
		%DeathMessage.text = why
		%NewRunButton.text = "처음부터"
		_death_revival = {}
	else:
		await _run_effects(revival.effects)   # 예: 부활 아이템 소모, 보호 플래그 해제
		%DeathMessage.text = why + ("

" + revival.text if revival.text != "" else "")
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
	var heavy := GameState.carry_speed_mult()
	%InventoryButton.text = "소지품 %d/%d · 무게 %s/%s%s" % [GameState.inventory.size(), GameState.slot_count(),
		_fmt(GameState.carry_weight()), _fmt(GameState.carry_max()),
		" (못 움직임)" if heavy <= 0.0 else (" (느림)" if heavy < 1.0 else "")]


## 무게 표시: 정수면 소수점 없이, 아니면 한 자리
static func _fmt(v: float) -> String:
	return str(int(v)) if is_equal_approx(v, roundf(v)) else "%.1f" % v
