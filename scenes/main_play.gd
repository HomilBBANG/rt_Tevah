extends Control
## 플레이 화면. 로직 없음: StoryRunner·GameState 시그널을 그리고 입력만 돌려준다.

const ChoiceButton = preload("res://ui/choice_button.gd")


func _ready() -> void:
	StoryRunner.node_shown.connect(_on_node_shown)
	StoryRunner.choices_shown.connect(_on_choices_shown)
	StoryRunner.message.connect(_on_message)
	StoryRunner.messages_cleared.connect(_on_messages_cleared)
	StoryRunner.ending_reached.connect(_on_ending)
	StoryRunner.inventory_full.connect(%Inventory.open_discard)
	GameState.stats_changed.connect(_update_status)
	GameState.inventory_changed.connect(_update_status)
	%InventoryButton.pressed.connect(%Inventory.open_browse)
	%MenuButton.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/episode_select.tscn"))
	_on_messages_cleared()
	_update_status()
	StoryRunner.launch()


func _update_status() -> void:
	%Stats.text = "체력 %d/%d    정신력 %d/%d    시간 %d/%d" % [
		GameState.get_stat("hp"), GameState.stat_max("hp"),
		GameState.get_stat("sanity"), GameState.stat_max("sanity"),
		GameState.get_stat("time"), GameState.stat_max("time")]
	%InventoryButton.text = "인벤토리 (%d/%d)" % [GameState.inventory.size(), GameState.slot_count()]


func _on_node_shown(node: Dictionary, speaker_name: String) -> void:
	%Speaker.text = speaker_name
	%Speaker.visible = speaker_name != ""
	%Text.text = node.get("text", "")


func _on_choices_shown(entries: Array) -> void:
	_clear_choices()
	if entries.is_empty():
		var b := Button.new()
		b.text = "계속"
		b.pressed.connect(StoryRunner.continue_story)
		%Choices.add_child(b)
		b.grab_focus.call_deferred()
		return
	for e in entries:
		var b := ChoiceButton.new()
		b.setup(e)
		b.pressed.connect(StoryRunner.choose.bind(e.choice.choice_id))
		%Choices.add_child(b)


func _on_message(text: String) -> void:
	%Messages.text += ("" if %Messages.text == "" else "\n") + text
	%Messages.visible = true


func _on_messages_cleared() -> void:
	%Messages.text = ""
	%Messages.visible = false


func _on_ending(ending_id: String) -> void:
	_clear_choices()
	%Text.text += "\n\n— 엔딩: %s —" % ending_id
	%InventoryButton.disabled = true
	var b := Button.new()
	b.text = "에피소드 선택으로"
	b.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/episode_select.tscn"))
	%Choices.add_child(b)


func _clear_choices() -> void:
	for c in %Choices.get_children():
		%Choices.remove_child(c)
		c.queue_free()
