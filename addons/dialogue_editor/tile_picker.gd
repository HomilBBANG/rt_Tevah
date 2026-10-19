@tool
extends Window
## 연출 카드의 칸 x·y 를 맵을 보며 고르는 창 (걷게 하기·카메라의 목표·시작 위치).
## 게임과 같은 렌더러(core/map_renderer.gd)로 맵을 그리고, 마우스를 올린 칸 + 그 칸을 노리는 카메라 화면 테두리
## (게임 화면 1920×1080 ÷ 확대 배율, 맵 끝 안으로 맞춤 — 게임의 _clamp_cam 과 같음, 위아래 띠 자리 표시)를 보여 준다.
## 누르면 그 칸을 picked 로 알리고 닫힘. 휠 = 확대·축소, 가운데·오른쪽 끌기 = 이동.

signal picked(cell: Vector2i)

const MapRenderer = preload("res://core/map_renderer.gd")
const MAP_DIR := "res://tools/maps/"
const SCREEN := Vector2(1920, 1080)
const BAR := 0.106

var map_id := ""
var current := Vector2i(-1, -1)      # 지금 값 (표시)
var other := Vector2i(-1, -1)        # 같은 단계의 다른 칸 (시작 위치 ↔ 목표, 화살표로 표시)
var zoom_px := 5                     # 이 단계에서의 카메라 도트 배율 (화면 테두리 크기)
var base_px := 5
var tile := 80.0
var show_frame := true

var _map := {}
var _renderer: Node2D
var _vp: SubViewport
var _overlay: Control
var _maps: OptionButton
var _info: Label
var _scale := 0.25
var _pan := Vector2.ZERO
var _hover := Vector2i(-1, -1)
var _drag := false


func _ready() -> void:
	title = "맵에서 칸 고르기"
	size = Vector2i(1280, 820)
	close_requested.connect(queue_free)
	var cfg = _read("res://data/config.json", {})
	tile = float(cfg.get("field_tile", 80)) if cfg is Dictionary else 80.0
	base_px = maxi(1, roundi(tile / float(cfg.get("tile_art_px", 16)))) if cfg is Dictionary else 5
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root)
	var bar := HBoxContainer.new()
	root.add_child(bar)
	var l := Label.new()
	l.text = "맵"
	bar.add_child(l)
	_maps = OptionButton.new()
	_maps.custom_minimum_size.x = 260
	var ids := []
	for f in DirAccess.get_files_at(MAP_DIR):
		if f.ends_with(".json"):
			ids.append(f.get_basename())
	ids.sort()
	for id in ids:
		_maps.add_item(id)
		if id == map_id:
			_maps.select(_maps.item_count - 1)
	_maps.item_selected.connect(func(i): _open(_maps.get_item_text(i)))
	bar.add_child(_maps)
	var fr := CheckBox.new()
	fr.text = "카메라 화면 테두리"
	fr.tooltip_text = "그 칸을 카메라가 노리면 화면에 보이는 범위 (지금 확대 배율, 맵 끝 안으로 맞춤). 위아래 어두운 곳 = 연출 중 띠"
	fr.button_pressed = show_frame
	fr.toggled.connect(func(on):
		show_frame = on
		_overlay.queue_redraw())
	bar.add_child(fr)
	var zl := Label.new()
	zl.text = "배율"
	bar.add_child(zl)
	var zo := OptionButton.new()
	for z in [3, 4, 5, 6, 7, 8, 10, 12]:
		zo.add_item("×%d%s" % [z, " (기본)" if z == base_px else ""])
		zo.set_item_metadata(zo.item_count - 1, z)
		if z == zoom_px:
			zo.select(zo.item_count - 1)
	zo.tooltip_text = "카메라 화면 테두리의 확대 배율 (이 단계 전에 '확대·축소'가 있으면 그 배율로 열림)"
	zo.item_selected.connect(func(i):
		zoom_px = int(zo.get_item_metadata(i))
		_overlay.queue_redraw())
	bar.add_child(zo)
	_info = Label.new()
	_info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	bar.add_child(_info)
	var stage := Control.new()
	stage.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stage.clip_contents = true
	root.add_child(stage)
	var view := SubViewportContainer.new()
	view.stretch = true
	view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	stage.add_child(view)
	_vp = SubViewport.new()
	_vp.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	view.add_child(_vp)
	var bg := ColorRect.new()
	bg.color = Color.BLACK
	bg.size = Vector2(1e5, 1e5)
	bg.position = Vector2(-5e4, -5e4)
	_vp.add_child(bg)
	_renderer = MapRenderer.new()
	_renderer.roof_alpha = 0.55
	_vp.add_child(_renderer)
	_overlay = Control.new()
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.draw.connect(_draw_overlay)
	_overlay.gui_input.connect(_on_input)
	stage.add_child(_overlay)
	var hint := Label.new()
	hint.text = "누르면 그 칸으로 · 휠 = 확대·축소 · 가운데/오른쪽 끌기 = 이동 · Esc = 닫기"
	hint.modulate = Color(1, 1, 1, 0.6)
	root.add_child(hint)
	if map_id == "" and _maps.item_count > 0:
		map_id = _maps.get_item_text(0)
	_open.call_deferred(map_id)


