extends RefCounted
## 🎬 연출 카드 (노드 kind = direct)의 단계 목록 규칙. 런타임(main_play·field)·대화 에디터·테스트가 같이 쓴다.
## 노드 `steps`: [{do, ...}] — 위에서부터 차례로 실행 (walk 의 wait=false 만 기다리지 않고 다음으로).
##   화면 (대화 화면이 처리 — 어디서든):
##     image     {file, fade}      직접 만든 그림을 화면 가득 (art/cutscenes/<file>). 대사 상자는 그 위에 뜬다
##     image_off {fade}            그림 내리기
##     fade      {to, time}        to = black / white (화면 덮기) / clear (걷기)
##     shake     {power, time}     화면 흔들기 (power 1~3)
##     wait      {time}            기다리기 (초)
##   필드 (탐험 화면이 처리 — 대화 에디터 미리보기에서는 건너뜀):
##     walk      {who, to:[x,y], speed, wait}   who = player 또는 맵 물체 object_id(NPC), to 까지 길을 찾아 걷기 (칸/초)
##     camera    {who 또는 to:[x,y], time}       카메라를 그 칸(또는 그 인물)으로. who = player 면 다시 플레이어를 따라감
##     vanish    {who}                           그 NPC 를 숨김 (이번에 맵에 있는 동안 — 계속 없애려면 플래그 + 나타나는 조건)
## 연출 카드가 돌아가는 동안 플레이어는 조작할 수 없고(대화 중), 대사 상자는 숨는다.

const CUTSCENE_DIR := "res://art/cutscenes/"
const SCREEN_STEPS := ["image", "image_off", "fade", "shake", "wait"]
const FIELD_STEPS := ["walk", "camera", "vanish"]
const LABEL := {
	"image": "🖼 그림 띄우기", "image_off": "그림 내리기", "fade": "페이드 (검게·하얗게·걷기)", "shake": "화면 흔들기",
	"wait": "기다리기", "walk": "🚶 걷게 하기 (필드)", "camera": "🎥 카메라 옮기기 (필드)", "vanish": "NPC 숨기기 (필드)",
}
const FADE_TO := ["black", "white", "clear"]
## 단계마다 기본값 (에디터에서 새로 추가할 때·빠진 칸 채우기)
const DEFAULTS := {
	"image": {"file": "", "fade": 0.5},
	"image_off": {"fade": 0.5},
	"fade": {"to": "black", "time": 0.6},
	"shake": {"power": 1.0, "time": 0.4},
	"wait": {"time": 1.0},
	"walk": {"who": "player", "to": [0, 0], "speed": 3.0, "wait": true},
	"camera": {"who": "", "to": [0, 0], "time": 1.0},
	"vanish": {"who": ""},
}


static func normalize(s: Dictionary) -> Dictionary:
	var out: Dictionary = DEFAULTS.get(str(s.get("do", "")), {}).duplicate(true)
	for k in s:
		out[k] = s[k]
	return out


## 그림 파일 목록 (art/cutscenes/ 의 png·jpg·webp)
static func image_files() -> Array:
	var out := []
	for f in DirAccess.get_files_at(CUTSCENE_DIR):
		if f.get_extension().to_lower() in ["png", "jpg", "jpeg", "webp"]:
			out.append(f)
	out.sort()
	return out


## 그림 불러오기: 가져오기(import)된 리소스가 있으면 그것, 없으면 파일을 직접 읽는다 (테스트·처음 넣은 그림)
static func load_image(file: String) -> Texture2D:
	var path := CUTSCENE_DIR + file
	if ResourceLoader.exists(path):
		return load(path)
	var img := Image.load_from_file(ProjectSettings.globalize_path(path))
	return ImageTexture.create_from_image(img) if img and not img.is_empty() else null
