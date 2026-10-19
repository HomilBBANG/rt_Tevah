@tool
extends RefCounted
## 그래픽 데이터 (data/graphics.json ← tools/sheets/graphics.xlsx). 게임(필드)과 맵 에디터가 같이 쓴다 — 에디터에서도 돌도록 @tool·static.
##   타일: tile_key → {name, layer(floor/detail/wall), file(art/tiles/), atlas_x, atlas_y, casts_shadow}
##   광원 프리셋, 시간대 환경광 day_night {profile: [[시, 환경색, 햇빛색, 햇빛 세기], ...]}
## 맵의 그래픽은 논리(벽 # / 바닥 . / 빈 공간 공백)와 따로: map.visual.layers {floor|detail|wall: {"x,y": tile_key}}
## 칠하지 않은 칸은 바닥 = floor_default, 벽 = wall_default.

const DATA_PATH := "res://data/graphics.json"
const TILES_DIR := "res://art/tiles/"
const PROPS_DIR := "res://art/props/"
const LAYERS := ["floor", "detail", "wall"]   # 바닥 그림 층 (cell_keys)
## 칠할 수 있는 층 = 바닥 그림 층 + 지붕 (지붕은 인물보다 위에 따로 — map_renderer 의 roof)
## 전경 가림(overhead): 인물 위에 늘 보이는 가림막·천장·상단 벽 — 보이기만, 충돌·시야·빛 차단 없음 (map_renderer 의 Overhead)
const PAINT_LAYERS := ["floor", "detail", "wall", "roof", "overhead"]
## 벽·바닥 층은 칠하면 그 칸의 판정도 같이 바뀜 (벽 = 지나갈 수 없음, 바닥 = 지나갈 수 있음). 나머지는 그림만 (map_canvas._paint_tile)
const LAYER_NAME := {"floor": "바닥 (지나갈 수 있음)", "detail": "바닥 장식 (그림만)", "wall": "벽 (지나갈 수 없음)", "roof": "지붕 (그림만)", "overhead": "전경 가림 (그림만)"}
const LOGIC_OF_LAYER := {"wall": "#", "floor": "."}

static var _data := {}
static var _tiles := {}
static var _tex := {}         # file → Texture2D


## 다시 읽기 (변환 뒤 에디터에서)
static func reload() -> void:
	_data = {}
	_tiles = {}
	_tex = {}


static func data() -> Dictionary:
	if _data.is_empty():
		var v = JSON.parse_string(FileAccess.get_file_as_string(DATA_PATH)) if FileAccess.file_exists(DATA_PATH) else null
		_data = v if v is Dictionary else {"tiles": [], "light_presets": [], "day_night": {}, "tile_art_px": 16}
		_tiles = {}
		for t in _data.get("tiles", []):
			_tiles[t.tile_key] = t
	return _data


static func tiles() -> Dictionary:
	data()
	return _tiles


static func art_px() -> int:
	return int(data().get("tile_art_px", 16))


## 오브젝트 그림 (나무·가구): prop_id → {name, file, foot_w, foot_h, solid, casts_shadow}
static func props() -> Dictionary:
	var out := {}
	for p in data().get("props", []):
		out[p.prop_id] = p
	return out


## 맵의 오브젝트(type=prop)가 차지하는 칸 → prop 정의. 놓은 칸 = 왼쪽 아래, foot_w 오른쪽·foot_h 위로
static func prop_cells(map: Dictionary) -> Dictionary:
	var out := {}
	var defs := props()
	for o in map.get("objects", []):
		if o.get("type", "") != "prop" or not defs.has(str(o.get("ref", ""))):
			continue
		var d: Dictionary = defs[o.ref]
		for dy in int(d.get("foot_h", 1)):
			for dx in int(d.get("foot_w", 1)):
				out[Vector2i(int(o.x) + dx, int(o.y) - dy)] = d
	return out


## 기타 가구(type=furniture)가 차지하는 칸: 놓은 칸 = 왼쪽 위, w 오른쪽·h 아래로
static func furniture_cells(o: Dictionary) -> Array:
	var out := []
	for dy in maxi(1, int(o.get("h", 1))):
		for dx in maxi(1, int(o.get("w", 1))):
			out.append(Vector2i(int(o.x) + dx, int(o.y) + dy))
	return out


