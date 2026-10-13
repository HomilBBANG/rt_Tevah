extends Control
## 대화 에디터의 '미리보기': user://dialogue_preview.json 의 노드부터 실제 대화 화면으로 실행.
## 새 회차 상태(소지품 없음·플래그 없음)에서 시작한다. 저장 효과(save)는 실제로 저장하지 않는다.

const DialogueScene = preload("res://scenes/main_play.tscn")

var _ui: Node


func _ready() -> void:
	var d = JSON.parse_string(FileAccess.get_file_as_string("user://dialogue_preview.json")) \
		if FileAccess.file_exists("user://dialogue_preview.json") else null
	var start: String = d.get("node", "") if d is Dictionary else ""
	if not DataLoader.nodes.has(start):
		%Info.text = "미리볼 노드가 없습니다: '%s'\n대화 에디터에서 변환·검사를 먼저 하세요." % start
		return
	GameState.reset_run()
	StoryRunner.save_slot_requested.connect(func(): StoryRunner.choose_save_slot.call_deferred(-1))
	%Info.text = "미리보기: %s   (save 효과는 저장하지 않음 · Esc 로 다시 시작)" % start
	_start(start)


func _start(node_id: String) -> void:
	if _ui:
		_ui.queue_free()
	_ui = DialogueScene.instantiate()
	_ui.embedded = true
	_ui.finished.connect(func(): %Info.text = "대화 끝 (EXIT).  Esc 로 다시 시작, 창을 닫으면 에디터로.")
	%Stage.add_child(_ui)
	StoryRunner.start_dialogue(node_id)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_tree().reload_current_scene()
