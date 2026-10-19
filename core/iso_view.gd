extends Node2D
## 쿼터뷰(아이소메트릭) 화면 — Config view_mode = "iso". 게임 규칙(충돌·길 찾기·AI·맵 파일)은 네모 격자 그대로 두고,
## 필드의 네모 세계(%World·렌더러)는 숨긴 채 여기서 마름모 화면으로 다시 그린다 (1차, 2026-10-19).
##   좌표: 네모 세계 점 p(px) → 화면 iso(p) = (p.x - p.y, (p.x + p.y) / 2). 한 칸 = 폭 2×tile, 높이 tile 의 마름모.
##   바닥: 렌더러의 바닥·장식 층을 같은 그림으로 복사해 변환(마름모로 기울임) — 지금 16×16 그림을 자동 변환한 모습.
##   벽: 칸마다 위로 솟은 블록 (윗면 = 벽 타일, 앞의 두 면 = 앞면 타일, 오른쪽 면은 더 어둡게). 높이 Config iso_wall_height.
##       바닥과 닿은 벽은 대각선 줄마다 한 노드로 인물과 앞뒤 정렬(Y 정렬), 벽에 둘러싸인 벽은 윗면만 한 층으로.
##   인물·물체: 플레이어 그림(네모 세계에서 옮겨 옴)·NPC·적·나무·가구·문·반짝이·텐트를 iso 자리에, Y 정렬.
##   조명: 렌더러의 환경광(CanvasModulate)은 그대로, 광원은 iso 자리에 복사 (그림자는 2차).
##   이동: 화면 기준 (W = 화면 위) — field_player 가 logic_dir 로 바꿈. 카메라는 플레이어 그림을 따라감.
## 2차(아직): 지붕·전경 가림·창문·벽에 맞춘 문·빛 그림자·조사/통로 표시 도형·몬스터 시야 표시.

const VisualData = preload("res://core/visual_data.gd")

var field: Node
var map := {}
var tile := 80.0
var wall_h := 120.0
var floors: Node2D          # 바닥 (변환된 TileMapLayer 들)
var tops: Node2D            # 벽에 둘러싸인 벽의 윗면 (변환, 위로 올림)
var sorted: Node2D          # Y 정렬: 바닥과 닿은 벽 줄 + 인물·물체
var lights_root: Node2D
var player_proxy: Node2D
var camera: Camera2D
var _proxies: Array = []    # [{src, node}] — 네모 세계 노드를 따라다님
var _lights := {}           # 렌더러 광원 → 복사본


static func iso(p: Vector2) -> Vector2:
	return Vector2(p.x - p.y, (p.x + p.y) * 0.5)


## 화면 방향 → 네모 세계 방향 (iso 의 역변환)
static func logic_dir(s: Vector2) -> Vector2:
	return Vector2(0.5 * s.x + s.y, -0.5 * s.x + s.y)


func build(p_field: Node) -> void:
	field = p_field
	map = field.map
	tile = field.tile
	wall_h = float(DataLoader.config.get("iso_wall_height", 120))
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_proxies = []
	_lights = {}
	var bg := ColorRect.new()   # 맵 바깥 검게
	bg.color = Color.BLACK
	bg.position = Vector2(-20000, -20000)
	bg.size = Vector2(40000, 40000)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.z_index = -30
	add_child(bg)
	var xf := Transform2D(Vector2(1, 0.5), Vector2(-1, 0.5), Vector2.ZERO)
	floors = Node2D.new()
	floors.name = "IsoFloors"
	floors.transform = xf
	floors.z_index = -20
	add_child(floors)
	var r = field.renderer
	for l in ["floor", "detail"]:
		floors.add_child(_copy_layer(r.layers[l]))
	tops = Node2D.new()
	tops.name = "IsoWallTops"
	tops.z_index = -10
	tops.position = Vector2(0, -wall_h)
	add_child(tops)
	sorted = Node2D.new()
	sorted.name = "IsoSorted"
	sorted.y_sort_enabled = true
	add_child(sorted)
	lights_root = Node2D.new()
	lights_root.name = "IsoLights"
	add_child(lights_root)
	_build_walls(r)
	_build_actors(r)


func _copy_layer(src: TileMapLayer) -> TileMapLayer:
	var t := TileMapLayer.new()
	t.tile_set = src.tile_set
	t.scale = src.scale
	t.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	for c in src.get_used_cells():
		t.set_cell(c, src.get_cell_source_id(c), src.get_cell_atlas_coords(c))
	return t


