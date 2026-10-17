@tool
extends Control
## Behavior Tree 그래프 (Unreal BT 에디터처럼 위 Root → 아래 자식, 왼쪽이 먼저). 몬스터 AI 기획 v2.0 §3.1, §6.
## 위치는 children 순서로 자동 배치 — 선 위치가 아니라 children 순서가 우선순위의 유일한 기준이고, 카드 왼쪽 위에 순서 번호.
## Decorator(파랑 ◇)는 카드 위쪽, Service(초록 ⟳)는 카드 아래쪽에 붙은 작은 줄. 색만이 아니라 기호·글자로도 구분.
## 조작: 누르기 = 고르기 / 두 번 누르기 = Task Graph 열기(Task 가 TaskGraph 일 때) / 카드를 좌우로 끌기 = 형제 사이 순서 바꾸기(미리보기 선)
##       가운데·오른쪽 버튼 끌기 = 화면 옮기기, 휠 = 확대·축소, 오른쪽 클릭 = 노드 찾아 넣기.

signal node_selected(id: String)
signal node_activated(id: String)
signal reorder_requested(id: String, new_index: int)
signal context_requested(screen_pos: Vector2, id: String)

const Tasks = preload("res://core/ai/bt_tasks.gd")
const Runner = preload("res://core/ai/bt_runner.gd")

const CARD_W := 290.0
const H_GAP := 36.0
const V_GAP := 70.0
const ROW_H := 30.0
const KIND_COLOR := {"Root": Color("3a3a44"), "Selector": Color("4a4f5a"), "Sequence": Color("4a4f5a"), "SimpleParallel": Color("3f5a5a"), "Task": Color("5a3f78")}
const KIND_MARK := {"Root": "⌂ ROOT", "Selector": "?  Selector", "Sequence": "→  Sequence", "SimpleParallel": "⇉  Simple Parallel", "Task": "▶  Task"}
const DECO_COLOR := Color("2f5f9a")
const SERV_COLOR := Color("2f7a5a")
const RESULT_COLOR := {"SUCCESS": Color("4caf50"), "FAILURE": Color("e05050"), "RUNNING": Color("f0c040"), "ABORTED": Color("c070ff")}

var tree := {}            # BT 자산
var selected := ""
var debug := {}           # 디버거: {active: [id], results: {id: 결과}} — 비면 표시 안 함
var errors := {}          # id -> 오류 글 (카드에 ⚠)
var breakpoints := {}     # id -> true: 디버거 브레이크포인트 (카드 왼쪽에 빨간 점)
var zoom := 1.0
var offset := Vector2(40, 30)
var rects := {}           # id -> Rect2 (내용 좌표)
var _nodes := {}
var _drag_id := ""
var _drag_from := Vector2.ZERO
var _drag_now := Vector2.ZERO
var _dragging := false
var _panning := false
var _need_fit := false


func _ready() -> void:
	clip_contents = true
	focus_mode = FOCUS_CLICK
	mouse_filter = MOUSE_FILTER_STOP


func set_tree(t: Dictionary) -> void:
	tree = t
	relayout()
	_need_fit = true   # 크기가 정해진 뒤 처음 그릴 때 전체가 보이게


func relayout() -> void:
	_nodes.clear()
	for n in tree.get("nodes", []):
		_nodes[str(n.id)] = n
	rects.clear()
	var root := str(tree.get("root_id", ""))
	if _nodes.has(root):
		var heights := {}
		_row_heights(root, 0, heights, {})
		var ys := [0.0]
		for d in range(1, heights.size() + 1):
			ys.append(ys[d - 1] + heights.get(d - 1, 0.0) + V_GAP)
		_place(root, 0.0, 0, ys, {})
	queue_redraw()


func card_height(n: Dictionary) -> float:
	var h := 2 * ROW_H + 10.0   # 제목 + 이름/요약
	h += ROW_H * n.get("decorators", []).size()
	h += ROW_H * n.get("services", []).size()
	if str(n.kind) == "Task" and not n.get("params", {}).is_empty():
		h += ROW_H
	return h


