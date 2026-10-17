@tool
extends Control
## 맵 그리기 화면.
##   왼쪽 버튼 = 도구 사용. 벽·바닥·빈 공간은 끌어서 칠하기, rect_mode(또는 Shift)면 사각형으로 채우기.
##   선택 도구: 물체 클릭(Shift+클릭 = 여러 개), 빈 곳을 끌면 영역 선택(그 안의 물체·타일), 고른 물체 끌어 옮기기,
##              문·통로·이용 더블클릭 = 이어진 맵 열기 (activated)
##   가운데·오른쪽 버튼 끌기 = 화면 이동, 휠 = 확대/축소.
##   단축키(캔버스를 누른 뒤): Ctrl+Z 실행 취소, Ctrl+Y·Ctrl+Shift+Z 다시 실행, Ctrl+C 복사, Ctrl+V 붙여넣기,
##              Delete 선택 삭제, Ctrl+A 모두 선택, Esc 선택 해제 → request(동작 이름)

signal changed
signal selection_changed(obj: Dictionary)
signal stroke_started             # 한 번의 누름(칠하기·옮기기)이 시작됨 — 실행 취소 단위
signal request(action: String)    # 단축키
signal activated(obj: Dictionary) # 더블클릭
signal notice(text: String)       # 상태 글자 (영역 옮기기를 못 할 때 등)

const OBJECT_TYPES := ["enemy", "investigate", "npc", "camp", "exit", "passage", "transit", "arrive", "event", "light", "prop", "window", "furniture"]
const VisualData = preload("res://core/visual_data.gd")
const TRAVEL_TYPES := ["exit", "passage", "transit"]
const COLORS := {
	"enemy": Color("d05050"), "investigate": Color("e8c35a"), "npc": Color("5a8fd0"),
	"camp": Color("5fae6a"), "exit": Color("a07850"),
	"passage": Color("6fa8dc"), "transit": Color("c8a060"), "arrive": Color("3fae5f"), "event": Color("c070d0"), "light": Color("f5d76e"), "prop": Color("9a8a70"), "window": Color("8ec0e0"), "furniture": Color.WHITE,
}
const LETTER := {"enemy": "적", "investigate": "조", "npc": "N", "camp": "거", "exit": "문", "passage": "통", "transit": "이", "arrive": "P", "event": "!!", "light": "빛", "prop": "◆", "window": "창", "furniture": "가"}
const EDGE_NAME := {"up": "위", "down": "아래", "left": "왼쪽", "right": "오른쪽"}
const DIR := {"up": Vector2i(0, -1), "down": Vector2i(0, 1), "left": Vector2i(-1, 0), "right": Vector2i(1, 0)}
## 표시 필터 묶음: 물체 종류 → 필터 이름
const FILTER_OF := {"enemy": "enemy", "investigate": "investigate", "npc": "npc", "camp": "camp",
	"exit": "travel", "passage": "travel", "transit": "travel", "arrive": "arrive", "event": "event", "light": "light", "prop": "props", "window": "light", "furniture": "furniture"}
const PAINT_TOOLS := ["wall", "floor", "void", "tile", "tile_erase"]   # 끌어서 칠하는 도구 (tile = 그래픽 층)

var map := {}                 # { map_id, tiles: [String], start, run_start, objects: [...], edges }
var tool := "select"
var rect_mode := false        # 벽·바닥·빈 공간·타일을 사각형으로 채우기
var tile_key := ""            # 타일 붓: 칠할 타일 (graphics.xlsx Tiles)
var tile_layer := "floor"     # 타일 붓·지우개가 칠하는 그래픽 층 (floor / detail / wall)
var graphics := false         # 뒤에 픽셀아트 그림(core/map_renderer)이 보이는 중 → 바닥·벽 색칠은 하지 않고 칸 선만
var light_defaults := {}      # 광원을 놓을 때 복사할 값 (프리셋)
var prop_id := ""             # 오브젝트 도구: 놓을 오브젝트 그림 (graphics.xlsx Props)
var cell := 32.0
var zoom := 1.0
var pan := Vector2(24, 24)
var sight_tiles := 5.0
var selected := {}            # 마지막으로 고른 물체 (오른쪽 칸)
var selection: Array = []     # 고른 물체들 (여러 개)
var region := Rect2i()        # 영역 선택 (칸). size 0 = 없음
var _region_moving := false   # 고른 영역 안을 잡고 끄는 중 → 놓으면 move_region
var _region_d := Vector2i.ZERO
var id_maker: Callable        # func(type) -> String
var require_default := false  # 베이스캠프: ★ 기본 P 가 꼭 있어야 함 (첫 P 는 자동 기본, 기본 P 는 못 지움)
## 표시 필터 (false = 숨김, 숨긴 물체는 고를 수도 없음)
var filters := {"tiles": true, "enemy": true, "investigate": true, "npc": true, "camp": true, "travel": true, "event": true, "light": true, "props": true, "furniture": true,
	"graphics": true, "lighting": true, "roof": true, "light_range": true, "occluders": false, "logic": false,
	"arrive": true, "sight": true, "names": true, "links": true}