## 가구의 막힌 칸: 위쪽 top_rows 줄은 '뒤로 지나갈 수 있는 윗부분'(키 큰 장롱·시계 — 그 뒤에 서면 가구가 인물을 가림, Y 정렬)
static func furniture_solid_cells(o: Dictionary) -> Array:
	if o.get("solid", true) == false:
		return []
	var top := clampi(int(o.get("top_rows", 0)), 0, maxi(1, int(o.get("h", 1))) - 1)
	return furniture_cells(o).filter(func(c): return c.y >= int(o.y) + top)


## 지나갈 수 없는 오브젝트 칸 (solid) — 필드 충돌·컷신 길 찾기
static func solid_cells(map: Dictionary) -> Array:
	var out := []
	var cells := prop_cells(map)
	for c in cells:
		if cells[c].get("solid", false):
			out.append(c)
	return out


static func presets() -> Array:
	return data().get("light_presets", [])


static func preset(id: String) -> Dictionary:
	for p in presets():
		if p.preset_id == id:
			return p
	return {}


static func profiles() -> Array:
	return data().get("day_night", {}).keys()


## 그림 파일 (가져오기된 리소스가 있으면 그것, 없으면 파일을 직접 읽음 — 처음 넣은 그림·테스트)
static func texture(file: String, dir := TILES_DIR) -> Texture2D:
	if _tex.has(dir + file):
		return _tex[dir + file]
	var path := dir + file
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		tex = load(path)
	else:
		var img := Image.load_from_file(ProjectSettings.globalize_path(path))
		if img and not img.is_empty():
			tex = ImageTexture.create_from_image(img)
	if tex == null:
		push_warning("[그래픽] 타일 그림을 찾을 수 없음: %s" % path)
	_tex[dir + file] = tex
	return tex


## 타일 한 칸의 그림 영역 → [Texture2D, Rect2] (없으면 [])
static func tile_region(key: String) -> Array:
	var t: Dictionary = tiles().get(key, {})
	if t.is_empty():
		return []
	var tex := texture(str(t.file))
	if tex == null:
		return []
	var px := art_px()
	return [tex, Rect2(int(t.get("atlas_x", 0)) * px, int(t.get("atlas_y", 0)) * px, px, px)]


## 칸 (x, y) 에 보일 타일: {floor, detail, wall} (없으면 ""). 칠한 타일이 없거나 틀리면 기본 타일
static func cell_keys(map: Dictionary, x: int, y: int) -> Dictionary:
	var out := {"floor": "", "detail": "", "wall": ""}
	var rows: Array = map.get("tiles", [])
	if y < 0 or y >= rows.size() or x < 0 or x >= String(rows[y]).length():
		return out
	var ch := String(rows[y])[x]
	if ch == " ":
		return out   # 빈 공간: 검게
	var vis: Dictionary = map.get("visual", {}) if map.get("visual") is Dictionary else {}
	var layers: Dictionary = vis.get("layers", {})
	var k := "%d,%d" % [x, y]
	var t := tiles()
	for layer in LAYERS:
		var cells = layers.get(layer, {})
		var key: String = str(cells.get(k, "")) if cells is Dictionary else ""
		if key != "" and t.has(key):
			out[layer] = key
	if ch == "#":
		out.floor = ""
		if out.wall == "":
			out.wall = _map_default(vis, "default_wall", "wall", "wall_default")
		out.wall = _face_of(out.wall, rows, x, y)
	elif out.floor == "":
		out.floor = _map_default(vis, "default_floor", "floor", "floor_default")
	return out


## 쿼터뷰 벽 블록 그림: {top: 윗면 타일, face: 옆면 타일}. 칠한 타일이 앞면 타일이면 그 앞면을 가진 벽 타일이 윗면
static func wall_keys(map: Dictionary, x: int, y: int) -> Dictionary:
	var rows: Array = map.get("tiles", [])
	var vis: Dictionary = map.get("visual", {}) if map.get("visual") is Dictionary else {}
	var cells = (vis.get("layers", {}) if vis.get("layers") is Dictionary else {}).get("wall", {})
	var key: String = str(cells.get("%d,%d" % [x, y], "")) if cells is Dictionary else ""
	if key == "" or not tiles().has(key):
		key = _map_default(vis, "default_wall", "wall", "wall_default")
	var base := key
	if face_keys().has(key):
		for k in tiles():
			if str(tiles()[k].get("face", "")) == key:
				base = k
				break
	var f = tiles().get(base, {}).get("face")
	return {"top": base, "face": str(f) if f != null and str(f) != "" and tiles().has(str(f)) else key}


