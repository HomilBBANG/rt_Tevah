extends Control
## 플레이 화면. 게임 로직 없음: StoryRunner·GameState 시그널을 그리고 입력만 돌려준다.
##
## 한 번의 행동 결과를 "페이지" 순서로 보여준다 (클릭/Space 로 넘김):
##   dice      — 주사위 판정 연출 (굴리는 중에 클릭하면 바로 결과). 지금 화면(말풍선·초상화) 위 가운데에 겹쳐 뜬다
##   system    — 획득·버림 등 시스템 메시지 (검은 상자, 가운데 정렬)
##   situation — 화자 없는 노드 (밝은 상자)
##   dialogue  — 화자 있는 노드 (초상화 + 말풍선, 직전 대사는 회색으로 위에)
##               주인공은 얼굴·이름이 나오지 않는다 (꼬리 없는 말풍선).
##               NPC는 먼저 말한 쪽이 왼쪽, 나중에 등장한 쪽이 오른쪽.
## 마지막 페이지에서 선택지를 띄우고, 선택지 없는 노드면 다음 클릭에 continue_story().
## 노드의 대본 페이지(core/script_pages.gd)는 글자가 한 자씩 나온다: 속도·{w=초} 대기·자동 넘김.
## 나오는 중에 입력 1번 = 이 페이지 전체 표시, 그다음 입력 = 다음 페이지.

const ChoiceButton = preload("res://ui/choice_button.gd")
const ScriptPages = preload("res://core/script_pages.gd")
const Direction = preload("res://core/direction.gd")
const KIND_OF := {"narration": "situation", "bubble": "dialogue", "system": "system", "subtitle": "subtitle", "free": "free"}

## 탐험 필드 위에 겹쳐 띄운 NPC 대화가 끝남 (embedded 일 때만)
signal finished

# 말풍선 위치 (기획서 기준, 화면 비율). 꼬리 방향에 따라 좌우로 약간 이동. none = 주인공(꼬리 없음)
const BUBBLE_X := {"left": [0.266, 0.676], "right": [0.287, 0.697], "none": [0.287, 0.697]}
const SIDES := ["left", "right"]
const BUBBLE_Y := [0.68, 0.83]
const PREV_BUBBLE_Y := [0.485, 0.635]

## 필드에서 NPC 대화용으로 띄울 때 add_child 전에 true. 이때는 launch() 대신 필드가 start_dialogue() 를 부른다.
var embedded := false
## 전투 화면 위에 띄운 대화 (전투 중 '대화'): 초상화·인벤토리 버튼을 숨긴다 (상대는 전투 화면 가운데에 이미 있음)
var over_combat := false
## 처음 보여줄 노드에서 몇 번째 페이지부터 볼지 (대화 에디터 미리보기)
var start_page := 0
## 컷신일 때 '건너뛰기' 버튼을 보일지 (로고는 false — 버튼 없이 Esc 로만 넘김)
var skip_button := true
var own_letterbox := true        # 자기 위아래 띠를 보이나 (필드 위에서는 필드가 띠를 밀어 넣음 → false)
var start_cover := {}            # 덮인 화면으로 시작 (Direction.opening_cover — 자동 시작 컷신·맵 미리보기)