func _open(id: String) -> void:
	map_id = id
	_map = _read(MAP_DIR + id + ".json", {})
	if not _map is Dictionary or _map.is_empty():
		_info.text = "맵을 읽을 수 없음: " + id
		return
	_renderer.minutes = 12 * 60.0
	_renderer.build(_map, tile)
	# 처음엔 지금 값(없으면 맵 가운데)이 가운데 오게, 맵 전체가 대략 보이는 크기로
	var msize := Vector2(String(_map.tiles[0]).length(), _map.tiles.size()) * tile
	var area: Vector2 = _overlay.size if _overlay.size.x > 10 else Vector2(1200, 700)
	_scale = clampf(minf(area.x / msize.x, area.y / msize.y) * 0.95, 0.05, 2.0)
	var focus := (Vector2(current) + Vector2(0.5, 0.5)) * tile if current.x >= 0 else msize / 2.0
	_pan = area / 2.0 - focus * _scale
	_apply()


func _apply() -> void:
	_renderer.scale = Vector2(_scale, _scale)
	_renderer.position = _pan
	_overlay.queue_redraw()


func _cell_at(p: Vector2) -> Vector2i:
	var w := (p - _pan) / _scale / tile
	return Vector2i(floori(w.x), floori(w.y))


func _in_map(c: Vector2i) -> bool:
	return not _map.is_empty() and c.y >= 0 and c.y < _map.tiles.size() and c.x >= 0 and c.x < String(_map.tiles[c.y]).length()


func _on_input(ev: InputEvent) -> void:
	if ev is InputEventMouseMotion:
		if _drag:
			_pan += ev.relative
			_apply()
		var c := _cell_at(ev.position)
		if c != _hover:
			_hover = c
			_info.text = ("칸 x %d · y %d" % [c.x, c.y]) if _in_map(c) else ""
			_overlay.queue_redraw()
	elif ev is InputEventMouseButton:
		if ev.button_index in [MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT]:
			_drag = ev.pressed
		elif ev.pressed and ev.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			var k := 1.15 if ev.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.15
			var ns := clampf(_scale * k, 0.03, 3.0)
			_pan = ev.position - (ev.position - _pan) * (ns / _scale)
			_scale = ns
			_apply()
		elif ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			var c := _cell_at(ev.position)
			if _in_map(c):
				picked.emit(c)
				queue_free()


func _unhandled_input(ev: InputEvent) -> void:
	if ev.is_action_pressed("ui_cancel"):
		queue_free()


## 칸 c 를 카메라가 노릴 때 보이는 화면 (게임처럼 맵 끝 안으로) — 맵 좌표 px
func camera_rect(c: Vector2i) -> Rect2:
	var view := SCREEN * float(base_px) / float(zoom_px)
	var msize := Vector2(String(_map.tiles[0]).length(), _map.tiles.size()) * tile
	var center := (Vector2(c) + Vector2(0.5, 0.5)) * tile
	var half := view / 2.0
	center.x = clampf(center.x, half.x, msize.x - half.x) if msize.x >= view.x else msize.x / 2.0
	center.y = clampf(center.y, half.y, msize.y - half.y) if msize.y >= view.y else msize.y / 2.0
	return Rect2(center - half, view)


func _draw_overlay() -> void:
	if _map.is_empty():
		return
	var s := tile * _scale
	var to_screen := func(r: Rect2) -> Rect2: return Rect2(_pan + r.position * _scale, r.size * _scale)
	var aim := _hover if _in_map(_hover) else current
	if show_frame and _in_map(aim):
		var r: Rect2 = to_screen.call(camera_rect(aim))
		_overlay.draw_rect(Rect2(r.position, Vector2(r.size.x, r.size.y * BAR)), Color(0, 0, 0, 0.45))
		_overlay.draw_rect(Rect2(r.position + Vector2(0, r.size.y * (1.0 - BAR)), Vector2(r.size.x, r.size.y * BAR)), Color(0, 0, 0, 0.45))
		_overlay.draw_rect(r, Color(1, 0.85, 0.3, 0.9), false, 2.0)
	if _in_map(other):
		var o := _pan + (Vector2(other) + Vector2(0.5, 0.5)) * s
		_overlay.draw_circle(o, maxf(4.0, s * 0.3), Color(0.5, 0.75, 1.0, 0.8))
		if _in_map(aim):
			_overlay.draw_line(o, _pan + (Vector2(aim) + Vector2(0.5, 0.5)) * s, Color(0.5, 0.75, 1.0, 0.8), 2.0)
	if _in_map(current):
		_overlay.draw_rect(Rect2(_pan + Vector2(current) * s, Vector2(s, s)), Color(0.4, 1.0, 0.5, 0.9), false, 3.0)
	if _in_map(_hover):
		_overlay.draw_rect(Rect2(_pan + Vector2(_hover) * s, Vector2(s, s)), Color(1, 1, 1, 0.35))
		_overlay.draw_rect(Rect2(_pan + Vector2(_hover) * s, Vector2(s, s)), Color.WHITE, false, 2.0)


static func _read(path: String, fallback: Variant) -> Variant:
	if not FileAccess.file_exists(path):
		return fallback
	var v = JSON.parse_string(FileAccess.get_file_as_string(path))
	return v if v != null else fallback