func _row_heights(id: String, depth: int, out: Dictionary, seen: Dictionary) -> void:
	if seen.has(id) or not _nodes.has(id):
		return
	seen[id] = true
	out[depth] = maxf(out.get(depth, 0.0), card_height(_nodes[id]))
	for c in _nodes[id].get("children", []):
		_row_heights(str(c), depth + 1, out, seen)


func _width(id: String, seen: Dictionary) -> float:
	if seen.has(id) or not _nodes.has(id):
		return 0.0
	seen[id] = true
	var kids: Array = _nodes[id].get("children", [])
	var w := 0.0
	for c in kids:
		w += _width(str(c), seen) + H_GAP
	return maxf(CARD_W, w - H_GAP)


func _place(id: String, left: float, depth: int, ys: Array, seen: Dictionary) -> void:
	if seen.has(id) or not _nodes.has(id):
		return
	var w := _width(id, seen.duplicate())
	seen[id] = true
	rects[id] = Rect2(left + (w - CARD_W) / 2.0, ys[depth], CARD_W, card_height(_nodes[id]))
	var x := left
	var kids: Array = _nodes[id].get("children", [])
	var kid_total := 0.0
	for c in kids:
		kid_total += _width(str(c), seen.duplicate()) + H_GAP
	kid_total -= H_GAP
	x = left + (w - kid_total) / 2.0
	for c in kids:
		var cw := _width(str(c), seen.duplicate())
		_place(str(c), x, depth + 1, ys, seen)
		x += cw + H_GAP


# ---------------------------------------------------------------- 그리기
func _to_screen(p: Vector2) -> Vector2:
	return p * zoom + offset


func _to_content(p: Vector2) -> Vector2:
	return (p - offset) / zoom


func _draw() -> void:
	if _need_fit and size.x > 50 and size.y > 50:
		_need_fit = false
		fit()
		return
	draw_rect(Rect2(Vector2.ZERO, size), Color("1e1f24"))
	var font := get_theme_default_font()
	var fs := int(clampf(18.0 * zoom, 8, 34))
	# 선 (부모 아래 가운데 → 자식 위 가운데)
	for id in rects:
		var kids: Array = _nodes[id].get("children", [])
		for c in kids:
			if not rects.has(str(c)):
				continue
			var a: Rect2 = rects[id]
			var b: Rect2 = rects[str(c)]
			var p1 := _to_screen(Vector2(a.get_center().x, a.end.y))
			var p2 := _to_screen(Vector2(b.get_center().x, b.position.y))
			var mid := (p1.y + p2.y) / 2.0
			var col := Color(0.75, 0.75, 0.8, 0.8)
			if debug.get("active", []).has(str(c)):
				col = RESULT_COLOR.RUNNING
			draw_polyline([p1, Vector2(p1.x, mid), Vector2(p2.x, mid), p2], col, maxf(1.5, 2.5 * zoom), true)
	for id in rects:
		_draw_card(id, font, fs)
	# 끌어서 순서 바꾸기 미리보기
	if _dragging and _drag_id != "":
		var target := _drop_index(_drag_id, _to_content(_drag_now))
		var parent := _parent_of(_drag_id)
		if parent != "":
			var sibs: Array = _nodes[parent].children
			var r: Rect2 = rects[_drag_id]
			var ghost := Rect2(_to_screen(Vector2(_to_content(_drag_now).x - r.size.x / 2, r.position.y)), r.size * zoom)
			draw_rect(ghost, Color(1, 1, 1, 0.12))
			draw_rect(ghost, Color(1, 1, 1, 0.5), false, 2.0)
			var anchor: Rect2 = rects[str(sibs[clampi(target, 0, sibs.size() - 1)])]
			var x := anchor.position.x - H_GAP / 2.0 if target <= sibs.find(_drag_id) else anchor.end.x + H_GAP / 2.0
			var top := _to_screen(Vector2(x, anchor.position.y))
			draw_line(top, top + Vector2(0, anchor.size.y * zoom), Color("ffd27a"), 4.0)
			draw_string(font, top + Vector2(6, -6), "→ %d 번째" % target, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color("ffd27a"))


