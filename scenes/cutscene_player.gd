extends Control
## 필드 밖에서 컷신(대화)을 화면 가득 차례로 보여 주고, 끝나면 다음 화면으로 (로고·타이틀 이전·타이틀 이후).
## 검은 바탕 위에 대화 화면(scenes/main_play, 그림·자막·연출·건너뛰기 그대로). 필드 단계(걷기·카메라)는 건너뜀.
## 쓰는 법: CutscenePlayer.play_then(get_tree(), [시작 노드...], "res://scenes/다음.tscn") — 보여 줄 게 없으면 바로 다음 화면.

const SELF := "res://scenes/cutscene_player.tscn"
const DialogueScene = preload("res://scenes/main_play.tscn")
const Triggers = preload("res://core/cutscene_triggers.gd")

static var queue: Array = []
static var next_scene := ""
var ui: Control


static func play_then(tree: SceneTree, ids: Array, scene: String) -> void:
	var valid := ids.filter(func(id): return DataLoader.nodes.has(id))
	if valid.is_empty():
		tree.change_scene_to_file(scene)
		return
	queue = valid
	next_scene = scene
	tree.change_scene_to_file(SELF)


func _ready() -> void:
	set_anchors_preset(PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color.BLACK
	bg.set_anchors_preset(PRESET_FULL_RECT)
	add_child(bg)
	_play_next()


func _play_next() -> void:
	if queue.is_empty():
		get_tree().change_scene_to_file.call_deferred(next_scene)
		return
	var id: String = queue.pop_front()
	ui = DialogueScene.instantiate()
	ui.embedded = true
	ui.skip_button = not Triggers.is_logo(id)   # 로고는 버튼 없이 (Esc 로는 넘어감)
	add_child(ui)
	ui.get_node("Scene").color = Color.BLACK   # 검은 바탕 (필드 위 대화처럼 비치지 않게)
	ui.get_node("%InventoryButton").visible = false
	ui.finished.connect(func():
		ui.queue_free()
		ui = null
		_play_next.call_deferred())
	StoryRunner.start_dialogue(id)
