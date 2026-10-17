@tool
extends VBoxContainer
## '몬스터 AI' 탭의 Runtime Debugger (Unreal BT Debugger 처럼, 기획 v2.0 §9).
## Godot 에서 게임(F5)이나 맵 탭 '테스트 플레이'로 실행하면, 게임이 0.25초마다 BT 몬스터 상태를 보낸다 (ai_debugger_plugin).
## 왼쪽 몬스터 목록에서 고르면: BT·지금 Task·Blackboard 값과 마지막으로 바꾼 곳(Sensor·Service·Task·Editor Override)·
## Decorator 판정·최근 기록(시작·끝·Observer Aborts 중단과 이유). 'BT 그래프에 표시' 를 켜 두면 Behavior Tree 탭의 카드에
## 실행 경로(노란 선)와 결과(SUCCESS 초록·FAILURE 빨강·RUNNING 노랑·ABORTED 보라)가 보인다. 기록을 누르면 그 노드로.

const Runner = preload("res://core/ai/bt_runner.gd")

var ed: Control                # ai_editor.gd
var latest := {}               # 마지막으로 받은 {map, frozen, paused, monsters}
var paused := false
var pause_btn: Button
var selected_id := ""
var status: Label
var follow: CheckBox
var list: ItemList
var info: Label
var keys: Tree
var decos: ItemList
var logs: ItemList
var _log_nodes: Array = []


func _ready() -> void:
	size_flags_horizontal = SIZE_EXPAND_FILL
	var bar := HBoxContainer.new()
	add_child(bar)
	status = Label.new()
	status.text = "게임 실행을 기다리는 중 — Godot 에서 F5 나 맵 탭 '▶ 테스트 플레이' 로 실행하면 BT 몬스터가 여기 나타납니다."
	status.size_flags_horizontal = SIZE_EXPAND_FILL
	status.clip_text = true
	bar.add_child(status)
	follow = CheckBox.new()
	follow.text = "BT 그래프에 표시"
	follow.button_pressed = true
	follow.tooltip_text = "고른 몬스터의 실행 경로·결과를 Behavior Tree 탭 카드에 표시"
	follow.toggled.connect(func(_v): _highlight())
	bar.add_child(follow)
	pause_btn = Button.new()
	pause_btn.text = "⏸ 일시정지"
	pause_btn.tooltip_text = "실행 중인 게임의 몬스터를 모두 멈춤 / 다시 움직임 (플레이어는 움직일 수 있음)"
	pause_btn.pressed.connect(func(): set_game_paused(not paused))
	bar.add_child(pause_btn)
	var step := Button.new()
	step.text = "▶| 한 단계"
	step.tooltip_text = "멈춘 상태에서 몬스터를 한 프레임만 진행"
	step.pressed.connect(func(): ed.send_to_game("monster_ai:step", []))
	bar.add_child(step)
	var open := Button.new()
	open.text = "이 몬스터의 BT 열기"
	open.pressed.connect(func():
		var m := monster()
		if not m.is_empty() and ed.assets.has(str(m.snap.bt)):
			ed.open_asset(str(m.snap.bt))
			ed.tabs.current_tab = 0
			_highlight())
	bar.add_child(open)
	var split := HSplitContainer.new()
	split.size_flags_vertical = SIZE_EXPAND_FILL
	add_child(split)
	list = ItemList.new()
	list.custom_minimum_size.x = 260
	list.item_selected.connect(func(i):
		selected_id = list.get_item_metadata(i)
		var m := monster()
		if not m.is_empty() and ed.assets.has(str(m.snap.bt)) and ed.current != str(m.snap.bt):
			ed.open_asset(str(m.snap.bt))
			ed.tabs.current_tab = 3
		_show())
	split.add_child(list)
	var right := VBoxContainer.new()
	right.size_flags_horizontal = SIZE_EXPAND_FILL
	split.add_child(right)
	info = Label.new()
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(info)
	var mid := HSplitContainer.new()
	mid.size_flags_vertical = SIZE_EXPAND_FILL
	right.add_child(mid)
	keys = Tree.new()
	keys.columns = 3
	keys.column_titles_visible = true
	keys.set_column_title(0, "Blackboard 키")
	keys.set_column_title(1, "값")
	keys.set_column_title(2, "마지막으로 바꾼 곳")
	keys.hide_root = true
	keys.size_flags_horizontal = SIZE_EXPAND_FILL
	keys.custom_minimum_size.x = 520
	for c in 3:
		keys.set_column_custom_minimum_width(c, [220, 160, 130][c])
		keys.set_column_expand_ratio(c, [3, 2, 2][c])
		keys.set_column_clip_content(c, true)
	mid.add_child(keys)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = SIZE_EXPAND_FILL
	mid.add_child(col)
	var dl := Label.new()
	dl.text = "◇ Decorator 마지막 판정"
	col.add_child(dl)
	decos = ItemList.new()
	decos.custom_minimum_size.y = 120
	col.add_child(decos)
	var ll := Label.new()
	ll.text = "기록 (최근이 위 — 누르면 그 노드로)"
	col.add_child(ll)
	logs = ItemList.new()
	logs.size_flags_vertical = SIZE_EXPAND_FILL
	logs.item_clicked.connect(func(i, _p, _b):
		if i < _log_nodes.size() and _log_nodes[i] != "":
			_focus(_log_nodes[i]))
	col.add_child(logs)


func set_game_paused(v: bool) -> void:
	paused = v
	pause_btn.text = "▶ 재개" if v else "⏸ 일시정지"
	ed.send_to_game("monster_ai:pause", [v])


func monster() -> Dictionary:
	for m in latest.get("monsters", []):
		if str(m.id) == selected_id:
			return m
	return {}


