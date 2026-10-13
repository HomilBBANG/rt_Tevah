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


static func read_json(path: String, default: Variant) -> Variant:
	if not FileAccess.file_exists(path):
		return default
	var v = JSON.parse_string(FileAccess.get_file_as_string(path))
	return v if v != null else default
