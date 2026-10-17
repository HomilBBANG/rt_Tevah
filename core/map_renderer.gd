@tool
extends Node2D
## 맵 그림 + 조명 (기획 tevah_pixelart_2d_lighting_map_editor_spec_v1.0). 탐험 필드와 맵 에디터가 같은 것을 쓴다.
## 논리(벽 충돌·문·시야·이동)는 건드리지 않는다 — 보이는 모습만.
##   층: 검은 바탕 → 바닥 → 바닥 장식 → 벽 외형 (TileMapLayer, 픽셀아트 nearest, 그림 1칸 tile_art_px → 화면 tile)
##   지붕: 인물·오브젝트보다 위(z 50). 이어진 지붕 칸 묶음 = 집 한 채 = TileMapLayer 하나 → 플레이어가 그 아래에 들어가면
##         그 집 지붕만 서서히 사라짐 (set_roof_open, 필드가 부름). 에디터는 반투명(roof_alpha)으로 아래가 보이게.
##   그림자: 그림자를 만드는 벽 타일(casts_shadow)과 닫힌 문에 LightOccluder2D
##   조명: CanvasModulate(환경광, 시간대·맵 환경 outdoor/indoor/underground) + 실외 햇빛(DirectionalLight2D, 그림자 없음)
##         + 광원(맵 물체 type=light → PointLight2D, 벽 그림자)
##   오브젝트 그림: 맵 물체 type=prop → Sprite2D (발 = 놓은 칸 아래쪽). 인물과 같은 Y 정렬 노드에 두면 앞뒤가 저절로
##         (필드는 build_props(%World), 에디터는 렌더러 안 props_root)
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
var props_root: Node2D           # 오브젝트 그림을 둘 Y 정렬 노드 (기본은 렌더러 안 — 필드는 인물이 있는 %World)
var prop_sprites: Array = []
var roof_regions: Array = []     # [{cells: {Vector2i: true}, layer: TileMapLayer, open: bool}]
var roof_alpha := 1.0            # 덮었을 때 지붕 불투명도 (에디터 미리보기는 반투명)
var _roof_cell := {}             # Vector2i → 지붕 묶음 번호
var _roof_root: Node2D
static var _cone_tex: Texture2D
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
	props_root = Node2D.new()
	props_root.name = "Props"
	props_root.y_sort_enabled = true
	add_child(props_root)
	_roof_root = Node2D.new()
	_roof_root.name = "Roofs"
	_roof_root.z_index = 50   # 인물(필드 %World, z 0)보다 위
	add_child(_roof_root)
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
	build_props(props_root)
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
	_rebuild_roofs(ts, scale_k)
	var pc := VisualData.prop_cells(map)
	for c in pc:
		if pc[c].get("casts_shadow", false):
			shadow_cells[c] = true   # 빛을 막는 오브젝트 (나무·상자) — 차지하는 칸
	_build_occluders(shadow_cells, rows.size(), w)


## 지붕: 이어진 칸(상하좌우)끼리 묶음 → 묶음마다 TileMapLayer
func _rebuild_roofs(ts: TileSet, scale_k: float) -> void:
	for c in _roof_root.get_children():
		_roof_root.remove_child(c)
		c.queue_free()
	roof_regions = []
	_roof_cell = {}
	var cells := VisualData.roof_cells(map)
	for start in cells:
		if _roof_cell.has(start):
			continue
		var idx := roof_regions.size()
		var region := {}
		var todo := [start]
		_roof_cell[start] = idx
		while not todo.is_empty():
			var c: Vector2i = todo.pop_back()
			region[c] = true
			for d in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
				var n: Vector2i = c + d
				if cells.has(n) and not _roof_cell.has(n):
					_roof_cell[n] = idx
					todo.append(n)
		var tl := TileMapLayer.new()
		tl.name = "Roof_%d" % idx
		tl.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		tl.tile_set = ts
		tl.scale = Vector2(scale_k, scale_k)
		for c in region:
			if _keys.has(cells[c]):
				tl.set_cell(c, _keys[cells[c]][0], _keys[cells[c]][1])
		tl.modulate.a = roof_alpha
		_roof_root.add_child(tl)
		roof_regions.append({"cells": region, "layer": tl, "open": false})


## 칸 c 를 덮는 지붕 묶음 번호 (없으면 -1)
func roof_region_at(c: Vector2i) -> int:
	return _roof_cell.get(c, -1)