## 앞면(벽면) 타일 이름들 — 어떤 벽 타일의 face 로 쓰이는 것 (칠해서 직접 쓴 것도 앞면)
static func face_keys() -> Dictionary:
	var out := {}
	for k in tiles():
		var f = tiles()[k].get("face")
		if f != null and str(f) != "":
			out[str(f)] = true
	return out


## 비스듬한 탑뷰 (피어앤헝거·RPG Maker 식): 벽 타일에 face(앞면 타일)가 있고, 아래(남쪽) face_rows 칸 안에 바닥이 있으면
## 그 칸은 앞면 그림 (벽 사이에 끼인 칸도 — 건물 정면 2줄 등). 아니면 윗면(원래 타일). 보이는 모습만, 판정은 그대로.
static func _face_of(key: String, rows: Array, x: int, y: int) -> String:
	var t: Dictionary = tiles().get(key, {})
	var face := str(t.get("face", "")) if t.get("face") != null else ""
	if face == "" or not tiles().has(face):
		return key
	var n := maxi(1, int(t.get("face_rows", 1)) if t.get("face_rows") != null else 1)
	for d in range(1, n + 1):
		if y + d >= rows.size() or x >= String(rows[y + d]).length():
			return key
		var c := String(rows[y + d])[x]
		if c == ".":
			return face
		if c != "#":
			return key
	return key


## 맵의 기본 그림 (visual.default_floor / default_wall — 칠하지 않은 칸). 없거나 틀리면 floor_default / wall_default
static func _map_default(vis: Dictionary, field: String, layer: String, fallback: String) -> String:
	var t := tiles()
	var key := str(vis.get(field, ""))
	if key != "" and t.has(key) and str(t[key].get("layer", "")) == layer:
		return key
	return fallback if t.has(fallback) else ""


## 물체 그림 기본값: 문 = layer door 중 _open 이 아닌 첫 타일, 조사 반짝이 = layer marker 첫 타일
static func default_art(layer: String) -> String:
	for k in tiles():
		if str(tiles()[k].get("layer", "")) == layer and not (layer == "door" and str(k).ends_with("_open")):
			return k
	return ""


## 타일 그림 영역 (애니메이션이면 frame 번째: atlas_x + frame)
static func tile_frame(key: String, frame: int) -> Array:
	var t: Dictionary = tiles().get(key, {})
	var tex := texture(str(t.get("file", ""))) if not t.is_empty() else null
	if tex == null:
		return []
	var px := art_px()
	var hh := maxi(1, int(t.get("h", 1)) if t.get("h") != null else 1)   # 그림 높이(칸) — 2칸 높이 문
	return [tex, Rect2((int(t.get("atlas_x", 0)) + frame) * px, int(t.get("atlas_y", 0)) * px, px, px * hh)]


## 전경 가림 칸 {Vector2i: tile_key} — 맵 안, 있는 overhead 타일만 (없는·다른 층 타일은 변환기가 오류로 잡음)
static func overhead_cells(map: Dictionary) -> Dictionary:
	var out := {}
	var cells = ((map.get("visual", {}) if map.get("visual") is Dictionary else {}).get("layers", {})).get("overhead", {})
	if not cells is Dictionary:
		return out
	var rows: Array = map.get("tiles", [])
	for k in cells:
		var xy := str(k).split(",")
		if xy.size() != 2:
			continue
		var c := Vector2i(int(xy[0]), int(xy[1]))
		if c.y < 0 or c.y >= rows.size() or c.x < 0 or c.x >= String(rows[c.y]).length():
			continue
		var key := str(cells[k])
		if tiles().has(key) and str(tiles()[key].get("layer", "")) == "overhead":
			out[c] = key
	return out


## 지붕 칸 {Vector2i: tile_key} — 맵 안, 있는 지붕 타일(layer=roof)만. 이어진 칸 묶음 하나 = 집 한 채
static func roof_cells(map: Dictionary) -> Dictionary:
	var out := {}
	var cells = ((map.get("visual", {}) if map.get("visual") is Dictionary else {}).get("layers", {})).get("roof", {})
	if not cells is Dictionary:
		return out
	var rows: Array = map.get("tiles", [])
	var t := tiles()
	for k in cells:
		var xy := str(k).split(",")
		if xy.size() != 2:
			continue
		var c := Vector2i(int(xy[0]), int(xy[1]))
		if c.y < 0 or c.y >= rows.size() or c.x < 0 or c.x >= String(rows[c.y]).length():
			continue
		var key := str(cells[k])
		if t.has(key) and str(t[key].get("layer", "")) == "roof":
			out[c] = key
	return out