## 연결 표시: object_id → [글자, 맞으면 true] (편집기가 채움). 가장자리는 "edge:방향"
var link_labels := {}

var _hover := Vector2i(-1, -1)
var _painting := false
var _panning := false
var _press_tile := Vector2i.ZERO
var _moving := false              # 고른 물체들 옮기는 중
var _move_from: Array = []        # [[물체, 원래 위치 Vector2i]] — 사전 키로 쓰면 위치가 바뀔 때 못 찾으므로 목록으로
var _band := false                # 영역 선택 중
var _rect_paint := false          # 사각형 칠하기 중
var _font: Font


func _init() -> void:
	clip_contents = true
	focus_mode = FOCUS_CLICK
	mouse_filter = MOUSE_FILTER_STOP
	_font = ThemeDB.fallback_font


func set_map(m: Dictionary) -> void:
	map = m
	selected = {}
	selection = []
	region = Rect2i()
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


func is_wall(t: Vector2i) -> bool:
	return in_bounds(t) and String(map.tiles[t.y])[t.x] == "#"


## 물체 종류 type 을 칸 t 에 둘 수 있나: 창문 = 옆(상하좌우)에 바닥이 있는 벽 칸, 나머지 = 바닥
func fits(type: String, t: Vector2i, o: Dictionary = {}) -> bool:
	if type == "furniture":   # 가구: 왼쪽 위 t 부터 w × h 칸이 모두 바닥이고 다른 물체가 없어야
		for c in VisualData.furniture_cells({"x": t.x, "y": t.y, "w": o.get("w", 1), "h": o.get("h", 1)}):
			var there := object_at(c)
			if not is_floor(c) or (not there.is_empty() and there != o):
				return false
		return true
	if type == "window":   # 창문: w × h 칸이 모두 벽 + 옆에 바닥이 있거나, 뒷벽(아래로 벽만 이어지다 바닥)
		var wo := {"x": t.x, "y": t.y, "w": o.get("w", 1), "h": o.get("h", 1)}
		for c in VisualData.furniture_cells(wo):
			var there := object_at(c)
			if not is_wall(c) or (not there.is_empty() and there != o):
				return false
		return VisualData.window_light(map, wo).dir != Vector2i.ZERO
	return is_floor(t)


## 벽 칸에 문을 낼 때: 바닥으로 바꾸고 그 칸의 벽·지붕 그림을 지움 (보이는 모습도 바닥으로)
func open_wall(t: Vector2i) -> void:
	if not is_wall(t):
		return
	set_tile(t, ".")
	var layers = (map.get("visual", {}) if map.get("visual") is Dictionary else {}).get("layers", {})
	if layers is Dictionary:
		for l in ["wall", "roof"]:
			if layers.get(l) is Dictionary:
				layers[l].erase("%d,%d" % [t.x, t.y])


## 그 칸의 물체 (숨긴 것 포함 — 겹치기 검사용)
func object_at(t: Vector2i) -> Dictionary:
	for o in map.get("objects", []):
		if int(o.x) == t.x and int(o.y) == t.y:
			return o
		if o.get("type", "") in ["furniture", "window"] and t.x >= int(o.x) and t.y >= int(o.y) 				and t.x < int(o.x) + maxi(1, int(o.get("w", 1))) and t.y < int(o.y) + maxi(1, int(o.get("h", 1))):
			return o   # 큰 가구·창문은 차지하는 칸 어디서나
	return {}


func is_visible_object(o: Dictionary) -> bool:
	return filters.get(FILTER_OF.get(o.get("type", ""), ""), true)


## 그 칸의 보이는 물체 (고르기용)
func visible_object_at(t: Vector2i) -> Dictionary:
	var o := object_at(t)
	return o if not o.is_empty() and is_visible_object(o) else {}


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


## 화면 가운데에 칸 t 가 오게
func center_on(t: Vector2i) -> void:
	pan = size / 2.0 - (Vector2(t) + Vector2(0.5, 0.5)) * cell * zoom
	queue_redraw()


