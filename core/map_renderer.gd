@tool
extends Node2D
## 맵 그림 + 조명 (기획 tevah_pixelart_2d_lighting_map_editor_spec_v1.0). 탐험 필드와 맵 에디터가 같은 것을 쓴다.
## 논리(벽 충돌·문·시야·이동)는 건드리지 않는다 — 보이는 모습만.
##   층: 검은 바탕 → 바닥 → 바닥 장식 → 벽 외형 (TileMapLayer, 픽셀아트 nearest, 그림 1칸 tile_art_px → 화면 tile)
##   지붕: 인물·오브젝트보다 위(z 50). 이어진 지붕 칸 묶음 = 집 한 채 = TileMapLayer 하나 → 플레이어가 그 아래에 들어가면
##         그 집 지붕만 서서히 사라짐 (set_roof_open, 필드가 부름). 에디터는 반투명(roof_alpha)으로 아래가 보이게.
##   전경 가림(Overhead, 기획 tevah_foreground_occlusion_map_editor_spec_v1.0): 인물·지붕보다 위(z 60) TileMapLayer 하나.
##         늘 불투명(게임). 보이기만 — 충돌(필드 벽은 논리 칸 #)·적 시야(물리 레이캐스트)·빛 그림자(occluder)와 무관.
##         에디터만 overhead_alpha(미리보기 투명도)·set_overhead_visible·set_overhead_only(전경만 보기) — 맵 파일에 저장 안 됨
##   그림자: 그림자를 만드는 벽 타일(casts_shadow)과 닫힌 문에 LightOccluder2D
##   조명: CanvasModulate(환경광, 시간대·맵 환경 outdoor/indoor/underground) + 실외 햇빛(DirectionalLight2D, 그림자 없음)
##         + 광원(맵 물체 type=light → PointLight2D, 벽 그림자)
##   오브젝트 그림: 맵 물체 type=prop → Sprite2D (발 = 놓은 칸 아래쪽). 인물과 같은 Y 정렬 노드에 두면 앞뒤가 저절로
##   물체 표시 그림 (Tiles layer door / marker): 문(exit) = 닫힘·열림 그림 (set_door_open 이 바꿈, 물체 look 으로 고름),
##         조사 지점(investigate) = 반짝이 애니메이션 (빛 영향 없이 어두워도 보임, set_spot_done 이 숨김)
##         (필드는 build_props(%World), 에디터는 렌더러 안 props_root)
##   창문 (맵 물체 type=window, 벽 칸): 그림 = Tiles layer window (커튼 = key_curtain), 옆 바닥 쪽으로 햇빛(부채꼴 PointLight2D,
##         실외 시간대 밝기·색 — 밤엔 꺼짐, 실내 맵에서도). 커튼을 치면 빛이 꺼짐 (set_curtain). 창문 칸은 그림자를 만들지 않음
## 쓰는 법: build(map, tile) → set_time(분) / set_door_open(id, 열림) / set_lighting(켜기)

