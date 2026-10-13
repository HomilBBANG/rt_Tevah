@tool
extends Control
## 맵 그리기 화면. 왼쪽 버튼 = 도구 사용(칠하기는 끌기 가능, 선택 도구는 물체 끌어 옮기기),
## 가운데·오른쪽 버튼 끌기 = 화면 이동, 휠 = 확대/축소.

signal changed
signal selection_changed(obj: Dictionary)

const OBJECT_TYPES := ["enemy", "investigate", "npc", "camp", "exit"]
const COLORS := {
	"enemy": Color("d05050"), "investigate": Color("e8c35a"), "npc": Color("5a8fd0"),
	"camp": Color("5fae6a"), "exit": Color("a07850"),
}
const LETTER := {"enemy": "적", "investigate": "조", "npc": "N", "camp": "거", "exit": "문"}
const DIR := {"up": Vector2i(0, -1), "down": Vector2i(0, 1), "left": Vector2i(-1, 0), "right": Vector2i(1, 0)}

var map := {}                 # { map_id, tiles: [String], start, run_start, objects: [...] }
var tool := "select"
var cell := 32.0
var zoom := 1.0
var pan := Vector2(24, 24)
var sight_tiles := 5.0
var selected := {}
var id_maker: Callable        # func(type) -> String

var _hover := Vector2i(-1, -1)
var _painting := false
var _panning := false
var _dragging := {}
var _font: Font


func _init() -> void:
	clip_contents = true
	focus_mode = FOCUS_CLICK
	mouse_filter = MOUSE_FILTER_STOP
	_font = ThemeDB.fallback_font


func set_map(m: Dictionary) -> void:
	map = m
	selected = {}
	queue_redraw()


# ---------------------------------------------------------------- 좌표
func tile_at(pos: Vector2) -> Vector2i:
	var t := (pos - pan) / (cell * zoom)
	return Vector2i(floori(t.x), floori(t.y))


func in_bounds(t: Vector2i) -> bool:
	var tiles: Array = map.get("tiles", [])
	return t.y >= 0 and t.y < tiles.size() and t.x >= 0 and t.x < String(tiles[t.y]).length()


func is_floor(t: Vector2i) -> bool:
	return in_bounds(t) and String(map.tiles[t.y])[t.x] == "."


func object_at(t: Vector2i) -> Dictionary:
	for o in map.get("objects", []):
		if int(o.x) == t.x and int(o.y) == t.y:
			return o
	return {}


func _is_marker(t: Vector2i, key: String) -> bool:
	var p = map.get(key)
	return p is Array and p.size() == 2 and int(p[0]) == t.x and int(p[1]) == t.y


func set_tile(t: Vector2i, ch: String) -> void:
	if not in_bounds(t):
		return
	var row := String(map.tiles[t.y])
	if row[t.x] == ch:
		return
	map.tiles[t.y] = row.substr(0, t.x) + ch + row.substr(t.x + 1)
	changed.emit()


# ---------------------------------------------------------------- 도구
## 칸 t 에 지금 도구 사용. first = 이번 누름의 첫 칸 (물체 놓기·선택은 첫 칸에서만)
func apply_tool(t: Vector2i, first := true) -> void:
	if map.is_empty() or not in_bounds(t):
		return
	match tool:
		"wall":
			if object_at(t).is_empty() and not _is_marker(t, "start") and not _is_marker(t, "run_start"):
				set_tile(t, "#")
		"floor":
			set_tile(t, ".")
		"start", "run_start":
			if is_floor(t) and first:
				map[tool] = [t.x, t.y]
				changed.emit()
		"select":
			if first:
				select(object_at(t))
				_dragging = selected
		"erase":
			if not first:
				return
			var o := object_at(t)
			if not o.is_empty():
				map.objects.erase(o)
				if selected == o:
					select({})
				changed.emit()
			elif _is_marker(t, "run_start"):
				map.run_start = null
				changed.emit()
		_:
			if tool in OBJECT_TYPES and first and is_floor(t) and object_at(t).is_empty():
				var o := {"object_id": id_maker.call(tool) if id_maker.is_valid() else "%s_%d" % [tool, map.objects.size() + 1],
					"type": tool, "x": t.x, "y": t.y, "ref": "", "name": "", "text": "",
					"patrol_dir": "", "patrol_len": 0, "condition": "", "schedule": ""}
				map.objects.append(o)
				select(o)
				changed.emit()
	queue_redraw()