# ---------------------------------------------------------------- 도구
## 칸 t 에 지금 도구 사용. first = 이번 누름의 첫 칸 (물체 놓기·선택은 첫 칸에서만)
func apply_tool(t: Vector2i, first := true) -> void:
	if map.is_empty() or not in_bounds(t):
		return
	match tool:
		"wall", "void", "floor":
			_paint(t, {"wall": "#", "void": " ", "floor": "."}[tool])
		"tile", "tile_erase":
			_paint_tile(t, tool == "tile_erase")
		"start", "run_start":
			if is_floor(t) and first:
				map[tool] = [t.x, t.y]
				changed.emit()
		"select":
			if first:
				select(visible_object_at(t))
		"erase":
			if not first:
				return
			var o := visible_object_at(t)
			if not o.is_empty() and o.type == "arrive" and not release_p(o):
				return   # 마지막 도착 P 는 못 지움
			if not o.is_empty():
				map.objects.erase(o)
				selection.erase(o)
				if selected == o:
					select({})
				changed.emit()
			elif _is_marker(t, "run_start"):
				map.run_start = null
				changed.emit()
		_:
			if tool in TRAVEL_TYPES and first and object_at(t).is_empty():
				open_wall(t)   # 벽에 문·통로를 놓으면 그 칸은 바닥이 됨
			if tool in OBJECT_TYPES and first and fits(tool, t) and object_at(t).is_empty():
				var o := {"object_id": id_maker.call(tool) if id_maker.is_valid() else "%s_%d" % [tool, map.objects.size() + 1],
					"type": tool, "x": t.x, "y": t.y, "ref": "", "name": "", "text": "",
					"patrol_dir": "", "patrol_len": 0, "condition": "", "schedule": "", "arrive": ""}
				if tool == "arrive" and require_default and default_p().is_empty():
					o.default = true   # 베이스캠프의 첫 도착 P = 기본
				if tool == "light":
					o.merge(light_defaults.duplicate(true), true)
				if tool == "furniture":
					o.merge({"w": 1, "h": 1, "label": "", "color": "#FFFFFF", "solid": true, "role": "", "use_condition": "", "use_fail_text": "", "effects": ""})   # 프리셋 값 복사 (광원마다 따로 고칠 수 있음)
				if tool == "prop":
					if prop_id == "":
						return
					o.ref = prop_id
					o.name = str(VisualData.props().get(prop_id, {}).get("name", ""))
				map.objects.append(o)
				select(o)
				changed.emit()
	queue_redraw()


## 칠하기 한 칸. 물체·P·S 가 있는 칸은 벽·빈 공간으로 안 바뀜
func _paint(t: Vector2i, ch: String) -> void:
	var o := object_at(t)
	if not o.is_empty() and o.get("type", "") == "window":
		return   # 창문 칸은 벽 그대로
	if ch != "." and (not o.is_empty() or _is_marker(t, "start") or _is_marker(t, "run_start")):
		return
	set_tile(t, ch)


## 그래픽 층 칠하기 (보이는 모습만 — 벽·바닥 판정은 그대로). map.visual.layers[층]["x,y"] = tile_key
func _paint_tile(t: Vector2i, erase: bool) -> void:
	if not erase and tile_key == "":
		return
	if not map.get("visual") is Dictionary:
		map.visual = {}
	if not map.visual.get("layers") is Dictionary:
		map.visual.layers = {}
	var layers: Dictionary = map.visual.layers
	if not layers.get(tile_layer) is Dictionary:
		layers[tile_layer] = {}
	var cells: Dictionary = layers[tile_layer]
	var k := "%d,%d" % [t.x, t.y]
	if erase:
		if not cells.has(k):
			return
		cells.erase(k)
		if cells.is_empty():
			layers.erase(tile_layer)
	else:
		if cells.get(k, "") == tile_key:
			return
		cells[k] = tile_key
	changed.emit()


## 사각형 채우기 (지금 칠하기 도구로)
func fill_rect(r: Rect2i) -> void:
	if tool in ["tile", "tile_erase"]:
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				_paint_tile(Vector2i(x, y), tool == "tile_erase")
		queue_redraw()
		return
	var ch: String = {"wall": "#", "void": " ", "floor": "."}.get(tool, ".")
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			_paint(Vector2i(x, y), ch)
	queue_redraw()


## 기본 도착 P (default) 물체. 없으면 {}
func default_p() -> Dictionary:
	for o in map.get("objects", []):
		if o.get("type", "") == "arrive" and o.get("default", false):
			return o
	return {}


