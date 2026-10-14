extends Control
## 전투 화면 가운데 적 그림. Enemies.image(res:// 경로)가 있으면 그 그림을 비율 유지해 아래쪽에 맞춰 그리고,
## 없으면 실루엣 도형(아트 전 placeholder). flash() = 맞았을 때 잠깐 붉게.

var texture: Texture2D
var _flash := 0.0


func _init() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE


## path 가 비었거나 읽을 수 없으면 실루엣
func set_image(path: String) -> void:
	texture = null
	if path != "" and ResourceLoader.exists(path):
		texture = load(path) as Texture2D
	queue_redraw()


func flash() -> void:
	var tw := create_tween()
	tw.tween_method(func(v: float):
		_flash = v
		queue_redraw(), 1.0, 0.0, 0.35)


func _draw() -> void:
	var tint := Color.WHITE.lerp(Color(1.0, 0.35, 0.35), _flash)
	if texture != null:
		var ts := texture.get_size()
		var k := minf(size.x / ts.x, size.y / ts.y)
		var s := ts * k
		draw_texture_rect(texture, Rect2(Vector2((size.x - s.x) / 2.0, size.y - s.y), s), false, tint)
		return
	# 실루엣: 머리·몸통·팔·다리 (높이 기준 비율)
	var h := size.y
	var cx := size.x / 2.0
	var col := Color(0.09, 0.02, 0.02).lerp(Color(0.6, 0.1, 0.1), _flash)
	var edge := Color(0.42, 0.12, 0.12)
	var head_c := Vector2(cx, h * 0.1)
	var head_r := h * 0.075
	var shapes := [
		Rect2(cx - h * 0.11, h * 0.19, h * 0.22, h * 0.36),    # 몸통
		Rect2(cx - h * 0.17, h * 0.2, h * 0.055, h * 0.33),    # 왼팔
		Rect2(cx + h * 0.115, h * 0.2, h * 0.055, h * 0.33),   # 오른팔
		Rect2(cx - h * 0.1, h * 0.55, h * 0.09, h * 0.45),     # 왼다리
		Rect2(cx + h * 0.01, h * 0.55, h * 0.09, h * 0.45),    # 오른다리
	]
	for r in shapes:
		var sb := StyleBoxFlat.new()
		sb.bg_color = col
		sb.set_corner_radius_all(int(h * 0.02))
		sb.set_border_width_all(2)
		sb.border_color = edge
		draw_style_box(sb, r)
	draw_circle(head_c, head_r, col)
	draw_arc(head_c, head_r, 0, TAU, 48, edge, 2, true)
