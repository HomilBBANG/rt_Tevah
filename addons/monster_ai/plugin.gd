@tool
extends EditorPlugin
## Godot 에디터 위쪽에 '몬스터 AI' 탭을 추가한다 (맵·대화 옆). 저장 안 한 자산이 있으면 닫을 때 Godot 가 묻는다.

const EditorPanel = preload("res://addons/monster_ai/ai_editor.gd")
const DebuggerPlugin = preload("res://addons/monster_ai/ai_debugger_plugin.gd")

var panel: Control
var debugger: EditorDebuggerPlugin


func _enter_tree() -> void:
	panel = EditorPanel.new()
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	EditorInterface.get_editor_main_screen().add_child(panel)
	_make_visible(false)
	debugger = DebuggerPlugin.new()   # 게임 실행 중 BT 몬스터 상태 받기 (Runtime Debugger)
	debugger.panel = panel
	add_debugger_plugin(debugger)


func _exit_tree() -> void:
	if debugger:
		remove_debugger_plugin(debugger)
		debugger = null
	if panel:
		panel.queue_free()


func _has_main_screen() -> bool:
	return true


func _make_visible(visible: bool) -> void:
	if panel:
		panel.visible = visible


func _get_plugin_name() -> String:
	return "몬스터 AI"


func _get_plugin_icon() -> Texture2D:
	return EditorInterface.get_editor_theme().get_icon("NavigationAgent2D", "EditorIcons")


func _get_unsaved_status(_for_scene: String) -> String:
	if panel and panel.has_unsaved():
		return "몬스터 AI 자산에 저장하지 않은 변경이 있습니다. 저장할까요?"
	return ""


func _save_external_data() -> void:
	if panel and panel.has_unsaved():
		panel.save()
