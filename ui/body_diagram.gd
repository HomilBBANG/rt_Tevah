extends Control
## 신체 부위 도식 (아트 전 placeholder). 부위마다 상자 + 이름 + HP.
## 화면 왼쪽 = 왼팔·왼다리 (회피 키 A 와 같은 쪽). 알 수 없는 부위 id 는 아래 줄에 나열.
## selectable 이면 부위를 클릭해 part_clicked 를 보낸다 (파괴된 부위 제외).

signal part_clicked(part_id: String)

## 알려진 부위의 자리 (도식 크기 대비 비율: x, y, w, h)
const LAYOUT := {
	"head": Rect2(0.38, 0.0, 0.24, 0.17),
	"torso": Rect2(0.33, 0.2, 0.34, 0.36),
	"left_arm": Rect2(0.08, 0.2, 0.22, 0.34),
	"right_arm": Rect2(0.70, 0.2, 0.22, 0.34),
	"left_leg": Rect2(0.33, 0.6, 0.16, 0.3),
	"right_leg": Rect2(0.51, 0.6, 0.16, 0.3),
}
const HIGHLIGHT := Color("ff9a3c")
## figure 모드(전투 화면 '내 상태'): 사람 모양. 좌표는 175 x 340 단위 (머리는 원)
const FIGURE_SIZE := Vector2(175, 340)
const FIGURE := {
	"head": Rect2(45, 0, 85, 85),
	"torso": Rect2(45, 87, 85, 125),
	"left_arm": Rect2(0, 87, 45, 125),
	"right_arm": Rect2(130, 87, 45, 125),
	"left_leg": Rect2(45, 212, 42.5, 128),
	"right_leg": Rect2(87.5, 212, 42.5, 128),
}

var parts := {}               # part_id -> { name, hp, max_hp, broken, (hit_chance) }
var order: Array = []
var figure := false           # true = 사람 모양 (부위 안에 HP 숫자만)
var selectable := false
var show_hit_chance := false
var highlight := ""           # 전조로 강조할 부위
var _hover := ""
var _font: Font


func _init() -> void:
	mouse_filter = MOUSE_FILTER_STOP
	_font = ThemeDB.fallback_font


func refresh() -> void:
	queue_redraw()


func set_highlight(part_id: String) -> void:
	if part_id != highlight:
		highlight = part_id
		queue_redraw()


func part_rect(part_id: String) -> Rect2:
	if figure and FIGURE.has(part_id):
		var k := minf(size.x / FIGURE_SIZE.x, size.y / FIGURE_SIZE.y)
		var origin := (size - FIGURE_SIZE * k) / 2.0
		return Rect2(origin + FIGURE[part_id].position * k, FIGURE[part_id].size * k)
	var r: Rect2
	if LAYOUT.has(part_id):
		r = LAYOUT[part_id]
	else:
		var extras := order.filter(func(p): return not LAYOUT.has(p))
		var i := extras.find(part_id)
		var w := 1.0 / maxi(1, extras.size())
		r = Rect2(i * w + 0.01, 0.92, w - 0.02, 0.08)
	return Rect2(r.position * size, r.size * size)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var h := _part_at(event.position) if selectable else ""
		if h != _hover:
			_hover = h
			queue_redraw()
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT and selectable:
		var p := _part_at(event.position)
		if p != "":
			part_clicked.emit(p)


func _part_at(pos: Vector2) -> String:
	for id in order:
		if not parts[id].broken and part_rect(id).has_point(pos):
			return id
	return ""


func _draw() -> void:
	if figure:
		_draw_figure()
		return
	for id in order:
		var p: Dictionary = parts[id]
		var r := part_rect(id)
		var ratio := float(p.hp) / maxf(1.0, p.max_hp)
		var fill := Color(0.12, 0.12, 0.13) if p.broken else Color(0.32, 0.30, 0.30).lerp(Color(0.55, 0.16, 0.16), 1.0 - ratio)
		var sb := StyleBoxFlat.new()
		sb.bg_color = fill
		sb.set_corner_radius_all(10)
		sb.set_border_width_all(2)
		sb.border_color = Color("777777")
		if id == highlight:
			sb.set_border_width_all(7)
			sb.border_color = HIGHLIGHT
		elif id == _hover:
			sb.set_border_width_all(5)
			sb.border_color = Color.WHITE
		elif selectable and not p.broken:
			sb.border_color = Color("cccccc")
		draw_style_box(sb, r)
		var lines := [p.name, "절단" if p.broken and not p.get("vital", false) else ("파괴" if p.broken else "%d/%d" % [p.hp, p.max_hp])]
		if show_hit_chance and not p.broken:
			lines.append("명중 %d%%" % roundi(p.hit_chance))
		var fs := 25
		var y := r.get_center().y - (lines.size() * (fs + 3)) / 2.0 + fs
		for line in lines:
			var tw := _font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			draw_string(_font, Vector2(r.get_center().x - tw / 2.0, y), line, HORIZONTAL_ALIGNMENT_LEFT, -1, fs,
				Color("777777") if p.broken else Color.WHITE)
			y += fs + 3
		if p.broken:
			draw_line(r.position + Vector2(10, 10), r.end - Vector2(10, 10), Color("884444"), 3)


## 사람 모양: 밝은 회색 → 다칠수록 붉게, 파괴·절단은 어둡게 + X. 부위 안에 HP (절단·파괴는 글자)
func _draw_figure() -> void:
	for id in order:
		var p: Dictionary = parts[id]
		var r := part_rect(id)
		var ratio := float(p.hp) / maxf(1.0, p.max_hp)
		var fill := Color(0.16, 0.16, 0.17) if p.broken else Color("c3c3c3").lerp(Color("b02a2a"), 1.0 - ratio)
		var border := Color("0e2433")
		var bw := 3.0
		if id == highlight:
			border = HIGHLIGHT
			bw = 7.0
		if id == "head":
			var c := r.get_center()
			var rad := minf(r.size.x, r.size.y) / 2.0
			draw_circle(c, rad, fill)
			draw_arc(c, rad, 0, TAU, 48, border, bw, true)
		else:
			draw_rect(r, fill)
			draw_rect(r.grow(-bw / 2.0), border, false, bw)
		var text := ("절단" if not p.get("vital", false) else "파괴") if p.broken else "%d/%d" % [p.hp, p.max_hp]
		var fs := 16
		var tw := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		while tw > r.size.x - 6 and fs > 11:   # 좁은 팔·다리 칸에 맞게 줄임
			fs -= 1
			tw = _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var pos := Vector2(r.get_center().x - tw / 2.0, r.get_center().y + fs / 3.0)
		draw_string(_font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color("999999") if p.broken else Color("111111"))
		if p.broken:
			draw_line(r.position + Vector2(6, 6), r.end - Vector2(6, 6), Color("884444"), 3)
			draw_line(Vector2(r.end.x - 6, r.position.y + 6), Vector2(r.position.x + 6, r.end.y - 6), Color("884444"), 3)