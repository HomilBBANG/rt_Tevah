@tool
extends Control
## 월드 맵: 모든 맵을 미니 그림으로 한 화면에 (맵 탭의 '🗺 월드 맵').
##   배치: 가장자리(edges)로 이어진 맵끼리는 실제로 이어지는 자리에 붙임 (이어지는 맵이면 칸 어긋남까지) → 한 묶음으로 같이 움직임.
##         묶음 위치는 끌어서 정하고 layout_path(tools/world_layout.json, 에디터 설정 — 게임과 무관)에 저장. 처음엔 자동으로 나란히.
##   연결선: 문·통로·이용 → 이동할 맵의 도착 P (출발 쪽 arrive → P 의 이어지는 곳 → 기본 P → start). 없는 맵·P 는 빨강.
##   조작: 휠 = 확대·축소, 오른쪽/가운데 끌기 = 화면 이동, 왼쪽 끌기 = 맵(묶음) 옮기기, 두 번 누르기 = 그 맵 편집 (open_requested).
##   이어붙이기: 끌어 놓을 때 다른 맵 가장자리와 SNAP 칸 안이면 딱 붙이고 link_requested(맵, 방향, 저쪽 맵, 칸 어긋남) — 에디터가 양쪽 맵에
##         '이어지는 맵' 가장자리를 씀. Shift+끌기 = 그 맵만 묶음에서 떼기 (unlink_requested — 이웃과의 가장자리 지움)

signal open_requested(map_id: String)
signal notice(text: String)
signal link_requested(map_id: String, dir: String, other: String, offset: int)
signal unlink_requested(map_id: String, other: String)

const SNAP := 2                      # 이 칸 수 안으로 가까이 놓으면 이어붙임

const VisualData = preload("res://core/visual_data.gd")
const GAP := 12                      # 자동 배치 때 묶음 사이 칸
const ROW_WIDTH := 420               # 자동 배치 한 줄 너비 (칸)
const TRAVEL_COLOR := {"exit": Color("c08850"), "passage": Color("6fa8dc"), "transit": Color("d8b060"), "stairs": Color("e0b070")}
const OPPOSITE := {"up": "down", "down": "up", "left": "right", "right": "left"}

var maps := {}                       # map_id → 맵 (에디터가 넘겨줌, 지금 맵은 편집 중인 내용)
var current := ""                    # 지금 편집 중인 맵 (노란 테두리)
var layout_path := "res://tools/world_layout.json"
var show_links := true
var pos := {}                        # map_id → Vector2i (칸)
var selected := ""
var zoom := 2.0                      # 화면 픽셀 / 칸
var pan := Vector2(40, 60)
var _thumbs := {}                    # map_id → ImageTexture (칸 하나 = 1px)
var _groups := []                    # [[map_id, ...]] 가장자리로 이어진 묶음
var _group_of := {}                  # map_id → 묶음 번호
var _drag := ""                      # 끄는 맵
var _drag_from := Vector2.ZERO
var _drag_start := {}                # 끌기 시작 때 묶음 위치들
var _panning := false
var _detach := false                 # Shift+끌기: 그 맵만 떼어 옮김
var _font: Font
static var _tile_colors := {}        # tile_key → 평균 색


func _init() -> void:
	clip_contents = true
	focus_mode = FOCUS_ALL
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_font = ThemeDB.fallback_font
	var bar := HBoxContainer.new()
	bar.position = Vector2(8, 6)
	add_child(bar)
	for b in [["맞춤 보기", fit_all, "모든 맵이 보이게"], ["자동 배치", auto_layout, "끌어 놓은 위치를 지우고 다시 나란히 (가장자리로 이어진 맵은 붙인 채)"]]:
		var btn := Button.new()
		btn.text = b[0]
		btn.tooltip_text = b[2]
		btn.pressed.connect(b[1])
		bar.add_child(btn)
	var links := CheckBox.new()
	links.text = "연결선"
	links.button_pressed = true
	links.toggled.connect(func(on):
		show_links = on
		queue_redraw())
	bar.add_child(links)
	var hint := Label.new()
	hint.text = "   두 번 누르기 = 편집 · 끌기 = 배치 (가장자리 가까이 놓으면 이어붙임) · Shift+끌기 = 떼기 · 휠 = 확대 · 오른쪽 끌기 = 이동"
	hint.modulate = Color(1, 1, 1, 0.6)
	bar.add_child(hint)


