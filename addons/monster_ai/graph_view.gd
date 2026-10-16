@tool
extends VBoxContainer
## '몬스터 AI' 탭의 Task Graph 화면 (Blueprint 스타일, 기획 v2.0 §5). BT 에서 TaskGraph Task 를 두 번 누르면 여기로.
## 흰 실행 핀(Exec)과 타입별 색 데이터 핀 — 타입이 안 맞는 선은 이어지지 않는다 (Int → Float 만 자동 변환).
## 실행 출력은 한 곳으로만 (새로 이으면 바뀜), 데이터 입력은 한 곳에서만. 연결 안 한 데이터 입력은 오른쪽 Details 의 '핀 기본값'.
## 왼쪽 Variables: Blackboard 키(Get/Set 노드 넣기)와 Task 지역 변수. 오른쪽 클릭 = 노드 찾아 넣기, Delete = 지우기.
## ed = ai_editor.gd (자산·실행 취소·검사·Details 를 같이 씀)

const Graph = preload("res://core/ai/task_graph.gd")
const Blackboard = preload("res://core/ai/blackboard.gd")

var ed: Control
var graph := {}
var selected := ""
var ge: GraphEdit
var vars_box: VBoxContainer
var back_btn: Button
var title_lbl: Label
var _building := false
var _errors := {}
var _clip: Array = []
const FONT := 18
const COL_W := 420.0
const ROW_H := 230.0


func _ready() -> void:
	size_flags_horizontal = SIZE_EXPAND_FILL
	var bar := HBoxContainer.new()
	add_child(bar)
	back_btn = Button.new()
	back_btn.text = "◀ BT 로 돌아가기"
	back_btn.tooltip_text = "이 그래프를 연 Behavior Tree 로 (Unreal: BT 에디터 탭으로)"
	back_btn.pressed.connect(func(): ed.go_back())
	bar.add_child(back_btn)
	title_lbl = Label.new()
	title_lbl.size_flags_horizontal = SIZE_EXPAND_FILL
	title_lbl.clip_text = true   # 긴 제목이 오른쪽 Details 칸을 밀어내지 않게
	bar.add_child(title_lbl)
	var add := Button.new()
	add.text = "＋ 노드"
	add.tooltip_text = "노드 찾아 넣기 (그래프에서 오른쪽 클릭해도 됨)"
	add.pressed.connect(func(): _search_popup(ge.get_screen_transform() * (ge.size / 2.0), ge.size / 2.0))
	bar.add_child(add)
	var arrange := Button.new()
	arrange.text = "자동 정렬"
	arrange.tooltip_text = "실행 순서대로 왼쪽→오른쪽, 데이터 노드는 쓰는 노드 아래로"
	arrange.pressed.connect(auto_layout)
	bar.add_child(arrange)
	var split := HSplitContainer.new()
	split.size_flags_vertical = SIZE_EXPAND_FILL
	add_child(split)
	var vs := ScrollContainer.new()
	vs.custom_minimum_size.x = 250
	vars_box = VBoxContainer.new()
	vars_box.size_flags_horizontal = SIZE_EXPAND_FILL
	vs.add_child(vars_box)
	split.add_child(vs)
	ge = GraphEdit.new()
	ge.size_flags_horizontal = SIZE_EXPAND_FILL
	ge.right_disconnects = true
	ge.show_zoom_label = true
	for i in Graph.TYPES.size():
		ge.add_valid_left_disconnect_type(i)
	ge.add_valid_connection_type(_tid("int"), _tid("float"))
	ge.connection_request.connect(_on_connect)
	ge.disconnection_request.connect(_on_disconnect)
	ge.delete_nodes_request.connect(_on_delete)
	ge.popup_request.connect(func(pos): _search_popup(ge.get_screen_transform() * pos, pos))
	ge.node_selected.connect(func(n): _select(String(n.name)))
	ge.begin_node_move.connect(func(): ed._touch())
	ge.end_node_move.connect(_save_positions)
	ge.copy_nodes_request.connect(_copy)
	ge.paste_nodes_request.connect(_paste)
	split.add_child(ge)


static func _tid(t: String) -> int:
	var i := Graph.TYPES.find(t)
	return i if i >= 0 else 99


func bb() -> Dictionary:
	return ed.assets.get(str(graph.get("blackboard_id", "")), {})