func select(o: Dictionary) -> void:
	selected = o
	selection_changed.emit(o)
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if map.is_empty():
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if mb.pressed:
				var old := zoom
				zoom = clampf(zoom * (1.12 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1 / 1.12), 0.3, 4.0)
				pan = mb.position - (mb.position - pan) * (zoom / old)
				queue_redraw()
		elif mb.button_index == MOUSE_BUTTON_MIDDLE or mb.button_index == MOUSE_BUTTON_RIGHT:
			_panning = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			_painting = mb.pressed
			if mb.pressed:
				apply_tool(tile_at(mb.position), true)
			else:
				_dragging = {}
		accept_event()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		var t := tile_at(mm.position)
		if t != _hover:
			_hover = t
			if _painting and (tool == "wall" or tool == "floor"):
				apply_tool(t, false)
			elif _painting and tool == "select" and not _dragging.is_empty() and is_floor(t) and object_at(t).is_empty():
				_dragging.x = t.x
				_dragging.y = t.y
				changed.emit()
				selection_changed.emit(_dragging)
			queue_redraw()
		if _panning:
			pan += mm.relative
			queue_redraw()


# ---------------------------------------------------------------- 그리기
func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.1, 0.1, 0.12))
	if map.is_empty():
		draw_string(_font, Vector2(24, 40), "맵을 열거나 '새 맵'을 만드세요.", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(1, 1, 1, 0.6))
		return
	var s := cell * zoom
	var tiles: Array = map.tiles
	for y in tiles.size():
		var row := String(tiles[y])
		for x in row.length():
			var r := Rect2(pan + Vector2(x, y) * s, Vector2(s, s))
			draw_rect(r, Color("16171d") if row[x] == "#" else Color("3a3e4a"))
			draw_rect(r, Color(1, 1, 1, 0.05), false, 1.0)
	# 적 시야·순찰
	for o in map.objects:
		if o.type != "enemy":
			continue
		var c := _center(int(o.x), int(o.y))
		draw_arc(c, sight_tiles * s, 0, TAU, 48, Color(1, 0.3, 0.3, 0.25), 1.0, true)
		if o.get("patrol_dir", "") in DIR and int(o.get("patrol_len", 0)) > 0:
			var d: Vector2i = DIR[o.patrol_dir]
			var e := _center(int(o.x) + d.x * int(o.patrol_len), int(o.y) + d.y * int(o.patrol_len))
			draw_line(c, e, Color(1, 0.5, 0.5, 0.8), 2.0)
			draw_circle(e, s * 0.12, Color(1, 0.5, 0.5, 0.8))
	# P / S
	for key in ["start", "run_start"]:
		var p = map.get(key)
		if p is Array and p.size() == 2:
			var r := Rect2(pan + Vector2(p[0], p[1]) * s, Vector2(s, s)).grow(-s * 0.12)
			draw_rect(r, Color("2f8f4f") if key == "start" else Color("b89a2a"))
			_label("P" if key == "start" else "S", r.get_center(), Color.WHITE, s * 0.5)
	# 물체
	for o in map.objects:
		var c := _center(int(o.x), int(o.y))
		var col: Color = COLORS.get(o.type, Color.WHITE)
		draw_circle(c, s * 0.38, col)
		if o == selected:
			draw_arc(c, s * 0.48, 0, TAU, 32, Color.WHITE, 2.0, true)
		_label(LETTER.get(o.type, "?"), c, Color.BLACK, s * 0.42)
		var nm: String = o.name if o.get("name", "") != "" else o.object_id
		_label(nm, c + Vector2(0, -s * 0.62), Color(1, 1, 1, 0.85), maxf(10.0, s * 0.32))
	if in_bounds(_hover):
		draw_rect(Rect2(pan + Vector2(_hover) * s, Vector2(s, s)), Color(1, 1, 1, 0.5), false, 2.0)


func _center(x: int, y: int) -> Vector2:
	var s := cell * zoom
	return pan + Vector2(x + 0.5, y + 0.5) * s


func _label(t: String, c: Vector2, col: Color, fs: float) -> void:
	var f := int(fs)
	var w := _font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, f).x
	draw_string(_font, c + Vector2(-w / 2.0, f * 0.35), t, HORIZONTAL_ALIGNMENT_LEFT, -1, f, col)