## 맵들을 다시 읽어 그림·배치를 만든다 (월드 맵을 열 때마다)
func refresh(p_maps: Dictionary, p_current: String) -> void:
	maps = p_maps
	current = p_current
	_thumbs = {}
	for id in maps:
		_thumbs[id] = _thumb(maps[id])
	_build_groups()
	_layout(_load_layout())
	queue_redraw()


# ---------------------------------------------------------------- 미니 그림
static func tile_color(key: String) -> Color:
	if _tile_colors.has(key):
		return _tile_colors[key]
	var c := Color(0.3, 0.3, 0.3)
	var fr := VisualData.tile_frame(key, 0)
	if not fr.is_empty() and fr[0] is Texture2D:
		var img: Image = (fr[0] as Texture2D).get_image()
		if img != null:
			if img.is_compressed():
				img.decompress()
			var r: Rect2i = Rect2i(fr[1])
			var sum := Color(0, 0, 0, 0)
			var n := 0.0
			for y in range(r.position.y, r.end.y):
				for x in range(r.position.x, r.end.x):
					var p := img.get_pixel(x, y)
					if p.a > 0.1:
						sum += p
						n += 1.0
			if n > 0:
				c = Color(sum.r / n, sum.g / n, sum.b / n)
	_tile_colors[key] = c
	return c


## 칸 하나 = 1px. 지붕·전경 가림이 있으면 그것(게임에서 위에 보이는 것), 아니면 벽·바닥 그림, 빈 공간은 투명
func _thumb(m: Dictionary) -> ImageTexture:
	var rows: Array = m.get("tiles", [])
	var w := 1
	for r in rows:
		w = maxi(w, String(r).length())
	var h := maxi(1, rows.size())
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var vis: Dictionary = m.get("visual", {}) if m.get("visual") is Dictionary else {}
	var layers: Dictionary = vis.get("layers", {}) if vis.get("layers") is Dictionary else {}
	var top := {}
	for l in ["roof", "overhead"]:
		if layers.get(l) is Dictionary:
			top.merge(layers[l], true)
	for y in rows.size():
		var row := String(rows[y])
		for x in row.length():
			var ch := row[x]
			if ch == " ":
				continue
			var k := "%d,%d" % [x, y]
			var key := ""
			if top.has(k):
				key = str(top[k])
			else:
				var ck := VisualData.cell_keys(m, x, y)
				key = ck.wall if ch == "#" else ck.floor
			var c := tile_color(key) if key != "" else (Color("2a2b31") if ch == "#" else Color("4a4e5a"))
			if ch == "#" and not top.has(k):
				c = c.darkened(0.25)
			img.set_pixel(x, y, c)
	return ImageTexture.create_from_image(img)


static func map_size(m: Dictionary) -> Vector2i:
	var w := 1
	for r in m.get("tiles", []):
		w = maxi(w, String(r).length())
	return Vector2i(w, maxi(1, m.get("tiles", []).size()))


# ---------------------------------------------------------------- 배치
## 가장자리로 이어진 맵 → 상대 위치. a 의 dir 가장자리가 b 로: b 의 왼쪽 위 = a 의 왼쪽 위 + 이 값
static func edge_offset(a: Dictionary, b: Dictionary, dir: String, offset: int) -> Vector2i:
	var sa := map_size(a)
	var sb := map_size(b)
	match dir:
		"down": return Vector2i(-offset, sa.y)
		"up": return Vector2i(-offset, -sb.y)
		"right": return Vector2i(sa.x, -offset)
	return Vector2i(-sb.x, -offset)