func _draw_card(id: String, font: Font, fs: int) -> void:
	var n: Dictionary = _nodes[id]
	var r: Rect2 = rects[id]
	var sr := Rect2(_to_screen(r.position), r.size * zoom)
	var kind := str(n.kind)
	var rh := ROW_H * zoom
	var pad := 8.0 * zoom
	draw_rect(sr, KIND_COLOR.get(kind, Color("444444")))
	var y := sr.position.y
	# Decorator (위)
	for d in n.get("decorators", []):
		var row := Rect2(sr.position.x, y, sr.size.x, rh)
		draw_rect(row.grow(-2 * zoom), DECO_COLOR)
		var ab := str(d.get("observer_aborts", "None"))
		_text(font, fs - 1, row, "◇ " + Runner.decorator_text(d) + ("" if ab == "None" else "   ⤴ " + ab), Color.WHITE)
		y += rh
	# 제목 + 이름
	var title := Rect2(sr.position.x, y, sr.size.x, rh)
	var mark: String = KIND_MARK.get(kind, kind)
	if kind == "Task":
		mark += ": " + str(n.get("task_type", "?"))
	_text(font, fs, title, mark, Color(1, 1, 1, 0.95))
	y += rh
	var name := str(n.get("name", ""))
	_text(font, fs - 1, Rect2(sr.position.x, y, sr.size.x, rh), name if name != "" else id, Color(1, 1, 1, 0.65))
	y += rh
	if kind == "Task" and not n.get("params", {}).is_empty():
		var parts := PackedStringArray()
		for k in n.params:
			parts.append("%s=%s" % [k, n.params[k]])
		_text(font, fs - 2, Rect2(sr.position.x, y, sr.size.x, rh), ", ".join(parts), Color(0.85, 0.85, 1, 0.75))
		y += rh
	y += 10 * zoom
	# Service (아래)
	for s in n.get("services", []):
		var row := Rect2(sr.position.x, y, sr.size.x, rh)
		draw_rect(row.grow(-2 * zoom), SERV_COLOR)
		_text(font, fs - 1, row, "⟳ %s  %ss" % [s.get("type", "?"), s.get("interval", 0.5)], Color.WHITE)
		y += rh
	# 순서 번호 (왼쪽 위)
	var parent := _parent_of(id)
	if parent != "":
		var idx: int = _nodes[parent].children.find(id)
		var badge := Rect2(sr.position - Vector2(10, 10) * zoom, Vector2(24, 24) * zoom)
		draw_rect(badge, Color("ffd27a"))
		var label := str(idx)
		if str(_nodes[parent].get("kind", "")) == "SimpleParallel":
			label = "주" if idx == 0 else "배"   # Simple Parallel: 0 = 주 Task, 1 = 배경 분기
		draw_string(font, badge.position + Vector2(6 * zoom, 18 * zoom), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color.BLACK)
	if breakpoints.has(id):
		draw_circle(Vector2(sr.position.x - 16 * zoom, sr.get_center().y), 9 * zoom, Color("e03030"))
	# 디버그 결과
	var res: String = debug.get("results", {}).get(id, "")
	if res != "":
		draw_rect(sr.grow(3 * zoom), RESULT_COLOR.get(res, Color.WHITE), false, 4.0 * zoom)
		draw_string(font, Vector2(sr.end.x - 90 * zoom, sr.position.y - 6 * zoom), res, HORIZONTAL_ALIGNMENT_LEFT, -1, fs - 1, RESULT_COLOR.get(res, Color.WHITE))
	if errors.has(id):
		draw_string(font, Vector2(sr.end.x - 22 * zoom, sr.position.y + 20 * zoom), "⚠", HORIZONTAL_ALIGNMENT_LEFT, -1, fs + 4, Color("ff6a4a"))
	if id == selected:
		draw_rect(sr.grow(2), Color("ffd27a"), false, 3.0)


