extends RefCounted
## 🎬 연출 카드 (노드 kind = direct)의 단계 목록 규칙. 런타임(main_play·field)·대화 에디터·테스트가 같이 쓴다.
## 노드 `steps`: [{do, ...}] — 위에서부터 차례로 실행 (walk 의 wait=false 만 기다리지 않고 다음으로).
##   화면 (대화 화면이 처리 — 어디서든):
##     image     {file, fade}      직접 만든 그림을 화면 가득 (art/cutscenes/<file>). 대사 상자는 그 위에 뜬다
##     image_off {fade}            그림 내리기
##     screen    {color, fade}     색 화면 (검은 화면·아무 색, "#RRGGBB") — 그림 칸처럼 대사 상자 아래, 그 위에 글을 띄울 수 있음
##     screen_off {fade}           색 화면 내리기
##     fade      {to, time}        to = black / white (화면 덮기) / clear (걷기)
##     shake     {power, time, speed, wait}  화면 흔들기 (power 0.1~3, time 초 — 0 = 멈출 때까지 계속(손떨림), speed = 초당 흔들림 수 1~60)
##     shake_off {}                계속 흔들기 멈춤
##     wait      {time}            기다리기 (초)
##     sound     {file, volume}    효과음 한 번 (audio/sfx/<file>, volume 0~100 %)
##     music     {file, fade, volume}  배경음 틀기 (audio/bgm/<file>, 반복) — 대화가 끝나도 계속, 끄려면 music_off
##     music_off {fade}            배경음 끄기
##   필드 (탐험 화면이 처리 — 대화 에디터 미리보기에서는 건너뜀):
##     walk      {who, to:[x,y], speed, wait}   who = player 또는 맵 물체 object_id(NPC), to 까지 길을 찾아 걷기 (칸/초)
##     zoom      {scale, time, wait}  확대·축소 — scale = 도트 배율(그림 1px = 화면 몇 px, 0 = 기본 field_tile/tile_art_px). 딱 떨어지는 배율로만, time 동안 한 단계씩
##     camera    {who 또는 to:[x,y], time, from?:[x,y], ease?, follow?, wait?}  follow = 그 인물(NPC)을 계속 따라감, wait=false = 기다리지 않고 다음 단계  카메라를 그 칸(또는 그 인물)으로 time 초 동안. from 이 있으면 먼저 그 칸으로 바로.
##                                               who = player 면 플레이어까지 움직인 뒤 다시 따라감. ease = smooth(천천히 시작·끝, 기본) / linear
##     vanish    {who}                           그 NPC 를 숨김 (이번에 맵에 있는 동안 — 계속 없애려면 플래그 + 나타나는 조건)
##     face      {who, dir}                      바라보는 방향 (up / down / left / right). 걸을 때는 가는 쪽을 저절로 봄
## 건너뛰기(대화 화면의 '건너뛰기' 버튼·Esc): 단계에 "_instant": true 를 붙여 바로 끝난 모습으로 (기다림·흔들기·효과음은 생략).
## 연출 카드가 돌아가는 동안 플레이어는 조작할 수 없고(대화 중), 대사 상자는 숨는다.

const CUTSCENE_DIR := "res://art/cutscenes/"
const SFX_DIR := "res://audio/sfx/"
const BGM_DIR := "res://audio/bgm/"
const SCREEN_STEPS := ["image", "image_off", "screen", "screen_off", "fade", "shake", "shake_off", "wait", "sound", "music", "music_off"]
const FIELD_STEPS := ["walk", "camera", "zoom", "vanish", "face"]
const DIRS := ["up", "down", "left", "right"]
const DIR_VEC := {"up": Vector2.UP, "down": Vector2.DOWN, "left": Vector2.LEFT, "right": Vector2.RIGHT}
const LABEL := {
	"image": "🖼 그림 띄우기", "image_off": "그림 내리기", "screen": "■ 색 화면 띄우기", "screen_off": "색 화면 내리기", "fade": "페이드 (검게·하얗게·걷기)", "shake": "화면 흔들기", "shake_off": "흔들기 멈춤",
	"wait": "기다리기", "sound": "🔊 효과음", "music": "🎵 배경음 틀기", "music_off": "배경음 끄기",
	"walk": "🚶 걷게 하기 (필드)", "face": "↻ 바라보기 (필드)", "camera": "🎥 카메라 옮기기 (필드)", "zoom": "🔍 확대·축소 (필드)", "vanish": "NPC 숨기기 (필드)",
}
const FADE_TO := ["black", "white", "clear"]
## 단계마다 기본값 (에디터에서 새로 추가할 때·빠진 칸 채우기)
const DEFAULTS := {
	"image": {"file": "", "fade": 0.5},
	"image_off": {"fade": 0.5},
	"screen": {"color": "#000000", "fade": 0.5},
	"screen_off": {"fade": 0.5},
	"fade": {"to": "black", "time": 0.6},
	"shake": {"power": 1.0, "time": 0.4, "speed": 30.0, "wait": true},
	"shake_off": {},
	"wait": {"time": 1.0},
	"sound": {"file": "", "volume": 100.0},
	"music": {"file": "", "fade": 1.0, "volume": 100.0},
	"music_off": {"fade": 1.0},
	"face": {"who": "player", "dir": "down"},
	"walk": {"who": "player", "to": [0, 0], "speed": 3.0, "wait": true},
	"camera": {"who": "", "to": [0, 0], "time": 1.0, "wait": true},
	"zoom": {"scale": 0, "time": 0.5, "wait": true},
	"vanish": {"who": ""},
}