func set_graph(g: Dictionary, back_to := "") -> void:
	var fresh: bool = graph.get("id", "") != g.get("id", "")
	graph = g
	back_btn.visible = back_to != ""
	back_btn.text = "◀ %s 로 돌아가기" % back_to
	title_lbl.text = "  Task Graph: %s   (UE 대응: BTTask_BlueprintBase 의 Event Graph — 테바 전용 소형 도구)" % g.get("id", "")
	if not g.has("variables"):
		g.variables = []
	if not g.has("connections"):
		g.connections = []
	rebuild()
	if fresh:
		ge.zoom = 0.9
		ge.scroll_offset = Vector2(-30, -70)   # 위쪽 확대·축소 도구가 첫 노드를 가리지 않게


func node(id: String) -> Dictionary:
	for n in graph.get("nodes", []):
		if str(n.id) == id:
			return n
	return {}


# ---------------------------------------------------------------- 그리기
func rebuild() -> void:
	_building = true
	ge.clear_connections()
	for c in ge.get_children():
		if c is GraphNode:
			ge.remove_child(c)
			c.queue_free()
	_errors.clear()
	for e in Graph.validate(graph, ed.assets):
		_errors[e.node] = e.msg
	var b := bb()
	for n in graph.get("nodes", []):
		ge.add_child(_make_node(n, b))
	for c in graph.get("connections", []):
		var fi := _port(str(c.from_node), str(c.from_pin), true)
		var ti := _port(str(c.to_node), str(c.to_pin), false)
		if fi >= 0 and ti >= 0:
			ge.connect_node(StringName(c.from_node), fi, StringName(c.to_node), ti)
	_building = false
	_build_vars()


func _port(id: String, pin: String, outs: bool) -> int:
	var n := node(id)
	if n.is_empty():
		return -1
	var list: Array = Graph.NODES.get(str(n.type), {}).get("outs" if outs else "ins", [])
	for i in list.size():
		if list[i][0] == pin:
			return i
	return -1


func _make_node(n: Dictionary, b: Dictionary) -> GraphNode:
	var def: Dictionary = Graph.NODES.get(str(n.type), {})
	var gn := GraphNode.new()
	gn.name = str(n.id)
	gn.add_theme_font_size_override("font_size", FONT)
	gn.get_titlebar_hbox().add_theme_constant_override("separation", 4)
	var title := str(def.get("title", n.type))
	var prm: Dictionary = n.get("params", {})
	if prm.has("key"):   # 짧게: Get BB: 키 (전체 이름은 마우스 설명·Details)
		title = {"GetBlackboard": "Get BB", "SetBlackboard": "Set BB", "ClearBlackboard": "Clear BB"}.get(str(n.type), title) + ": " + str(prm.key)
	elif prm.has("var"):
		title = ("Get" if n.type == "GetVariable" else "Set") + ": " + str(prm.var)
	if def.get("async", false):
		title += "  ⏱"
	if _errors.has(str(n.id)):
		title = "⚠ " + title
	gn.title = title
	for c in gn.get_titlebar_hbox().get_children():
		if c is Label:
			c.add_theme_font_size_override("font_size", FONT)
	gn.tooltip_text = "UE 대응: %s\n%s%s" % [def.get("ue", "?"), def.get("desc", ""), ("\n⚠ " + _errors[str(n.id)]) if _errors.has(str(n.id)) else ""]
	var pos: Array = n.get("pos", [0, 0])
	gn.position_offset = Vector2(float(pos[0]), float(pos[1]))
	var ins := Graph.pins(n, graph, b, false)
	var outs := Graph.pins(n, graph, b, true)
	var linked_in := {}
	for c in graph.get("connections", []):
		if str(c.to_node) == str(n.id):
			linked_in[str(c.to_pin)] = true
	for i in maxi(ins.size(), outs.size()):
		var row := HBoxContainer.new()
		var l := Label.new()
		l.add_theme_font_size_override("font_size", FONT)
		if i < ins.size():
			l.text = _pin_label(ins[i])
			if ins[i][1] != "exec" and not linked_in.has(ins[i][0]) and prm.has(ins[i][0]):
				l.text += " = " + Blackboard.show(Blackboard.coerce(ins[i][1], prm[ins[i][0]]))
		row.add_child(l)
		var sp := Control.new()
		sp.size_flags_horizontal = SIZE_EXPAND_FILL
		sp.custom_minimum_size.x = 30
		row.add_child(sp)
		var rl := Label.new()
		rl.add_theme_font_size_override("font_size", FONT)
		if i < outs.size():
			rl.text = _pin_label(outs[i])
		rl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(rl)
		gn.add_child(row)
		var has_in := i < ins.size()
		var has_out := i < outs.size()
		gn.set_slot(i, has_in, _tid(ins[i][1]) if has_in else 0, Graph.TYPE_COLOR.get(ins[i][1], Color.GRAY) if has_in else Color.WHITE,
			has_out, _tid(outs[i][1]) if has_out else 0, Graph.TYPE_COLOR.get(outs[i][1], Color.GRAY) if has_out else Color.WHITE)
	if prm.has("success"):
		var res := Label.new()
		res.add_theme_font_size_override("font_size", FONT)
		res.text = "Success = %s" % ("true" if prm.success else "false")
		gn.add_child(res)
	var sb := StyleBoxFlat.new()
	sb.bg_color = {"Event": Color("6a1f1f"), "Flow": Color("3a3a3a"), "Data": Color("1f4a3a"), "Action": Color("1f3a6a"), "Result": Color("4a2f6a")}.get(def.get("cat", ""), Color("333333"))
	sb.set_content_margin_all(6)
	gn.add_theme_stylebox_override("titlebar", sb)
	var sb2: StyleBoxFlat = sb.duplicate()
	sb2.bg_color = sb.bg_color.lightened(0.2)
	gn.add_theme_stylebox_override("titlebar_selected", sb2)
	gn.selected = str(n.id) == selected
	return gn