## 도착 P 를 지우기 전에. 베이스캠프의 기본 P 면 다른 P 에 기본을 넘기고, 남은 P 가 없으면 false (못 지움).
## 다른 맵은 기본 P 가 선택이라 그냥 지운다
func release_p(o: Dictionary) -> bool:
	if not require_default or not o.get("default", false):
		return true
	var others: Array = map.objects.filter(func(x): return x.get("type", "") == "arrive" and x != o)
	if others.is_empty():
		return false
	if o.get("default", false):
		o.erase("default")
		others[0].default = true
	return true


func select(o: Dictionary) -> void:
	selected = o
	selection = [] if o.is_empty() else [o]
	region = Rect2i()
	selection_changed.emit(o)
	queue_redraw()


## 여러 개 고르기 (영역 선택·검색·붙여넣기)
func select_many(objs: Array, r := Rect2i()) -> void:
	selection = objs.duplicate()
	region = r
	selected = selection.back() if not selection.is_empty() else {}
	selection_changed.emit(selected)
	queue_redraw()


## 영역 안의 보이는 물체
func objects_in(r: Rect2i) -> Array:
	return map.get("objects", []).filter(func(o): return r.has_point(Vector2i(int(o.x), int(o.y))) and is_visible_object(o))


static func _rect_from(a: Vector2i, b: Vector2i) -> Rect2i:
	var p := Vector2i(mini(a.x, b.x), mini(a.y, b.y))
	return Rect2i(p, Vector2i(absi(a.x - b.x) + 1, absi(a.y - b.y) + 1))


# ---------------------------------------------------------------- 입력
func _gui_input(event: InputEvent) -> void:
	if map.is_empty():
		return
	if event is InputEventKey and event.pressed and not event.echo:
		_key(event as InputEventKey)
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
			if mb.pressed:
				grab_focus()
				_press(tile_at(mb.position), mb.shift_pressed, mb.double_click)
			else:
				_release(tile_at(mb.position))
		accept_event()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		var t := tile_at(mm.position)
		if t != _hover:
			_hover = t
			if _painting and tool in PAINT_TOOLS and not _rect_paint:
				apply_tool(t, false)
			elif _painting and _region_moving:
				_region_d = t - _press_tile
			elif _painting and _moving:
				_move_selection(t - _press_tile)
			queue_redraw()
		if _panning:
			pan += mm.relative
			queue_redraw()


func _press(t: Vector2i, shift: bool, double: bool) -> void:
	_painting = true
	_press_tile = t
	stroke_started.emit()
	if tool in PAINT_TOOLS and (rect_mode or shift):
		_rect_paint = true
		return
	if tool != "select":
		apply_tool(t, true)
		return
	var o := visible_object_at(t)
	if double and not o.is_empty():
		activated.emit(o)
		return
	if not shift and region.size != Vector2i.ZERO and region.has_point(t):
		_region_moving = true   # 고른 영역 안을 잡음 → 끌어서 놓으면 벽·바닥·칠한 그림·물체를 통째로
		_region_d = Vector2i.ZERO
		return
	if o.is_empty():
		if not shift:
			select({})
		_band = true
		return
	if shift:
		if o in selection:
			selection.erase(o)
		else:
			selection.append(o)
		select_many(selection)
	elif not o in selection:
		select(o)
	else:
		selected = o
		selection_changed.emit(o)
	_moving = true
	_move_from = []
	for s in selection:
		_move_from.append([s, Vector2i(int(s.x), int(s.y))])


func _release(t: Vector2i) -> void:
	if _region_moving:
		_region_moving = false
		if t - _press_tile != Vector2i.ZERO:
			move_region(region, t - _press_tile)
	elif _rect_paint:
		fill_rect(_rect_from(_press_tile, t))
	elif _band:
		var r := _rect_from(_press_tile, t)
		var found := objects_in(r)
		if Input.is_key_pressed(KEY_SHIFT):
			for o in found:
				if not o in selection:
					selection.append(o)
			found = selection
		select_many(found, r)
	_painting = false
	_rect_paint = false
	_band = false
	_moving = false
	queue_redraw()