static func normalize(s: Dictionary) -> Dictionary:
	var out: Dictionary = DEFAULTS.get(str(s.get("do", "")), {}).duplicate(true)
	for k in s:
		out[k] = s[k]
	return out


## 자동 시작 컷신이 '덮인 화면'으로 시작해야 하나: 시작 노드에서 (대화 시작·효과 카드를 지나) 처음 만나는 연출 카드의
## 첫 단계가 검게·하얗게 덮기(fade) 또는 색 화면(screen)이면 → {layer: "fade"/"screen", color}. 아니면 {}.
## 필드가 열리자마자 맵이 잠깐 보였다가 검게 덮이는 것을 막는다 (맵은 연출이 걷어낼 때 처음 보임).
static func opening_cover(start_id: String) -> Dictionary:
	var id := start_id
	for i in 12:
		var n: Dictionary = DataLoader.nodes.get(id, {})
		var kind := str(n.get("kind", ""))
		if n.is_empty() or not kind in ["start", "effect", "direct"]:
			return {}
		if kind == "direct":
			var steps: Array = n.get("steps", [])
			if not steps.is_empty():
				var s := normalize(steps[0])
				if s.do == "fade" and s.to in ["black", "white"]:
					return {"layer": "fade", "color": Color.WHITE if s.to == "white" else Color.BLACK}
				if s.do == "screen":
					return {"layer": "screen", "color": Color.html(str(s.color)) if Color.html_is_valid(str(s.color)) else Color.BLACK}
				return {}
		id = str(n.get("next_node", ""))
	return {}


## 그림 파일 목록 (art/cutscenes/ 의 png·jpg·webp)
static func image_files() -> Array:
	return _files(CUTSCENE_DIR, ["png", "jpg", "jpeg", "webp"])


## 소리 파일 목록 (audio/sfx/ 또는 audio/bgm/ 의 ogg·wav·mp3)
static func audio_files(dir: String) -> Array:
	return _files(dir, ["ogg", "wav", "mp3"])


static func _files(dir: String, exts: Array) -> Array:
	var out := []
	for f in DirAccess.get_files_at(dir):
		if f.get_extension().to_lower() in exts:
			out.append(f)
	out.sort()
	return out


## 소리 불러오기: 가져오기(import)된 리소스가 있으면 그것, 없으면 파일을 직접 읽는다
static func load_audio(path: String) -> AudioStream:
	if ResourceLoader.exists(path):
		return load(path)
	var full := ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(full):
		return null
	match path.get_extension().to_lower():
		"ogg": return AudioStreamOggVorbis.load_from_file(full)
		"wav": return AudioStreamWAV.load_from_file(full)
		"mp3":
			var mp3 := AudioStreamMP3.new()
			mp3.data = FileAccess.get_file_as_bytes(full)
			return mp3
	return null


## 그림 불러오기: 가져오기(import)된 리소스가 있으면 그것, 없으면 파일을 직접 읽는다 (테스트·처음 넣은 그림)
static func load_image(file: String) -> Texture2D:
	var path := CUTSCENE_DIR + file
	if ResourceLoader.exists(path):
		return load(path)
	var img := Image.load_from_file(ProjectSettings.globalize_path(path))
	return ImageTexture.create_from_image(img) if img and not img.is_empty() else null
