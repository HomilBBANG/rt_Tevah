extends Control
## 소지품(인벤토리) 창: 격자 칸. 두 가지 모드:
##   browse  — 칸을 눌러 설명 보기, 사용, 장착(우클릭·끌어서 장비창에 놓기)
##   discard — 인벤토리 초과 시 버릴 칸 고르기 (StoryRunner.inventory_full 에 연결)
## 칸 수 = GameState.slot_count() (기본 + 가방). 위에 들고 있는 무게 / 최대 무게.
## dock = "right" 이면 화면 오른쪽에 붙고 뒤를 가리지 않는다 (필드: 장비창과 같이 열어 끌어다 놓기).

const ItemCell = preload("res://ui/item_cell.gd")

## 비어 있지 않으면 '사용' 버튼이 StoryRunner.use_item 대신 이것을 부른다 (전투: 칸 번호를 받음)
var use_handler: Callable
## "center" (가운데, 뒤를 어둡게) / "right" (오른쪽, 뒤 조작 가능)
var dock := "center"
## 장착 가능 여부 (장착 버튼·우클릭). 전투 중에는 끈다
var allow_equip := true

var _mode := "browse"
var _selected := -1


func _ready() -> void:
	hide()
	%UseButton.pressed.connect(_on_use)
	%EquipButton.pressed.connect(func(): equip_slot(_selected))
	%GiveUpButton.pressed.connect(_finish_discard.bind(-1))
	%CloseButton.pressed.connect(hide)
	GameState.inventory_changed.connect(func(): if visible: _refresh())
	GameState.equipment_changed.connect(func(): if visible: _refresh())


func open_browse() -> void:
	_mode = "browse"
	_selected = -1
	%UseButton.visible = true
	%EquipButton.visible = allow_equip
	%CloseButton.visible = true
	%GiveUpButton.visible = false
	%Hint.visible = allow_equip
	%Status.text = ""
	_apply_dock()
	_refresh()
	show()


func open_discard(item_id: String, amount: int) -> void:
	_mode = "discard"
	_selected = -1
	%UseButton.visible = false
	%EquipButton.visible = false
	%CloseButton.visible = false
	%GiveUpButton.visible = true
	%GiveUpButton.text = "%s 포기" % DataLoader.item_name(item_id)
	%Hint.visible = false
	%Status.text = ""
	_apply_dock()
	_refresh()
	%Title.text = "소지품이 가득 찼습니다: %s x%d\n버릴 칸을 고르세요." % [DataLoader.item_name(item_id), amount]
	show()


## 인벤토리 칸을 장착 (우클릭·장착 버튼·끌어다 놓기). 실패하면 이유를 보여준다.
func equip_slot(i: int) -> void:
	if not allow_equip or i < 0:
		return
	var err := GameState.equip(i)
	%Status.text = err
	if err == "":
		_selected = -1


func _apply_dock() -> void:
	var right := dock == "right"
	$Dim.visible = not right
	mouse_filter = MOUSE_FILTER_IGNORE if right else MOUSE_FILTER_STOP
	$Center.mouse_filter = MOUSE_FILTER_IGNORE if right else MOUSE_FILTER_STOP
	$Center.anchor_left = 0.56 if right else 0.0


func _refresh() -> void:
	for c in %Slots.get_children():
		%Slots.remove_child(c)
		c.queue_free()
	var inv := GameState.inventory
	if _selected >= inv.size():
		_selected = -1
	var total := GameState.slot_count()
	if _mode == "browse":
		%Title.text = "소지품   %d / %d 칸" % [inv.size(), total]
	_show_weight()
	for i in maxi(total, inv.size()):
		var cell := ItemCell.new()
		cell.source = "inv"
		cell.index = i
		if i < inv.size():
			cell.setup(inv[i].id, inv[i].count)
			cell.pressed.connect(_on_slot.bind(i))
			cell.right_clicked.connect(func(): if _mode == "browse": equip_slot(i))
		else:
			cell.setup("", 0)
		cell.set_selected(i == _selected)
		# 장비창에서 끌어온 장비를 놓으면 벗기
		cell.accept = func(d): return _mode == "browse" and d.from == "equip"
		cell.on_drop = func(d): %Status.text = GameState.unequip(d.slot_id)
		%Slots.add_child(cell)

	var item: Dictionary = DataLoader.items.get(inv[_selected].id, {}) if _selected >= 0 else {}
	if item.is_empty():
		%Desc.text = "아이템을 선택하세요." if _mode == "browse" else ""
	else:
		var slot_name := _slot_name(item.get("equip_slot", ""))
		%Desc.text = "[%s] %s\n무게 %s%s" % [item.type, item.description, _num(item.get("weight", 0.0)),
			"   ·   장착: %s" % slot_name if slot_name != "" else ""]
	var story_over := StoryRunner.ended and StoryRunner.mode == "episode" and not use_handler.is_valid()   # 필드에서는 대화 밖에서도 사용 가능
	%UseButton.disabled = item.get("use_effects", "") == "" or story_over
	%EquipButton.disabled = item.get("equip_slot", "") == ""


func _show_weight() -> void:
	var w := GameState.carry_weight()
	var mx := GameState.carry_max()
	var mult := GameState.carry_speed_mult()
	var note := ""
	var col := Color("bbbbbb")
	if mult <= 0.0:
		note = "  —  너무 무거워 움직일 수 없다"
		col = Color("e46a6a")
	elif mult < 1.0:
		note = "  —  무거워서 느려진다"
		col = Color("e8c35a")
	%Weight.text = "무게 %s / %s%s" % [_num(w), _num(mx), note]
	%Weight.add_theme_color_override("font_color", col)


func _slot_name(slot_id: String) -> String:
	for s in DataLoader.equip_slots:
		if s.slot_id == slot_id:
			return s.name
	return slot_id


static func _num(v: float) -> String:
	return str(int(v)) if is_equal_approx(v, roundf(v)) else "%.1f" % v


func _on_use() -> void:
	if use_handler.is_valid():
		use_handler.call(_selected)
	else:
		StoryRunner.use_item(_selected)


func _on_slot(i: int) -> void:
	if _mode == "discard":
		_finish_discard(i)
	else:
		_selected = i
		%Status.text = ""
		_refresh()


func _finish_discard(slot: int) -> void:
	hide()
	StoryRunner.choose_discard(slot)
