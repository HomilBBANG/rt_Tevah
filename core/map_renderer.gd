@tool
extends Node2D
## 맵 그림 + 조명 (기획 tevah_pixelart_2d_lighting_map_editor_spec_v1.0). 탐험 필드와 맵 에디터가 같은 것을 쓴다.
## 논리(벽 충돌·문·시야·이동)는 건드리지 않는다 — 보이는 모습만.
##   층: 검은 바탕 → 바닥 → 바닥 장식 → 벽 외형 (TileMapLayer, 픽셀아트 nearest, 그림 1칸 tile_art_px → 화면 tile)
##   그림자: 그림자를 만드는 벽 타일(casts_shadow)과 닫힌 문에 LightOccluder2D
##   조명: CanvasModulate(환경광, 시간대·맵 환경 outdoor/indoor/underground) + 실외 햇빛(DirectionalLight2D, 그림자 없음)
##         + 광원(맵 물체 type=light → PointLight2D, 벽 그림자)
## 쓰는 법: build(map, tile) → set_time(분) / set_door_open(id, 열림) / set_lighting(켜기)

const VisualData = preload("res://core/visual_data.gd")
const LIGHT_TEX_SIZE := 256

var map := {}
var tile := 80.0
var lighting := true
var minutes := 720.0
var layers := {}                 # floor / detail / wall → TileMapLayer
var lights: Array = []           # PointLight2D
var doors := {}                  # object_id → LightOccluder2D
var occluder_count := 0          # 벽 그림자 조각 수 (테스트·디버그)
var _bg: ColorRect
var _occ_root: Node2D
var _light_root: Node2D
var _modulate: CanvasModulate
var _sun: DirectionalLight2D
var _keys := {}                  # tile_key → [source_id, atlas]
static var _light_tex: Texture2D


func _init() -> void:
	_bg = ColorRect.new()
	_bg.color = Color.BLACK
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)
	for l in VisualData.LAYERS:
		var t := TileMapLayer.new()
		t.name = "Tiles_" + l
		t.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		add_child(t)
		layers[l] = t
	_occ_root = Node2D.new()
	_occ_root.name = "Occluders"
	add_child(_occ_root)
	_light_root = Node2D.new()
	_light_root.name = "Lights"
	add_child(_light_root)
	_modulate = CanvasModulate.new()
	add_child(_modulate)
	_sun = DirectionalLight2D.new()
	_sun.shadow_enabled = false   # Godot 방향광 그림자는 끝없이 길어서 1차에서는 색·밝기만 (기획 §5.2)
	add_child(_sun)


func build(p_map: Dictionary, p_tile: float) -> void:
	map = p_map
	tile = p_tile
	rebuild_tiles()
	rebuild_lights()
	set_time(minutes)


## 타일 층 + 벽 그림자 + 문 그림자를 다시 만든다 (에디터에서 칠할 때마다)
func rebuild_tiles() -> void:
	var rows: Array = map.get("tiles", [])
	var w := 0
	for r in rows:
		w = maxi(w, String(r).length())
	_bg.position = Vector2(-4000, -4000)
	_bg.size = Vector2(w * tile + 8000, rows.size() * tile + 8000)
	var ts := _tileset()
	var scale_k := tile / float(VisualData.art_px())
	for l in layers:
		var tl: TileMapLayer = layers[l]
		tl.tile_set = ts
		tl.scale = Vector2(scale_k, scale_k)
		tl.clear()
	var shadow_cells := {}
	for y in rows.size():
		for x in String(rows[y]).length():
			var keys := VisualData.cell_keys(map, x, y)
			for l in VisualData.LAYERS:
				var key: String = keys[l]
				if key != "" and _keys.has(key):
					layers[l].set_cell(Vector2i(x, y), _keys[key][0], _keys[key][1])
			if keys.wall != "" and VisualData.tiles().get(keys.wall, {}).get("casts_shadow", false):
				shadow_cells[Vector2i(x, y)] = true
	_build_occluders(shadow_cells, rows.size(), w)


## 타일셋: 그림 파일마다 아틀라스 하나 (tile_key 는 바뀌지 않는 이름, 그림·칸은 graphics.xlsx 에서)
func _tileset() -> TileSet:
	var px := VisualData.art_px()
	var ts := TileSet.new()
	ts.tile_size = Vector2i(px, px)
	_keys = {}
	var sources := {}
	for key in VisualData.tiles():
		var t: Dictionary = VisualData.tiles()[key]
		var file := str(t.file)
		if not sources.has(file):
			var tex := VisualData.texture(file)
			if tex == null:
				continue
			var src := TileSetAtlasSource.new()
			src.texture = tex
			src.texture_region_size = Vector2i(px, px)
			sources[file] = [ts.add_source(src), src]
		var atlas := Vector2i(int(t.get("atlas_x", 0)), int(t.get("atlas_y", 0)))
		var s: TileSetAtlasSource = sources[file][1]
		if not s.has_tile(atlas):
			if atlas.x >= s.get_atlas_grid_size().x or atlas.y >= s.get_atlas_grid_size().y:
				push_warning("[그래픽] 타일 '%s' 칸 %s 가 그림 밖" % [key, atlas])
				continue
			s.create_tile(atlas)
		_keys[key] = [sources[file][0], atlas]
	return ts


