@tool
extends "res://addons/dialogue_editor/dialogue_card.gd"
## ▶ 대화 시작 카드 (노드 kind = start, NPC 대화 파일마다 하나). 화면에 보이지 않는다.
## 말을 걸면 여기서 시작: 길(routes)을 위에서부터 보고 조건이 맞는 첫 길로, 하나도 안 맞으면 '그 외 →' (next_node).
## 예) 길 1: 대화 횟수 == 0 → 첫 만남 / 길 2: 플래그 met_boss → 보스 이야기 / 그 외 → 반복 대사
## 연결점: ["route", i] = routes[i].next_node, ["next"] = next_node. 들어오는 연결점은 없다.

const ExprRows = preload("res://addons/expr_rows.gd")
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
	title = "▶ 대화 시작   " + data.node_id
	for s in ["titlebar", "titlebar_selected"]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = START_COLOR.lightened(0.15 if s == "titlebar_selected" else 0.0)
		sb.set_content_margin_all(6)
		add_theme_stylebox_override(s, sb)
	var head := Label.new()
	head.text = "말을 걸면 여기서 시작. 위에서부터 조건이 맞는 첫 길로 갑니다."
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


func port_target(port: int) -> Array:
	var p: Array = out_ports[port]
	if p[0] == "route":
		return [data.routes[p[1]], "next_node"]
	return [data, "next_node"]
