@tool
extends RefCounted
## 대화·맵 에디터가 같이 쓰는 도우미.


## tools/xlsx_to_json.py 를 실행하고 결과 글을 log_view 에 보여준다. 성공하면 true.
## 결과는 UTF-8 로그 파일로 받는다 (윈도우 콘솔 출력 인코딩 문제를 피함). 맥은 python3, 윈도우는 python.
static func run_convert(log_view: TextEdit) -> bool:
	var script := ProjectSettings.globalize_path("res://tools/xlsx_to_json.py")
	var python := _python()
	var log_path := ProjectSettings.globalize_path("user://convert_log.txt")
	if FileAccess.file_exists(log_path):
		DirAccess.remove_absolute(log_path)
	var out := []
	var code := OS.execute(python, [script, "--log", log_path], out, true)
	if FileAccess.file_exists(log_path):
		log_view.text = FileAccess.get_file_as_string(log_path)
	else:
		var o := "\n".join(out)
		if "openpyxl" in o:
			log_view.text = "변환에 필요한 openpyxl 이 없습니다. 터미널에서 설치한 뒤 다시 누르세요:\n  %s -m pip install --user openpyxl\n\n%s" % [python, o]
		elif "Traceback" in o:
			log_view.text = "변환 스크립트가 오류로 멈췄습니다 (맨 아래 줄이 원인):\n%s" % o
		else:
			log_view.text = "변환 스크립트를 실행하지 못했습니다. %s 가 설치되어 있고 PATH 에 있는지 확인하세요.\n%s" % [python, o]
	if code == 0 and Engine.is_editor_hint():
		EditorInterface.get_resource_filesystem().scan()
	return code == 0


static var _python_found := ""


## 변환기를 돌릴 파이썬. 맥에는 파이썬이 여러 개일 수 있어서(시스템·Homebrew·python.org) openpyxl 이 깔린 것을 찾는다.
## 하나도 없으면 기본 이름(윈도우 python, 맥 python3) → 실행 오류 글에 그 이름으로 설치 안내.
static func _python() -> String:
	if _python_found != "":
		return _python_found
	var names := ["python", "py"] if OS.get_name() == "Windows" else \
		["python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3",
		"/Library/Frameworks/Python.framework/Versions/Current/bin/python3"]
	for n in names:
		if OS.execute(n, ["-c", "import openpyxl"]) == 0:
			_python_found = n
			return n
	return names[0]


const HELP_CFG := "user://editor_help.cfg"


## 사용법 칸: bar 오른쪽 끝에 '❓ 사용법' 버튼, parent 의 index 자리에 접을 수 있는 설명 칸.
## 처음에는 펼쳐 두고, 접거나 펼친 상태는 user://editor_help.cfg 에 기억한다. 만든 설명 칸을 돌려준다.
static func add_help(parent: Container, index: int, bar: HBoxContainer, key: String, bbcode: String) -> PanelContainer:
	var cfg := ConfigFile.new()
	cfg.load(HELP_CFG)
	var panel := PanelContainer.new()
	panel.name = "Help"
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.13, 0.16, 0.22)
	sb.border_color = Color(0.45, 0.6, 0.85)
	sb.set_border_width_all(1)
	sb.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", sb)
	var text := RichTextLabel.new()
	text.bbcode_enabled = true
	text.text = bbcode
	text.custom_minimum_size.y = 240
	text.selection_enabled = true
	panel.add_child(text)
	parent.add_child(panel)
	parent.move_child(panel, index)
	var btn := Button.new()
	btn.text = "❓ 사용법"
	btn.toggle_mode = true
	btn.tooltip_text = "이 에디터 쓰는 법을 펼치거나 접습니다"
	bar.add_child(btn)
	var set_open := func(open: bool):
		panel.visible = open
		btn.set_pressed_no_signal(open)
		cfg.set_value("help", key, open)
		cfg.save(HELP_CFG)
	btn.toggled.connect(set_open)
	set_open.call(bool(cfg.get_value("help", key, true)))
	return panel


## 사용법 창: bar 에 '❓ 사용법' 버튼, 누르면 설명 창이 뜬다 (화면 자리를 차지하지 않음). 만든 창을 돌려준다.
static func add_help_window(owner: Control, bar: HBoxContainer, title: String, bbcode: String) -> AcceptDialog:
	var dlg := AcceptDialog.new()
	dlg.title = title
	dlg.ok_button_text = "닫기"
	dlg.exclusive = false
	var text := RichTextLabel.new()
	text.bbcode_enabled = true
	text.text = bbcode
	text.selection_enabled = true
	text.custom_minimum_size = Vector2(900, 560)
	dlg.add_child(text)
	owner.add_child(dlg)
	var btn := Button.new()
	btn.text = "❓ 사용법"
	btn.flat = true
	btn.tooltip_text = "이 에디터 쓰는 법"
	btn.pressed.connect(func(): dlg.popup_centered())
	bar.add_child(btn)
	return dlg


