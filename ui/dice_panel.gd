extends Control
## 주사위 판정 연출 (사용자 시안): 대화 화면 위 가운데에 겹쳐 뜬다. 뒤의 말풍선·초상화는 그대로 보인다.
##   위 "요구 N" (목표값) / 가운데 빨간 d20 (굴리는 동안 숫자가 바뀌고 흔들림 → 나온 눈) / 아래 "총 보정 +N" / 결과 줄
## play(result) 의 result 는 StoryRunner.dice_rolled 의 내용 (roll, mod, total, dc, success, critical, parts).

signal finished

const ROLL_TIME := 0.8
const SUCCESS_COLOR := Color("7fd48a")
const FAIL_COLOR := Color("ff6a6a")
const DIE_FILL := Color("c8102e")
const DIE_EDGE := Color.WHITE
const FACE_NUMBERS := ["2", "14", "8", "18", "4", "6"]   # 옆면 장식 숫자 (그림용)

var is_rolling := false

var _result := {}
var _t := 0.0
var _tick := 0.0
var _shown := 20               # 가운데 면에 보이는 숫자
var _need: Label
var _mod: Label
var _outcome: Label


func _init() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	_need = _label(42)
	_need.anchor_right = 1.0
	_need.offset_bottom = 60
	_mod = _label(40)
	_outcome = _label(36)
	resized.connect(_layout)


func play(result: Dictionary) -> void:
	_result = result
	_need.text = "요구 %d" % int(result.dc)
	_mod.text = "총 보정 %+d" % int(result.get("mod", 0))
	_outcome.text = ""
	_t = 0.0
	_tick = 0.0
	is_rolling = true
	_layout()
	queue_redraw()


## 굴리는 중이면 바로 결과로
func skip() -> void:
	if is_rolling:
		_t = ROLL_TIME


func _process(delta: float) -> void:
	if not is_rolling:
		return
	_t += delta
	_tick -= delta
	if _t >= ROLL_TIME:
		_show_result()
	elif _tick <= 0.0:
		_tick = 0.05
		_shown = randi_range(1, 20)
	queue_redraw()


func _show_result() -> void:
	is_rolling = false
	_shown = int(_result.roll)
	var verdict: String
	match _result.get("critical", ""):
		"success": verdict = "대성공!"
		"fail": verdict = "대실패!"
		_: verdict = "성공" if _result.success else "실패"
	_outcome.text = "%d %+d = %d   ·   %s" % [int(_result.roll), int(_result.get("mod", 0)), int(_result.total), verdict]
	_outcome.add_theme_color_override("font_color", SUCCESS_COLOR if _result.success else FAIL_COLOR)
	queue_redraw()
	finished.emit()


# ---------------------------------------------------------------- 그리기
func _radius() -> float:
	return clampf(minf(size.x, size.y) * 0.24, 40.0, 110.0)


func _die_center() -> Vector2:
	return Vector2(size.x / 2.0, 70.0 + _radius())


func _layout() -> void:
	var r := _radius()
	var below := _die_center().y + r + 10.0
	for pair in [[_mod, below], [_outcome, below + 56.0]]:
		var l: Label = pair[0]
		l.anchor_right = 1.0
		l.offset_top = pair[1]
		l.offset_bottom = pair[1] + 56.0


func _draw() -> void:
	var r := _radius()
	var wobble := sin(_t * 40.0) * 0.18 * (1.0 - _t / ROLL_TIME) if is_rolling else 0.0
	draw_set_transform(_die_center(), wobble, Vector2.ONE)
	# 바깥 육각형 (뾰족한 쪽이 위) — 정이십면체를 앞에서 본 모양
	var hexa := PackedVector2Array()
	for i in 6:
		var a := -PI / 2.0 + i * PI / 3.0
		hexa.append(Vector2(cos(a), sin(a)) * r)
	# 가운데 면 (위를 향한 삼각형)
	var ta := Vector2(0, -0.58) * r
	var tb := Vector2(-0.6, 0.42) * r
	var tc := Vector2(0.6, 0.42) * r
	draw_colored_polygon(hexa, DIE_FILL)
	draw_colored_polygon(PackedVector2Array([ta, tb, tc]), DIE_FILL.lightened(0.06))
	var w := maxf(2.0, r * 0.03)
	var closed := hexa.duplicate()
	closed.append(hexa[0])
	draw_polyline(closed, DIE_EDGE, w, true)
	draw_polyline(PackedVector2Array([ta, tb, tc, ta]), DIE_EDGE, w, true)
	# 가운데 삼각형 꼭짓점 → 육각형 꼭짓점 (면 나누기)
	for e in [[ta, 0], [ta, 1], [ta, 5], [tb, 5], [tb, 4], [tb, 3], [tc, 1], [tc, 2], [tc, 3]]:
		draw_line(e[0], hexa[e[1]], DIE_EDGE, w * 0.8, true)
	var font := get_theme_default_font()
	# 옆면 장식 숫자: 각 면의 무게중심
	var faces := [[ta, hexa[5], tb], [ta, hexa[1], tc], [tb, tc, hexa[3]], [ta, hexa[0], hexa[5]], [ta, hexa[0], hexa[1]], [tc, hexa[2], hexa[3]]]
	for i in faces.size():
		var c: Vector2 = (faces[i][0] + faces[i][1] + faces[i][2]) / 3.0
		_draw_centered(font, FACE_NUMBERS[i], c, int(r * 0.2), Color(1, 1, 1, 0.85))
	# 가운데 숫자
	_draw_centered(font, str(_shown), (ta + tb + tc) / 3.0 + Vector2(0, r * 0.04), int(r * 0.42), Color.WHITE)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_centered(font: Font, text: String, at: Vector2, font_size: int, color: Color) -> void:
	var sz := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	var pos := at + Vector2(-sz.x / 2.0, font.get_ascent(font_size) - sz.y / 2.0)
	draw_string_outline(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, maxi(2, font_size / 10), Color(0.35, 0, 0.05))
	draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)


func _label(font_size: int) -> Label:
	var l := Label.new()
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", Color.WHITE)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("outline_size", 8)
	l.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(l)
	return l
