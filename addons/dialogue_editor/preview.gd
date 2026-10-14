extends Control
## 대화 에디터의 '미리보기': user://dialogue_preview.json 의 노드(와 page 번째 페이지)부터 실제 대화 화면으로 실행.
## 새 회차 상태(소지품 없음·플래그 없음)에서 시작한다. 저장 효과(save)는 실제로 저장하지 않는다.

const DialogueScene = preload("res://scenes/main_play.tscn")
const CombatScene = preload("res://scenes/combat.tscn")

var _ui: Node
var _combat: Node
var _start_page := 0   # 대본 칸에서 고른 페이지부터


func _ready() -> void:
	var d = JSON.parse_string(FileAccess.get_file_as_string("user://dialogue_preview.json")) \
		if FileAccess.file_exists("user://dialogue_preview.json") else null
	var start: String = d.get("node", "") if d is Dictionary else ""
	_start_page = int(d.get("page", 0)) if d is Dictionary else 0
	if not DataLoader.nodes.has(start):
		%Info.text = "미리볼 노드가 없습니다: '%s'\n대화 에디터에서 변환·검사를 먼저 하세요." % start
		return
	GameState.reset_run()
	# 대화 횟수(count:talk)는 Esc 로 다시 시작해도 이어진다 → 두 번째부터 반복 대사 확인. 창을 닫으면 처음부터.
	GameState.talk_counts = Engine.get_meta("preview_talk_counts", {}).duplicate()
	StoryRunner.save_slot_requested.connect(func(): StoryRunner.choose_save_slot.call_deferred(-1))
	StoryRunner.combat_requested.connect(_on_combat)
	%Info.text = "미리보기: %s   (save 효과는 저장하지 않음 · Esc 로 다시 시작)" % start
	_start(start)


func _start(node_id: String) -> void:
	if _ui:
		_ui.queue_free()
	_ui = DialogueScene.instantiate()
	_ui.embedded = true
	_ui.start_page = _start_page
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