var _pages: Array = []          # [{kind, text, speaker_id}]
var _page_i := -1
var _choices: Array = []
var _pending_msgs: PackedStringArray = []
var _pending_dice := {}
var _ended := false
var _cur_line := {}             # 지금 말풍선의 대사 {text, speaker_id, side}
var _prev_line := {}            # 직전 대사 (회색)
var _slots := ["", ""]          # 초상화 자리 [왼쪽, 오른쪽] 에 선 NPC char_id
var _slot_spoke := [0, 0]       # 각 자리가 마지막으로 말한 순번
var _line_no := 0
var _closing := false           # 필드 대화가 끝났고 남은 페이지만 보여주는 중
var _links: Array = []          # [[signal, callable]] — 화면이 닫힐 때 끊는다
# 글자 출력 (타이핑)
var _type_label: Label          # 지금 글자가 나오는 칸 (null = 다 나옴)
var _type_shown := 0.0
var _type_total := 0
var _type_cps := 0.0
var _type_pauses: Array = []    # [[글자 위치, 초], ...] 남은 대기
var _type_wait := 0.0
var _auto_left := -1.0          # 자동 넘김까지 남은 초 (-1 = 없음)
# 🎬 연출 (core/direction.gd): 그림 칸·페이드 칸은 배경 바로 위, 대사 상자 아래 (검은 화면·그림 위에 글을 띄울 수 있게)
var cg: TextureRect
var screen: ColorRect           # 색 화면 (연출 screen — 그림 칸 위, 페이드 아래)
var fade: ColorRect
var directing := false
var cutscene := false           # 이 대화에서 연출 카드를 한 번이라도 돌렸나 (건너뛰기 버튼이 보임)
var skipping := false           # 건너뛰는 중: 연출은 바로 끝난 모습으로, 대사는 저절로 넘김 → 선택지·대화 끝에서 멈춤
var skip_btn: Button
# 자막 (상자 없이 화면 아래 글자 — 영상 자막처럼)
var subtitle: Label
var subtitle_name: Label
var free_text: Label             # 자유 위치 글자 (상자 없이 화면 아무 곳에 — 페이지 display free)
var _tweens: Array = []


func _ready() -> void:
	$Letterbox.visible = own_letterbox
	_link(StoryRunner.node_shown, _on_node_shown)
	_link(StoryRunner.choices_shown, _on_choices_shown)
	_link(StoryRunner.message, func(t): _pending_msgs.append(t))
	_link(StoryRunner.messages_cleared, func():
		_pending_msgs.clear()
		_pending_dice = {})
	_link(StoryRunner.dice_rolled, func(r): _pending_dice = r)
	_link(StoryRunner.ending_reached, _on_ending)
	_link(StoryRunner.dialogue_ended, _on_dialogue_ended)
	_link(StoryRunner.inventory_full, %Inventory.open_discard)
	_link(StoryRunner.direction_requested, _on_direction)
	cg = TextureRect.new()
	cg.set_anchors_preset(PRESET_FULL_RECT)
	cg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	cg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	cg.mouse_filter = MOUSE_FILTER_IGNORE
	cg.modulate.a = 0.0
	cg.visible = false
	add_child(cg)
	move_child(cg, $Scene.get_index() + 1)
	screen = ColorRect.new()
	screen.set_anchors_preset(PRESET_FULL_RECT)
	screen.mouse_filter = MOUSE_FILTER_IGNORE
	screen.color = Color(0, 0, 0, 0)
	screen.visible = false
	add_child(screen)
	move_child(screen, cg.get_index() + 1)
	fade = ColorRect.new()
	fade.set_anchors_preset(PRESET_FULL_RECT)
	fade.mouse_filter = MOUSE_FILTER_IGNORE
	fade.color = Color(0, 0, 0, 0)
	add_child(fade)
	move_child(fade, screen.get_index() + 1)
	if not start_cover.is_empty():   # 첫 연출이 검게 덮기·색 화면이면 처음부터 덮어 둠 (맵이 먼저 보이지 않게)
		var cc: Color = start_cover.color
		if start_cover.layer == "screen":
			screen.color = Color(cc.r, cc.g, cc.b, 1.0)
			screen.visible = true
		else:
			fade.color = Color(cc.r, cc.g, cc.b, 1.0)
	subtitle_name = Label.new()
	subtitle_name.anchor_left = 0.1
	subtitle_name.anchor_right = 0.9
	subtitle_name.anchor_top = 0.74
	subtitle_name.anchor_bottom = 0.78
	subtitle_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle_name.add_theme_font_size_override("font_size", 28)
	subtitle_name.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	subtitle_name.add_theme_constant_override("outline_size", 8)
	subtitle_name.mouse_filter = MOUSE_FILTER_IGNORE
	subtitle_name.visible = false
	add_child(subtitle_name)
	subtitle = Label.new()
	subtitle.anchor_left = 0.1
	subtitle.anchor_right = 0.9
	subtitle.anchor_top = 0.78
	subtitle.anchor_bottom = 0.9
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	subtitle.add_theme_font_size_override("font_size", 38)
	subtitle.add_theme_color_override("font_color", Color(1, 1, 1))
	subtitle.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.95))
	subtitle.add_theme_constant_override("outline_size", 12)
	subtitle.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	subtitle.add_theme_constant_override("shadow_offset_x", 2)
	subtitle.add_theme_constant_override("shadow_offset_y", 3)
	subtitle.mouse_filter = MOUSE_FILTER_IGNORE
	subtitle.visible = false
	add_child(subtitle)
	free_text = Label.new()
	free_text.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	free_text.add_theme_constant_override("outline_size", 10)
	free_text.mouse_filter = MOUSE_FILTER_IGNORE
	free_text.visible = false
	add_child(free_text)
	skip_btn = Button.new()
	skip_btn.text = "건너뛰기 ▶▶"
	skip_btn.tooltip_text = "컷신을 건너뜁니다 (Esc). 선택지가 나오면 멈춥니다"
	skip_btn.focus_mode = FOCUS_NONE
	skip_btn.anchor_left = 0.87
	skip_btn.anchor_right = 0.985
	skip_btn.anchor_top = 0.115
	skip_btn.anchor_bottom = 0.165
	skip_btn.visible = false
	skip_btn.pressed.connect(skip)
	add_child(skip_btn)
	_link(GameState.stats_changed, _update_status)
	_link(GameState.inventory_changed, _update_status)
	%InventoryButton.pressed.connect(%Inventory.open_browse)
	%MenuButton.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/episode_select.tscn"))
	%ClickCatcher.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			advance())
	_update_status()
	if embedded:
		# 필드 위 대화: 체력·정신력·시간 표시와 메뉴는 숨기고, 뒤의 필드가 비치게
		%Stats.visible = false
		%MenuButton.visible = false
		$Scene.color.a = 0.55
	if over_combat:
		%InventoryButton.visible = false
		$Scene.color.a = 0.35
	elif not embedded:   # 겹쳐 띄운 대화는 띄운 쪽이 start_dialogue() 를 부른다
		StoryRunner.launch()