## 조건·효과 고르기(addons/expr_rows.gd)와 이동 대상 목록에 쓰는 이름표들 (data/*.json 에서).
## items·survival·abilities·parts·loot·nodes: [[id, 보이는 이름]], flags·wflags·traits: [이름] (이미 쓰이는 것)
static func load_lookups() -> Dictionary:
	var lk := {"items": [], "survival": [], "abilities": [], "parts": [], "loot": [], "nodes": [], "endings": [], "statuses": [], "dests": [],
		"flags": [], "wflags": [], "traits": [], "trait_list": [], "enemies": [], "people": []}
	for i in read_json("res://data/items.json", []):
		lk.items.append([i.item_id, "%s (%s)" % [i.name, i.item_id]])
	for e in read_json("res://data/enemies.json", []):
		lk.enemies.append([e.enemy_id, "%s (%s)%s" % [e.name, e.enemy_id, " · 몬스터" if e.get("kind", "") == "monster" else ""]])
	for st in read_json("res://data/status_effects.json", []):
		lk.statuses.append([st.status_id, "%s (%s)" % [st.name, st.status_id]])
	for s in read_json("res://data/survival.json", []):
		lk.survival.append([s.param_id, s.name])
	for a in read_json("res://data/abilities.json", []):
		lk.abilities.append([a.ability_id, a.name])
	for p in read_json("res://data/player_parts.json", []):
		if not p.get("vital", false):
			lk.parts.append([p.part_id, p.name])
	var spots := {}
	for l in read_json("res://data/loot.json", []):
		if not spots.has(l.spot_id):
			spots[l.spot_id] = true
			lk.loot.append([l.spot_id, l.spot_id])
	for e in read_json("res://data/endings.json", []):
		lk.endings.append([e.ending_id, e.get("episode_id", "")])
	var names := {}
	var traits := {}
	for c in read_json("res://data/characters.json", []):
		names[c.char_id] = c.name
		for t in c.get("traits", []):
			traits[t] = true
	# 특성: player.xlsx Traits (+ 예전 데이터의 능력 이름)
	for t in read_json("res://data/traits.json", []):
		traits[t.trait_id] = true
		lk.trait_list.append([t.trait_id, "%s (%s) %+d" % [t.name, t.trait_id, int(t.points)]])
	lk.traits = traits.keys()
	lk.traits.sort()
	# 이미 쓰이는 플래그 이름 모으기
	var texts := PackedStringArray()
	for n in read_json("res://data/nodes.json", []):
		var kind: String = n.get("kind", "")
		var label := "(효과 카드)" if kind == "effect" else ("(조건 분기)" if kind == "branch" else ("▶ 대화 시작" if kind == "start" else
			"%s: %s" % [names.get(n.speaker_id, "내레이션") if n.speaker_id != "" else "내레이션", String(n.text).left(16)]))
		lk.nodes.append([n.node_id, n.get("episode_id", ""), label])
		texts.append(n.get("on_enter", ""))
		texts.append(n.get("condition", ""))
	for c in read_json("res://data/choices.json", []):
		texts.append_array([c.get("condition", ""), c.get("effects", ""), c.get("fail_effects", "")])
	for m in read_json("res://data/maps.json", []):
		lk.dests.append([m.map_id, "%s — 기본 도착(P)" % m.map_id])
		for o in m.get("objects", []):
			if o.get("type", "") == "npc":   # 연출 카드의 인물 (걷게 하기·카메라·숨기기)
				lk.people.append([o.object_id, "%s · %s" % [m.map_id, o.get("name", "") if o.get("name", "") != "" else o.object_id]])
		for o in m.get("objects", []):
			texts.append(o.get("condition", ""))
			if o.get("type", "") == "arrive":
				lk.dests.append(["%s@%s" % [m.map_id, o.object_id], "%s — %s" % [m.map_id, o.get("name", "") if o.get("name", "") != "" else o.object_id]])
	for f in ["camp_actions", "revivals"]:
		for r in read_json("res://data/%s.json" % f, []):
			texts.append_array([r.get("condition", ""), r.get("effects", "")])
	for i in read_json("res://data/items.json", []):
		texts.append(i.get("use_effects", ""))
	var all := " ".join(texts)
	var flags := {}
	var wflags := {}
	for m in RegEx.create_from_string("\\b(?:setflag|clearflag|flag):(\\w+)").search_all(all):
		flags[m.get_string(1)] = true
	for m in RegEx.create_from_string("\\b(?:setwflag|wflag):(\\w+)").search_all(all):
		wflags[m.get_string(1)] = true
	lk.flags = flags.keys()
	lk.flags.sort()
	lk.wflags = wflags.keys()
	lk.wflags.sort()
	return lk


static func read_json(path: String, default: Variant) -> Variant:
	if not FileAccess.file_exists(path):
		return default
	var v = JSON.parse_string(FileAccess.get_file_as_string(path))
	return v if v != null else default