## 지붕 열기(사라짐)·닫기(덮음). instant = 바로 (맵을 처음 열 때)
func set_roof_open(i: int, open: bool, instant := false) -> void:
	if i < 0 or i >= roof_regions.size():
		return
	var r: Dictionary = roof_regions[i]
	r.open = open
	var to := 0.0 if open else roof_alpha
	if instant or not is_inside_tree():
		r.layer.modulate.a = to
		return
	var tw := create_tween()
	tw.tween_property(r.layer, "modulate:a", to, 0.25)


func set_roofs_visible(v: bool) -> void:
	_roof_root.visible = v


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


## 오브젝트 그림을 parent(Y 정렬 노드)에 둔다. 다시 부르면 전에 만든 것을 지우고 새로
func build_props(parent: Node2D) -> void:
	for s in prop_sprites:
		if is_instance_valid(s):
			if s.get_parent():   # 필드가 맵을 바꿀 때 이미 빼냈을 수 있음
				s.get_parent().remove_child(s)
			s.queue_free()
	prop_sprites = []
	var defs := VisualData.props()
	var k := tile / float(VisualData.art_px())
	for o in map.get("objects", []):
		if o.get("type", "") != "prop" or not defs.has(str(o.get("ref", ""))):
			continue
		var d: Dictionary = defs[o.ref]
		var tex := VisualData.texture(str(d.file), VisualData.PROPS_DIR)
		if tex == null:
			continue
		var sp := Sprite2D.new()
		sp.texture = tex
		sp.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		sp.centered = false
		sp.scale = Vector2(k, k)
		# 위치 = 발(차지하는 칸의 아래 가운데) → Y 정렬 기준. 그림은 그 위로
		var fw := int(d.get("foot_w", 1))
		sp.position = Vector2((float(o.x) + fw / 2.0) * tile, (float(o.y) + 1.0) * tile)
		sp.offset = Vector2(-tex.get_width() / 2.0, -tex.get_height())
		sp.set_meta("object_id", o.get("object_id", ""))
		parent.add_child(sp)
		prop_sprites.append(sp)


## 광원 노드 하나 (프리셋·맵 광원 값): shape point = 둥근 빛, cone = 앞(오른쪽, rotation 으로 돌림)으로 비추는 원뿔
static func make_light(o: Dictionary, p_tile: float) -> PointLight2D:
	var p := PointLight2D.new()
	var cone: bool = str(o.get("shape", "point")) == "cone"
	p.texture = cone_texture() if cone else light_texture()
	p.color = Color.html(str(o.color)) if Color.html_is_valid(str(o.get("color", ""))) else Color.WHITE
	p.energy = float(o.get("energy", 1.0))
	p.texture_scale = float(o.get("radius", 4.0)) * p_tile * 2.0 / LIGHT_TEX_SIZE
	p.shadow_enabled = bool(o.get("shadow", true))
	p.shadow_filter = Light2D.SHADOW_FILTER_NONE   # 픽셀아트: 딱딱한 그림자 가장자리
	p.enabled = bool(o.get("enabled", true))
	return p


## 원뿔 빛 그림: 가운데에서 오른쪽으로 퍼지는 부채꼴 (반각 28°), 멀수록 흐림
static func cone_texture() -> Texture2D:
	if _cone_tex == null:
		var n := LIGHT_TEX_SIZE
		var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
		var c := Vector2(n, n) / 2.0
		for y in n:
			for x in n:
				var v := Vector2(x, y) - c
				var d := v.length() / (n / 2.0)
				var a := absf(v.angle())
				var edge := clampf((deg_to_rad(28.0) - a) / deg_to_rad(8.0), 0.0, 1.0)
				var near := clampf(1.0 - d, 0.0, 1.0)
				var glow := clampf(1.0 - v.length() / 14.0, 0.0, 1.0) * 0.6   # 손 주변 조금
				var k := maxf(edge * near, glow) if d <= 1.0 else 0.0
				img.set_pixel(x, y, Color(1, 1, 1, k))
		_cone_tex = ImageTexture.create_from_image(img)
	return _cone_tex


## 광원: 맵 물체 type=light (놓을 때 프리셋 값이 복사돼 광원마다 다를 수 있음)
func rebuild_lights() -> void:
	for c in _light_root.get_children():
		_light_root.remove_child(c)
		c.queue_free()
	lights = []
	for o in map.get("objects", []):
		if o.get("type", "") != "light":
			continue
		var p := make_light(o, tile)
		p.position = Vector2((float(o.x) + 0.5) * tile, (float(o.y) + 0.5) * tile)
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