## 영역 r 을 d 만큼 통째로 옮김: 논리 칸(벽·바닥·빈 공간) + 칠한 그림(바닥·장식·벽·지붕) + 그 안의 물체(숨긴 것도)·S.
## 비운 자리는 바닥(.)에 칠한 그림 없음(맵 기본 그림). 맵 밖으로 나가거나 영역 밖 물체와 겹치면 안 옮김 → false
func move_region(r: Rect2i, d: Vector2i) -> bool:
	if map.is_empty() or r.size == Vector2i.ZERO or d == Vector2i.ZERO:
		return false
	var dest := Rect2i(r.position + d, r.size)
	for y in range(dest.position.y, dest.end.y):
		for x in range(dest.position.x, dest.end.x):
			if not in_bounds(Vector2i(x, y)):
				notice.emit("맵 밖으로는 옮길 수 없어요")
				return false
	var movers: Array = map.objects.filter(func(o): return r.has_point(Vector2i(int(o.x), int(o.y))))
	for o in map.objects:
		if o in movers:
			continue
		var cells: Array = VisualData.object_cells(o)
		for c in cells:
			if dest.has_point(c):
				notice.emit("옮길 자리에 영역 밖 물체가 있어요: %s" % (o.name if str(o.get("name", "")) != "" else o.object_id))
				return false
	# 원래 내용 기억 → 원래 자리 비우기 → 새 자리에 쓰기 (겹쳐 옮겨도 맞게)
	if not map.get("visual") is Dictionary:
		map.visual = {}
	if not map.visual.get("layers") is Dictionary:
		map.visual.layers = {}
	var layers: Dictionary = map.visual.layers
	var chars := {}
	var paint := {}
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var c := Vector2i(x, y)
			chars[c] = String(map.tiles[y])[x] if in_bounds(c) else "."
			var k := "%d,%d" % [x, y]
			for l in layers:
				if layers[l] is Dictionary and layers[l].has(k):
					paint[[l, c]] = layers[l][k]
					layers[l].erase(k)
			_set_char(c, ".")
	for c in chars:
		var to: Vector2i = c + d
		_set_char(to, chars[c])
		var k := "%d,%d" % [to.x, to.y]
		for l in layers:
			if layers[l] is Dictionary:
				layers[l].erase(k)
	for key in paint:
		var to: Vector2i = key[1] + d
		layers[key[0]]["%d,%d" % [to.x, to.y]] = paint[key]
	for o in movers:
		o.x = int(o.x) + d.x
		o.y = int(o.y) + d.y
	for key in ["start", "run_start"]:
		var p = map.get(key)
		if p is Array and p.size() == 2 and r.has_point(Vector2i(int(p[0]), int(p[1]))):
			map[key] = [int(p[0]) + d.x, int(p[1]) + d.y]
	select_many(movers.filter(is_visible_object), dest)
	changed.emit()
	return true


func _set_char(t: Vector2i, ch: String) -> void:
	if in_bounds(t):
		var row := String(map.tiles[t.y])
		map.tiles[t.y] = row.substr(0, t.x) + ch + row.substr(t.x + 1)


## 고른 물체들을 원래 자리 + d 로 (모두 바닥이고 다른 물체가 없을 때만)
func _move_selection(d: Vector2i) -> void:
	# 끄는 동안 마우스가 있는 칸으로 바로 (한 번에 여러 칸, 벽 너머도). 갈 칸이 벽·빈 공간이거나 다른 물체가 있으면 그 칸은 건너뜀
	var movers := _move_from.map(func(p): return p[0])
	for p in _move_from:
		var to: Vector2i = p[1] + d
		var there := object_at(to)
		if not fits(str(p[0].get("type", "")), to, p[0]) or (not there.is_empty() and not there in movers):
			return
	for p in _move_from:
		p[0].x = p[1].x + d.x
		p[0].y = p[1].y + d.y
	changed.emit()
	selection_changed.emit(selected)


func _key(k: InputEventKey) -> void:
	var ctrl := k.ctrl_pressed or k.meta_pressed
	var action := ""
	match k.keycode:
		KEY_Z when ctrl: action = "redo" if k.shift_pressed else "undo"
		KEY_Y when ctrl: action = "redo"
		KEY_C when ctrl: action = "copy"
		KEY_V when ctrl: action = "paste"
		KEY_A when ctrl:
			select_many(map.objects.filter(is_visible_object))
		KEY_DELETE, KEY_BACKSPACE: action = "delete"
		KEY_ESCAPE: select({})
		_: return
	if action != "":
		request.emit(action)
	accept_event()


