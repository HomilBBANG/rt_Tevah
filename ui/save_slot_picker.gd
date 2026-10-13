extends Control
## 저장 슬롯 선택 창 (화면 위에 겹쳐 띄움). open("save") / open("load") 후 chosen 을 기다린다.
##   save: 모든 슬롯 선택 가능. 이미 쓴 슬롯은 한 번 더 눌러야 덮어쓴다. 취소 = "저장하지 않기"
##   load: 저장된 슬롯만 선택 가능
## 키보드: ↑↓ 이동, Enter/Space 선택, Esc 취소

signal chosen(slot: int)   # 1 ~ N, -1 = 취소

const ChoiceButton = preload("res://ui/choice_button.gd")

var mode := "save"
var _armed := 0            # 덮어쓰기 확인 중인 슬롯
var _title: Label
var _list: VBoxContainer
var _cancel: Button


func _init() -> void:
	set_anchors_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_preset(PRESET_FULL_RECT)
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(PRESET_FULL_RECT)
	add_child(center)
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.03, 0.03, 0.04, 0.97)
	sb.border_color = Color(0.4, 0.4, 0.42)
	sb.set_border_width_all(2)
	sb.set_content_margin_all(40)
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.custom_minimum_size.x = 1000
	box.add_theme_constant_override("separation", 17)
	panel.add_child(box)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 37)
	box.add_child(_title)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 10)
	box.add_child(_list)
	_cancel = ChoiceButton.new()
	_cancel.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_cancel.pressed.connect(_done.bind(-1))
	box.add_child(_cancel)


func open(m: String) -> void:
	mode = m
	_armed = 0
	_title.text = "어느 슬롯에 저장할까?" if mode == "save" else "불러올 슬롯을 고르세요"
	_cancel.text = "저장하지 않기  (Esc)" if mode == "save" else "취소  (Esc)"
	_refresh()
	show()
	for b in _list.get_children():
		if not b.disabled:
			b.grab_focus.call_deferred()
			break


func _refresh(focus_slot := 0) -> void:
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	for i in range(1, SaveManager.slot_count() + 1):
		var info := SaveManager.slot_info(i)
		var b := ChoiceButton.new()
		var desc := "(비어 있음)"
		if not info.is_empty():
			desc = "%d일차 %s   ·   %d회차   ·   저장 %s" % [int(info.day), info.time, int(info.run_count), str(info.saved_at).substr(0, 16)]
		b.text = "슬롯 %d      %s" % [i, desc]
		if i == _armed:
			b.text += "      ← 다시 누르면 덮어씀"
		b.disabled = mode == "load" and info.is_empty()
		b.pressed.connect(_on_slot.bind(i))
		_list.add_child(b)
		if i == focus_slot:
			b.grab_focus.call_deferred()


func _on_slot(slot: int) -> void:
	if mode == "save" and SaveManager.has_run_save(slot) and _armed != slot:
		_armed = slot
		_refresh(slot)
		return
	_done(slot)


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		_done(-1)
		get_viewport().set_input_as_handled()


func _done(slot: int) -> void:
	hide()
	chosen.emit(slot)