static func _pin_label(p: Array) -> String:
	if p[1] == "exec":
		return "" if p[0] in ["exec_in", "exec_out"] else str(p[0]).capitalize()   # 흰 핀 (True·False·On Success …)
	return "%s (%s)" % [str(p[0]).capitalize(), p[1]]


## 실행 순서대로 정렬: 이벤트마다 한 줄 묶음, 실행 노드는 깊이만큼 오른쪽, 데이터 노드는 처음 쓰는 노드 아래
func auto_layout() -> void:
	ed._touch()
	var nodes := Graph.index(graph)
	var exec_next := {}
	var data_users := {}
	for c in graph.connections:
		var ft := Graph.pin_type(nodes.get(str(c.from_node), {}), str(c.from_pin), graph, bb(), true)
		if ft == "exec":
			if not exec_next.has(str(c.from_node)):
				exec_next[str(c.from_node)] = []
			exec_next[str(c.from_node)].append(str(c.to_node))
		elif not data_users.has(str(c.from_node)):
			data_users[str(c.from_node)] = str(c.to_node)
	var placed := {}
	var row_y := 0.0
	for ev in Graph.EVENTS:
		for id in nodes:
			if nodes[id].type != ev:
				continue
			var lanes := {}   # 깊이 -> 그 깊이에서 쓴 줄 수
			var todo := [[id, 0]]
			var max_lane := 0
			while not todo.is_empty():
				var it: Array = todo.pop_front()
				if placed.has(it[0]):
					continue
				var lane: int = lanes.get(it[1], 0)
				lanes[it[1]] = lane + 1
				max_lane = maxi(max_lane, lane)
				placed[it[0]] = Vector2(it[1] * COL_W, row_y + lane * ROW_H)
				for nx in exec_next.get(it[0], []):
					todo.append([nx, it[1] + 1])
			row_y += (max_lane + 1) * ROW_H + ROW_H * 0.6
	for id in nodes:
		if not placed.has(id) and data_users.has(id) and placed.has(data_users[id]):
			var at: Vector2 = placed[data_users[id]]
			var p := at + Vector2(-COL_W * 0.55, ROW_H * 0.55)
			while placed.values().has(p):
				p.y += ROW_H * 0.45
			placed[id] = p
	for id in nodes:
		if not placed.has(id):
			placed[id] = Vector2(0, row_y)
			row_y += ROW_H * 0.6
		nodes[id].pos = [roundi(placed[id].x), roundi(placed[id].y)]
	_changed()


# ---------------------------------------------------------------- 편집
func _on_connect(from: StringName, fport: int, to: StringName, tport: int) -> void:
	var fn := node(String(from))
	var tn := node(String(to))
	var fpin: String = Graph.NODES[fn.type].outs[fport][0]
	var tpin: String = Graph.NODES[tn.type].ins[tport][0]
	connect_pins(String(from), fpin, String(to), tpin)