func _exit_tree() -> void:
	for l in _links:
		if l[0].is_connected(l[1]):
			l[0].disconnect(l[1])
	_links.clear()


## 신호 연결. 화면이 숨겨져 있으면(전투 중 대화 아래에 깔린 원래 대화 등) 받지 않는다
func _link(sig: Signal, callable: Callable) -> void:
	var guarded: Callable
	match callable.get_argument_count():
		0: guarded = func(): if is_visible_in_tree(): callable.call()
		1: guarded = func(a): if is_visible_in_tree(): callable.call(a)
		_: guarded = func(a, b): if is_visible_in_tree(): callable.call(a, b)
	sig.connect(guarded)
	_links.append([sig, guarded])


func _unhandled_input(event: InputEvent) -> void:
	if cutscene and event.is_action_pressed("ui_cancel"):
		skip()
		get_viewport().set_input_as_handled()
		return
	var go := event.is_action_pressed("ui_accept") or (InputMap.has_action("interact") and event.is_action_pressed("interact"))
	if go and not %Inventory.visible:
		advance()
		get_viewport().set_input_as_handled()


## 다음 페이지로. 마지막 페이지이고 선택지 없는 노드면 스토리를 진행.
func advance() -> void:
	if directing:
		return   # 연출 중에는 넘기지 않는다
	_auto_left = -1.0
	if _type_label != null:
		_finish_typing()   # 나오는 중 → 이 페이지 전체 표시
		return
	if StoryRunner.busy or %Choices.get_child_count() > 0:
		return
	if %DicePanel.is_rolling:
		%DicePanel.skip()
		return
	if _page_i < _pages.size() - 1:
		_next_page()
	elif _closing:
		finished.emit()
	elif not _ended and _choices.is_empty():
		StoryRunner.continue_story()


func _next_page() -> void:
	_page_i += 1
	_show_page(_pages[_page_i])