# ---------------------------------------------------------------- 벽 블록
func _is_wall(x: int, y: int) -> bool:
	var rows: Array = map.tiles
	return y >= 0 and y < rows.size() and x >= 0 and x < String(rows[y]).length() and String(rows[y])[x] == "#"


func _is_open(x: int, y: int) -> bool:   # 바닥 (빈 공간·맵 밖은 아님)
	var rows: Array = map.tiles
	return y >= 0 and y < rows.size() and x >= 0 and x < String(rows[y]).length() and String(rows[y])[x] == "."


func _build_walls(r) -> void:
	var top_layer := TileMapLayer.new()
	top_layer.tile_set = r.layers.wall.tile_set
	top_layer.scale = r.layers.wall.scale
	top_layer.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	var top_holder := Node2D.new()
	top_holder.transform = Transform2D(Vector2(1, 0.5), Vector2(-1, 0.5), Vector2.ZERO)
	top_holder.add_child(top_layer)
	tops.add_child(top_holder)
	var rows_by_diag := {}   # x+y → [칸] (바닥과 닿은 벽)
	var keys: Dictionary = r._keys
	for y in map.tiles.size():
		for x in String(map.tiles[y]).length():
			if not _is_wall(x, y):
				continue
			var wk := VisualData.wall_keys(map, x, y)
			var boundary := false
			for d in [Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1), Vector2i(-1, 0), Vector2i(1, 0), Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1)]:
				if _is_open(x + d.x, y + d.y):
					boundary = true
					break
			if boundary:
				rows_by_diag.get_or_add(x + y, []).append([Vector2i(x, y), wk])
			elif keys.has(wk.top):
				top_layer.set_cell(Vector2i(x, y), keys[wk.top][0], keys[wk.top][1])
	for d in rows_by_diag:
		var row := WallRow.new()
		row.view = self
		row.cells = rows_by_diag[d]
		row.position = Vector2(0, (d + 1) * tile * 0.5)   # 정렬 기준 = 칸 가운데 높이 (앞 칸 인물보다 먼저, 뒤 칸 인물보다 나중)
		sorted.add_child(row)


## 대각선(x+y 같은) 한 줄의 벽 블록들: 앞의 두 면(바닥 쪽으로 보이는 면만) + 윗면
class WallRow extends Node2D:
	const VD = preload("res://core/visual_data.gd")
	var view
	var cells := []

	func _draw() -> void:
		var t: float = view.tile
		var h: float = view.wall_h
		for item in cells:
			var c: Vector2i = item[0]
			var wk: Dictionary = item[1]
			var n: Vector2 = view.iso(Vector2(c.x, c.y) * t) - position
			var e: Vector2 = view.iso(Vector2(c.x + 1, c.y) * t) - position
			var s: Vector2 = view.iso(Vector2(c.x + 1, c.y + 1) * t) - position
			var w: Vector2 = view.iso(Vector2(c.x, c.y + 1) * t) - position
			var up := Vector2(0, -h)
			if not view._is_wall(c.x, c.y + 1):   # 왼쪽 앞면 (아래 칸 쪽)
				_quad([w + up, s + up, s, w], wk.face, Color(0.82, 0.82, 0.82))
			if not view._is_wall(c.x + 1, c.y):   # 오른쪽 앞면 (오른쪽 칸 쪽)
				_quad([s + up, e + up, e, s], wk.face, Color(0.62, 0.62, 0.66))
			_quad([n + up, e + up, s + up, w + up], wk.top, Color.WHITE)

	func _quad(pts: Array, key: String, col: Color) -> void:
		var fr := VD.tile_frame(key, 0)
		var poly := PackedVector2Array(pts)
		if fr.is_empty():
			draw_colored_polygon(poly, Color(0.18, 0.18, 0.2) * col)
			return
		var tex: Texture2D = fr[0]
		var rr: Rect2 = fr[1]
		rr.size.y = minf(rr.size.y, rr.size.x)
		var sz := Vector2(tex.get_width(), tex.get_height())
		var uv := PackedVector2Array([rr.position / sz, Vector2(rr.end.x, rr.position.y) / sz, rr.end / sz, Vector2(rr.position.x, rr.end.y) / sz])
		draw_polygon(poly, PackedColorArray([col, col, col, col]), uv, tex)


