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
const PAINT_LAYERS := ["floor", "detail", "wall", "roof"]
const LAYER_NAME := {"floor": "바닥", "detail": "바닥 장식", "wall": "벽 외형", "roof": "지붕"}

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
	elif out.floor == "":
		out.floor = _map_default(vis, "default_floor", "floor", "floor_default")
	return out


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
	return [tex, Rect2((int(t.get("atlas_x", 0)) + frame) * px, int(t.get("atlas_y", 0)) * px, px, px)]


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


static func _row(r: Array) -> Dictionary:
	return {"ambient": Color.html(str(r[1])), "sun": Color.html(str(r[2])), "sun_energy": float(r[3])}
