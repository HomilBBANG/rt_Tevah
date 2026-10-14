extends Control
## 능력치 육각형 그래프. 꼭짓점마다 능력치 이름과 값, 안쪽 다각형이 값 / max_value.
## values: [[이름, 값], ...] (6개가 아니어도 그 수만큼 각을 나눈다). 첫 항목이 맨 위, 시계 방향.

var values: Array = []
var max_value := 10.0
var _font: Font


func _init() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	_font = ThemeDB.fallback_font


func set_values(v: Array, mx: float) -> void:
	values = v
	max_value = maxf(1.0, mx)
	queue_redraw()


func _corner(i: int, r: float) -> Vector2:
	var a := -PI / 2.0 + TAU * i / values.size()
	return size / 2.0 + Vector2(cos(a), sin(a)) * r


func _draw() -> void:
	var n := values.size()
	if n < 3:
		return
	var radius := minf(size.x, size.y) / 2.0 - 70.0
	# 바탕 고리 (25 · 50 · 75 · 100%)
	for k in [0.25, 0.5, 0.75, 1.0]:
		var ring := PackedVector2Array()
		for i in n + 1:
			ring.append(_corner(i % n, radius * k))
		draw_polyline(ring, Color(1, 1, 1, 0.35 if k == 1.0 else 0.15), 2.0 if k == 1.0 else 1.0, true)
	for i in n:
		draw_line(size / 2.0, _corner(i, radius), Color(1, 1, 1, 0.15), 1.0, true)
	# 값
	var poly := PackedVector2Array()
	for i in n:
		poly.append(_corner(i, radius * clampf(float(values[i][1]) / max_value, 0.0, 1.0)))
	draw_colored_polygon(poly, Color(0.85, 0.3, 0.3, 0.45))
	poly.append(poly[0])
	draw_polyline(poly, Color("ff7a6a"), 3.0, true)
	# 이름 · 값
	for i in n:
		var p := _corner(i, radius + 38.0)
		var label := String(values[i][0])
		var num := str(values[i][1])
		var fs := 24
		var w := _font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string(_font, p + Vector2(-w / 2.0, -2), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color("dddddd"))
		var w2 := _font.get_string_size(num, HORIZONTAL_ALIGNMENT_LEFT, -1, 26).x
		draw_string(_font, p + Vector2(-w2 / 2.0, 26), num, HORIZONTAL_ALIGNMENT_LEFT, -1, 26, Color("ffb070"))
