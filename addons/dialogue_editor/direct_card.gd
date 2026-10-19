@tool
extends "res://addons/dialogue_editor/dialogue_card.gd"
## 🎬 연출 카드 (노드 kind = direct). 단계(steps)를 위에서부터 차례로: 그림 띄우기·페이드·흔들기·기다리기 (어디서든),
## 걷게 하기·카메라·NPC 숨기기 (탐험 필드에서만 — 미리보기에서는 건너뜀). 다 끝나면 '다음 →'.
## 단계 규칙은 core/direction.gd. 연출 중에는 대사 상자가 숨고 플레이어는 조작할 수 없다.

const Direction = preload("res://core/direction.gd")
const DIRECT_COLOR := Color(0.16, 0.32, 0.45)

var lookups := {}


func uses_pages() -> bool:
	return false


func rebuild() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	out_ports = []
	if not data.get("steps", []) is Array:
		data.steps = []
	var steps: Array = data.steps
	title = "🎬 연출   " + data.node_id
	for s in ["titlebar", "titlebar_selected"]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = DIRECT_COLOR.lightened(0.15 if s == "titlebar_selected" else 0.0)
		sb.set_content_margin_all(6)
		add_theme_stylebox_override(s, sb)
	var head := Label.new()
	head.text = "위에서부터 차례로 보여 줍니다. 그동안 대사 상자는 숨고 플레이어는 움직일 수 없습니다."
	head.modulate = Color(1, 1, 1, 0.7)
	head.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	head.custom_minimum_size.x = 460
	_add_row(head, true, false)
	for i in steps.size():
		_add_row(_step_box(i), false, false)
	var add := MenuButton.new()
	add.text = "＋ 연출 추가 ▾"
	add.flat = false
	var pm := add.get_popup()
	for k in Direction.LABEL:
		pm.add_item(Direction.LABEL[k])
		pm.set_item_metadata(pm.item_count - 1, k)
	pm.index_pressed.connect(func(idx):
		steps.append(Direction.normalize({"do": pm.get_item_metadata(idx)}))
		rebuild()
		changed.emit("step_add"))
	_add_row(add, false, false)
	var nx := Label.new()
	nx.text = "다음 →  " + _target_hint(data.get("next_node", ""))
	nx.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_mark_missing(nx, data.get("next_node", ""))
	_add_row(nx, false, true)
	out_ports.append(["next", -1])
	size = Vector2(size.x, 0)