const VisualData = preload("res://core/visual_data.gd")
const WindowView = preload("res://core/window_view.gd")
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
var overhead: TileMapLayer       # 전경 가림 층
var overhead_alpha := 1.0        # 에디터 미리보기 투명도 (게임은 늘 1)
var _roof_cell := {}             # Vector2i → 지붕 묶음 번호
var markers := {}                # object_id → {sprite, kind: door/spark/window, key, frames, fps}
var windows := {}                # object_id → {light: PointLight2D, curtain: bool, outside: bool, lit: bool}
var world_maps := {}             # 다른 맵들 {map_id: 맵} — 바깥 창문이 안쪽 맵 불을 보려고 (필드 = DataLoader.maps, 에디터 = 맵 파일들)
const LAMP_GLOW := Color(1.0, 0.78, 0.45)   # 불 켜진 창 (안쪽 맵에 켜진 광원)
static var _window_tex: Texture2D
var _marker_root: Node2D
var _anim_t := 0.0
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
	_marker_root = Node2D.new()
	_marker_root.name = "Markers"
	add_child(_marker_root)
	_roof_root = Node2D.new()
	_roof_root.name = "Roofs"
	_roof_root.z_index = 50   # 인물(필드 %World, z 0)보다 위
	add_child(_roof_root)
	overhead = TileMapLayer.new()
	overhead.name = "Overhead"
	overhead.z_index = 60     # 인물·지붕보다 위. HUD(CanvasLayer)는 따로라 덮지 않음
	overhead.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(overhead)
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
	build_markers()
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
	var face_cells := {}   # 벽 앞면(방 쪽 세로 면): 빛을 받는 면이라 칸 전체로는 안 막고, 맨 위 경계에 얇은 그림자 선만
	var faces := VisualData.face_keys()
	for y in rows.size():
		for x in String(rows[y]).length():
			var keys := VisualData.cell_keys(map, x, y)
			for l in VisualData.LAYERS:
				var key: String = keys[l]
				if key != "" and _keys.has(key):
					layers[l].set_cell(Vector2i(x, y), _keys[key][0], _keys[key][1])
			if keys.wall != "" and faces.has(keys.wall):
				face_cells[Vector2i(x, y)] = true
			elif keys.wall != "" and VisualData.tiles().get(keys.wall, {}).get("casts_shadow", false):
				shadow_cells[Vector2i(x, y)] = true
	_rebuild_roofs(ts, scale_k)
	overhead.tile_set = ts
	overhead.scale = Vector2(scale_k, scale_k)
	overhead.clear()
	var oc := VisualData.overhead_cells(map)
	for c in oc:
		if _keys.has(oc[c]):
			overhead.set_cell(c, _keys[oc[c]][0], _keys[oc[c]][1])
	overhead.modulate.a = overhead_alpha
	for o in map.get("objects", []):
		if o.get("type", "") == "window":
			for c in VisualData.object_cells(o):
				shadow_cells.erase(c)   # 창문 칸으로 빛이 지나감
	var pc := VisualData.prop_cells(map)
	for c in pc:
		if pc[c].get("casts_shadow", false):
			shadow_cells[c] = true   # 빛을 막는 오브젝트 (나무·상자) — 차지하는 칸
	var face_tops := {}   # 앞면 묶음의 맨 위 칸 (위가 앞면이 아님) — 벽 너머 방의 빛이 새지 않게
	for c in face_cells:
		if not face_cells.has(c + Vector2i.UP):
			face_tops[c] = true
	_build_occluders(shadow_cells, rows.size(), w, face_tops)


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