## 벽 그림자: 가로로 이어진 칸을 사각형 하나로. 문(exit)은 따로 (닫혀 있을 때만)
func _build_occluders(cells: Dictionary, h: int, w: int) -> void:
	for c in _occ_root.get_children():
		_occ_root.remove_child(c)
		c.queue_free()
	doors = {}
	occluder_count = 0
	for y in h:
		var x := 0
		while x < w:
			if not cells.has(Vector2i(x, y)):
				x += 1
				continue
			var start := x
			while x < w and cells.has(Vector2i(x, y)):
				x += 1
			_occ_root.add_child(_occluder(Rect2(start * tile, y * tile, (x - start) * tile, tile)))
			occluder_count += 1
	for o in map.get("objects", []):
		if o.get("type", "") == "exit":
			var occ := _occluder(Rect2(int(o.x) * tile, int(o.y) * tile, tile, tile))
			_occ_root.add_child(occ)
			doors[o.object_id] = occ   # 처음엔 닫힘 (빛을 막음)


func _occluder(r: Rect2) -> LightOccluder2D:
	var occ := LightOccluder2D.new()
	var poly := OccluderPolygon2D.new()
	poly.polygon = PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)])
	poly.cull_mode = OccluderPolygon2D.CULL_DISABLED
	occ.occluder = poly
	return occ


## 문을 열면 빛이 지나가고 닫으면 막힌다 (논리 — 통과·시야 — 는 필드가 따로 처리)
func set_door_open(object_id: String, open: bool) -> void:
	if doors.has(object_id):
		doors[object_id].visible = not open


## 광원: 맵 물체 type=light (놓을 때 프리셋 값이 복사돼 광원마다 다를 수 있음)
func rebuild_lights() -> void:
	for c in _light_root.get_children():
		_light_root.remove_child(c)
		c.queue_free()
	lights = []
	for o in map.get("objects", []):
		if o.get("type", "") != "light":
			continue
		var p := PointLight2D.new()
		p.texture = light_texture()
		p.position = Vector2((float(o.x) + 0.5) * tile, (float(o.y) + 0.5) * tile)
		p.color = Color.html(str(o.color)) if Color.html_is_valid(str(o.get("color", ""))) else Color.WHITE
		p.energy = float(o.get("energy", 1.0))
		p.texture_scale = float(o.get("radius", 4.0)) * tile * 2.0 / LIGHT_TEX_SIZE
		p.shadow_enabled = bool(o.get("shadow", true))
		p.shadow_filter = Light2D.SHADOW_FILTER_NONE   # 픽셀아트: 딱딱한 그림자 가장자리
		p.enabled = bool(o.get("enabled", true))
		p.set_meta("object_id", o.get("object_id", ""))
		_light_root.add_child(p)
		lights.append(p)
	_apply_lighting()


static func light_texture() -> Texture2D:
	if _light_tex == null:
		var g := Gradient.new()
		g.set_color(0, Color.WHITE)
		g.set_color(1, Color(1, 1, 1, 0))
		g.add_point(0.55, Color(1, 1, 1, 0.5))
		var t := GradientTexture2D.new()
		t.gradient = g
		t.fill = GradientTexture2D.FILL_RADIAL
		t.fill_from = Vector2(0.5, 0.5)
		t.fill_to = Vector2(1.0, 0.5)
		t.width = LIGHT_TEX_SIZE
		t.height = LIGHT_TEX_SIZE
		_light_tex = t
	return _light_tex


## 시각(분, 하루 0~1440). 게임 시계를 따라 필드가 부르고, 에디터는 '시간 미리보기'로 부른다
func set_time(p_minutes: float) -> void:
	minutes = p_minutes
	_apply_lighting()


func set_lighting(on: bool) -> void:
	lighting = on
	_apply_lighting()


func profile() -> String:
	var env = map.get("environment", {})
	return str(env.get("profile", "outdoor")) if env is Dictionary and str(env.get("profile", "")) != "" else "outdoor"


func _apply_lighting() -> void:
	var a := VisualData.ambient(profile(), minutes)
	_modulate.visible = lighting
	_modulate.color = a.ambient
	_sun.enabled = lighting and a.sun_energy > 0.0
	_sun.color = a.sun
	_sun.energy = a.sun_energy
	_light_root.visible = lighting
