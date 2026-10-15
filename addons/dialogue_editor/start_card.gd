@tool
extends "res://addons/dialogue_editor/dialogue_card.gd"
## ▶ 대화 시작 카드 (노드 kind = start, 한 대화에 여러 개 가능). 화면에 보이지 않는다.
## 말을 걸면 여기서 시작: 길(routes)을 위에서부터 보고 조건이 맞는 첫 길로, 하나도 안 맞으면 '그 외 →' (next_node).
## 예) 길 1: 대화 횟수 == 0 → 첫 만남 / 길 2: 플래그 met_boss → 보스 이야기 / 그 외 → 반복 대사
## 연결점: ["route", i] = routes[i].next_node, ["next"] = next_node. 들어오는 연결점은 없다.
## '🎬 자동 시작' 토글(data.trigger {when, map, once}): 켜면 말을 걸지 않아도 그 시점에 시작 — 로고 / 타이틀 이전 / 타이틀 이후 /
## 새 게임 시작 후 / 방 진입 후(맵 고르기). 한 대화에 시작 카드를 여러 개 둘 수 있다 (NPC 용 + 컷신 용 등).

const ExprRows = preload("res://addons/expr_rows.gd")
const Triggers = preload("res://core/cutscene_triggers.gd")
const START_COLOR := Color(0.55, 0.42, 0.12)

var lookups := {}


func uses_pages() -> bool:
	return false


func rebuild() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	out_ports = []
	if not data.get("routes", []) is Array:
		data.routes = []
	var routes: Array = data.routes
	title = ("🎬 자동 시작   " if _trigger_on() else "▶ 대화 시작   ") + data.node_id
	for s in ["titlebar", "titlebar_selected"]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = START_COLOR.lightened(0.15 if s == "titlebar_selected" else 0.0)
		sb.set_content_margin_all(6)
		add_theme_stylebox_override(s, sb)
	_add_row(_trigger_box(), false, false)
	var head := Label.new()
	head.text = ("자동으로 시작합니다. " if _trigger_on() else "말을 걸면 여기서 시작. ") + "위에서부터 조건이 맞는 첫 길로 갑니다."
	head.modulate = Color(1, 1, 1, 0.7)
	head.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	head.custom_minimum_size.x = 400
	_add_row(head, false, false)
	for i in routes.size():
		var r: Dictionary = routes[i]
		var box := VBoxContainer.new()
		var top := HBoxContainer.new()
		box.add_child(top)
		var l := Label.new()
		l.text = "길 %d — 이 조건이면" % (i + 1)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		top.add_child(l)
		for b in [["↑", "위로 (먼저 확인)", i - 1], ["↓", "아래로", i + 1]]:
			var mv := Button.new()
			mv.text = b[0]
			mv.flat = true
			mv.tooltip_text = b[1]
			mv.disabled = b[2] < 0 or b[2] >= routes.size()
			var to: int = b[2]
			mv.pressed.connect(func():
				routes.remove_at(i)
				routes.insert(to, r)
				rebuild()
				changed.emit("route_move"))
			top.add_child(mv)
		var del := Button.new()
		del.text = "✕"
		del.flat = true
		del.tooltip_text = "이 길 지우기"
		del.pressed.connect(func():
			routes.remove_at(i)
			rebuild()
			changed.emit("route_del"))
		top.add_child(del)
		var rows: Node = ExprRows.new().setup("cond", r.get("condition", ""), lookups)
		rows.changed.connect(func(t):
			r.condition = t
			changed.emit("route_cond:%s:%d" % [data.node_id, i]))
		box.add_child(rows)
		var go := Label.new()
		go.text = "→  " + _target_hint(r.get("next_node", ""))
		go.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_mark_missing(go, r.get("next_node", ""))
		box.add_child(go)
		_add_row(box, false, true)
		out_ports.append(["route", i])
	var add := Button.new()
	add.text = "＋ 조건 길 추가"
	add.tooltip_text = "조건이 맞을 때 갈 길을 하나 더 (위에 있는 길을 먼저 봅니다)"
	add.pressed.connect(func():
		routes.append({"condition": "", "next_node": ""})
		rebuild()
		changed.emit("route_add"))
	_add_row(add, false, false)
	var other := Label.new()
	other.text = "그 외 →  " + _target_hint(data.get("next_node", ""))
	other.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	other.tooltip_text = "어느 길의 조건도 안 맞을 때 (길이 없으면 항상 여기)"
	_mark_missing(other, data.get("next_node", ""))
	_add_row(other, false, true)
	out_ports.append(["next", -1])
	size = Vector2(size.x, 0)


func _trigger_on() -> bool:
	return data.get("trigger") is Dictionary and str(data.trigger.get("when", "")) != ""


## 자동 시작: 토글 → 시점 목록 (방 진입이면 맵, 한 번만)
func _trigger_box() -> Control:
	var vb := VBoxContainer.new()
	var tog := CheckButton.new()
	tog.text = "🎬 자동 시작 (컷신)"
	tog.tooltip_text = "켜면 말을 걸지 않아도 고른 시점에 이 대화가 시작됩니다 (로고·인트로·오프닝·방 진입 컷신)"
	tog.button_pressed = _trigger_on()
	tog.toggled.connect(func(on):
		if on:
			data.trigger = {"when": "new_game", "map": "", "once": true}
		else:
			data.erase("trigger")
		rebuild()
		changed.emit("trigger"))
	vb.add_child(tog)
	if not _trigger_on():
		return vb
	var t: Dictionary = data.trigger
	var when := OptionButton.new()
	for i in Triggers.WHENS.size():
		when.add_item(Triggers.LABEL[Triggers.WHENS[i]])
		if Triggers.WHENS[i] == t.get("when", ""):
			when.select(i)
	when.item_selected.connect(func(i):
		t.when = Triggers.WHENS[i]
		rebuild()
		changed.emit("trigger"))
	vb.add_child(when)
	if t.get("when", "") == "map_enter":
		var maps: Array = lookups.get("dests", []).filter(func(d): return not "@" in str(d[0])).map(func(d): return d[0])
		var mo := OptionButton.new()
		mo.add_item("(맵 고르기)")
		for m in maps:
			mo.add_item(m)
			if m == t.get("map", ""):
				mo.select(mo.item_count - 1)
		mo.item_selected.connect(func(i):
			t.map = maps[i - 1] if i >= 1 else ""
			rebuild()
			changed.emit("trigger"))
		vb.add_child(mo)
	if t.get("when", "") != "new_game":
		var once := CheckBox.new()
		once.text = "그 회차에 한 번만" if t.get("when", "") == "map_enter" else "처음 켤 때만 (한 번만)"
		once.button_pressed = t.get("once", false)
		once.toggled.connect(func(on):
			t.once = on
			changed.emit("trigger"))
		vb.add_child(once)
	return vb


func port_target(port: int) -> Array:
	var p: Array = out_ports[port]
	if p[0] == "route":
		return [data.routes[p[1]], "next_node"]
	return [data, "next_node"]