## 문·조사 지점 그림 (Tiles 에 그림이 없으면 만들지 않음 — 필드의 MapView 가 예전 도형으로 그림)
func build_markers() -> void:
	for c in _marker_root.get_children():
		_marker_root.remove_child(c)
		c.queue_free()
	markers = {}
	var door := VisualData.default_art("door")
	var spark := VisualData.default_art("marker")
	var px := float(VisualData.art_px())
	for o in map.get("objects", []):
		var key := ""
		var kind := ""
		if o.get("type") == "exit":
			key = str(o.get("look", "")) if str(o.get("look", "")) != "" and VisualData.tiles().has(str(o.get("look", ""))) else door
			kind = "door"
		elif o.get("type") == "investigate":
			key = spark
			kind = "spark"
		elif o.get("type") == "light" and VisualData.light_on_wall(map, o):   # 벽걸이등 그림 (Tiles layer lamp)
			key = VisualData.default_art("lamp")
			kind = "lamp"
		elif o.get("type") == "camp":   # 거점: 텐트 그림 (Tiles layer camp)
			key = VisualData.default_art("camp")
			kind = "camp"
		elif o.get("type") == "window":
			key = str(o.get("look", "")) if VisualData.tiles().has(str(o.get("look", ""))) else ""
			kind = "window"
			if key == "":   # 그림을 따로 안 골랐으면 크기에 맞춰 그린 기본 창문 (core/window_view.gd)
				var wv := WindowView.new()
				var wl := VisualData.window_light(map, o)
				var mode := "side_v" if wl.dir in [Vector2i.LEFT, Vector2i.RIGHT] else ("side_h" if wl.dir == Vector2i.UP else "face")
				wv.position = Vector2(float(o.x), float(o.y)) * tile
				wv.setup(Vector2i(int(o.get("w", 1)), int(o.get("h", 1))), mode, tile / px)
				_marker_root.add_child(wv)
				markers[str(o.object_id)] = {"view": wv, "kind": "window", "key": "", "frames": 1, "fps": 0.0}
				if windows.has(str(o.object_id)):
					set_curtain(str(o.object_id), windows[str(o.object_id)].curtain)
				continue
		if key == "":
			continue
		var fr := VisualData.tile_frame(key, 0)
		if fr.is_empty():
			continue
		var s := Sprite2D.new()
		var at := AtlasTexture.new()
		at.atlas = fr[0]
		at.region = fr[1]
		s.texture = at
		s.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		s.position = Vector2((float(o.x) + 0.5) * tile, (float(o.y) + 0.5) * tile)
		s.scale = Vector2.ONE * (tile / px) * (0.9 if kind == "spark" else 1.0)
		if kind == "door" and fr[1].size.y > px:   # 키 큰 문 그림 (Tiles h): 밑은 문 칸 바닥, 위로 벽 칸까지
			s.position.y -= (fr[1].size.y / px - 1.0) * tile / 2.0
		if kind == "camp":   # 거점 텐트: 1.5배, 밑변은 칸 바닥에
			s.scale *= 1.5
			s.position.y -= tile * 0.25
		if kind == "window":   # 창문 크기 w × h 칸 (그림을 늘림)
			var ww := maxi(1, int(o.get("w", 1)))
			var wh := maxi(1, int(o.get("h", 1)))
			s.position = (Vector2(float(o.x), float(o.y)) + Vector2(ww, wh) / 2.0) * tile
			s.scale = Vector2(ww, wh) * (tile / px)
		if kind == "lamp":   # 켜진 등은 빛 영향 없이 밝게, 꺼지면 방과 같이
			s.visible = true
			if o.get("enabled", true) != false:
				var lm := CanvasItemMaterial.new()
				lm.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED
				s.material = lm
			else:
				s.modulate = Color(0.55, 0.55, 0.55)
		if kind == "spark":
			var mat := CanvasItemMaterial.new()
			mat.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED   # 어두워도 보이는 반짝임
			s.material = mat
		_marker_root.add_child(s)
		var t: Dictionary = VisualData.tiles()[key]
		markers[str(o.object_id)] = {"sprite": s, "kind": kind, "key": key,
			"frames": maxi(1, int(t.get("frames", 1) if t.get("frames") != null else 1)), "fps": float(t.get("fps", 6.0) if t.get("fps") != null else 6.0)}
		if kind == "window" and windows.has(str(o.object_id)):
			set_curtain(str(o.object_id), windows[str(o.object_id)].curtain)   # 그림·유리 밝기 (_apply_windows)


## 조사를 마친 곳은 반짝이를 숨김
func set_spot_done(object_id: String, done: bool) -> void:
	if markers.has(object_id):
		markers[object_id].sprite.visible = not done


func _process(delta: float) -> void:
	_anim_t += delta
	for id in markers:
		var m: Dictionary = markers[id]
		if m.frames > 1 and m.sprite.visible:
			var fr := VisualData.tile_frame(m.key, int(_anim_t * m.fps) % m.frames)
			if not fr.is_empty():
				m.sprite.texture.region = fr[1]


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


## 에디터: 전경 가림 보이기·숨기기 / 미리보기 투명도 (맵 데이터와 게임 출력에는 영향 없음)
func set_overhead_visible(v: bool) -> void:
	overhead.visible = v


func set_overhead_alpha(a: float) -> void:
	overhead_alpha = clampf(a, 0.0, 1.0)
	overhead.modulate.a = overhead_alpha