func _text(font: Font, fs: int, row: Rect2, t: String, col: Color) -> void:
	var w := row.size.x - 16 * zoom
	draw_string(font, row.position + Vector2(8 * zoom, row.size.y * 0.72), t, HORIZONTAL_ALIGNMENT_LEFT, w, fs, col, TextServer.JUSTIFICATION_NONE)


# ---------------------------------------------------------------- 조작
func id_at(screen: Vector2) -> String:
	var p := _to_content(screen)
	for id in rects:
		if rects[id].has_point(p):
			return id
	return ""


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		if e.button_index == MOUSE_BUTTON_WHEEL_UP or e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if e.pressed:
				var before := _to_content(e.position)
				zoom = clampf(zoom * (1.1 if e.button_index == MOUSE_BUTTON_WHEEL_UP else 1 / 1.1), 0.3, 2.5)
				offset += e.position - _to_screen(before)
				queue_redraw()
			accept_event()
			return
		if e.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = e.pressed
			accept_event()
			return
		if e.button_index == MOUSE_BUTTON_RIGHT and e.pressed:
			var id := id_at(e.position)
			if id != "":
				select(id)
			context_requested.emit(get_screen_transform() * e.position, id)
			accept_event()
			return
		if e.button_index == MOUSE_BUTTON_LEFT:
			if e.pressed:
				grab_focus()
				var id := id_at(e.position)
				if e.double_click and id != "":
					node_activated.emit(id)
					return
				select(id)
				_drag_id = id if _parent_of(id) != "" else ""
				_drag_from = e.position
				_drag_now = e.position
				_dragging = false
				if id == "":
					_panning = true
			else:
				if _dragging and _drag_id != "":
					var to := _drop_index(_drag_id, _to_content(e.position))
					var parent := _parent_of(_drag_id)
					if parent != "" and to != _nodes[parent].children.find(_drag_id):
						reorder_requested.emit(_drag_id, to)
				_dragging = false
				_drag_id = ""
				_panning = false
				queue_redraw()
			accept_event()
	elif e is InputEventMouseMotion:
		if _panning:
			offset += e.relative
			queue_redraw()
		elif _drag_id != "" and (e.button_mask & MOUSE_BUTTON_MASK_LEFT):
			_drag_now = e.position
			if not _dragging and _drag_now.distance_to(_drag_from) > 8.0:
				_dragging = true
			queue_redraw()


func select(id: String) -> void:
	selected = id
	queue_redraw()
	node_selected.emit(id)


## 끌어 놓을 x 에 맞는 형제 순서
func _drop_index(id: String, p: Vector2) -> int:
	var parent := _parent_of(id)
	if parent == "":
		return 0
	var sibs: Array = _nodes[parent].children
	var i := 0
	for s in sibs:
		if str(s) == id:
			continue
		if p.x > rects[str(s)].get_center().x:
			i += 1
	return i


func _parent_of(id: String) -> String:
	for pid in _nodes:
		if id in _nodes[pid].get("children", []):
			return pid
	return ""


## 고른 카드를 화면 가운데로 (F)
func focus_node(id: String) -> void:
	if not rects.has(id):
		return
	offset = size / 2.0 - rects[id].get_center() * zoom
	queue_redraw()


## 트리 전체가 보이게
func fit() -> void:
	if rects.is_empty():
		return
	var all := Rect2(rects.values()[0])
	for r in rects.values():
		all = all.merge(r)
	zoom = clampf(minf((size.x - 60) / all.size.x, (size.y - 60) / all.size.y), 0.3, 1.2)
	offset = size / 2.0 - all.get_center() * zoom
	queue_redraw()
