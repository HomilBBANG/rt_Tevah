extends Control
## 장비창 (필드에서 Q). 화면 왼쪽에 붙고, 소지품 창(I, 오른쪽)과 같이 열어 끌어다 놓을 수 있다.
##   장비 탭  — EquipSlots 칸마다 장착한 아이템. 소지품에서 끌어와 놓으면 장착, 칸을 우클릭하거나 소지품으로 끌면 벗기
##   능력치 탭 — 맨 위 '내 상태'(부위 HP), 아래 능력치 6개 육각형

const ItemCell = preload("res://ui/item_cell.gd")
const BodyDiagram = preload("res://ui/body_diagram.gd")
const Hexagon = preload("res://ui/ability_hexagon.gd")

var _tabs: TabContainer
var _slots_box: GridContainer
var _info: Label
var _status: Label
var _body: Control
var _hex: Control


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
	_slots_box = GridContainer.new()
	_slots_box.columns = 2
	_slots_box.add_theme_constant_override("h_separation", 20)
	_slots_box.add_theme_constant_override("v_separation", 12)
	equip.add_child(_slots_box)
	_info = Label.new()
	_info.add_theme_font_size_override("font_size", 22)
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	equip.add_child(_info)
	var hint := Label.new()
	hint.text = "소지품(I)에서 끌어와 놓거나 소지품에서 우클릭하면 장착.\n칸을 우클릭하거나 소지품으로 끌면 벗기."
	hint.add_theme_font_size_override("font_size", 20)
	hint.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	equip.add_child(hint)

	# ---- 능력치 탭
	var stats := VBoxContainer.new()
	stats.name = "능력치"
	_tabs.add_child(stats)
	var title := Label.new()
	title.text = "내 상태"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 32)
	stats.add_child(title)
	_body = BodyDiagram.new()
	_body.figure = true
	_body.mouse_filter = MOUSE_FILTER_IGNORE
	_body.custom_minimum_size = Vector2(0, 260)
	stats.add_child(_body)
	_hex = Hexagon.new()
	_hex.size_flags_vertical = SIZE_EXPAND_FILL
	_hex.custom_minimum_size = Vector2(0, 360)
	stats.add_child(_hex)

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

	for sig in [GameState.equipment_changed, GameState.inventory_changed, GameState.body_changed]:
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
	for s in DataLoader.equip_slots:
		var l := Label.new()
		l.text = s.name
		l.custom_minimum_size.x = 90
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_slots_box.add_child(l)
		var cell := ItemCell.new()
		cell.source = "equip"
		cell.slot_id = s.slot_id
		cell.custom_minimum_size = Vector2(380, 84)
		cell.setup(GameState.equipment.get(s.slot_id, ""), 1, "(비어 있음)")
		var sid: String = s.slot_id
		cell.right_clicked.connect(func(): _status.text = GameState.unequip(sid))
		# 소지품에서 끌어온, 이 칸에 맞는 아이템만 받는다
		cell.accept = func(d): return d.from == "inv" and DataLoader.items.get(d.item_id, {}).get("equip_slot", "") == sid
		cell.on_drop = func(d): _status.text = GameState.equip(d.index)
		_slots_box.add_child(cell)
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


static func _num(v: float) -> String:
	return str(int(v)) if is_equal_approx(v, roundf(v)) else "%.1f" % v