# ---------------------------------------------------------------- StoryRunner 시그널
func _on_node_shown(node: Dictionary, _speaker_name: String) -> void:
	_pages = []
	_flush_messages()
	for p in ScriptPages.pages_of(node):
		var parsed := ScriptPages.parse_text(p.text)
		_pages.append({"kind": KIND_OF[p.display], "text": parsed.text, "pauses": parsed.pauses, "speaker_id": p.speaker_id,
			"cps": ScriptPages.cps(p.speed, DataLoader.config, node.get("text_speed", "")),
			"advance": p.advance, "auto_wait": p.auto_wait, "free": p if p.display == "free" else {}})


func _on_choices_shown(entries: Array) -> void:
	_choices = entries
	_ended = false
	_start_pages()


func _on_ending(ending_id: String) -> void:
	_pages = []
	_flush_messages()
	# TODO(기획 확인): Endings 시트에 제목·본문이 없어 엔딩 ID만 시스템 상자로 표시한다.
	_pages.append({"kind": "system", "text": "— 엔딩: %s —" % ending_id, "speaker_id": ""})
	_choices = []
	_ended = true
	%InventoryButton.disabled = true
	_start_pages()


## 필드 대화가 EXIT 에 닿음: 남은 시스템 메시지가 있으면 보여준 뒤 닫는다
func _on_dialogue_ended() -> void:
	_pages = []
	_flush_messages()
	_choices = []
	_closing = true
	if _pages.is_empty():
		finished.emit()
	else:
		_start_pages()


func _flush_messages() -> void:
	if not _pending_dice.is_empty():
		_pages.append({"kind": "dice", "result": _pending_dice, "text": "", "speaker_id": ""})
		_pending_dice = {}
	if not _pending_msgs.is_empty():
		_pages.append({"kind": "system", "text": "\n".join(_pending_msgs), "speaker_id": ""})
		_pending_msgs.clear()


func _start_pages() -> void:
	_clear_choices()
	_page_i = clampi(start_page, 0, maxi(_pages.size() - 1, 0)) - 1
	start_page = 0
	if not _pages.is_empty():
		_next_page()


# ---------------------------------------------------------------- 🎬 연출
## 건너뛰기: 돌고 있는 연출은 바로 끝난 모습으로, 그 뒤 대사는 저절로 넘긴다 (선택지·대화 끝에서 멈춤)
func skip() -> void:
	if not cutscene or skipping:
		return
	skipping = true
	for tw in _tweens:
		if tw.is_valid():
			tw.custom_step(1e6)
	if StoryRunner.field_director.is_valid():
		StoryRunner.field_director.call({"do": "_finish"})


func _skip_tick() -> void:
	if %Choices.get_child_count() > 0 or _ended:
		skipping = false   # 선택지는 플레이어가 고른다 (에피소드 엔딩도 멈춤)
		return
	if not StoryRunner.busy:
		advance()


## 연출 카드: 대사 상자를 숨기고 단계를 차례로 실행한 뒤 StoryRunner 에 알린다
func _on_direction(steps: Array) -> void:
	directing = true
	cutscene = true
	skip_btn.visible = skip_button
	%InventoryButton.visible = false   # 컷신 중에는 소지품을 열지 않는다
	_auto_left = -1.0
	_type_label = null
	_clear_choices()
	for n in [%SituationBox, %SystemBox, %Bubble, %PrevBubble, %PortraitLeft, %PortraitRight, %DicePanel, %AdvanceHint, subtitle, subtitle_name, free_text]:
		n.visible = false
	var dim: float = $Scene.color.a
	if embedded:
		$Scene.color.a = 0.0   # 필드 위 연출: 뒤의 맵이 그대로 보이게
	for s in steps:
		var st := Direction.normalize(s)
		if skipping:
			st["_instant"] = true
		await _do_step(st)
	if embedded:
		$Scene.color.a = dim
	directing = false
	StoryRunner.direction_finished()


