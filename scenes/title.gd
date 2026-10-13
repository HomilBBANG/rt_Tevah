extends Control
## 타이틀. 새 회차 / 이어하기(베이스캠프에서 마지막으로 저장한 회차) / 프로토타입 테스트

const FIELD := "res://scenes/field/field.tscn"


func _ready() -> void:
	var has_save := SaveManager.has_run_save()
	%ContinueButton.disabled = not has_save
	%RunInfo.text = "지금까지 %d번 부활했다." % GameState.run_count if GameState.run_count > 0 else ""
	%NewRunButton.pressed.connect(func():
		SaveManager.begin_run()
		get_tree().change_scene_to_file(FIELD))
	%ContinueButton.pressed.connect(func():
		if SaveManager.load_run():
			get_tree().change_scene_to_file(FIELD))
	%StartButton.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/episode_select.tscn"))
	%CombatButton.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/combat.tscn"))
	%QuitButton.pressed.connect(func(): get_tree().quit())
	(%ContinueButton if has_save else %NewRunButton).grab_focus()
