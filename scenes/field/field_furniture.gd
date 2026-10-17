extends Node2D
## 기타 가구 (맵 물체 type=furniture): 그림 대신 색 사각형 + 표시 메모. 위치 = 왼쪽 아래 모서리(발 → Y 정렬), 사각형은 위로.

var size_px := Vector2(80, 80)
var color := Color.WHITE
var label := ""


func _draw() -> void:
	var r := Rect2(Vector2(0, -size_px.y), size_px)
	draw_rect(r, color)
	draw_rect(r, color.darkened(0.45), false, 3.0)
	if label == "":
		return
	var font := ThemeDB.fallback_font
	var ink := Color(0.08, 0.08, 0.1) if color.get_luminance() > 0.5 else Color(0.95, 0.95, 0.95)
	var room := r.size.x - 8
	var fs := 20   # 한 줄에 들어가게 글자를 줄이고 (14까지), 그래도 길면 여러 줄로
	while fs > 14 and font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > room:
		fs -= 1
	if font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x <= room:
		draw_string(font, Vector2(r.position.x + 4, r.get_center().y + fs * 0.35), label, HORIZONTAL_ALIGNMENT_CENTER, room, fs, ink)
		return
	var h := font.get_multiline_string_size(label, HORIZONTAL_ALIGNMENT_CENTER, room, fs).y
	draw_multiline_string(font, Vector2(r.position.x + 4, r.get_center().y - h / 2.0 + font.get_ascent(fs)), label,
		HORIZONTAL_ALIGNMENT_CENTER, room, fs, -1, ink)