func _links_of(id: String) -> Array:   # [[이웃 map_id, 상대 위치]] — 양쪽 방향 모두
	var out := []
	var m: Dictionary = maps[id]
	for d in m.get("edges", {}):
		var e = m.edges[d]
		if e is Dictionary and maps.has(str(e.get("ref", ""))) and str(e.ref) != id:
			var off := int(e.get("offset", 0)) if e.get("seamless", false) else 0
			out.append([str(e.ref), edge_offset(m, maps[e.ref], d, off)])
	for other in maps:   # 저쪽에서만 이 맵으로 정해 둔 가장자리
		if other == id:
			continue
		var om: Dictionary = maps[other]
		for d in om.get("edges", {}):
			var e = om.edges[d]
			if e is Dictionary and str(e.get("ref", "")) == id:
				var off := int(e.get("offset", 0)) if e.get("seamless", false) else 0
				out.append([other, -edge_offset(om, maps[id], d, off)])
	return out


func _build_groups() -> void:
	_groups = []
	_group_of = {}
	var ids := maps.keys()
	ids.sort()
	for id in ids:
		if _group_of.has(id):
			continue
		var g := []
		var todo := [id]
		_group_of[id] = _groups.size()
		while not todo.is_empty():
			var cur: String = todo.pop_front()
			g.append(cur)
			for l in _links_of(cur):
				if not _group_of.has(l[0]):
					_group_of[l[0]] = _groups.size()
					todo.append(l[0])
		_groups.append(g)


## saved = {map_id: Vector2i}. 묶음마다 저장된 위치가 있는 맵을 기준으로 나머지를 가장자리대로, 없으면 자동으로 나란히
func _layout(saved: Dictionary) -> void:
	pos = {}
	var cursor := Vector2i(0, 0)
	var row_h := 0
	for g in _groups:
		var anchor := ""
		for id in g:
			if saved.has(id):
				anchor = id
				break
		var rel := {(anchor if anchor != "" else g[0]): Vector2i.ZERO}
		var todo := [anchor if anchor != "" else g[0]]
		while not todo.is_empty():
			var cur: String = todo.pop_front()
			for l in _links_of(cur):
				if not rel.has(l[0]):
					rel[l[0]] = rel[cur] + l[1]
					todo.append(l[0])
		var lo := Vector2i(1 << 30, 1 << 30)
		var hi := Vector2i(-(1 << 30), -(1 << 30))
		for id in rel:
			lo = Vector2i(mini(lo.x, rel[id].x), mini(lo.y, rel[id].y))
			var s := map_size(maps[id])
			hi = Vector2i(maxi(hi.x, rel[id].x + s.x), maxi(hi.y, rel[id].y + s.y))
		var origin: Vector2i
		if anchor != "":
			origin = saved[anchor] - rel[anchor]
		else:
			if cursor.x > 0 and cursor.x + (hi.x - lo.x) > ROW_WIDTH:
				cursor = Vector2i(0, cursor.y + row_h + GAP)
				row_h = 0
			origin = cursor - lo
			cursor.x += (hi.x - lo.x) + GAP
			row_h = maxi(row_h, hi.y - lo.y)
		for id in rel:
			pos[id] = origin + rel[id]
	# 자동으로 놓은 묶음이 저장된 묶음과 겹치지 않게: 저장된 것들 아래로
	if not saved.is_empty():
		var bottom := -(1 << 30)
		var auto_ids := []
		for g in _groups:
			if g.any(func(i): return saved.has(i)):
				for id in g:
					bottom = maxi(bottom, pos[id].y + map_size(maps[id]).y)
			else:
				auto_ids.append_array(g)
		if bottom > -(1 << 30) and not auto_ids.is_empty():
			var top := 1 << 30
			for id in auto_ids:
				top = mini(top, pos[id].y)
			for id in auto_ids:
				pos[id] += Vector2i(0, bottom + GAP - top)


