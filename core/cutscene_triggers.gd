extends RefCounted
## 자동 시작 컷신 (대화 에디터의 ▶ 대화 시작 카드 → '🎬 자동 시작' 토글). DataLoader.triggers 에서 지금 보여 줄 시작 노드들을 꺼낸다.
##   logo         게임을 켜자마자 (타이틀 전)          — scenes/boot
##   before_title 로고 다음, 타이틀이 나오기 전         — scenes/boot
##   after_title  타이틀에서 새 게임·새 회차·이어하기를 누른 직후 — scenes/title
##   new_game     새 게임 시작 후 (캐릭터 생성 직후, 필드가 열리면) — scenes/field
##   map_enter    그 맵에 들어올 때 (회차 시작·이동·불러오기)        — scenes/field
## once(한 번만): 로고·타이틀 이전·이후는 '처음 켤 때만' (user:// 에 기록), 방 진입은 '그 회차에 한 번' (회차 상태 field_state).
## 같은 시점에 여러 개면 대화 파일 순서대로 차례로.

const WHENS := ["logo", "before_title", "after_title", "new_game", "map_enter"]
const LABEL := {
	"logo": "로고 (게임을 켜자마자)",
	"before_title": "타이틀 이전 (로고 다음)",
	"after_title": "타이틀 이후 (새 게임·이어하기를 누르면)",
	"new_game": "새 게임 시작 후 (캐릭터 생성 직후)",
	"map_enter": "방 진입 후 (그 맵에 들어올 때)",
}


## when 시점에 보여 줄 시작 노드들 (한 번만인 것은 본 것으로 기록하고 꺼낸다)
static func take(when: String, map_id := "") -> Array:
	var out := []
	for t in DataLoader.triggers.get(when, []):
		if when == "map_enter" and t.map != map_id:
			continue
		if t.once:
			if when == "map_enter":
				if GameState.field_has(map_id, "done", "cut:" + t.node_id):
					continue
				GameState.field_mark(map_id, "done", "cut:" + t.node_id)
			elif when != "new_game":
				if seen(t.node_id):
					continue
				mark_seen(t.node_id)
		out.append(t.node_id)
	return out


static func _cfg_path() -> String:
	return SaveManager.save_dir + "seen_cutscenes.cfg"


static func seen(node_id: String) -> bool:
	var cfg := ConfigFile.new()
	cfg.load(_cfg_path())
	return cfg.get_value("seen", node_id, false)


static func mark_seen(node_id: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(_cfg_path())
	cfg.set_value("seen", node_id, true)
	DirAccess.make_dir_recursive_absolute(SaveManager.save_dir)
	cfg.save(_cfg_path())
