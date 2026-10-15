extends Node
## 게임을 켜면 처음 오는 화면: 자동 시작 컷신 '로고' → '타이틀 이전' 을 보여 준 뒤 타이틀로 (없으면 바로 타이틀).

const CutscenePlayer = preload("res://scenes/cutscene_player.gd")
const Triggers = preload("res://core/cutscene_triggers.gd")
const TITLE := "res://scenes/title.tscn"


func _ready() -> void:
	_go.call_deferred()


func _go() -> void:
	CutscenePlayer.play_then(get_tree(), Triggers.take("logo") + Triggers.take("before_title"), TITLE)