## 선 잇기 (실행 출력·데이터 입력은 기존 선을 바꿈). 안 되면 이유를 돌려준다
func connect_pins(from: String, fpin: String, to: String, tpin: String) -> String:
	var why := Graph.can_connect(graph, bb(), from, fpin, to, tpin)
	if why != "":
		ed._status("⛔ " + why)
		return why
	ed._touch()
	var ft := Graph.pin_type(node(from), fpin, graph, bb(), true)
	graph.connections = graph.connections.filter(func(c):
		if ft == "exec":
			return not (c.from_node == from and c.from_pin == fpin)
		return not (c.to_node == to and c.to_pin == tpin))
	graph.connections.append({"from_node": from, "from_pin": fpin, "to_node": to, "to_pin": tpin})
	_changed()
	return ""


func _on_disconnect(from: StringName, fport: int, to: StringName, tport: int) -> void:
	var fn := node(String(from))
	var tn := node(String(to))
	var fpin: String = Graph.NODES[fn.type].outs[fport][0]
	var tpin: String = Graph.NODES[tn.type].ins[tport][0]
	ed._touch()
	graph.connections = graph.connections.filter(func(c): return not (c.from_node == String(from) and c.from_pin == fpin and c.to_node == String(to) and c.to_pin == tpin))
	_changed()


func _on_delete(names: Array) -> void:
	delete_nodes(names.map(func(n): return String(n)))


func delete_nodes(ids: Array) -> void:
	if ids.is_empty():
		return
	ed._touch()
	graph.nodes = graph.nodes.filter(func(n): return not str(n.id) in ids)
	graph.connections = graph.connections.filter(func(c): return not str(c.from_node) in ids and not str(c.to_node) in ids)
	if selected in ids:
		selected = ""
	_changed()


func add_node(type: String, at: Vector2, params := {}) -> String:
	if not Graph.NODES.has(type):
		return ""
	ed._touch()
	var used := {}
	for n in graph.nodes:
		used[str(n.id)] = true
	var base := type.to_snake_case()
	var i := 1
	while used.has("%s_%d" % [base, i]):
		i += 1
	var id := "%s_%d" % [base, i]
	var p := params.duplicate()
	for spec in Graph.NODES[type].get("params", []):
		if not p.has(spec[0]) and spec[2] != null and str(spec[2]) != "":
			p[spec[0]] = spec[2]
	var n := {"id": id, "type": type, "pos": [roundi(at.x), roundi(at.y)]}
	if not p.is_empty():
		n.params = p
	graph.nodes.append(n)
	selected = id
	_changed()
	return id


func _save_positions() -> void:
	for c in ge.get_children():
		if c is GraphNode:
			var n := node(String(c.name))
			if not n.is_empty():
				n.pos = [roundi(c.position_offset.x), roundi(c.position_offset.y)]
	ed.dirty[ed.current] = true
	ed.refresh_list()


func _select(id: String) -> void:
	if _building:
		return
	selected = id
	ed._build_details()


func _changed() -> void:
	ed.dirty[ed.current] = true
	var keep := ge.scroll_offset
	rebuild()
	ge.scroll_offset = keep
	ed.refresh_list()
	ed._validate_current()
	ed._build_details()


func focus_node(id: String) -> void:
	for c in ge.get_children():
		if c is GraphNode:
			c.selected = String(c.name) == id
			if String(c.name) == id:
				ge.scroll_offset = c.position_offset * ge.zoom - ge.size / 2.0 + c.size / 2.0
	_select(id)


func _copy() -> void:
	_clip = []
	for c in ge.get_children():
		if c is GraphNode and c.selected:
			_clip.append(node(String(c.name)).duplicate(true))


func _paste() -> void:
	if _clip.is_empty():
		return
	for n in _clip:
		var pos: Array = n.get("pos", [0, 0])
		add_node(str(n.type), Vector2(float(pos[0]) + 40, float(pos[1]) + 40), n.get("params", {}))