func _do_step(s: Dictionary) -> void:
	var instant: bool = s.get("_instant", false)
	if instant:
		for k in ["fade", "time"]:
			if s.has(k):
				s[k] = 0.0
	match s.do:
		"image":
			var tex := Direction.load_image(str(s.file))
			if tex == null:
				push_warning("[연출] 그림을 찾을 수 없음: %s" % s.file)
				return
			cg.texture = tex
			cg.visible = true
			await _tween(cg, "modulate:a", 1.0, float(s.fade))
		"image_off":
			await _tween(cg, "modulate:a", 0.0, float(s.fade))
			cg.visible = false
		"screen":
			var sc := Color.html(str(s.color)) if Color.html_is_valid(str(s.color)) else Color.BLACK
			screen.color = Color(sc.r, sc.g, sc.b, screen.color.a if screen.visible else 0.0)
			screen.visible = true
			await _tween(screen, "color:a", 1.0, float(s.fade))
		"screen_off":
			await _tween(screen, "color:a", 0.0, float(s.fade))
			screen.visible = false
		"fade":
			if s.to != "clear":
				var c := Color.WHITE if s.to == "white" else Color.BLACK
				fade.color = Color(c.r, c.g, c.b, fade.color.a)
			await _tween(fade, "color:a", 0.0 if s.to == "clear" else 1.0, float(s.time))
		"shake":
			if instant:
				return
			if StoryRunner.field_director.is_valid():
				StoryRunner.field_director.call(s)   # 맵(카메라)도 같이 — 기다리지 않음
			if float(s.time) <= 0.0:
				return   # 계속 흔들기(손떨림)는 맵 카메라만 — 대사 상자는 그대로
			if s.get("wait", true):
				await _shake(float(s.power), float(s.time))
			else:
				_shake(float(s.power), float(s.time))
		"shake_off":
			if StoryRunner.field_director.is_valid():
				StoryRunner.field_director.call(s)
		"wait":
			var left := float(s.time)
			while left > 0.0 and not skipping:
				await get_tree().process_frame
				left -= get_process_delta_time()
		"sound":
			if not instant:
				Sound.play_sfx(str(s.file), float(s.volume))
		"music":
			Sound.play_music(str(s.file), float(s.fade), float(s.volume))   # 기다리지 않음 (소리가 커지는 동안 다음 단계)
		"music_off":
			Sound.stop_music(float(s.fade))
		_:
			# 필드 단계 (walk·camera·vanish): 탐험 화면이 있을 때만 (미리보기에서는 건너뜀)
			if StoryRunner.field_director.is_valid():
				await StoryRunner.field_director.call(s)


func _tween(obj: Object, prop: String, value: Variant, time: float) -> void:
	if time <= 0.0:
		obj.set_indexed(NodePath(prop), value)
		return
	var tw := create_tween()
	tw.tween_property(obj, prop, value, time)
	_tweens.append(tw)
	if skipping:
		tw.custom_step(1e6)
	await tw.finished
	_tweens.erase(tw)


func _shake(power: float, time: float) -> void:
	var base := position
	var t := 0.0
	while t < time and not skipping:
		position = base + Vector2(randf_range(-1, 1), randf_range(-1, 1)) * 12.0 * power
		await get_tree().process_frame
		t += get_process_delta_time()
	position = base


