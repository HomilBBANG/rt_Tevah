@tool
extends RefCounted
## 대화·맵 에디터가 같이 쓰는 도우미.


## tools/xlsx_to_json.py 를 실행하고 결과 글을 log_view 에 보여준다. 성공하면 true.
## 결과는 UTF-8 로그 파일로 받는다 (윈도우 콘솔 출력 인코딩 문제를 피함). 맥은 python3, 윈도우는 python.
static func run_convert(log_view: TextEdit) -> bool:
	var script := ProjectSettings.globalize_path("res://tools/xlsx_to_json.py")
	var python := "python" if OS.get_name() == "Windows" else "python3"
	var log_path := ProjectSettings.globalize_path("user://convert_log.txt")
	if FileAccess.file_exists(log_path):
		DirAccess.remove_absolute(log_path)
	var out := []
	var code := OS.execute(python, [script, "--log", log_path], out, true)
	if FileAccess.file_exists(log_path):
		log_view.text = FileAccess.get_file_as_string(log_path)
	else:
		log_view.text = "변환 스크립트를 실행하지 못했습니다. %s 가 설치되어 있고 PATH 에 있는지 확인하세요.\n%s" % [python, "\n".join(out)]
	if code == 0 and Engine.is_editor_hint():
		EditorInterface.get_resource_filesystem().scan()
	return code == 0


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


static func read_json(path: String, default: Variant) -> Variant:
	if not FileAccess.file_exists(path):
		return default
	var v = JSON.parse_string(FileAccess.get_file_as_string(path))
	return v if v != null else default
