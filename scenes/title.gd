extends Control
## 타이틀. 새 게임(캐릭터 생성) / 새 회차 / 이어하기(슬롯 선택) / 프로토타입 테스트

const FIELD := "res://scenes/field/field.tscn"
const CREATION := "res://scenes/character_creation.tscn"
const SlotPicker = preload("res://ui/save_slot_picker.gd")


func _ready() -> void:
	var has_save := SaveManager.has_run_save()
	%ContinueButton.disabled = not has_save
	%RunInfo.text = "%d회차 · 사망 %d번" % [GameState.run_count, GameState.death_count] if GameState.run_count > 0 else ""
	# 캐릭터를 아직 안 만들었으면 '새 게임' = 캐릭터 생성. 만들었으면 '새 회차'(같은 캐릭터·특성) + '새 게임'(다시 만들기)
	if GameState.character_created:
		%NewRunButton.text = "새 회차"
		%NewRunButton.pressed.connect(func():
			SaveManager.begin_run()
			get_tree().change_scene_to_file(FIELD))
		var again := Button.new()
		again.name = "NewGameButton"
		again.text = "새 게임 (캐릭터 다시 만들기)"
		again.pressed.connect(_ask_new_game)
		%NewRunButton.add_sibling(again)
	else:
		%NewRunButton.text = "새 게임"
		%NewRunButton.pressed.connect(func(): get_tree().change_scene_to_file(CREATION))
	%ContinueButton.pressed.connect(_continue)
	%StartButton.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/episode_select.tscn"))
	%CombatButton.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/combat.tscn"))
	%QuitButton.pressed.connect(func(): get_tree().quit())
	(%ContinueButton if has_save else %NewRunButton).grab_focus()


## 이어하기: 불러올 슬롯 고르기
func _continue() -> void:
	var picker := SlotPicker.new()
	add_child(picker)
	picker.open("load")
	var slot: int = await picker.chosen
	picker.queue_free()
	if slot > 0 and SaveManager.load_run(slot):
		get_tree().change_scene_to_file(FIELD)
	else:
		%ContinueButton.grab_focus()


## 완전히 새 게임: 특성·회차 기록을 지우고 캐릭터 생성부터 (저장 슬롯은 남음)
func _ask_new_game() -> void:
	var dlg := ConfirmationDialog.new()
	dlg.title = "새 게임"
	dlg.dialog_text = "캐릭터를 처음부터 다시 만듭니다.
지금 특성과 회차·사망 기록, 월드 플래그가 사라집니다.
(저장 슬롯은 남아 있어 '이어하기'로 불러올 수 있습니다)"
	dlg.ok_button_text = "새 게임"
	dlg.cancel_button_text = "취소"
	dlg.confirmed.connect(func():
		SaveManager.new_game()
		get_tree().change_scene_to_file(CREATION))
	dlg.canceled.connect(dlg.queue_free)
	add_child(dlg)
	dlg.popup_centered()