# ---------------------------------------------------------------- 인물·물체
func _build_actors(r) -> void:
	# 플레이어: 그림과 카메라를 옮겨 옴 (애니메이션은 field_player 가 그대로 바꿈)
	var p = field.player
	player_proxy = Node2D.new()
	player_proxy.name = "IsoPlayer"
	sorted.add_child(player_proxy)
	if p.sprite:
		p.sprite.reparent(player_proxy, false)
	camera = p.get_node_or_null("Camera2D")
	if camera:
		camera.reparent(player_proxy, false)
		camera.position = Vector2.ZERO
		var w := float(map.width) * tile
		var hh := float(map.height) * tile
		camera.limit_left = int(-hh)
		camera.limit_right = int(w)
		camera.limit_top = int(-wall_h - tile)
		camera.limit_bottom = int((w + hh) * 0.5 + tile)
		camera.reset_smoothing.call_deferred()
	_proxies.append({"src": p, "node": player_proxy})
	for n in field.npcs:
		_add_actor(n.node, Color("5a8fd0"), str(n.data.get("name", "")))
	for e in field.enemies:
		_add_actor(e, Color("c04848"), "")
	for f in field.furniture:
		var b := FurnitureBlock.new()
		b.view = self
		b.src = f
		b.position = iso(Vector2(int(f.data.x) + maxi(1, int(f.data.get("w", 1))), int(f.data.y) + maxi(1, int(f.data.get("h", 1)))) * tile) - Vector2(0, tile * 0.5)
		sorted.add_child(b)
		_proxies.append({"src": f.node, "node": b, "static": true})
	for sp in r.prop_sprites:   # 나무·가구 그림 (발 = 놓은 칸 아래)
		if not is_instance_valid(sp):
			continue
		var c := Sprite2D.new()
		c.texture = sp.texture
		c.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		c.centered = sp.centered
		c.offset = sp.offset
		c.scale = sp.scale
		c.position = iso(sp.position)
		sorted.add_child(c)
	var objs := {}
	for o in map.get("objects", []):
		objs[str(o.get("object_id", ""))] = o
	for id in r.markers:   # 문·반짝이·텐트·벽걸이등 (창문·벽에 맞춘 문 그림은 2차)
		var mk: Dictionary = r.markers[id]
		var m = mk.get("sprite")
		if m is Sprite2D and mk.kind == "lamp" and objs.has(id):   # 벽걸이등: 벽 블록의 바닥 쪽 앞면, 벽 높이 중간쯤
			var o: Dictionary = objs[id]
			var wl := VisualData.window_light(map, {"x": o.x, "y": o.y})
			var lc := Sprite2D.new()
			lc.texture = m.texture
			lc.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			lc.scale = m.scale
			lc.material = m.material
			lc.modulate = m.modulate
			lc.position = iso((Vector2(int(o.x), int(o.y)) + Vector2(0.5, 0.5) + Vector2(wl.dir) * 0.52) * tile)
			lc.offset = Vector2(0, -wall_h * 0.6 / maxf(0.01, m.scale.y))
			sorted.add_child(lc)
			continue
		if m is Sprite2D:
			var c := Sprite2D.new()
			c.texture = m.texture   # 같은 AtlasTexture — 문을 열면 같이 바뀜
			c.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			c.scale = m.scale
			c.material = m.material
			var reg: Rect2 = m.texture.region if m.texture is AtlasTexture else Rect2(0, 0, 16, 16)
			var hc := reg.size.y / maxf(1.0, reg.size.x)   # 키 큰 그림(2칸 문): 렌더러가 위로 올린 만큼 되돌려 칸 가운데 기준으로
			var base: Vector2 = m.position + Vector2(0, (hc - 1.0) * tile * 0.5)
			c.position = iso(base) - Vector2(0, (hc - 1.0) * tile * 0.5)
			_proxies.append({"src": m, "node": c, "static": true})
			sorted.add_child(c)


func _add_actor(src: Node2D, col: Color, nm: String) -> void:
	var a := ActorMark.new()
	a.src = src
	a.color = col
	a.label = nm
	a.radius = float(src.get("radius")) if src.get("radius") != null else tile * 0.3
	sorted.add_child(a)
	_proxies.append({"src": src, "node": a})


## NPC·적 (아트 전 도형): 바닥에 납작한 타원 + 바라보는 쪽 + 이름
class ActorMark extends Node2D:
	var src: Node2D
	var color := Color.WHITE
	var label := ""
	var radius := 24.0

	func _draw() -> void:
		var r := radius * 1.2
		var pts := PackedVector2Array()
		for i in 24:
			var a := TAU * i / 24.0
			pts.append(Vector2(cos(a) * r, sin(a) * r * 0.5 - r * 0.5))
		draw_colored_polygon(pts, color)
		pts.append(pts[0])
		draw_polyline(pts, color.darkened(0.6), 3.0)
		var f = src.get("facing")
		if f is Vector2 and f != Vector2.ZERO:
			var d: Vector2 = Vector2(f.x - f.y, (f.x + f.y) * 0.5).normalized()
			draw_line(Vector2(0, -r * 0.5), Vector2(0, -r * 0.5) + d * r, color.darkened(0.6), 4.0)
		if label != "":
			var font := ThemeDB.fallback_font
			var w := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 25).x
			draw_string_outline(font, Vector2(-w / 2.0, -r - 18), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 25, 8, Color.BLACK)
			draw_string(font, Vector2(-w / 2.0, -r - 18), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 25, Color("cfe0ff"))