# ---------------------------------------------------------------- 그리기
func _draw() -> void:
	if not graphics:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.1, 0.1, 0.12))
	if map.is_empty():
		draw_string(_font, Vector2(24, 40), "맵을 열거나 '새 맵'을 만드세요.", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(1, 1, 1, 0.6))
		return
	var s := cell * zoom
	var tiles: Array = map.tiles
	var dim: bool = not filters.tiles
	# 화면에 보이는 칸만 (큰 맵에서도 빠르게)
	var y0 := clampi(floori(-pan.y / s), 0, tiles.size())
	var y1 := clampi(ceili((size.y - pan.y) / s), 0, tiles.size())
	var x0 := maxi(0, floori(-pan.x / s))
	var x1 := maxi(0, ceili((size.x - pan.x) / s))
	var grid_lines := s >= 6.0   # 많이 줄이면 칸 선은 안 그림
	for y in range(y0, y1):
		var row := String(tiles[y])
		for x in range(x0, mini(x1, row.length())):
			var r := Rect2(pan + Vector2(x, y) * s, Vector2(s, s))
			if graphics:
				# 뒤에 픽셀아트 그림이 보임: 칸 선, '벽 판정' 을 켜면 벽(지나갈 수 없음)·빈 공간 표시
				if filters.logic and row[x] != ".":
					draw_rect(r, Color(1, 0.2, 0.2, 0.28) if row[x] == "#" else Color(0.4, 0.4, 1, 0.28))
				if grid_lines:
					draw_rect(r, Color(1, 1, 1, 0.06), false, 1.0)
				continue
			var col := Color.BLACK if row[x] == " " else (Color("16171d") if row[x] == "#" else Color("3a3e4a"))
			if dim and row[x] != " ":
				col = Color("202228")   # 타일 숨김: 벽·바닥 구분을 흐리게
			draw_rect(r, col)
			if grid_lines:
				draw_rect(r, Color(1, 1, 1, 0.05), false, 1.0)
	# 그림자 차단 윤곽: 빛을 막는 벽 타일·문 (그래픽 데이터 기준)
	if filters.occluders:
		for y in range(y0, y1):
			for x in range(x0, mini(x1, String(tiles[y]).length())):
				var wk: String = VisualData.cell_keys(map, x, y).wall
				if wk != "" and VisualData.tiles().get(wk, {}).get("casts_shadow", false):
					draw_rect(Rect2(pan + Vector2(x, y) * s, Vector2(s, s)).grow(-2), Color(1, 0.85, 0.2, 0.8), false, 2.0)
		for o in map.get("objects", []):
			if o.type == "exit":
				draw_rect(Rect2(pan + Vector2(o.x, o.y) * s, Vector2(s, s)).grow(-4), Color(1, 0.6, 0.1, 0.9), false, 3.0)
	# 오브젝트 그림이 차지하는 칸 (지나갈 수 없으면 붉게)
	if filters.props:
		var pc := VisualData.prop_cells(map)
		for cc in pc:
			var solid: bool = pc[cc].get("solid", false)
			draw_rect(Rect2(pan + Vector2(cc) * s, Vector2(s, s)).grow(-3), Color(1, 0.4, 0.3, 0.75) if solid else Color(0.8, 0.8, 0.6, 0.6), false, 1.5)
	# 없는 타일 이름이 칠해진 칸: 붉은 X (게임에서는 기본 타일로 보임)
	var vlayers = map.get("visual", {}).get("layers", {}) if map.get("visual") is Dictionary else {}
	if vlayers is Dictionary and not VisualData.tiles().is_empty():
		for l in vlayers:
			if not vlayers[l] is Dictionary:
				continue
			for k in vlayers[l]:
				if not VisualData.tiles().has(str(vlayers[l][k])):
					var xy := str(k).split(",")
					if xy.size() == 2:
						var r := Rect2(pan + Vector2(int(xy[0]), int(xy[1])) * s, Vector2(s, s)).grow(-4)
						draw_line(r.position, r.end, Color("ff4040"), 2.0)
						draw_line(Vector2(r.end.x, r.position.y), Vector2(r.position.x, r.end.y), Color("ff4040"), 2.0)
	# 광원 범위
	if filters.light and filters.light_range:
		for o in map.get("objects", []):
			if o.type == "light":
				var lc := Color.html(str(o.get("color", "#ffffff"))) if Color.html_is_valid(str(o.get("color", ""))) else Color.WHITE
				var c := pan + (Vector2(o.x, o.y) + Vector2(0.5, 0.5)) * s
				draw_circle(c, float(o.get("radius", 4.0)) * s, Color(lc.r, lc.g, lc.b, 0.08))
				draw_arc(c, float(o.get("radius", 4.0)) * s, 0, TAU, 48, Color(lc.r, lc.g, lc.b, 0.6 if o.get("enabled", true) else 0.25), 1.5, true)
	# 가장자리 이동 (edges): 맵 바깥쪽에 띠 + 이동할 맵 이름 (잘못되면 빨강)
	var h := tiles.size()
	var w := 0
	for row in tiles:
		w = maxi(w, String(row).length())
	if filters.travel:
		for d in map.get("edges", {}):
			var e: Dictionary = map.edges[d]
			if e.get("ref", "") == "":
				continue
			var band := s * 0.35
			var r: Rect2
			match d:
				"up": r = Rect2(pan + Vector2(0, -band), Vector2(w * s, band))
				"down": r = Rect2(pan + Vector2(0, h * s), Vector2(w * s, band))
				"left": r = Rect2(pan + Vector2(-band, 0), Vector2(band, h * s))
				_: r = Rect2(pan + Vector2(w * s, 0), Vector2(band, h * s))
			var info: Array = link_labels.get("edge:" + d, ["%s → %s" % [EDGE_NAME.get(d, d), e.ref], true])
			draw_rect(r, Color(0.43, 0.66, 0.86, 0.55) if info[1] else Color(0.85, 0.25, 0.25, 0.6))
			_label(info[0], r.get_center(), Color.WHITE, maxf(10.0, s * 0.3))
	# 적 순찰 길 (시야 원은 고르거나 마우스를 올린 적만 — 겹쳐서 지저분해지지 않게)
	var focus := _focus_objects()
	if filters.sight and filters.enemy:
		for o in map.objects:
			if o.type != "enemy":
				continue
			var c := _center(int(o.x), int(o.y))
			if o in focus:
				draw_arc(c, sight_tiles * s, 0, TAU, 48, Color(1, 0.3, 0.3, 0.35), 1.5, true)
			if o.get("patrol_dir", "") in DIR and int(o.get("patrol_len", 0)) > 0:
				var d: Vector2i = DIR[o.patrol_dir]
				var e := _center(int(o.x) + d.x * int(o.patrol_len), int(o.y) + d.y * int(o.patrol_len))
				draw_line(c, e, Color(1, 0.5, 0.5, 0.8), 2.0)
				draw_circle(e, s * 0.12, Color(1, 0.5, 0.5, 0.8))
	# S (회차 시작). 도착 P 는 모두 물체(arrive) — 예전 맵처럼 기본 P 물체가 없으면 start 를 그린다
	for key in ["start", "run_start"]:
		if key == "start" and map.get("objects", []).any(func(x): return x.get("type", "") == "arrive"):
			continue   # 도착 P 물체가 있으면 start 는 따로 안 그림 (예전 맵만)
		var p = map.get(key)
		if p is Array and p.size() == 2:
			var r := Rect2(pan + Vector2(p[0], p[1]) * s, Vector2(s, s)).grow(-s * 0.12)
			draw_rect(r, Color("2f8f4f") if key == "start" else Color("b89a2a"))
			_label("P" if key == "start" else "S", r.get_center(), Color.WHITE, s * 0.5)
	# 물체
	for o in map.objects:
		if not is_visible_object(o):
			continue
		if o.type == "window" and (int(o.get("w", 1)) > 1 or int(o.get("h", 1)) > 1):   # 큰 창문: 차지하는 칸만큼 하늘색 테두리
			var wr := Rect2(pan + Vector2(o.x, o.y) * s, Vector2(maxi(1, int(o.get("w", 1))), maxi(1, int(o.get("h", 1)))) * s).grow(-2)
			draw_rect(wr, Color(0.55, 0.75, 0.88, 0.35))
			draw_rect(wr, Color.WHITE if o in selection else COLORS.window, false, 3.0 if o in selection else 2.0)
			_label(LETTER.window, wr.get_center(), Color.WHITE, s * 0.42)
			continue
		if o.type == "furniture":   # 기타 가구: 차지하는 칸만큼 색 사각형 + 표시 메모
			var fr := Rect2(pan + Vector2(o.x, o.y) * s, Vector2(maxi(1, int(o.get("w", 1))), maxi(1, int(o.get("h", 1)))) * s).grow(-2)
			var fc := Color.html(str(o.get("color", ""))) if Color.html_is_valid(str(o.get("color", ""))) else Color.WHITE
			draw_rect(fr, Color(fc.r, fc.g, fc.b, 0.9))
			draw_rect(fr, Color.WHITE if o in selection else fc.darkened(0.5), false, 3.0 if o in selection else 1.5)
			var ink := Color(0.08, 0.08, 0.1) if fc.get_luminance() > 0.5 else Color.WHITE
			var fl := str(o.get("label", ""))
			if fl != "" and s >= 10.0:
				var fsz := int(clampf(s * 0.3, 9.0, 22.0))
				draw_string(_font, Vector2(fr.position.x + 2, fr.get_center().y + fsz * 0.35), fl, HORIZONTAL_ALIGNMENT_CENTER, fr.size.x - 4, fsz, ink)
			if str(o.get("role", "")) != "":   # 쓸 수 있는 가구: 오른쪽 위 작은 점
				draw_circle(fr.position + Vector2(fr.size.x - s * 0.15, s * 0.15), maxf(2.0, s * 0.08), Color("e8a33a"))
			continue
		var c := _center(int(o.x), int(o.y))
		var col: Color = COLORS.get(o.type, Color.WHITE)
		draw_circle(c, s * 0.38, col)
		var info: Array = link_labels.get(o.object_id, [])
		if filters.links and not info.is_empty() and not info[1]:
			draw_arc(c, s * 0.46, 0, TAU, 32, Color("ff4040"), 3.0, true)   # 잘못된 연결
		if o in selection:
			draw_arc(c, s * 0.52, 0, TAU, 32, Color.WHITE, 2.0, true)
		_label(LETTER.get(o.type, "?"), c, Color.BLACK, s * 0.42)
		if o.get("default", false):
			_label("★", c + Vector2(s * 0.36, -s * 0.3), Color("ffd84a"), maxf(10.0, s * 0.36))
		# 이름표: 충분히 확대했을 때만 (고르거나 마우스를 올리면 늘)
		if filters.names and (s >= 26.0 or o in focus):
			var nm: String = o.name if o.get("name", "") != "" else o.object_id
			_label(nm, c + Vector2(0, -s * 0.62), Color(1, 1, 1, 0.8), maxf(10.0, s * 0.32))
		# 연결 글자: 고르거나 마우스를 올린 것만. 잘못된 연결은 ⚠ 만 늘
		if filters.links and not info.is_empty():
			if o in focus:
				_label(info[0], c + Vector2(0, s * 0.72), Color("9cc4ec") if info[1] else Color("ff6060"), maxf(10.0, s * 0.3))
			elif not info[1]:
				_label("⚠", c + Vector2(s * 0.42, -s * 0.3), Color("ff6060"), maxf(10.0, s * 0.4))
	# 영역 선택·사각형 칠하기 미리보기
	if not region.size == Vector2i.ZERO:
		draw_rect(Rect2(pan + Vector2(region.position) * s, Vector2(region.size) * s), Color(0.5, 0.8, 1.0), false, 2.0)
		if _region_moving and _region_d != Vector2i.ZERO:   # 놓을 자리 미리보기
			var pr := Rect2(pan + Vector2(region.position + _region_d) * s, Vector2(region.size) * s)
			draw_rect(pr, Color(0.5, 0.8, 1.0, 0.18))
			draw_rect(pr, Color(0.7, 0.9, 1.0), false, 3.0)
	if (_band or _rect_paint) and in_bounds(_hover):
		var pr := _rect_from(_press_tile, _hover)
		var pcol := Color(0.5, 0.8, 1.0, 0.25) if _band else Color(1, 0.85, 0.4, 0.3)
		draw_rect(Rect2(pan + Vector2(pr.position) * s, Vector2(pr.size) * s), pcol)
	if in_bounds(_hover):
		draw_rect(Rect2(pan + Vector2(_hover) * s, Vector2(s, s)), Color(1, 1, 1, 0.5), false, 2.0)
		# 칸 좌표 (대화 에디터 🎬 연출의 '걷게 하기'·'카메라' 칸 x·y 에 쓴다)
		var at := pan + (Vector2(_hover) + Vector2(0.5, 1.0)) * s + Vector2(0, 11)
		draw_rect(Rect2(at - Vector2(24, 9), Vector2(48, 18)), Color(0, 0, 0, 0.7))
		_label("%d, %d" % [_hover.x, _hover.y], at, Color(1, 1, 1, 0.9), 13)


## 자세히 보여 줄 물체: 고른 것 + 마우스가 올라간 것
func _focus_objects() -> Array:
	var out := selection.duplicate()
	var h := visible_object_at(_hover) if in_bounds(_hover) else {}
	if not h.is_empty() and not h in out:
		out.append(h)
	return out


func _center(x: int, y: int) -> Vector2:
	var s := cell * zoom
	return pan + Vector2(x + 0.5, y + 0.5) * s


func _label(t: String, c: Vector2, col: Color, fs: float) -> void:
	var f := int(fs)
	var w := _font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, f).x
	draw_string(_font, c + Vector2(-w / 2.0, f * 0.35), t, HORIZONTAL_ALIGNMENT_LEFT, -1, f, col)