func _load_layout() -> Dictionary:
	var out := {}
	if not FileAccess.file_exists(layout_path):
		return out
	var v = JSON.parse_string(FileAccess.get_file_as_string(layout_path))
	if v is Dictionary and v.get("maps") is Dictionary:
		for id in v.maps:
			var p = v.maps[id]
			if p is Array and p.size() == 2 and maps.has(id):
				out[id] = Vector2i(int(p[0]), int(p[1]))
	return out


func save_layout() -> void:
	var data := {"maps": {}}
	for id in pos:
		data.maps[id] = [pos[id].x, pos[id].y]
	var f := FileAccess.open(layout_path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data, "\t", true) + "\n")


func auto_layout() -> void:
	_layout({})
	save_layout()
	fit_all()
	notice.emit("월드 맵: 자동 배치")


func fit_all() -> void:
	if pos.is_empty():
		return
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for id in pos:
		var s := Vector2(map_size(maps[id]))
		lo = Vector2(minf(lo.x, pos[id].x), minf(lo.y, pos[id].y))
		hi = Vector2(maxf(hi.x, pos[id].x + s.x), maxf(hi.y, pos[id].y + s.y))
	var room := size - Vector2(60, 100)
	zoom = clampf(minf(room.x / maxf(1.0, hi.x - lo.x), room.y / maxf(1.0, hi.y - lo.y)), 0.2, 24.0)
	pan = Vector2(30, 70) - lo * zoom
	queue_redraw()


# ---------------------------------------------------------------- 그리기
func map_rect(id: String) -> Rect2:
	return Rect2(pan + Vector2(pos[id]) * zoom, Vector2(map_size(maps[id])) * zoom)


func map_at(p: Vector2) -> String:
	var ids := pos.keys()
	ids.reverse()
	for id in ids:
		if map_rect(id).has_point(p):
			return id
	return ""


## 문·통로·이용이 도착하는 칸 (출발 쪽 arrive → 저쪽 P 의 이어지는 곳 → 기본 P → start). 맵이 없으면 null
func arrival_cell(o: Dictionary) -> Variant:
	var t = maps.get(str(o.get("ref", "")))
	if not t is Dictionary:
		return null
	var objs: Array = t.get("objects", [])
	for p in objs:
		if p.get("type", "") == "arrive" and str(o.get("arrive", "")) != "" and p.object_id == o.arrive:
			return Vector2i(int(p.x), int(p.y))
	for p in objs:
		if p.get("type", "") == "arrive" and str(o.get("object_id", "")) in p.get("from", []):
			return Vector2i(int(p.x), int(p.y))
	for p in objs:
		if p.get("type", "") == "arrive" and p.get("default", false):
			return Vector2i(int(p.x), int(p.y))
	var st = t.get("start")
	if st is Array and st.size() == 2:
		return Vector2i(int(st[0]), int(st[1]))
	for p in objs:
		if p.get("type", "") == "arrive":
			return Vector2i(int(p.x), int(p.y))
	return null


