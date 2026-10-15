extends Node
## 소리 (autoload Sound): 효과음(audio/sfx/)과 배경음(audio/bgm/). 🎬 연출 카드의 sound·music·music_off 가 쓴다.
## 배경음은 화면이 바뀌어도(대화가 끝나도) 계속 반복되고, music_off 나 다른 배경음이 나올 때까지 이어진다.
## TODO(기획): 게임 옵션의 음량 (지금은 단계마다 volume % 만)

const Direction = preload("res://core/direction.gd")

var music_file := ""            # 지금 틀어 둔 배경음 (테스트·저장용)
var _music: AudioStreamPlayer
var _music_tween: Tween
var _sfx: Array = []            # 효과음 플레이어 (겹쳐 날 수 있게 여럿)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_music = AudioStreamPlayer.new()
	_music.finished.connect(func(): if music_file != "": _music.play())   # 반복
	add_child(_music)


func play_sfx(file: String, volume := 100.0) -> void:
	var stream := Direction.load_audio(Direction.SFX_DIR + file)
	if stream == null:
		push_warning("[Sound] 효과음을 찾을 수 없음: %s" % file)
		return
	var p: AudioStreamPlayer = null
	for x in _sfx:
		if not x.playing:
			p = x
			break
	if p == null:
		p = AudioStreamPlayer.new()
		add_child(p)
		_sfx.append(p)
	p.stream = stream
	p.volume_db = _db(volume)
	p.play()


## 배경음 틀기 (fade 초 동안 커짐). 이미 다른 곡이 나오면 그 곡을 줄이고 바꾼다
func play_music(file: String, fade := 1.0, volume := 100.0) -> void:
	var stream := Direction.load_audio(Direction.BGM_DIR + file)
	if stream == null:
		push_warning("[Sound] 배경음을 찾을 수 없음: %s" % file)
		return
	if music_file != "" and _music.playing and fade > 0.0:
		await _fade_to(-60.0, fade / 2.0)
		fade /= 2.0
	music_file = file
	_music.stream = stream
	_music.volume_db = -60.0 if fade > 0.0 else _db(volume)
	_music.play()
	if fade > 0.0:
		await _fade_to(_db(volume), fade)


func stop_music(fade := 1.0) -> void:
	music_file = ""
	if fade > 0.0 and _music.playing:
		await _fade_to(-60.0, fade)
	_music.stop()


func _fade_to(db: float, time: float) -> void:
	if _music_tween and _music_tween.is_valid():
		_music_tween.kill()
	_music_tween = create_tween()
	_music_tween.tween_property(_music, "volume_db", db, time)
	await _music_tween.finished


static func _db(percent: float) -> float:
	return linear_to_db(clampf(percent, 0.0, 100.0) / 100.0) if percent > 0.0 else -80.0