## 에디터 '전경만 보기': 전경 가림 말고 다른 그림(바닥·벽·지붕·오브젝트·표시 그림)을 숨김
func set_overhead_only(on: bool) -> void:
	for l in layers:
		layers[l].visible = not on
	_roof_root.visible = not on
	props_root.visible = not on
	_marker_root.visible = not on
	_bg.visible = not on


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
func _build_occluders(cells: Dictionary, h: int, w: int, thin: Dictionary = {}) -> void:
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
		x = 0
		while x < w:   # 벽 앞면 맨 위의 얇은 선 (가로로 이어 붙임)
			if not thin.has(Vector2i(x, y)):
				x += 1
				continue
			var t0 := x
			while x < w and thin.has(Vector2i(x, y)):
				x += 1
			_occ_root.add_child(_occluder(Rect2(t0 * tile, y * tile, (x - t0) * tile, tile * 0.1)))
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
	if markers.has(object_id) and markers[object_id].kind == "door":   # 문 그림: 열림 = key_open (없으면 같은 그림)
		var m: Dictionary = markers[object_id]
		var key: String = m.key + "_open" if open and VisualData.tiles().has(m.key + "_open") else m.key
		var fr := VisualData.tile_frame(key, 0)
		if not fr.is_empty():
			m.sprite.texture.region = fr[1]
	if doors.has(object_id):
		doors[object_id].visible = not open


## 커튼 치기(closed = true)·걷기: 그림 = key_curtain, 햇빛 꺼짐
func set_curtain(object_id: String, closed: bool) -> void:
	if windows.has(object_id):
		windows[object_id].curtain = closed
	if markers.has(object_id) and markers[object_id].has("view"):
		markers[object_id].view.curtain = closed
	elif markers.has(object_id) and markers[object_id].kind == "window":
		var m: Dictionary = markers[object_id]
		var key: String = m.key + "_curtain" if closed and VisualData.tiles().has(m.key + "_curtain") else m.key
		var fr := VisualData.tile_frame(key, 0)
		if not fr.is_empty():
			m.sprite.texture.region = fr[1]
	_apply_windows()


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
		if VisualData.light_on_wall(map, o):   # 벽걸이등: 벽 속은 그림자에 갇히므로 그 벽 앞 바닥 가장자리에서 비춤
			var wl := VisualData.window_light(map, {"x": o.x, "y": o.y})
			if wl.dir != Vector2i.ZERO:
				p.position = (wl.origin + Vector2(wl.dir) * 0.06) * tile
		p.set_meta("object_id", o.get("object_id", ""))
		_light_root.add_child(p)
		lights.append(p)
	# 창문 햇빛: 창문 칸의 바닥 쪽 가장자리에서 안으로 퍼지는 부채꼴
	var old := windows
	windows = {}
	for o in map.get("objects", []):
		if o.get("type", "") != "window":
			continue
		var wl := VisualData.window_light(map, o)
		var d: Vector2i = wl.dir
		if d == Vector2i.ZERO:
			continue
		var p := PointLight2D.new()
		p.texture = window_texture()
		p.texture_scale = float(VisualData.data().get("window_light_radius", 6)) * tile * 2.0 / LIGHT_TEX_SIZE
		p.texture_scale *= sqrt(float(maxi(1, int(o.get("w", 1)) if d.y != 0 else int(o.get("h", 1)))))   # 넓은 창문은 조금 더 멀리
		p.shadow_enabled = true
		p.shadow_filter = Light2D.SHADOW_FILTER_PCF13   # 창문 빛은 부드러운 그림자 (등불처럼 딱딱하면 무대 조명 같음)
		p.shadow_filter_smooth = 6.0
		p.position = (wl.origin + Vector2(d) * 0.04) * tile   # 바닥 가장자리 바로 안쪽 (벽 그림자에 묻히지 않게)
		p.rotation = Vector2(d).angle()
		p.set_meta("object_id", o.get("object_id", ""))
		_light_root.add_child(p)
		var oid := str(o.get("object_id", ""))
		# 실외 맵의 창문 = 건물 바깥: 햇빛을 내보내지 않음. 안쪽 맵에 불이 켜져 있으면 따뜻한 불빛 (밤에 잘 보임)
		var outside := profile() == "outdoor"
		windows[oid] = {"light": p, "curtain": old[oid].curtain if old.has(oid) else bool(o.get("curtain", false)),
			"outside": outside, "lit": outside and VisualData.inside_lit(map, o, world_maps)}
	_apply_lighting()