# ---------------------------------------------------------------- 그리기
func _show_page(p: Dictionary) -> void:
	_clear_choices()
	_type_label = null
	_auto_left = -1.0
	if p.kind == "dice":
		# 주사위는 뒤의 대화를 지우지 않고 위에 겹친다 (사용자 시안)
		%DicePanel.visible = true
		%DicePanel.play(p.result)
		# 선택지와 겹치지 않게 숨겼던 지난 대사도 다시 (시안: 회색 지난 말풍선 + 지금 말풍선)
		%PrevBubble.visible = %Bubble.visible and not _prev_line.is_empty()
		_page_done()
		return
	%SituationBox.visible = p.kind == "situation"
	subtitle.visible = p.kind == "subtitle"
	subtitle_name.visible = p.kind == "subtitle" and p.speaker_id != ""
	free_text.visible = p.kind == "free"
	%SystemBox.visible = p.kind == "system"
	%DicePanel.visible = false
	var is_dialogue: bool = p.kind == "dialogue"
	%Bubble.visible = is_dialogue
	%PrevBubble.visible = false
	%PortraitLeft.visible = false
	%PortraitRight.visible = false
	match p.kind:
		"situation":
			%SituationText.text = p.text
			_cur_line = {}
			_prev_line = {}
			_slots = ["", ""]
		"system":
			%SystemText.text = p.text
		"subtitle":
			subtitle.text = p.text
			subtitle_name.text = DataLoader.character_name(p.speaker_id)
			var nc := DataLoader.character_color(p.speaker_id)
			subtitle_name.add_theme_color_override("font_color", Color.html(nc) if Color.html_is_valid(nc) else Color("ffd27a"))
		"dialogue":
			_show_dialogue(p)
		"free":
			_place_free(p.text, p.get("free", {}))
	match p.kind:
		"situation": _begin_typing(%SituationText, p)
		"system": _begin_typing(%SystemText, p)
		"subtitle": _begin_typing(subtitle, p)
		"free": _begin_typing(free_text, p)
		"dialogue": _begin_typing(%Bubble.text_label(), p)
		_: _page_done()


## 자유 위치 글자: 기준점 = 화면의 x·y %, 정렬에 따라 오른쪽/양쪽/왼쪽으로 자라고 세로는 가운데
func _place_free(text: String, f: Dictionary) -> void:
	free_text.text = text
	free_text.add_theme_font_size_override("font_size", int(f.get("size", 38)))
	var c := str(f.get("color", "#FFFFFF"))
	free_text.add_theme_color_override("font_color", Color.html(c) if Color.html_is_valid(c) else Color.WHITE)
	var al := str(f.get("align", "center"))
	free_text.horizontal_alignment = {"left": HORIZONTAL_ALIGNMENT_LEFT, "right": HORIZONTAL_ALIGNMENT_RIGHT}.get(al, HORIZONTAL_ALIGNMENT_CENTER)
	var ax := float(f.get("x", 50.0)) / 100.0
	var ay := float(f.get("y", 50.0)) / 100.0
	free_text.anchor_left = ax
	free_text.anchor_right = ax
	free_text.anchor_top = ay
	free_text.anchor_bottom = ay
	free_text.offset_left = 0
	free_text.offset_right = 0
	free_text.offset_top = 0
	free_text.offset_bottom = 0
	free_text.grow_horizontal = {"left": GROW_DIRECTION_END, "right": GROW_DIRECTION_BEGIN}.get(al, GROW_DIRECTION_BOTH)
	free_text.grow_vertical = GROW_DIRECTION_BOTH
	free_text.reset_size()


## 글자를 한 자씩 내보내기 시작 (속도 0 = 즉시)
func _begin_typing(label: Label, p: Dictionary) -> void:
	label.visible_characters_behavior = TextServer.VC_CHARS_AFTER_SHAPING
	_type_total = label.text.length()
	_type_cps = float(p.get("cps", 0.0))
	if _type_cps <= 0.0 or _type_total == 0 or skipping:
		label.visible_characters = -1
		_page_done()
		return
	_type_label = label
	_type_shown = 0.0
	_type_wait = 0.0
	_type_pauses = p.get("pauses", []).duplicate()
	label.visible_characters = 0
	%AdvanceHint.visible = false


func _process(delta: float) -> void:
	if skipping and not directing:
		_skip_tick()
		return
	if _type_label == null:
		if _auto_left >= 0.0 and not %Inventory.visible:
			_auto_left -= delta
			if _auto_left < 0.0:
				advance()
		return
	if _type_wait > 0.0:
		_type_wait -= delta
		return
	_type_shown += _type_cps * delta
	if not _type_pauses.is_empty() and _type_shown >= _type_pauses[0][0]:
		_type_shown = _type_pauses[0][0]
		_type_wait = _type_pauses[0][1]
		_type_pauses.pop_front()
	if _type_shown >= _type_total:
		_finish_typing()
	else:
		_type_label.visible_characters = int(_type_shown)