func _step_box(i: int) -> Control:
	var steps: Array = data.steps
	var s: Dictionary = Direction.normalize(steps[i])
	steps[i] = s
	var key := "step:%s:%d" % [data.node_id, i]
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.13, 0.15, 0.19)
	sb.border_width_left = 3
	sb.border_color = Color("7fb2ff") if s.do in Direction.SCREEN_STEPS else Color("7fd48a")
	sb.set_content_margin_all(6)
	panel.add_theme_stylebox_override("panel", sb)
	var vb := VBoxContainer.new()
	panel.add_child(vb)
	var top := HBoxContainer.new()
	vb.add_child(top)
	var n := Label.new()
	n.text = "%d." % (i + 1)
	top.add_child(n)
	var kind := OptionButton.new()
	var kinds: Array = Direction.LABEL.keys()
	for k in kinds:
		kind.add_item(Direction.LABEL[k])
	kind.select(kinds.find(s.do))
	kind.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	kind.item_selected.connect(func(idx):
		steps[i] = Direction.normalize({"do": kinds[idx]})
		rebuild()
		changed.emit(key))
	top.add_child(kind)
	for b in [["↑", i - 1], ["↓", i + 1]]:
		var mv := Button.new()
		mv.text = b[0]
		mv.flat = true
		mv.disabled = b[1] < 0 or b[1] >= steps.size()
		var to: int = b[1]
		mv.pressed.connect(func():
			steps.remove_at(i)
			steps.insert(to, s)
			rebuild()
			changed.emit("step_move"))
		top.add_child(mv)
	var del := Button.new()
	del.text = "✕"
	del.flat = true
	del.tooltip_text = "이 단계 지우기"
	del.pressed.connect(func():
		steps.remove_at(i)
		rebuild()
		changed.emit("step_del"))
	top.add_child(del)
	var row := HBoxContainer.new()
	vb.add_child(row)
	match s.do:
		"image":
			var files := Direction.image_files()
			var o := OptionButton.new()
			o.add_item("(그림 고르기 — art/cutscenes/)")
			for f in files:
				o.add_item(f)
				if f == s.file:
					o.select(o.item_count - 1)
			if s.file != "" and not s.file in files:
				o.add_item("⚠ %s (없음)" % s.file)
				o.select(o.item_count - 1)
			o.item_selected.connect(func(idx):
				s.file = files[idx - 1] if idx >= 1 and idx - 1 < files.size() else s.file
				rebuild()
				changed.emit(key))
			row.add_child(o)
			_num(row, "나타나는 시간", s, "fade", 0, 10, key)
			if s.file != "":
				var tex := Direction.load_image(s.file)
				if tex:
					var thumb := TextureRect.new()
					thumb.texture = tex
					thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
					thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
					thumb.custom_minimum_size = Vector2(240, 135)
					vb.add_child(thumb)
		"image_off", "screen_off":
			_num(row, "사라지는 시간", s, "fade", 0, 10, key)
		"screen":
			var cp := ColorPickerButton.new()
			cp.color = Color.html(str(s.color)) if Color.html_is_valid(str(s.color)) else Color.BLACK
			cp.edit_alpha = false
			cp.custom_minimum_size = Vector2(60, 28)
			cp.tooltip_text = "화면 색 (검은 화면이면 검정)"
			cp.color_changed.connect(func(c):
				s.color = "#" + c.to_html(false).to_upper()
				changed.emit(key))
			row.add_child(cp)
			_num(row, "나타나는 시간", s, "fade", 0, 10, key)
		"fade":
			var o := OptionButton.new()
			for t in [["black", "검게 덮기"], ["white", "하얗게 덮기"], ["clear", "걷기 (다시 보이게)"]]:
				o.add_item(t[1])
				if t[0] == s.to:
					o.select(o.item_count - 1)
			o.item_selected.connect(func(idx):
				s.to = Direction.FADE_TO[idx]
				changed.emit(key))
			row.add_child(o)
			_num(row, "시간", s, "time", 0, 10, key)
		"shake":
			_num(row, "세기", s, "power", 0.1, 3, key)
			_num(row, "시간 (0 = 계속)", s, "time", 0, 60, key)
			_num(row, "떨림 빠르기", s, "speed", 1, 60, key)
			_wait_box(vb, s, key, "끝날 때까지 기다림", "끄면 흔들리는 동안 다음 단계 (대사와 함께 흔들기). 시간 0(계속)은 늘 기다리지 않고, '흔들기 멈춤' 단계나 대화 끝에서 멈춤")
			_hint(vb, "떨림 빠르기: 1~5 = 느리게 출렁(손에 든 카메라) / 30 = 보통 / 60 = 아주 빠르게 덜덜")
		"wait":
			_num(row, "초", s, "time", 0, 60, key)
		"sound", "music":
			var dir: String = Direction.SFX_DIR if s.do == "sound" else Direction.BGM_DIR
			_file(row, s, Direction.audio_files(dir), "(소리 고르기 — %s)" % dir.trim_prefix("res://"), key)
			if s.do == "music":
				_num(row, "커지는 시간", s, "fade", 0, 10, key)
			_num(row, "볼륨 %", s, "volume", 0, 100, key)
			var play := Button.new()
			play.text = "▶"
			play.tooltip_text = "들어 보기"
			play.disabled = s.file == ""
			play.pressed.connect(func(): _listen(dir + str(s.file), float(s.volume)))
			row.add_child(play)
		"music_off":
			_num(row, "작아지는 시간", s, "fade", 0, 10, key)
		"face":
			_who(row, s, [["player", "플레이어"]], key)
			var o := OptionButton.new()
			for d in [["up", "↑ 위"], ["down", "↓ 아래"], ["left", "← 왼쪽"], ["right", "→ 오른쪽"]]:
				o.add_item(d[1])
				if d[0] == s.get("dir", "down"):
					o.select(o.item_count - 1)
			o.item_selected.connect(func(idx):
				s.dir = Direction.DIRS[idx]
				changed.emit(key))
			row.add_child(o)
		"walk":
			_who(row, s, [["player", "플레이어"]], key)
			_tile(row, s, key)
			_num(row, "속도(칸/초)", s, "speed", 0.5, 20, key)
			var w := CheckBox.new()
			w.text = "다 걸을 때까지 기다림"
			w.tooltip_text = "끄면 걷기 시작하자마자 다음 단계로 (여럿이 같이 걷기)"
			w.button_pressed = s.get("wait", true)
			w.toggled.connect(func(on):
				s.wait = on
				changed.emit(key))
			vb.add_child(w)
		"camera":
			_who(row, s, [["", "(칸으로)"], ["player", "플레이어 (도착하면 다시 따라가기)"]], key)
			if s.get("who", "") == "":
				_tile(row, s, key)
			_num(row, "시간", s, "time", 0, 60, key)
			var ez := OptionButton.new()
			for e in [["smooth", "천천히 시작·끝"], ["linear", "일정한 속도"]]:
				ez.add_item(e[1])
				if e[0] == str(s.get("ease", "smooth")):
					ez.select(ez.item_count - 1)
			ez.tooltip_text = "카메라가 움직이는 느낌"
			ez.item_selected.connect(func(idx):
				s.ease = ["smooth", "linear"][idx]
				changed.emit(key))
			row.add_child(ez)
			var row2 := HBoxContainer.new()
			vb.add_child(row2)
			var fr := CheckBox.new()
			fr.text = "시작 위치 (먼저 여기로 바로)"
			fr.tooltip_text = "켜면 카메라가 이 칸에서 바로 시작해 위의 곳까지 '시간' 동안 움직임.
