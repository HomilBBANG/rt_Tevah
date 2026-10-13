extends Control


func _ready() -> void:
	%StartButton.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/episode_select.tscn"))
	%CombatButton.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/combat.tscn"))
	%QuitButton.pressed.connect(func(): get_tree().quit())
	%StartButton.grab_focus()
