@tool
extends EditorPlugin
## Godot 에디터 위쪽에 '대화' 탭을 추가한다 (2D·3D·Script 옆).

const EditorPanel = preload("res://addons/dialogue_editor/dialogue_editor.gd")

var panel: Control


func _enter_tree() -> void:
	panel = EditorPanel.new()
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	EditorInterface.get_editor_main_screen().add_child(panel)
	_make_visible(false)


func _exit_tree() -> void:
	if panel:
		panel.queue_free()


func _has_main_screen() -> bool:
	return true


func _make_visible(visible: bool) -> void:
	if panel:
		panel.visible = visible
		if visible:
			panel.refresh_file_list()


func _get_plugin_name() -> String:
	return "대화"


func _get_plugin_icon() -> Texture2D:
	return EditorInterface.get_editor_theme().get_icon("GraphEdit", "EditorIcons")
