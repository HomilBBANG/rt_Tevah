extends Control
## 타이틀. 새 회차 / 이어하기(슬롯 선택) / 프로토타입 테스트

const FIELD := "res://scenes/field/field.tscn"
const SlotPicker = preload("res://ui/save_slot_picker.gd")


func _ready() -> void:
	var has_save := SaveManager.has_run_save()
	%ContinueButton.disabled = not has_save
	%RunInfo.text = "%d회차 · 사망 %d번" % [GameState.run_count, GameState.death_count] if GameState.run_count > 0 else ""
	%NewRunButton.pressed.connect(func():
		SaveManager.begin_run()
		get_tree().change_scene_to_file(FIELD))
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
