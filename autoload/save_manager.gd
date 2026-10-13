extends Node
## user:// 에 월드 상태 파일 1개 + 에피소드별 진행 파일을 따로 저장한다.
##   user://saves/world.json            월드 플래그
##   user://saves/episode_<id>.json     진행 중인 에피소드 (노드·스탯·인벤토리·에피소드 플래그)
##   user://saves/run.json              탐험 회차 (베이스캠프에서만 저장, 사망하면 삭제 — 기획서 §13)
## 엔딩에 도달하면 해당 에피소드 진행 파일은 지운다.

var save_dir := "user://saves/"   # 테스트에서 바꿔 쓴다


func _ready() -> void:
	load_world()


func world_path() -> String:
	return save_dir + "world.json"


func episode_path(episode_id: String) -> String:
	return save_dir + "episode_%s.json" % episode_id


func save_world() -> void:
	_write(world_path(), GameState.world_to_dict())


func load_world() -> void:
	var d = _read(world_path())
	GameState.world_from_dict(d if d is Dictionary else {})


func save_episode() -> void:
	if GameState.episode_id == "":
		return
	_write(episode_path(GameState.episode_id), GameState.episode_to_dict())


func has_episode_save(episode_id: String) -> bool:
	return FileAccess.file_exists(episode_path(episode_id))


## 성공하면 true. 저장된 노드가 데이터에서 사라졌으면 false.
func load_episode(episode_id: String) -> bool:
	var d = _read(episode_path(episode_id))
	if not d is Dictionary:
		return false
	if not DataLoader.episodes.has(d.get("episode_id", "")):
		push_error("[SaveManager] 저장된 에피소드가 데이터에 없음: %s" % d.get("episode_id", ""))
		return false
	if not DataLoader.nodes.has(d.get("node_id", "")):
		push_error("[SaveManager] 저장된 노드가 데이터에 없음: %s" % d.get("node_id", ""))
		return false
	GameState.episode_from_dict(d)
	return true


func delete_episode_save(episode_id: String) -> void:
	if has_episode_save(episode_id):
		DirAccess.remove_absolute(episode_path(episode_id))


# ---------------------------------------------------------------- 탐험 회차 (§11, §13)
func run_path() -> String:
	return save_dir + "run.json"


func has_run_save() -> bool:
	return FileAccess.file_exists(run_path())


## 베이스캠프에서만 부른다
func save_run() -> void:
	_write(run_path(), GameState.run_to_dict())


func load_run() -> bool:
	var d = _read(run_path())
	if not d is Dictionary or not DataLoader.maps.has(d.get("current_map", "")):
		return false
	GameState.run_from_dict(d)
	return true


## 새 회차: 이전 회차 저장을 지우고 회차 수를 늘린다 (월드 상태는 유지)
func begin_run() -> void:
	delete_run_save()
	GameState.reset_run()
	GameState.run_count += 1
	save_world()


## 사망: 회차 저장을 지워 죽음을 되돌릴 수 없게 한다
func end_run() -> void:
	delete_run_save()
	save_world()


func delete_run_save() -> void:
	if has_run_save():
		DirAccess.remove_absolute(run_path())


## 모든 저장 삭제 (테스트·초기화용)
func delete_all() -> void:
	var dir := DirAccess.open(save_dir)
	if dir:
		for f in dir.get_files():
			if f.ends_with(".json"):
				dir.remove(f)
	GameState.world_from_dict({})


func _write(path: String, data: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(save_dir)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("[SaveManager] 저장 실패: %s (%s)" % [path, error_string(FileAccess.get_open_error())])
		return
	f.store_string(JSON.stringify(data, " ", true, true))   # full_precision: 생존 수치(소수) 그대로


func _read(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed == null:
		push_error("[SaveManager] 저장 파일 손상: %s" % path)
	return parsed