func _search_popup(screen_pos: Vector2, graph_pos: Vector2) -> void:
	var pop := PopupPanel.new()
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(340, 400)
	var le := LineEdit.new()
	le.placeholder_text = "노드 찾기 (Branch, Get Blackboard, Move To, Finish …)"
	box.add_child(le)
	var list := ItemList.new()
	list.size_flags_vertical = SIZE_EXPAND_FILL
	box.add_child(list)
	pop.add_child(box)
	var at := (graph_pos + ge.scroll_offset) / ge.zoom
	var fill := func(t: String):
		list.clear()
		for cat in Graph.CATS:
			for k in Graph.NODES:
				var d: Dictionary = Graph.NODES[k]
				if d.cat != cat:
					continue
				if t != "" and not t.to_lower() in (k + " " + str(d.title)).to_lower():
					continue
				list.add_item("[%s] %s" % [cat, d.title])
				list.set_item_metadata(list.item_count - 1, k)
				list.set_item_tooltip(list.item_count - 1, "UE 대응: %s\n%s" % [d.ue, d.desc])
	fill.call("")
	le.text_changed.connect(fill)
	var pick := func(i):
		add_node(list.get_item_metadata(i), at)
		pop.hide()
	list.item_activated.connect(pick)
	le.text_submitted.connect(func(_t):
		if list.item_count > 0:
			pick.call(0))
	pop.popup_hide.connect(pop.queue_free)
	add_child(pop)
	pop.popup(Rect2i(Vector2i(screen_pos), Vector2i(340, 400)))
	le.grab_focus.call_deferred()


# ---------------------------------------------------------------- Variables (왼쪽)
func _build_vars() -> void:
	for c in vars_box.get_children():
		vars_box.remove_child(c)
		c.queue_free()
	var h := Label.new()
	h.text = "Blackboard 키 (%s)" % graph.get("blackboard_id", "?")
	h.tooltip_text = "몬스터가 아는 값 — 다른 Task·Decorator 와 같이 씀. Get/Set 을 누르면 노드를 넣음"
	h.mouse_filter = MOUSE_FILTER_PASS
	vars_box.add_child(h)
	for k in bb().get("keys", []):
		var row := HBoxContainer.new()
		var l := Label.new()
		l.text = "◆ %s" % k.name
		l.add_theme_color_override("font_color", Graph.TYPE_COLOR.get(str(k.type), Color.WHITE))
		l.tooltip_text = str(k.type)
		l.mouse_filter = MOUSE_FILTER_PASS
		l.size_flags_horizontal = SIZE_EXPAND_FILL
		l.clip_text = true
		row.add_child(l)
		var key := str(k.name)
		for t in [["Get", "GetBlackboard"], ["Set", "SetBlackboard"]]:
			var b := Button.new()
			b.text = t[0]
			b.pressed.connect(func(): add_node(t[1], _view_center(), {"key": key}))
			row.add_child(b)
		vars_box.add_child(row)
	vars_box.add_child(HSeparator.new())
	var h2 := Label.new()
	h2.text = "Task 지역 변수 (테바: 실행할 때마다 기본값)"
	vars_box.add_child(h2)
	var vs: Array = graph.get("variables", [])
	for i in vs.size():
		var v: Dictionary = vs[i]
		var row := HBoxContainer.new()
		var ne := LineEdit.new()
		ne.text = str(v.name)
		ne.custom_minimum_size.x = 90
		ne.text_submitted.connect(func(t): _rename_var(str(v.name), t.strip_edges()))
		row.add_child(ne)
		var tb := OptionButton.new()
		for t in Graph.TYPES.slice(1):
			tb.add_item(t)
			if t == str(v.type):
				tb.select(tb.item_count - 1)
		tb.item_selected.connect(func(ti):
			ed._touch()
			v.type = Graph.TYPES.slice(1)[ti]
			v.default = Blackboard.coerce(v.type, null)
			_changed())
		row.add_child(tb)
		for t in [["Get", "GetVariable"], ["Set", "SetVariable"]]:
			var b := Button.new()
			b.text = t[0]
			var vn := str(v.name)
			b.pressed.connect(func(): add_node(t[1], _view_center(), {"var": vn}))
			row.add_child(b)
		var x := Button.new()
		x.text = "✕"
		x.pressed.connect(func():
			ed._touch()
			vs.remove_at(i)
			_changed())
		row.add_child(x)
		vars_box.add_child(row)
	var add := Button.new()
	add.text = "＋ 변수"
	add.pressed.connect(add_var)
	vars_box.add_child(add)


func add_var() -> String:
	ed._touch()
	var names: Array = graph.variables.map(func(v): return str(v.name))
	var i := 1
	while names.has("Var%d" % i):
		i += 1
	graph.variables.append({"name": "Var%d" % i, "type": "bool", "default": false})
	_changed()
	return "Var%d" % i