예) 맵 위쪽 칸 → 플레이어, 시간 4초 = 위에서 천천히 내려오기 (화면이 덮여 있을 때 하면 자연스러움)"
			fr.button_pressed = s.get("from") is Array
			fr.toggled.connect(func(on):
				if on:
					s.from = (s.to.duplicate() if s.get("to") is Array else [0, 0])
				else:
					s.erase("from")
				rebuild()
				changed.emit(key))
			row2.add_child(fr)
			if s.get("from") is Array:
				_tile(row2, s, key, "from")
			var row3 := HBoxContainer.new()
			vb.add_child(row3)
			_wait_box(row3, s, key, "다 움직일 때까지 기다림", "끄면 카메라가 움직이는 동안 다음 단계 (걷기·대사와 동시에)")
			if str(s.get("who", "")) not in ["", "player"]:
				var fo := CheckBox.new()
				fo.text = "그 인물을 계속 따라감"
				fo.tooltip_text = "도착한 뒤에도 그 인물이 걸으면 카메라가 따라감 (다음 카메라 단계나 대화 끝까지)"
				fo.button_pressed = s.get("follow", false)
				fo.toggled.connect(func(on):
					s.follow = on
					changed.emit(key))
				row3.add_child(fo)
		"vanish":
			_who(row, s, [], key)
		"zoom":
			var zo := OptionButton.new()
			var scales := [0, 3, 4, 5, 6, 7, 8, 10, 12]
			for z in scales:
				zo.add_item("기본 배율 (원래대로)" if z == 0 else "도트 ×%d%s" % [z, "  (기본)" if z == 5 else ""])
				if int(s.get("scale", 0)) == z:
					zo.select(zo.item_count - 1)
			zo.tooltip_text = "그림 1px 을 화면 몇 px 로 (딱 떨어지는 배율이라 도트가 깨끗함). 기본 = ×5 (타일 16px → 80px)
×6 이상 = 확대, ×4 이하 = 축소"
			zo.item_selected.connect(func(idx):
				s.scale = scales[idx]
				changed.emit(key))
			row.add_child(zo)
			_num(row, "시간", s, "time", 0, 30, key)
			_wait_box(vb, s, key, "끝날 때까지 기다림", "끄면 확대되는 동안 다음 단계")
			_hint(vb, "시간 동안 한 단계씩 (×5 → ×6 → ×7) 바뀌어 도트가 흐려지지 않습니다. 대화가 끝나면 원래 배율로 돌아갑니다.")
	if s.do in Direction.FIELD_STEPS:
		var hint := Label.new()
		hint.text = "필드에서만 (미리보기에서는 건너뜀). 칸 x·y 는 맵 탭에서 마우스를 올리면 보입니다."
		hint.add_theme_font_size_override("font_size", 14)
		hint.modulate = Color(1, 1, 1, 0.5)
		vb.add_child(hint)
	return panel