func _cell_point(id: String, c: Vector2i) -> Vector2:
	return pan + (Vector2(pos[id]) + Vector2(c) + Vector2(0.5, 0.5)) * zoom


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.08, 0.085, 0.1))
	if pos.is_empty():
		draw_string(_font, Vector2(24, 80), "맵이 없습니다.", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(1, 1, 1, 0.6))
		return
	for id in pos:
		var r := map_rect(id)
		if not r.intersects(Rect2(Vector2.ZERO, size)):
			continue
		draw_rect(r, Color(0, 0, 0, 0.6))
		if _thumbs.has(id):
			draw_texture_rect(_thumbs[id], r, false)
		var border := Color(1, 0.85, 0.3) if id == current else (Color.WHITE if id == selected else Color(1, 1, 1, 0.35))
		draw_rect(r, border, false, 3.0 if id in [current, selected] else 1.0)
		if zoom >= 3.0:   # 물체 점 (확대했을 때만)
			for o in maps[id].get("objects", []):
				var c := _cell_point(id, Vector2i(int(o.get("x", 0)), int(o.get("y", 0))))
				var col: Color = {"arrive": Color("3fae5f"), "exit": TRAVEL_COLOR.exit, "passage": TRAVEL_COLOR.passage, "transit": TRAVEL_COLOR.transit,
					"enemy": Color("d05050"), "npc": Color("5a8fd0"), "camp": Color("5fae6a")}.get(o.get("type", ""), Color(0, 0, 0, 0))
				if col.a > 0:
					draw_circle(c, maxf(2.0, zoom * 0.35), col)
	if show_links:
		_draw_links()
	for id in pos:   # 이름은 맨 위에
		var r := map_rect(id)
		var fs := int(clampf(zoom * 4.0, 11.0, 20.0))
		var label: String = str(id) + ("  (편집 중)" if id == current else "")
		var tw := _font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_rect(Rect2(r.position + Vector2(0, -fs - 6), Vector2(tw + 8, fs + 6)), Color(0, 0, 0, 0.65))
		draw_string(_font, r.position + Vector2(4, -5), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 0.9, 0.5) if id == current else Color.WHITE)


func _draw_links() -> void:
	for id in pos:
		var m: Dictionary = maps[id]
		for o in m.get("objects", []):
			var t := str(o.get("type", ""))
			if not TRAVEL_COLOR.has(t) or str(o.get("ref", "")) == "":
				continue
			var a := _cell_point(id, Vector2i(int(o.x), int(o.y)))
			var cell = arrival_cell(o)
			if cell == null or not pos.has(str(o.ref)):
				draw_line(a, a + Vector2(14, -14), Color("ff5050"), 2.0)
				draw_string(_font, a + Vector2(16, -14), "⚠ " + str(o.ref), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("ff6060"))
				continue
			var b := _cell_point(str(o.ref), cell)
			_arrow(a, b, TRAVEL_COLOR[t])
		for d in m.get("edges", {}):   # 가장자리: 이어지는 맵은 붙어 있으니 초록 띠, 아니면 점선으로 도착 자리까지
			var e = m.edges[d]
			if not e is Dictionary or not pos.has(str(e.get("ref", ""))):
				continue
			var r := map_rect(id)
			var seg: Array = {"up": [r.position, Vector2(r.end.x, r.position.y)], "down": [Vector2(r.position.x, r.end.y), r.end],
				"left": [r.position, Vector2(r.position.x, r.end.y)], "right": [Vector2(r.end.x, r.position.y), r.end]}.get(d, [r.position, r.position])
			if e.get("seamless", false):
				draw_line(seg[0], seg[1], Color(0.4, 1.0, 0.5, 0.8), 3.0)
			else:
				var mid: Vector2 = (seg[0] + seg[1]) / 2.0
				var tm: Dictionary = maps[str(e.ref)]
				var cell := Vector2i(int(tm.get("start", [0, 0])[0]), int(tm.get("start", [0, 0])[1])) if tm.get("start") is Array else Vector2i.ZERO
				var tgt := _cell_point(str(e.ref), cell)
				var n := int(mid.distance_to(tgt) / 10.0)
				for i in n:
					if i % 2 == 0:
						draw_line(mid.lerp(tgt, float(i) / n), mid.lerp(tgt, float(i + 1) / n), Color(0.6, 0.9, 1.0, 0.7), 2.0)


