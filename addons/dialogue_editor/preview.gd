extends Control
## 대화 에디터의 '미리보기': user://dialogue_preview.json 의 노드(와 page 번째 페이지)부터 실제 대화 화면으로 실행.
## 새 회차 상태(소지품 없음·플래그 없음)에서 시작한다. 저장 효과(save)는 실제로 저장하지 않는다.

const DialogueScene = preload("res://scenes/main_play.tscn")
const CombatScene = preload("res://scenes/combat.tscn")
const Triggers = preload("res://core/cutscene_triggers.gd")
const FieldScene = preload("res://scenes/field/field.tscn")
const FieldScript = preload("res://scenes/field/field.gd")

var _ui: Node
var _combat: Node
var _start_page := 0   # 대본 칸에서 고른 페이지부터
var _map := ""         # 미리볼 맵 (""= 맵 없이 — 필드 연출은 건너뜀)
var _field: Node


func _ready() -> void:
	var d = JSON.parse_string(FileAccess.get_file_as_string("user://dialogue_preview.json")) \
		if FileAccess.file_exists("user://dialogue_preview.json") else null
	var start: String = d.get("node", "") if d is Dictionary else ""
	_start_page = int(d.get("page", 0)) if d is Dictionary else 0
	_map = str(d.get("map", "")) if d is Dictionary else ""
	if not DataLoader.nodes.has(start):
		%Info.text = "미리볼 노드가 없습니다: '%s'\n대화 에디터에서 변환·검사를 먼저 하세요." % start
		return
	GameState.reset_run()
	if _map != "" and DataLoader.maps.has(_map):
		_start_on_map(start)
		return
	# 대화 횟수(count:talk)는 Esc 로 다시 시작해도 이어진다 → 두 번째부터 반복 대사 확인. 창을 닫으면 처음부터.
	GameState.talk_counts = Engine.get_meta("preview_talk_counts", {}).duplicate()
	StoryRunner.save_slot_requested.connect(func(): StoryRunner.choose_save_slot.call_deferred(-1))
	StoryRunner.combat_requested.connect(_on_combat)
	%Info.text = "미리보기: %s   (save 효과는 저장하지 않음 · Esc 로 다시 시작)" % start
	_start(start)


## 맵 위에서 미리보기: 그 맵을 필드로 열고 (시작 S → 없으면 P) 고른 카드부터 — 걷기·카메라·바라보기 같은 필드 연출도 보임.
## 저장은 user://playtest_saves/ 에만, 자동 시작 컷신(새 게임·방 진입)은 끔. 대화가 끝나면 그 맵을 그대로 돌아다닐 수 있음.
func _start_on_map(node_id: String) -> void:
	SaveManager.save_dir = "user://playtest_saves/"
	DataLoader.triggers = {}
	GameState.current_map = _map
	GameState.wake_at_run_start = true
	FieldScript.next_map_id = _map
	_field = FieldScene.instantiate()
	%Stage.add_child(_field)
	# 서 있는 칸의 이벤트 칸이 먼저 시작하지 않게 (미리볼 카드만)
	_field._last_tile = Vector2i(floori(_field.player.position.x / _field.tile), floori(_field.player.position.y / _field.tile))
	%Info.text = "미리보기 (맵 %s): %s   (Esc 로 다시 시작)" % [_map, node_id]
	await get_tree().process_frame
	await get_tree().process_frame
	# 안내 글은 필드 HUD 위에 (맨 위 줄 아래)
	var layer := CanvasLayer.new()
	layer.layer = 50
	add_child(layer)
	%Info.reparent(layer, false)
	%Info.anchor_top = 0.105
	%Info.anchor_bottom = 0.15
	_field._start_dialogue({"data": {"ref": node_id}})
	_watch_end()


## 맵 미리보기: 대화가 끝나면 안내 바꾸기
func _watch_end() -> void:
	while is_instance_valid(_field) and _field._dialogue_ui != null:
		await get_tree().process_frame
	%Info.text = "대화 끝 (EXIT) — 맵 %s 를 그대로 돌아다닐 수 있음. Esc 로 다시 시작." % _map


func _start(node_id: String) -> void:
	if _ui:
		_ui.queue_free()
	_ui = DialogueScene.instantiate()
	_ui.embedded = true
	_ui.start_page = _start_page
	_ui.skip_button = not Triggers.is_logo(node_id)   # 로고는 게임처럼 건너뛰기 버튼 없이
	_ui.finished.connect(func(): %Info.text = "대화 끝 (EXIT).  Esc 로 다시 시작, 창을 닫으면 에디터로.")
	%Stage.add_child(_ui)
	StoryRunner.start_dialogue(node_id)
	Engine.set_meta("preview_talk_counts", GameState.talk_counts.duplicate())
	%Info.text += "   · 대화 횟수(count:talk) = %d" % GameState.talk_now


## 전투 선택지: 대화를 숨기고 전투 화면. 이기거나 도주하면 대화 계속, 지면 대화 끝 (미리보기는 사망 처리 없음)
func _on_combat(enemy_id: String) -> void:
	_ui.visible = false
	%Info.visible = false   # 전투 화면의 '내 상태'와 겹침
	_combat = CombatScene.instantiate()
	_combat.embedded = true
	_combat.enemy_id_override = enemy_id
	_combat.player_state = GameState.player_body
	_combat.finished.connect(_on_combat_finished)
	%Stage.add_child(_combat)


func _on_combat_finished(outcome: String) -> void:
	GameState.player_body = _combat.combat.player_parts.duplicate(true)
	_combat.queue_free()
	_combat = null
	%Info.visible = true
	if outcome == "win" or outcome == "fled":
		_ui.visible = true
		StoryRunner.finish_combat(outcome)
	else:
		StoryRunner.finish_combat("lose")
		_ui.queue_free()
		_ui = null
		%Info.text = "전투에서 졌다 → 대화 끝 (게임에서는 사망 처리).  Esc 로 다시 시작."


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_tree().reload_current_scene()
