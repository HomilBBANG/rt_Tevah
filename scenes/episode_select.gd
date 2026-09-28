extends Control


func _ready() -> void:
	%BackButton.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/title.tscn"))
	%ResetButton.pressed.connect(func():
		SaveManager.delete_all()
		_build())
	_build()


func _build() -> void:
	for c in %List.get_children():
		%List.remove_child(c)
		c.queue_free()
	for id in DataLoader.episode_order:
		var ep: Dictionary = DataLoader.episodes[id]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var label := Label.new()
		label.text = ep.title
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)
		if not StoryRunner.is_unlocked(id):
			label.modulate = Color(1, 1, 1, 0.45)
			var locked := Label.new()
			locked.text = "잠김"
			locked.modulate = Color(1, 1, 1, 0.45)
			row.add_child(locked)
		elif SaveManager.has_episode_save(id):
			row.add_child(_button("이어하기", id, true))
			row.add_child(_button("처음부터", id, false))
		else:
			row.add_child(_button("시작", id, false))
		%List.add_child(row)


func _button(text: String, episode_id: String, resume: bool) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(func():
		StoryRunner.prepare(episode_id, resume)
		get_tree().change_scene_to_file("res://scenes/main_play.tscn"))
	return b
