extends Button
## 아이템 칸 하나 (인벤토리 격자 칸 · 장비창 칸). 아트 전 placeholder: 이름 + 개수 글자.
## 끌어다 놓기: 아이템이 있으면 끌 수 있고(drag 데이터 = info()), accept·on_drop 을 준 칸에 놓을 수 있다.
## 우클릭 → right_clicked.

signal right_clicked

const SIZE := Vector2(116, 116)

var source := "inv"           # "inv" (인벤토리 칸) / "equip" (장비 칸)
var index := -1               # 인벤토리 칸 번호
var slot_id := ""             # 장비 칸 id
var item_id := ""
var count := 0
var selected := false
var accept: Callable          # func(data: Dictionary) -> bool
var on_drop: Callable         # func(data: Dictionary)


func _init() -> void:
	custom_minimum_size = SIZE
	clip_text = true
	autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_theme_font_size_override("font_size", 20)
	focus_mode = Control.FOCUS_NONE


func setup(p_item: String, p_count: int, empty_text := "") -> void:
	item_id = p_item
	count = p_count
	if item_id == "":
		text = empty_text
		tooltip_text = ""
	else:
		var nm := DataLoader.item_name(item_id)
		text = nm if count <= 1 else "%s\nx%d" % [nm, count]
		tooltip_text = nm
	_restyle()


func set_selected(on: bool) -> void:
	selected = on
	_restyle()


func info() -> Dictionary:
	return {"from": source, "index": index, "slot_id": slot_id, "item_id": item_id}


func _restyle() -> void:
	for s in ["normal", "hover", "pressed", "disabled"]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.12, 0.12, 0.14) if item_id != "" else Color(0.07, 0.07, 0.08)
		if s == "hover":
			sb.bg_color = sb.bg_color.lightened(0.12)
		sb.set_border_width_all(4 if selected else 2)
		sb.border_color = Color("ff9a3c") if selected else Color(0.35, 0.35, 0.38)
		sb.set_content_margin_all(6)
		add_theme_stylebox_override(s, sb)
	add_theme_color_override("font_color", Color("eeeeee") if item_id != "" else Color("666666"))


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		right_clicked.emit()
		accept_event()


func _get_drag_data(_pos: Vector2) -> Variant:
	if item_id == "":
		return null
	var pv := Label.new()
	pv.text = DataLoader.item_name(item_id)
	pv.add_theme_font_size_override("font_size", 24)
	pv.modulate = Color(1, 1, 1, 0.85)
	set_drag_preview(pv)
	return info()


func _can_drop_data(_pos: Vector2, data: Variant) -> bool:
	return data is Dictionary and accept.is_valid() and accept.call(data)


func _drop_data(_pos: Vector2, data: Variant) -> void:
	if on_drop.is_valid():
		on_drop.call(data)
