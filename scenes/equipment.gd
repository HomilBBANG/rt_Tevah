extends Control
## 장비창 (필드에서 Q). 화면 왼쪽에 붙고, 소지품 창(I, 오른쪽)과 같이 열어 끌어다 놓을 수 있다.
##   장비 탭  — EquipSlots 칸(엑셀 col·row 위치)마다 장착한 아이템. 소지품에서 끌어와 놓으면 장착,
##              칸을 우클릭하거나 소지품으로 끌면 벗기. 손 칸에는 아무 아이템이나 들 수 있다
##   능력치 탭 — 왼쪽 내 몸 상태(부위 HP), 오른쪽 위 상태이상 목록(이름에 마우스를 올리면 설명), 오른쪽 아래 능력치 6개 육각형

const ItemCell = preload("res://ui/item_cell.gd")
const BodyDiagram = preload("res://ui/body_diagram.gd")
const Hexagon = preload("res://ui/ability_hexagon.gd")
const CELL := 124.0            # 장비 칸 한 변
const GAP := 10.0

var _tabs: TabContainer
var _slots_box: Control        # 장비 칸들 (col·row 로 자리 잡음)
var _info: Label
var _status: Label
var _body: Control
var _hex: Control
var _status_list: VBoxContainer   # 상태이상 이름들


func _ready() -> void:
	hide()
	set_anchors_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_IGNORE
	var panel := PanelContainer.new()
	panel.anchor_left = 0.03
	panel.anchor_right = 0.44
	panel.anchor_top = 0.12
	panel.anchor_bottom = 0.88
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.03, 0.03, 0.04, 0.97)
	sb.set_border_width_all(2)
	sb.border_color = Color(0.4, 0.4, 0.42)
	sb.set_content_margin_all(20)
	panel.add_theme_stylebox_override("panel", sb)
	add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	panel.add_child(vb)
	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = SIZE_EXPAND_FILL
	vb.add_child(_tabs)

	# ---- 장비 탭
	var equip := VBoxContainer.new()
	equip.name = "장비"
	equip.add_theme_constant_override("separation", 14)
	_tabs.add_child(equip)
	var center := CenterContainer.new()
	equip.add_child(center)
	_slots_box = Control.new()
	center.add_child(_slots_box)
	_info = Label.new()
	_info.add_theme_font_size_override("font_size", 22)
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	equip.add_child(_info)
	var hint := Label.new()
	hint.text = "소지품(I)에서 끌어와 놓거나 소지품에서 우클릭하면 장착. 손에는 아무 아이템이나 들 수 있고,\n손에 든 것은 소지품 칸을 차지하지 않는다. 칸을 우클릭하거나 소지품으로 끌면 벗기."
	hint.add_theme_font_size_override("font_size", 20)
	hint.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	equip.add_child(hint)

	# ---- 능력치 탭: 왼쪽 몸 상태 | 오른쪽 (위 상태이상, 아래 육각형)
	var stats := HBoxContainer.new()
	stats.name = "능력치"
	stats.add_theme_constant_override("separation", 16)
	_tabs.add_child(stats)
	_body = BodyDiagram.new()
	_body.figure = true
	_body.mouse_filter = MOUSE_FILTER_IGNORE
	_body.size_flags_horizontal = SIZE_EXPAND_FILL
	_body.size_flags_stretch_ratio = 0.8
	_body.custom_minimum_size = Vector2(220, 0)
	stats.add_child(_body)
	var right := VBoxContainer.new()
	right.size_flags_horizontal = SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 10)
	stats.add_child(right)
	var title := Label.new()
	title.text = "상태"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 34)
	right.add_child(title)
	var status_box := _boxed(Color.BLACK)
	status_box.custom_minimum_size = Vector2(0, 220)
	right.add_child(status_box)
	_status_list = VBoxContainer.new()
	_status_list.add_theme_constant_override("separation", 6)
	status_box.add_child(_status_list)
	var hex_box := _boxed(Color(0.07, 0.07, 0.08))
	hex_box.size_flags_vertical = SIZE_EXPAND_FILL
	right.add_child(hex_box)
	_hex = Hexagon.new()
	_hex.custom_minimum_size = Vector2(0, 300)
	hex_box.add_child(_hex)

	var bottom := HBoxContainer.new()
	vb.add_child(bottom)
	_status = Label.new()
	_status.size_flags_horizontal = SIZE_EXPAND_FILL
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", 22)
	_status.add_theme_color_override("font_color", Color(1, 0.75, 0.45))
	bottom.add_child(_status)
	var close := Button.new()
	close.text = "닫기"
	close.pressed.connect(hide)
	bottom.add_child(close)

	for sig in [GameState.equipment_changed, GameState.inventory_changed, GameState.body_changed, GameState.statuses_changed]:
		sig.connect(func(): if visible: refresh())