## 창문 빛 그림: 창문(가운데)에서 방 안(오른쪽)으로 은은하게 번지는 빛 — 테두리 없이 넓게, 멀수록 부드럽게 사라짐.
## 최대 밝기도 낮게 (WINDOW_PEAK) — 방 전체 분위기를 해치지 않는 '창가가 조금 밝은' 정도
const WINDOW_PEAK := 0.6
static func window_texture() -> Texture2D:
	if _window_tex == null:
		var n := LIGHT_TEX_SIZE
		var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
		var c := Vector2(n, n) / 2.0
		for y in n:
			for x in n:
				var v := (Vector2(x, y) - c) / (n / 2.0)
				var d := Vector2(v.x, v.y * 1.15).length()                 # 벽을 따라 조금 더 넓게
				var ang := absf(v.angle())
				var side := 1.0 - smoothstep(deg_to_rad(35.0), deg_to_rad(105.0), ang)   # 옆으로 갈수록 서서히
				var fall := pow(1.0 - smoothstep(0.0, 1.0, d), 1.6)       # 멀수록 서서히 (끝이 딱 끊기지 않게)
				# 창문 쪽(뒤)으로도 가까운 곳은 은은하게 — 창 아래 벽면과 창 앞에 선 캐릭터 윗몸 (벽 앞면은 빛을 받는 면)
				var back := 0.8 * pow(1.0 - smoothstep(0.0, 0.32, Vector2(v.x * 0.8, v.y).length()), 1.3)
				img.set_pixel(x, y, Color(1, 1, 1, WINDOW_PEAK * maxf(side * fall, back)))
		_window_tex = ImageTexture.create_from_image(img)
	return _window_tex


## 창문 햇빛 밝기: 실외 시간대 × Config window_light_energy, 커튼을 치면 꺼짐
func _apply_windows() -> void:
	var dl := VisualData.daylight(minutes)
	var e := float(VisualData.data().get("window_light_energy", 1.2)) * float(dl.k)
	for id in windows:
		var w: Dictionary = windows[id]
		if w.get("outside", false):   # 바깥 창문: 불 켜진 집만 따뜻한 빛, 낮엔 거의 안 보이고 밤에 또렷
			var le := float(VisualData.data().get("window_light_energy", 1.2)) * 0.7 * (1.0 - 0.85 * float(dl.k))
			w.light.color = LAMP_GLOW
			w.light.energy = le
			w.light.enabled = w.lit and not w.curtain and le > 0.01
		else:
			w.light.color = dl.color
			w.light.energy = e
			w.light.enabled = not w.curtain and e > 0.01
		if markers.has(id) and markers[id].has("view"):   # 기본 창문 그림: 유리 밝기·커튼·불 켜짐
			var wv = markers[id].view
			wv.daylight = float(dl.k)
			wv.curtain = w.curtain
			wv.lamp = w.get("lit", false)
			wv.refresh()
		elif markers.has(id):   # 창문 유리: 낮에는 바깥 빛으로 밝게 (주변광과 상관없이), 밤·커튼이면 방과 같이 어둡게
			var sp: Sprite2D = markers[id].sprite
			if w.get("lit", false) and not w.curtain:   # 불 켜진 창
				if sp.material == null:
					var lm := CanvasItemMaterial.new()
					lm.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED
					sp.material = lm
				sp.modulate = LAMP_GLOW
			elif w.curtain or float(dl.k) < 0.05:
				sp.material = null
				sp.modulate = Color.WHITE
			else:
				if sp.material == null:
					var mat := CanvasItemMaterial.new()
					mat.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED
					sp.material = mat
				var g := lerpf(0.45, 0.95, float(dl.k))
				sp.modulate = Color(g, g, g * 0.97)


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
	_apply_windows()