## 시간대 환경광: profile 의 시각(분)별 색을 부드럽게 섞음 → {ambient, sun, sun_energy}
static func ambient(profile: String, minutes: float) -> Dictionary:
	var dn: Dictionary = data().get("day_night", {})
	var rows: Array = dn.get(profile, dn.get("outdoor", []))
	if rows.is_empty():
		return {"ambient": Color.WHITE, "sun": Color.BLACK, "sun_energy": 0.0}
	var h := fposmod(minutes / 60.0, 24.0)
	var n := rows.size()
	# 시각들은 하루를 도는 고리: i → i+1 구간, 마지막 → 처음 구간은 자정을 넘는다
	for i in n:
		var a: Array = rows[i]
		var b: Array = rows[(i + 1) % n]
		var ah := float(a[0])
		var bh := float(b[0]) + (24.0 if i == n - 1 else 0.0)
		var hh := h + 24.0 if i == n - 1 and h < ah else h
		if hh >= ah and hh <= bh:
			var t := (hh - ah) / (bh - ah) if bh > ah else 0.0
			var ra := _row(a)
			var rb := _row(b)
			return {"ambient": ra.ambient.lerp(rb.ambient, t), "sun": ra.sun.lerp(rb.sun, t),
				"sun_energy": lerpf(ra.sun_energy, rb.sun_energy, t)}
	return _row(rows[0])


## 창문으로 들어오는 햇빛: 맵 환경과 상관없이 실외(outdoor) 시간대로 → {color, k(0 밤 ~ 1 가장 밝을 때)}
static func daylight(minutes: float) -> Dictionary:
	var rows: Array = data().get("day_night", {}).get("outdoor", [])
	if rows.is_empty():
		return {"color": Color.WHITE, "k": 1.0}
	var lo := INF
	var hi := -INF
	for r in rows:
		lo = minf(lo, float(r[3]))
		hi = maxf(hi, float(r[3]))
	var a := ambient("outdoor", minutes)
	return {"color": a.sun, "k": clampf((a.sun_energy - lo) / (hi - lo), 0.0, 1.0) if hi > lo else 1.0}


const WINDOW_SCAN := 12   # 뒷벽 창문: 창문 아래로 벽(#)만 이어지다 바닥이 나오기까지 볼 칸 수


## 창문 빛: 창문 사각형(x, y, w × h 칸) 바로 옆의 바닥 쪽(아래 → 위 → 왼쪽 → 오른쪽), 없으면 비스듬한 탑뷰의 뒷벽 —
## 창문 아래로 벽만 이어지다 나오는 바닥 쪽(아래). → {dir, origin(빛이 시작하는 칸 좌표, 바닥 가장자리 가운데), reach_y(바닥 줄)}. 못 찾으면 dir ZERO
static func window_light(map: Dictionary, o: Dictionary) -> Dictionary:
	var rows: Array = map.get("tiles", [])
	var x := int(o.get("x", 0))
	var y := int(o.get("y", 0))
	var w := maxi(1, int(o.get("w", 1)))
	var h := maxi(1, int(o.get("h", 1)))
	var ch := func(cx: int, cy: int) -> String:
		return String(rows[cy])[cx] if cy >= 0 and cy < rows.size() and cx >= 0 and cx < String(rows[cy]).length() else " "
	for cx in range(x, x + w):
		if ch.call(cx, y + h) == ".":
			return {"dir": Vector2i.DOWN, "origin": Vector2(x + w / 2.0, y + h), "reach_y": y + h}
	for cx in range(x, x + w):
		if ch.call(cx, y - 1) == ".":
			return {"dir": Vector2i.UP, "origin": Vector2(x + w / 2.0, y), "reach_y": y}
	for cy in range(y, y + h):
		if ch.call(x - 1, cy) == ".":
			return {"dir": Vector2i.LEFT, "origin": Vector2(x, y + h / 2.0), "reach_y": y + h}
	for cy in range(y, y + h):
		if ch.call(x + w, cy) == ".":
			return {"dir": Vector2i.RIGHT, "origin": Vector2(x + w, y + h / 2.0), "reach_y": y + h}
	for cy in range(y + h, y + h + WINDOW_SCAN):   # 뒷벽: 아래로 벽만 이어지다 바닥
		var c: String = ch.call(x + (w >> 1), cy)
		if c == ".":
			return {"dir": Vector2i.DOWN, "origin": Vector2(x + w / 2.0, cy), "reach_y": cy}
		if c != "#":
			break
	return {"dir": Vector2i.ZERO, "origin": Vector2.ZERO, "reach_y": y + h}


