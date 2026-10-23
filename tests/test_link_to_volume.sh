#!/bin/bash
# check の第2引数は eval で後から評価するため、あえてシングルクォートで渡している
# shellcheck disable=SC2016,SC2034
# provision.sh の link_to_volume をダミーディレクトリで検証する（RunPod 不要）
# 使い方: bash tests/test_link_to_volume.sh
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
eval "$(sed -n '/^link_to_volume() {/,/^}/p' "$HERE/../provision.sh")"
declare -F link_to_volume >/dev/null || { echo "link_to_volume が provision.sh に見つからない"; exit 1; }

FAIL=0
ok()   { echo "ok   - $1"; }
ng()   { echo "FAIL - $1"; FAIL=1; }
check() { if eval "$2"; then ok "$1"; else ng "$1"; fi; }
is_link_to() { [ -L "$1" ] && [ "$(readlink -f "$1")" = "$(readlink -f "$2")" ]; }

setup() {
  T=$(mktemp -d); C=$T/ComfyUI; V=$T/workspace
  mkdir -p "$C/output" "$C/models/loras" "$V"
  touch "$C/output/_output_images_will_be_put_here" "$C/models/loras/put_loras_here"
}

echo "# 1. clone 直後（プレースホルダ入りの実ディレクトリ）"
setup
link_to_volume "$C/output" "$V/outputs"; rc=$?
check "成功を返す" '[ $rc -eq 0 ]'
check "output が Volume へのリンクになる" 'is_link_to "$C/output" "$V/outputs"'
check "中に outputs リンクが作られない（v2 の不具合）" '[ ! -e "$V/outputs/outputs" ]'
check "プレースホルダは Volume に持ち込まない" '[ ! -e "$V/outputs/_output_images_will_be_put_here" ]'
echo song > "$C/output/song.flac"
check "書き込みが Volume に届く" '[ -f "$V/outputs/song.flac" ]'
link_to_volume "$C/models/loras" "$V/models/loras"
check "models/loras も同様にリンクになる" 'is_link_to "$C/models/loras" "$V/models/loras" && [ ! -e "$V/models/loras/put_loras_here" ]'

echo "# 2. 再実行（既にリンク済み）"
link_to_volume "$C/output" "$V/outputs"; rc=$?
check "成功を返す" '[ $rc -eq 0 ]'
check "リンクのまま・生成物も残る" 'is_link_to "$C/output" "$V/outputs" && [ -f "$V/outputs/song.flac" ]'
check "退避ディレクトリは作られない" '! ls -d "$C"/output.local-backup-* >/dev/null 2>&1'
rm -rf "$T"

echo "# 3. v2 で壊れた状態から再実行（output/ 実体に生成物 + outputs リンク）"
setup
mkdir -p "$V/outputs"; ln -s "$V/outputs" "$C/output/outputs"
echo local > "$C/output/lost_song.flac"; mkdir "$C/output/sub"; echo x > "$C/output/sub/a.flac"; touch "$C/output/.hidden"
link_to_volume "$C/output" "$V/outputs"; rc=$?
check "成功を返す" '[ $rc -eq 0 ]'
check "output が Volume へのリンクになる" 'is_link_to "$C/output" "$V/outputs"'
check "Podローカルに取り残された生成物を Volume へ救出" '[ -f "$V/outputs/lost_song.flac" ] && [ -f "$V/outputs/sub/a.flac" ] && [ -e "$V/outputs/.hidden" ]'
check "Volume 側に自己参照リンクを作らない" '[ ! -e "$V/outputs/outputs" ] && [ ! -L "$V/outputs/outputs" ]'
rm -rf "$T"

echo "# 4. 同名ファイルが Volume 側にもある"
setup
mkdir -p "$V/outputs"; echo volume > "$V/outputs/song.flac"; echo local > "$C/output/song.flac"
link_to_volume "$C/output" "$V/outputs"; rc=$?
check "成功を返す" '[ $rc -eq 0 ]'
check "Volume 側は上書きされない" '[ "$(cat "$V/outputs/song.flac")" = volume ]'
check "ローカル側は退避ディレクトリに残る" '[ "$(cat "$C"/output.local-backup-*/song.flac)" = local ]'
check "output が Volume へのリンクになる" 'is_link_to "$C/output" "$V/outputs"'
rm -rf "$T"

echo "# 5. 存在しない / 別の場所へのリンク / ただのファイル"
setup
rm -rf "$C/output"
link_to_volume "$C/output" "$V/outputs"
check "無ければ作る" 'is_link_to "$C/output" "$V/outputs"'
rm "$C/output"; mkdir "$T/elsewhere"; ln -s "$T/elsewhere" "$C/output"
link_to_volume "$C/output" "$V/outputs"
check "別の場所へのリンクは張り替える" 'is_link_to "$C/output" "$V/outputs"'
rm "$C/output"; echo file > "$C/output"
link_to_volume "$C/output" "$V/outputs"
check "ファイルは退避してリンクにする" 'is_link_to "$C/output" "$V/outputs" && [ "$(cat "$C"/output.local-backup-*)" = file ]'
rm -rf "$T"

if [ "$(id -u)" -ne 0 ]; then
  echo "# 6. 置き換えられないときは失敗を返す"
  setup
  echo local > "$C/output/song.flac"; mkdir -p "$V/outputs"; echo volume > "$V/outputs/song.flac"
  chmod a-w "$C"
  link_to_volume "$C/output" "$V/outputs" 2>/dev/null; rc=$?
  chmod u+w "$C"
  check "失敗を返す" '[ $rc -ne 0 ]'
  check "ローカルの生成物は消さない" '[ "$(cat "$C/output/song.flac")" = local ]'
  rm -rf "$T"

  echo "# 7. Volume に書き込めないときは置き換えずに失敗を返す"
  setup
  echo local > "$C/output/song.flac"; mkdir -p "$V/outputs"; chmod a-w "$V/outputs"
  link_to_volume "$C/output" "$V/outputs" 2>/dev/null; rc=$?
  chmod u+w "$V/outputs"
  check "失敗を返す" '[ $rc -ne 0 ]'
  check "output は実ディレクトリのまま・生成物も残る" '[ -d "$C/output" ] && [ ! -L "$C/output" ] && [ "$(cat "$C/output/song.flac")" = local ]'
  rm -rf "$T"
else
  echo "# 6-7. root では権限エラーを再現できないためスキップ"
fi

if [ $FAIL -eq 0 ]; then echo "ALL PASSED"; else echo "SOME FAILED"; exit 1; fi