## 기타 가구: 차지하는 칸만큼 블록 (윗면 색 + 앞의 두 면 어둡게) + 표시 메모
class FurnitureBlock extends Node2D:
	var view
	var src: Dictionary

	func _draw() -> void:
		var o: Dictionary = src.data
		var t: float = view.tile
		var w := maxi(1, int(o.get("w", 1)))
		var hh := maxi(1, int(o.get("h", 1)))
		var x := int(o.x)
		var y := int(o.y)
		var h: float = t * 0.6
		var col := Color.html(str(o.get("color", ""))) if Color.html_is_valid(str(o.get("color", ""))) else Color.WHITE
		var n: Vector2 = view.iso(Vector2(x, y) * t) - position
		var e: Vector2 = view.iso(Vector2(x + w, y) * t) - position
		var s: Vector2 = view.iso(Vector2(x + w, y + hh) * t) - position
		var ww: Vector2 = view.iso(Vector2(x, y + hh) * t) - position
		var up := Vector2(0, -h)
		draw_colored_polygon(PackedVector2Array([ww + up, s + up, s, ww]), col.darkened(0.2))
		draw_colored_polygon(PackedVector2Array([s + up, e + up, e, s]), col.darkened(0.38))
		draw_colored_polygon(PackedVector2Array([n + up, e + up, s + up, ww + up]), col)
		draw_polyline(PackedVector2Array([n + up, e + up, s + up, ww + up, n + up]), col.darkened(0.55), 2.0)
		var label := str(o.get("label", ""))
		if label != "":
			var font := ThemeDB.fallback_font
			var c := (n + s) / 2.0 + up
			var fs := 20
			var lw := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			var ink := Color(0.08, 0.08, 0.1) if col.get_luminance() > 0.5 else Color.WHITE
			draw_string(font, c + Vector2(-lw / 2.0, fs * 0.35), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, ink)


# ---------------------------------------------------------------- 매 프레임
func sync() -> void:
	var p = field.player
	if p and p.sprite and is_instance_valid(p.sprite) and p.sprite.get_parent() != player_proxy:   # 그림은 한 프레임 늦게 생김 (setup_sprite deferred)
		p.sprite.reparent(player_proxy, false)
	if field.enemies.size() > 0:   # 나중에 들어온 적 (다른 맵에서 쫓아온 몬스터)
		var have := {}
		for pr in _proxies:
			have[pr.src] = true
		for e in field.enemies:
			if is_instance_valid(e) and not have.has(e):
				_add_actor(e, Color("c04848"), "")
	for pr in _proxies:
		var src = pr.src
		var node: Node2D = pr.node
		if not is_instance_valid(src) or not is_instance_valid(node):
			if is_instance_valid(node):
				node.visible = false
			continue
		if not pr.get("static", false):
			node.position = iso(src.position)
			node.queue_redraw()
		node.visible = src.visible
	_sync_lights()


## 렌더러 광원(네모 세계)을 iso 자리에 복사 — 둥근 빛은 마름모 바닥에 맞게 납작한 타원 (그림자는 2차)
func _sync_lights() -> void:
	var r = field.renderer
	var srcs: Array = r._light_root.get_children()
	if field.held_light and is_instance_valid(field.held_light):
		srcs.append(field.held_light)
	var seen := {}
	for l in srcs:
		if not l is PointLight2D:
			continue
		seen[l] = true
		var m: PointLight2D = _lights.get(l)
		if m == null:
			m = PointLight2D.new()
			m.texture = l.texture
			m.shadow_enabled = false
			lights_root.add_child(m)
			_lights[l] = m
		m.color = l.color
		m.energy = l.energy
		m.enabled = l.enabled and r.lighting
		m.texture_scale = l.texture_scale
		m.position = iso(l.global_position - field.global_position)
		var dir := Vector2.RIGHT.rotated(l.global_rotation)
		m.rotation = Vector2(dir.x - dir.y, (dir.x + dir.y) * 0.5).angle()
		m.scale = Vector2(1.41, 0.71) if absf(sin(m.rotation)) < 0.3 else Vector2(1.06, 1.06)
	for l in _lights.keys():
		if not seen.has(l):
			_lights[l].queue_free()
			_lights.erase(l)