func _finish_typing() -> void:
	if _type_label != null:
		_type_label.visible_characters = -1
		_type_label = null
	_page_done()


## 페이지가 다 나옴: 마지막 페이지면 선택지, 자동 넘김이면 타이머
func _page_done() -> void:
	var p: Dictionary = _pages[_page_i] if _page_i >= 0 and _page_i < _pages.size() else {}
	var last := _page_i == _pages.size() - 1
	if last and _ended:
		var b := ChoiceButton.new()
		b.text = "에피소드 선택으로"
		b.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/episode_select.tscn"))
		%Choices.add_child(b)
	elif last and not _choices.is_empty():
		%PrevBubble.visible = false   # 선택지와 겹치지 않도록 지나간 대사는 숨김
		for e in _choices:
			var b := ChoiceButton.new()
			b.setup(e)
			b.pressed.connect(StoryRunner.choose.bind(e.choice.choice_id))
			%Choices.add_child(b)
	%AdvanceHint.visible = %Choices.get_child_count() == 0
	if p.get("advance", "input") == "auto" and %Choices.get_child_count() == 0:
		_auto_left = float(p.get("auto_wait", 1.0))


func _show_dialogue(p: Dictionary) -> void:
	var protagonist: String = GameState.protagonist_id
	var side := "none"
	if p.speaker_id != protagonist:
		var i := _slots.find(p.speaker_id)
		if i == -1:
			i = _slots.find("")
		if i == -1:
			# TODO(기획 확인): 세 번째 NPC가 말하면 더 오래 말하지 않은 쪽 자리를 넘겨준다.
			i = 0 if _slot_spoke[0] <= _slot_spoke[1] else 1
		_slots[i] = p.speaker_id
		_line_no += 1
		_slot_spoke[i] = _line_no
		side = SIDES[i]
	var line := {"text": p.text, "speaker_id": p.speaker_id, "side": side}
	# 같은 노드를 다시 보여줄 때(아이템 사용 후 등)는 대사 기록을 밀지 않는다
	if not _cur_line.is_empty() and _cur_line != line:
		_prev_line = _cur_line
	_cur_line = line

	# 초상화: 다른 NPC가 말할 때만 회색. 주인공이 말할 때는 둘 다 그대로.
	var portraits := [%PortraitLeft, %PortraitRight]
	for j in 2:
		portraits[j].show_character(DataLoader.character_name(_slots[j]), side == "none" or side == SIDES[j])
		if over_combat:
			portraits[j].visible = false
	_show_line(%Bubble, line, BUBBLE_Y, false)
	if not _prev_line.is_empty():
		_show_line(%PrevBubble, _prev_line, PREV_BUBBLE_Y, true)
		%PrevBubble.visible = true


func _show_line(bubble: Control, line: Dictionary, y: Array, dimmed: bool) -> void:
	_place(bubble, BUBBLE_X[line.side], y)
	var is_npc: bool = line.side != "none"
	bubble.show_line(line.text, line.side, dimmed,
		DataLoader.character_name(line.speaker_id) if is_npc else "",
		DataLoader.character_color(line.speaker_id) if is_npc else "")


func _place(c: Control, x: Array, y: Array) -> void:
	c.anchor_left = x[0]
	c.anchor_right = x[1]
	c.anchor_top = y[0]
	c.anchor_bottom = y[1]
	c.offset_left = 0
	c.offset_right = 0
	c.offset_top = 0
	c.offset_bottom = 0


func _update_status() -> void:
	%Stats.text = "체력 %d/%d    정신력 %d/%d    시간 %d/%d" % [
		GameState.get_stat("hp"), GameState.stat_max("hp"),
		GameState.get_stat("sanity"), GameState.stat_max("sanity"),
		GameState.get_stat("time"), GameState.stat_max("time")]
	%InventoryButton.text = "인벤토리 (%d/%d)" % [GameState.inventory.size(), GameState.slot_count()]


func _clear_choices() -> void:
	for c in %Choices.get_children():
		%Choices.remove_child(c)
		c.queue_free()
