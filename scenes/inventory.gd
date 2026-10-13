extends Control
## 인벤토리 오버레이. 두 가지 모드:
##   browse  — 목록·설명 보기, 아이템 사용
##   discard — 인벤토리 초과 시 버릴 칸 고르기 (StoryRunner.inventory_full 에 연결)

var _mode := "browse"
var _selected := -1


func _ready() -> void:
	hide()
	%UseButton.pressed.connect(func(): StoryRunner.use_item(_selected))
	%GiveUpButton.pressed.connect(_finish_discard.bind(-1))
	%CloseButton.pressed.connect(hide)
	GameState.inventory_changed.connect(func(): if visible: _refresh())


func open_browse() -> void:
	_mode = "browse"
	_selected = -1
	%Title.text = "인벤토리"
	%UseButton.visible = true
	%CloseButton.visible = true
	%GiveUpButton.visible = false
	_refresh()
	show()


func open_discard(item_id: String, amount: int) -> void:
	_mode = "discard"
	_selected = -1
	%Title.text = "인벤토리가 가득 찼습니다: %s x%d\n버릴 칸을 고르세요." % [DataLoader.item_name(item_id), amount]
	%UseButton.visible = false
	%CloseButton.visible = false
	%GiveUpButton.visible = true
	%GiveUpButton.text = "%s 포기" % DataLoader.item_name(item_id)
	_refresh()
	show()


func _refresh() -> void:
	for c in %Slots.get_children():
		%Slots.remove_child(c)
		c.queue_free()
	var inv := GameState.inventory
	if _selected >= inv.size():
		_selected = -1
	for i in GameState.slot_count():
		var b := Button.new()
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(200, 34)
		if i < inv.size():
			b.text = "%s%s x%d" % ["▶ " if i == _selected else "", DataLoader.item_name(inv[i].id), inv[i].count]
			b.pressed.connect(_on_slot.bind(i))
		else:
			b.text = "(빈 칸)"
			b.disabled = true
		%Slots.add_child(b)

	var item: Dictionary = DataLoader.items.get(inv[_selected].id, {}) if _selected >= 0 else {}
	if item.is_empty():
		%Desc.text = "아이템을 선택하세요." if _mode == "browse" else ""
	else:
		%Desc.text = "[%s] %s" % [item.type, item.description]
	var story_over := StoryRunner.ended and StoryRunner.mode == "episode"   # 필드에서는 대화 밖에서도 사용 가능
	%UseButton.disabled = item.get("use_effects", "") == "" or story_over


func _on_slot(i: int) -> void:
	if _mode == "discard":
		_finish_discard(i)
	else:
		_selected = i
		_refresh()


func _finish_discard(slot: int) -> void:
	hide()
	StoryRunner.choose_discard(slot)
