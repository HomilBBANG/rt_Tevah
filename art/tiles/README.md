# 타일 그림

픽셀아트 타일(한 칸 = 16x16 px, 엑셀 graphics.xlsx Config 의 tile_art_px)을 png 로 넣고,
`tools/sheets/graphics.xlsx` 의 `Tiles` 시트에 한 줄씩 등록한다 (tile_key, 이름, 층, 파일, 칸 위치 atlas_x·atlas_y).
한 그림에 여러 타일을 격자로 넣어도 된다 (atlas_x·atlas_y = 몇 번째 칸).
게임에서는 5배(80px)로, 흐림 없이(nearest) 그려진다.

`test_tiles.png` 는 테스트용 더미 타일 (바닥 4 · 벽 2 · 장식 2).