## 끌어 놓음: (Shift 면 이웃과 떼고) 다른 맵 가장자리 가까이면 딱 붙여 이어붙이기 요청, 배치 저장
func _drop() -> void:
	var moved: Array = _drag_start.keys()
	var cut := []
	if _detach:
		for l in _links_of(_drag):
			if l[0] != _drag and not l[0] in cut:
				cut.append(l[0])
	var snap := find_snap(moved)
	if not snap.is_empty():
		for g in moved:
			pos[g] += snap.delta
	save_layout()   # 먼저 저장 — 에디터가 연결을 바꾼 뒤 월드 맵을 다시 읽음
	for other in cut:
		unlink_requested.emit(_drag, other)
	if not snap.is_empty():
		var a: String = snap.map
		var b: String = snap.other
		var off: int = (pos[a].x - pos[b].x) if snap.dir in ["up", "down"] else (pos[a].y - pos[b].y)
		link_requested.emit(a, snap.dir, b, off)
	if _detach or not snap.is_empty():
		_build_groups()
	queue_redraw()


## 옮긴 맵들(moved) 중 하나의 가장자리가 다른 맵 가장자리와 SNAP 칸 안이고 옆으로 겹치면 → {map, dir, other, delta} (가장 가까운 것)
func find_snap(moved: Array) -> Dictionary:
	var best := {}
	var best_gap := SNAP + 1
	for m in moved:
		var ma := Rect2i(pos[m], map_size(maps[m]))
		for n in pos:
			if n in moved:
				continue
			var nb := Rect2i(pos[n], map_size(maps[n]))
			var v_overlap := mini(ma.end.y, nb.end.y) - maxi(ma.position.y, nb.position.y)
			var h_overlap := mini(ma.end.x, nb.end.x) - maxi(ma.position.x, nb.position.x)
			var cands := []
			if v_overlap > 0:
				cands.append(["right", Vector2i(nb.position.x - ma.end.x, 0)])
				cands.append(["left", Vector2i(nb.end.x - ma.position.x, 0)])
			if h_overlap > 0:
				cands.append(["down", Vector2i(0, nb.position.y - ma.end.y)])
				cands.append(["up", Vector2i(0, nb.end.y - ma.position.y)])
			for c in cands:
				var gap: int = absi(c[1].x) + absi(c[1].y)
				if gap < best_gap:
					best_gap = gap
					best = {"map": m, "dir": c[0], "other": n, "delta": c[1]}
	return best


func _arrow(a: Vector2, b: Vector2, col: Color) -> void:
	draw_line(a, b, Color(col.r, col.g, col.b, 0.85), 2.0, true)
	draw_circle(a, 3.0, col)
	var dirv := (b - a).normalized()
	if dirv == Vector2.ZERO:
		return
	var side := dirv.orthogonal() * 5.0
	draw_colored_polygon(PackedVector2Array([b, b - dirv * 10.0 + side, b - dirv * 10.0 - side]), col)


# ---------------------------------------------------------------- 입력
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN] and mb.pressed:
			var old := zoom
			zoom = clampf(zoom * (1.15 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1 / 1.15), 0.2, 32.0)
			pan = mb.position - (mb.position - pan) * (zoom / old)
			queue_redraw()
		elif mb.button_index in [MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
			_panning = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				grab_focus()
				var id := map_at(mb.position)
				if mb.double_click and id != "":
					open_requested.emit(id)
					return
				selected = id
				_drag = id
				_drag_from = mb.position
				_drag_start = {}
				_detach = mb.shift_pressed
				if id != "":
					for g in ([id] if _detach else _groups[_group_of[id]]):
						_drag_start[g] = pos[g]
					notice.emit("%s  (%d × %d칸)" % [id, map_size(maps[id]).x, map_size(maps[id]).y])
				queue_redraw()
			else:
				if _drag != "" and not _drag_start.is_empty() and pos[_drag] != _drag_start[_drag]:
					_drop()
				_drag = ""
		accept_event()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _panning:
			pan += mm.relative
			queue_redraw()
		elif _drag != "" and not _drag_start.is_empty():
			var d := Vector2i(((mm.position - _drag_from) / zoom).round())
			for g in _drag_start:
				pos[g] = _drag_start[g] + d
			queue_redraw()