func open(tab := 0) -> void:
	_tabs.current_tab = tab
	_status.text = ""
	refresh()
	show()


func refresh() -> void:
	for c in _slots_box.get_children():
		_slots_box.remove_child(c)
		c.queue_free()
	var extent := Vector2.ZERO
	for s in DataLoader.equip_slots:
		var cell := ItemCell.new()
		cell.source = "equip"
		cell.slot_id = s.slot_id
		cell.custom_minimum_size = Vector2(CELL, CELL)
		cell.size = Vector2(CELL, CELL)
		cell.position = Vector2(float(s.col), float(s.row)) * (CELL + GAP)
		extent = extent.max(cell.position + cell.size)
		var held: String = GameState.equipment.get(s.slot_id, "")
		cell.setup(held, 1, s.name)
		if held != "":
			cell.text = "%s\n%s" % [s.name, DataLoader.item_name(held)]
		var sid: String = s.slot_id
		cell.right_clicked.connect(func(): _status.text = GameState.unequip(sid))
		# 소지품에서 끌어온, 이 칸에 넣을 수 있는 아이템만 받는다 (손은 아무거나)
		cell.accept = func(d): return d.from == "inv" and GameState.can_equip_in(d.item_id, sid)
		cell.on_drop = func(d): _status.text = GameState.equip(d.index, sid)
		_slots_box.add_child(cell)
	_slots_box.custom_minimum_size = extent
	var base := DataLoader.get_config_int("inventory_slots", 8)
	var bonus := GameState.slot_count() - base
	_info.text = "소지품 칸: 기본 %d%s = %d칸\n무게 %s / %s" % [base, " + 가방 %d" % bonus if bonus > 0 else "", GameState.slot_count(),
		_num(GameState.carry_weight()), _num(GameState.carry_max())]
	# 능력치 탭
	_body.parts = GameState.player_body
	_body.order = DataLoader.player_parts.map(func(p): return p.part_id)
	_body.refresh()
	var vals := []
	for id in DataLoader.abilities:
		vals.append([DataLoader.ability_name(id), GameState.get_ability(id)])
	_hex.set_values(vals, float(DataLoader.config.get("ability_chart_max", 10)))
	# 상태이상: 빨간 이름, 마우스를 올리면 설명 (StatusEffects.description)
	for c in _status_list.get_children():
		_status_list.remove_child(c)
		c.queue_free()
	for id in GameState.statuses:
		var def: Dictionary = DataLoader.status_effects.get(id, {})
		var row := PanelContainer.new()
		var rsb := StyleBoxFlat.new()
		rsb.bg_color = Color(0.17, 0.17, 0.18)
		rsb.content_margin_left = 12
		rsb.content_margin_top = 2
		rsb.content_margin_bottom = 2
		row.add_theme_stylebox_override("panel", rsb)
		row.mouse_filter = MOUSE_FILTER_STOP
		row.tooltip_text = "%s\n%s" % [def.get("name", id), def.get("description", "")]
		var l := Label.new()
		l.text = def.get("name", id)
		l.add_theme_color_override("font_color", Color("ff3030"))
		l.mouse_filter = MOUSE_FILTER_IGNORE
		row.add_child(l)
		_status_list.add_child(row)
	if GameState.statuses.is_empty():
		var none := Label.new()
		none.text = "없음"
		none.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		_status_list.add_child(none)


## 테두리 있는 칸 (상태이상 목록·육각형)
func _boxed(bg: Color) -> PanelContainer:
	var box := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_border_width_all(2)
	sb.border_color = Color(0.85, 0.85, 0.85)
	sb.set_content_margin_all(10)
	box.add_theme_stylebox_override("panel", sb)
	return box


static func _num(v: float) -> String:
	return str(int(v)) if is_equal_approx(v, roundf(v)) else "%.1f" % v