## 게임에서 받은 상태 (0.25초마다)
func on_snapshot(data: Dictionary) -> void:
	latest = data
	var ms: Array = data.get("monsters", [])
	var hits := ms.filter(func(m): return str(m.snap.get("bp_hit", "")) != "")
	status.text = "실행 중 — 맵 %s · BT 몬스터 %d%s%s" % [data.get("map", "?"), ms.size(), "  (필드 멈춤: 전투·대화·메뉴)" if data.get("frozen", false) else "",
		("  ⏸ 몬스터 일시정지" + (" — 브레이크포인트: %s" % ", ".join(hits.map(func(m): return "%s @ %s" % [m.id, m.snap.bp_hit])) if not hits.is_empty() else "")) if data.get("paused", false) else ""]
	if bool(data.get("paused", false)) != paused:
		paused = bool(data.get("paused", false))
		pause_btn.text = "▶ 재개" if paused else "⏸ 일시정지"
	if not hits.is_empty() and selected_id == "":
		selected_id = str(hits[0].id)
	list.clear()
	for m in ms:
		var s: Dictionary = m.snap
		list.add_item("%s  %s\n   %s · %s" % [m.id, m.get("name", ""), s.bt, s.task if s.task != "" else "-"])
		list.set_item_metadata(list.item_count - 1, str(m.id))
		if str(m.id) == selected_id:
			list.select(list.item_count - 1)
	if selected_id == "" and not ms.is_empty():
		selected_id = str(ms[0].id)
		list.select(0)
	_show()


func on_session_stopped() -> void:
	status.text = "게임이 끝남 — 마지막으로 받은 상태를 보여 줍니다."
	if ed and ed.canvas:
		ed.canvas.debug = {}
		ed.canvas.queue_redraw()


func _show() -> void:
	var m := monster()
	keys.clear()
	decos.clear()
	logs.clear()
	_log_nodes.clear()
	if m.is_empty():
		info.text = "몬스터를 고르세요."
		_highlight()
		return
	var s: Dictionary = m.snap
	var path: Array = s.active.map(func(id): return _name(s.bt, id))
	info.text = "%s (%s) · 위치 %s · BT %s / BB %s · 시간 %.1f초%s\n실행 경로: %s\n지금 Task: %s%s%s" % [
		m.id, m.get("ref", ""), m.tile, s.bt, s.bb, s.time, "  · 도주 유예 %.1f초" % m.grace if m.grace > 0 else "",
		" → ".join(path) if not path.is_empty() else "(없음 — 다음 tick 에 처음부터)",
		_name(s.bt, s.task) if s.task != "" else "-", "  (Task Graph %s: %s)" % [s.graph, " → ".join(s.graph_trace)] if s.graph != "" else "",
		"\n⛔ 오류: " + s.error if s.error != "" else ""]
	var r := keys.create_item()
	for k in s.keys:
		var it := keys.create_item(r)
		it.set_text(0, "%s (%s)" % [k[0], k[3]])
		it.set_text(1, k[1])
		it.set_text(2, k[2])
		it.set_tooltip_text(1, k[1])
	for key in s.decorators:
		var id: String = key.split("/")[0]
		var i := int(key.split("/")[1])
		var d: Dictionary = _decorator(s.bt, id, i)
		decos.add_item("%s %s · %s = %s%s" % ["✓" if s.decorators[key] else "✗", _name(s.bt, id), Runner.decorator_text(d) if not d.is_empty() else "#%d" % i,
			s.decorators[key], "   ⤴ " + str(d.get("observer_aborts", "None")) if str(d.get("observer_aborts", "None")) != "None" else ""])
	var lg: Array = s.log.duplicate()
	lg.reverse()
	for e in lg:
		var txt := "%6.2f  %s  %s  %s  %s" % [e.t, e.ev, _name(s.bt, e.node) if e.node != "" else "", e.result, e.reason]
		logs.add_item(txt)
		logs.set_item_tooltip(logs.item_count - 1, txt)
		_log_nodes.append(str(e.node))
		var c := Color.WHITE
		match str(e.ev):
			"observer_abort", "abort": c = Color("c070ff")
			"error": c = Color("ff6060")
			"decorator": c = Color("f0a040")
			"exit": c = Color("8fd08f") if e.result == "SUCCESS" else Color("e08080")
		logs.set_item_custom_fg_color(logs.item_count - 1, c)
	_highlight()


## Behavior Tree 탭 카드에 실행 경로·결과 표시 (고른 몬스터의 BT 가 열려 있을 때)
func _highlight() -> void:
	if ed == null or ed.canvas == null:
		return
	var m := monster()
	if follow.button_pressed and not m.is_empty() and ed.current == str(m.snap.bt):
		ed.canvas.debug = {"active": m.snap.active, "results": m.snap.results}
	else:
		ed.canvas.debug = {}
	ed.canvas.queue_redraw()


func _focus(id: String) -> void:
	var m := monster()
	if m.is_empty():
		return
	if ed.current != str(m.snap.bt):
		ed.open_asset(str(m.snap.bt))
	ed.tabs.current_tab = 0
	if not ed.node(id).is_empty():
		ed._select(id, true)
	_highlight()


func _node_of(bt: String, id: String) -> Dictionary:
	for n in ed.assets.get(bt, {}).get("nodes", []):
		if str(n.id) == id:
			return n
	return {}


func _name(bt: String, id: String) -> String:
	var n := _node_of(bt, id)
	if n.is_empty():
		return id
	var nm := str(n.get("name", ""))
	return nm if nm != "" else "%s(%s)" % [n.get("task_type", n.get("kind", "?")), id]


func _decorator(bt: String, id: String, i: int) -> Dictionary:
	var ds: Array = _node_of(bt, id).get("decorators", [])
	return ds[i] if i < ds.size() else {}
