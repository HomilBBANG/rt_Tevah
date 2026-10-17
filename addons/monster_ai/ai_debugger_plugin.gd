@tool
extends EditorDebuggerPlugin
## 게임(F5·맵 테스트 플레이)이 보내는 "monster_ai:snapshot" 을 받아 '몬스터 AI' 탭의 Debugger 로 넘긴다.
## (게임 쪽 보내기: scenes/field/field.gd _process → ai_snapshot)

var panel: Control   # ai_editor.gd


func _has_capture(prefix: String) -> bool:
	return prefix == "monster_ai"


func _capture(message: String, data: Array, _session_id: int) -> bool:
	if message == "monster_ai:snapshot" and panel and not data.is_empty():
		panel.on_snapshot(data[0])
		return true
	return false


func _setup_session(session_id: int) -> void:
	var s := get_session(session_id)
	s.started.connect(func():
		if panel:
			panel.send_breakpoints.call_deferred())   # 게임이 켜지면 지금 브레이크포인트를 알려 줌
	s.stopped.connect(func():
		if panel:
			panel.on_session_stopped())