## '기다림' 체크 (걷기·카메라·확대·흔들기 공통 — 끄면 다음 단계와 동시에)
func _wait_box(parent: Control, s: Dictionary, key: String, text: String, tip: String) -> void:
	var w := CheckBox.new()
	w.text = text
	w.tooltip_text = tip
	w.button_pressed = s.get("wait", true)
	w.toggled.connect(func(on):
		s.wait = on
		changed.emit(key))
	parent.add_child(w)


func _hint(parent: Control, t: String) -> void:
	var l := Label.new()
	l.text = t
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", 14)
	l.modulate = Color(1, 1, 1, 0.5)
	parent.add_child(l)


## 파일 고르기 (그림·소리 공통)
func _file(row: HBoxContainer, s: Dictionary, files: Array, empty: String, key: String) -> void:
	var o := OptionButton.new()
	o.add_item(empty)
	for f in files:
		o.add_item(f)
		if f == s.get("file", ""):
			o.select(o.item_count - 1)
	if s.get("file", "") != "" and not s.file in files:
		o.add_item("⚠ %s (없음)" % s.file)
		o.select(o.item_count - 1)
	o.item_selected.connect(func(idx):
		if idx >= 1 and idx - 1 < files.size():
			s.file = files[idx - 1]
		rebuild()
		changed.emit(key))
	row.add_child(o)


## 에디터에서 소리 들어 보기
var _player: AudioStreamPlayer

func _listen(path: String, volume: float) -> void:
	var stream := Direction.load_audio(path)
	if stream == null:
		return
	if _player == null:
		_player = AudioStreamPlayer.new()
		add_child(_player)
	_player.stream = stream
	_player.volume_db = linear_to_db(maxf(0.01, volume / 100.0))
	_player.play()


func _num(row: HBoxContainer, label: String, s: Dictionary, k: String, lo: float, hi: float, key: String) -> void:
	var l := Label.new()
	l.text = label
	row.add_child(l)
	var sp := SpinBox.new()
	sp.min_value = lo
	sp.max_value = hi
	sp.step = 0.1
	sp.value = float(s.get(k, lo))
	sp.custom_minimum_size.x = 90
	sp.value_changed.connect(func(v):
		s[k] = v
		changed.emit(key + ":" + k))
	row.add_child(sp)


## 인물: 앞 목록(플레이어 등) + 맵의 NPC (lookups.people: [object_id, "맵 · 이름"])
func _who(row: HBoxContainer, s: Dictionary, first: Array, key: String) -> void:
	var opts: Array = first + lookups.get("people", [])
	var o := OptionButton.new()
	o.fit_to_longest_item = false
	o.custom_minimum_size.x = 200
	o.clip_text = true
	var found := false
	for p in opts:
		o.add_item(p[1])
		if p[0] == s.get("who", ""):
			o.select(o.item_count - 1)
			found = true
	if not found:
		o.add_item("(인물 고르기)" if s.get("who", "") == "" else "⚠ %s (없음)" % s.who)
		o.select(o.item_count - 1)
	o.item_selected.connect(func(idx):
		if idx < opts.size():
			s.who = opts[idx][0]
			rebuild()
			changed.emit(key))
	row.add_child(o)


func _tile(row: HBoxContainer, s: Dictionary, key: String, k := "to") -> void:
	if not s.get(k) is Array or s[k].size() != 2:
		s[k] = [0, 0]
	for j in 2:
		var l := Label.new()
		l.text = "xy"[j]
		row.add_child(l)
		var sp := SpinBox.new()
		sp.min_value = 0
		sp.max_value = 500
		sp.value = int(s[k][j])
		var jj := j
		sp.value_changed.connect(func(v):
			s[k][jj] = int(v)
			changed.emit(key + ":" + k))
		row.add_child(sp)
