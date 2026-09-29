extends Control
## 주사위 판정 연출: 숫자가 잠깐 굴러간 뒤 결과(주사위 + 보정 = 합계 / 목표, 성공·실패)를 보여준다.
## play(result) 의 result 는 StoryRunner.dice_rolled 의 내용.

signal finished

const ROLL_TIME := 0.8
const SUCCESS_COLOR := Color("7fd48a")
const FAIL_COLOR := Color("e46a6a")

var is_rolling := false

var _result := {}
var _t := 0.0
var _tick := 0.0
var _title: Label
var _die: Label
var _detail: Label
var _outcome: Label


func _init() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	var box := VBoxContainer.new()
	box.set_anchors_preset(PRESET_FULL_RECT)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 10)
	box.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(box)
	resized.connect(queue_redraw)
	_title = _label(box, 20, Color("dddddd"))
	_die = _label(box, 64, Color.WHITE)
	_die.custom_minimum_size = Vector2(0, 110)
	_die.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_detail = _label(box, 18, Color("bbbbbb"))
	_outcome = _label(box, 28, Color.WHITE)


func play(result: Dictionary) -> void:
	_result = result
	_title.text = "%s 판정  ·  목표 %d" % [result.ability_name, result.dc]
	_detail.text = ""
	_outcome.text = ""
	_t = 0.0
	_tick = 0.0
	is_rolling = true
	queue_redraw()


## 굴리는 중이면 바로 결과로
func skip() -> void:
	if is_rolling:
		_t = ROLL_TIME


func _process(delta: float) -> void:
	if not is_rolling:
		return
	_t += delta
	queue_redraw()
	_tick -= delta
	if _t >= ROLL_TIME:
		_show_result()
	elif _tick <= 0.0:
		_tick = 0.05
		_die.text = str(randi_range(1, 20))


func _show_result() -> void:
	is_rolling = false
	_die.text = str(_result.roll)
	var line := "주사위 %d" % _result.roll
	for p in _result.parts:
		line += "  %s  %s %d" % ["+" if p.value >= 0 else "−", p.label, absi(p.value)]
	_detail.text = "%s   =   %d" % [line, _result.total]
	_outcome.text = "성공" if _result.success else "실패"
	_outcome.add_theme_color_override("font_color", SUCCESS_COLOR if _result.success else FAIL_COLOR)
	queue_redraw()
	finished.emit()


func _draw() -> void:
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0, 0, 0, 0.9)
	bg.set_corner_radius_all(10)
	bg.border_color = Color("555555")
	bg.set_border_width_all(1)
	draw_style_box(bg, Rect2(Vector2.ZERO, size))
	# 주사위 칸
	var die_size := 96.0
	var center := _die.get_global_rect().get_center() - get_global_rect().position
	var die := StyleBoxFlat.new()
	die.bg_color = Color(0.16, 0.16, 0.18)
	die.set_corner_radius_all(14)
	die.set_border_width_all(2)
	die.border_color = Color("888888") if is_rolling or _result.is_empty() else \
		(SUCCESS_COLOR if _result.success else FAIL_COLOR)
	draw_style_box(die, Rect2(center - Vector2(die_size, die_size) / 2, Vector2(die_size, die_size)))


func _label(parent: Control, font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l
