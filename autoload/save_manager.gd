extends Node
## user:// 에 월드 상태 파일 1개 + 에피소드별 진행 파일을 따로 저장한다.
##   user://saves/world.json            월드 플래그
##   user://saves/episode_<id>.json     진행 중인 에피소드 (노드·스탯·인벤토리·에피소드 플래그)
##   user://saves/run_<1~5>.json        탐험 회차 저장 슬롯 (베이스캠프에서만, 저장할 때마다 슬롯 선택. 사망해도 지우지 않음)
## 엔딩에 도달하면 해당 에피소드 진행 파일은 지운다.

var save_dir := "user://saves/"   # 테스트에서 바꿔 쓴다


func _ready() -> void:
	_migrate_old_save()
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
## 저장 슬롯 1 ~ save_slots. 저장할 때마다 슬롯을 고른다 (잠·고양이). 0 은 '아무 슬롯'.
func slot_count() -> int:
	return maxi(1, DataLoader.get_config_int("save_slots", 5))


func slot_path(slot: int) -> String:
	return save_dir + "run_%d.json" % slot


func has_run_save(slot := 0) -> bool:
	if slot > 0:
		return FileAccess.file_exists(slot_path(slot))
	for i in range(1, slot_count() + 1):
		if FileAccess.file_exists(slot_path(i)):
			return true
	return false


## 슬롯 목록 표시용: { day, time, map_id, run_count, saved_at, saved_unix } (비었으면 {})
func slot_info(slot: int) -> Dictionary:
	var d = _read(slot_path(slot)) if has_run_save(slot) else null
	return d.get("meta", {}) if d is Dictionary else {}


## 가장 최근에 저장한 슬롯 (없으면 0)
func latest_slot() -> int:
	var best := 0
	var best_t := -1.0
	for i in range(1, slot_count() + 1):
		var t := float(slot_info(i).get("saved_unix", -1.0))
		if t > best_t:
			best = i
			best_t = t
	return best


## 탐험 회차는 베이스캠프에서만 저장할 수 있다 (§13)
func can_save_run() -> bool:
	return GameState.current_map != "" and GameState.current_map == DataLoader.get_config_str("basecamp_map")


## can_save_run() 을 확인한 뒤 부른다
func save_run(slot: int) -> void:
	var d := GameState.run_to_dict()
	d.meta = {"day": GameState.day(), "time": GameState.clock_text(), "map_id": GameState.current_map,
		"run_count": GameState.run_count, "saved_at": Time.get_datetime_string_from_system(false, true),
		"saved_unix": Time.get_unix_time_from_system()}
	_write(slot_path(slot), d)


func load_run(slot: int) -> bool:
	var d = _read(slot_path(slot))
	if not d is Dictionary or not DataLoader.maps.has(d.get("current_map", "")):
		return false
	GameState.run_from_dict(d)
	return true


func delete_run_save(slot: int) -> void:
	if has_run_save(slot):
		DirAccess.remove_absolute(slot_path(slot))


## 슬롯 도입 전 저장(run.json)은 빈 슬롯 1로 옮긴다
func _migrate_old_save() -> void:
	var old := save_dir + "run.json"
	if FileAccess.file_exists(old) and not FileAccess.file_exists(slot_path(1)):
		DirAccess.rename_absolute(old, slot_path(1))


## 새 회차: 회차 수를 늘리고 처음 상태로 (월드 상태 유지). 저장 슬롯은 지우지 않고, 새 회차에서 저장하면 덮어쓴다.
func begin_run() -> void:
	GameState.reset_run()
	GameState.run_count += 1
	save_world()


## 부활 없는 사망: 게임 처음부터. 저장 슬롯은 지우지 않는다 (기획 변경 — 기획서 §13 의 '죽음 취소 불가'와 다름).
func end_run() -> void:
	GameState.death_count += 1
	save_world()


## 부활(초월체·아이템): 저장은 그대로, 사망 횟수만 센다. 모두 유지한 채 베이스캠프에서 깨어남.
func revive_run() -> void:
	GameState.death_count += 1
	GameState.restore_after_revival()
	save_world()


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