## 창문 칸에서 빛이 들어갈 쪽 (1칸 창문, 예전 이름)
static func window_dir(map: Dictionary, x: int, y: int) -> Vector2i:
	return window_light(map, {"x": x, "y": y}).dir


## 바깥 창문의 '안쪽 맵': 물체 inside(직접 고름) → 없으면 그 맵에서 가장 가까운 문·통로·이용의 이동할 맵. 없으면 ""
static func window_inside(map: Dictionary, o: Dictionary) -> String:
	if str(o.get("inside", "")) != "":
		return str(o.inside)
	var best := ""
	var best_d := INF
	for t in map.get("objects", []):
		if str(t.get("type", "")) in ["exit", "passage", "transit"] and str(t.get("ref", "")) != "":
			var d := Vector2(int(t.x) - int(o.x), int(t.y) - int(o.y)).length()
			if d < best_d:
				best_d = d
				best = str(t.ref)
	return best


## 안쪽 맵에 켜진 광원(type=light, enabled)이 있나 — 바깥 창문이 불 켜진 창으로 보임. maps = {map_id: 맵}
static func inside_lit(map: Dictionary, o: Dictionary, maps: Dictionary) -> bool:
	var m = maps.get(window_inside(map, o), {})
	if not m is Dictionary:
		return false
	for t in m.get("objects", []):
		if str(t.get("type", "")) == "light" and t.get("enabled", true) != false:
			return true
	return false


## 문이 달린 벽: face = 정면 (위가 벽 — 뒷벽, 키 큰 문) / face_short = 정면이지만 위도 바닥 (1칸 두께 가로벽 — 1칸 문) /
## side = 옆벽 (위아래가 벽) / bottom = 방의 아랫벽 (위가 바닥, 아래가 막힘 — 앞면이 안 보이는 벽).
## 문 칸 자체는 바닥이므로 이웃 칸으로 판단. 정면만 Tiles 문 그림(2칸 높이), 나머지는 core/door_view.gd
static func door_mode(map: Dictionary, o: Dictionary) -> String:
	var rows: Array = map.get("tiles", [])
	var x := int(o.get("x", 0))
	var y := int(o.get("y", 0))
	var wall := func(cx: int, cy: int) -> bool:
		return cy < 0 or cy >= rows.size() or cx < 0 or cx >= String(rows[cy]).length() or String(rows[cy])[cx] != "."
	var up: bool = wall.call(x, y - 1)
	var down: bool = wall.call(x, y + 1)
	var left: bool = wall.call(x - 1, y)
	var right: bool = wall.call(x + 1, y)
	if up and down and not (left and right):
		return "side"
	if not up and (left or right):
		return "face_short" if not down else "bottom"
	return "face"


## 키 1칸짜리 문 그림 (1칸 두께 벽의 정면 문): door 층에서 h 1 인 첫 타일 (열림 제외)
static func short_door_art() -> String:
	for k in tiles():
		var t: Dictionary = tiles()[k]
		if str(t.get("layer", "")) == "door" and not str(k).ends_with("_open") and int(t.get("h", 1) if t.get("h") != null else 1) <= 1:
			return k
	return ""


## 광원이 벽 칸에 있나 (벽걸이등) — 빛은 그 벽 앞 바닥 가장자리에서 (window_light 와 같은 규칙)
static func light_on_wall(map: Dictionary, o: Dictionary) -> bool:
	var rows: Array = map.get("tiles", [])
	var x := int(o.get("x", -1))
	var y := int(o.get("y", -1))
	return y >= 0 and y < rows.size() and x >= 0 and x < String(rows[y]).length() and String(rows[y])[x] == "#"


## 크기가 있는 물체(가구·창문)가 차지하는 칸, 나머지는 놓은 칸 하나
static func object_cells(o: Dictionary) -> Array:
	if str(o.get("type", "")) in ["furniture", "window"]:
		return furniture_cells(o)
	return [Vector2i(int(o.get("x", 0)), int(o.get("y", 0)))]


static func _row(r: Array) -> Dictionary:
	return {"ambient": Color.html(str(r[1])), "sun": Color.html(str(r[2])), "sun_energy": float(r[3])}