func _rename_var(old: String, new_name: String) -> void:
	if new_name == "" or new_name == old or graph.variables.any(func(v): return v.name == new_name):
		return
	ed._touch()
	for v in graph.variables:
		if v.name == old:
			v.name = new_name
	for n in graph.nodes:
		if n.get("params", {}).get("var", "") == old:
			n.params.var = new_name
	_changed()


func _view_center() -> Vector2:
	return (ge.scroll_offset + ge.size / 2.0) / ge.zoom - Vector2(100, 40)


# ---------------------------------------------------------------- Details (오른쪽, ed 가 부른다)
func build_details(box: VBoxContainer) -> void:
	var n := node(selected)
	if n.is_empty():
		ed._head("Task Graph: " + str(graph.get("id", "")), "UE 대응: BTTask_BlueprintBase 의 Event Graph (테바 전용 소형 도구 — 실제 Blueprint 자산과 호환되지 않음)")
		ed._note("노드를 고르면 여기서 설정합니다. 오른쪽 클릭 = 노드 찾기, 흰 핀 = 실행 순서, 색 핀 = 데이터.")
		ed._option("Blackboard", ed._ids_of("blackboard").map(func(b): return [b, b]), str(graph.get("blackboard_id", "")), func(v):
			ed._touch()
			graph.blackboard_id = v
			_changed())
		return
	var def: Dictionary = Graph.NODES.get(str(n.type), {})
	ed._head(str(def.get("title", n.type)), "UE 대응: %s\n%s" % [def.get("ue", "?"), def.get("desc", "")])
	ed._note("ID: %s   ·   분류: %s%s" % [n.id, def.get("cat", ""), "   ·   비동기 (RUNNING 유지)" if def.get("async", false) else ""])
	if not n.has("params"):
		n.params = {}
	var prm: Dictionary = n.params
	var set_p := func(key: String, v, rebuild_all := true):
		ed._touch("gparam:%s:%s" % [n.id, key])
		prm[key] = v
		ed.dirty[ed.current] = true
		if rebuild_all:
			_changed()
		else:
			rebuild()
			ed._validate_current()
	for spec in def.get("params", []):
		var pname: String = spec[0]
		match str(spec[1]):
			"key":
				ed._option(pname, ed._keys_of_types([]), str(prm.get(pname, "")), func(v): set_p.call(pname, v))
			"var":
				ed._option(pname, graph.variables.map(func(v): return [str(v.name), "%s (%s)" % [v.name, v.type]]), str(prm.get(pname, "")), func(v): set_p.call(pname, v))
			"op":
				ed._option(pname, Graph.OPS.map(func(o): return [o, o]), str(prm.get(pname, "<")), func(v): set_p.call(pname, v))
			"who":
				ed._option(pname, [["self", "자기 (몬스터)"], ["player", "플레이어"]], str(prm.get(pname, "self")), func(v): set_p.call(pname, v))
			"bool":
				var row: HBoxContainer = ed._row(pname)
				row.add_child(ed._value_editor("bool", prm.get(pname, spec[2]), func(v): set_p.call(pname, v, false)))
			"number":
				var row: HBoxContainer = ed._row(pname)
				row.add_child(ed._value_editor("float", prm.get(pname, spec[2]), func(v): set_p.call(pname, v, false)))
	# 연결 안 한 데이터 입력 = 핀 기본값
	var linked := {}
	for c in graph.connections:
		if str(c.to_node) == str(n.id):
			linked[str(c.to_pin)] = true
	var shown := false
	for pin in Graph.pins(n, graph, bb(), false):
		if pin[1] == "exec" or linked.has(pin[0]) or pin[1] in ["any", "entity_ref"]:
			continue
		if not shown:
			ed._section("핀 기본값 (선을 잇지 않았을 때)")
			shown = true
		var row: HBoxContainer = ed._row("%s (%s)" % [pin[0], pin[1]])
		var pn: String = pin[0]
		row.add_child(ed._value_editor(pin[1], prm.get(pn), func(v): set_p.call(pn, v, false)))
	if _errors.has(str(n.id)):
		ed._note("⚠ " + _errors[str(n.id)])
	var del := Button.new()
	del.text = "이 노드 지우기 (Delete)"
	del.pressed.connect(func(): delete_nodes([str(n.id)]))
	box.add_child(del)
