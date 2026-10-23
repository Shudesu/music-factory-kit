#!/bin/bash
# check の第2引数は eval で後から評価するため、あえてシングルクォートで渡している
# shellcheck disable=SC2016,SC2034,SC2329
# provision.sh のモデル取得（download_model / ensure_models）をローカル HTTP サーバーで検証する（RunPod・本物の20GB 不要）
# 使い方: bash tests/test_download_models.sh
#        bash tests/test_download_models.sh --online   # 追加で、ACE_MODELS のパスとサイズが HF 上の実物と一致するか API で確認（ダウンロードはしない）
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
eval "$(sed -n -e "/^ACE_MODELS='/,/^'/p" -e '/^MODEL_BASE=/p' -e '/^fsize() /p' \
  -e '/^download_model() {/,/^}/p' -e '/^ensure_models() {/,/^}/p' "$HERE/../provision.sh")"
for f in download_model ensure_models fsize; do
  declare -F "$f" >/dev/null || { echo "$f が provision.sh に見つからない"; exit 1; }
done
REAL_MODELS=$ACE_MODELS REAL_BASE=$MODEL_BASE
export MFK_RETRY_WAIT=0

FAIL=0
ok()   { echo "ok   - $1"; }
ng()   { echo "FAIL - $1"; FAIL=1; }
check() { if eval "$2"; then ok "$1"; else ng "$1"; fi; }
reqs() { grep -c "$1" "$LOG"; }  # ログ中で $1 を含むリクエスト数

if [ "${1:-}" = --online ]; then
  echo "# 0. ACE_MODELS が HF 上の実ファイルと一致するか（${REAL_BASE}）"
  repo=${REAL_BASE#https://huggingface.co/}; rev=${repo##*/resolve/}; repo=${repo%%/resolve/*}
  tree=$(curl -fsSL "https://huggingface.co/api/models/$repo/tree/$rev?recursive=true") || { ng "HF API に届かない"; exit 1; }
  while read -r path size; do
    [ -n "$path" ] || continue
    real=$(printf '%s' "$tree" | python3 -c 'import json,sys; print({e["path"]: e.get("size") for e in json.load(sys.stdin)}.get(sys.argv[1], "なし"))' "$path")
    check "$path = $size バイト（HF: ${real}）" '[ "$real" = "$size" ]'
  done <<< "$REAL_MODELS"
fi

T=$(mktemp -d); SRV=$T/srv; LOG=$T/requests.log; M=$T/models
trap 'kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$SRV/checkpoints" "$SRV/split_files/vae" "$SRV/split_files/text_encoders"
head -c 300000 /dev/urandom > "$SRV/checkpoints/aio.safetensors"
head -c 50000  /dev/urandom > "$SRV/split_files/vae/vae.safetensors"
head -c 80000  /dev/urandom > "$SRV/split_files/text_encoders/te.safetensors"
: > "$LOG"
python3 "$HERE/range_server.py" "$SRV" "$T/port" "$LOG" & PID=$!
for _ in $(seq 1 50); do [ -s "$T/port" ] && break; sleep 0.1; done
[ -s "$T/port" ] || { echo "テスト用サーバーが起動しない"; exit 1; }
URL=http://127.0.0.1:$(cat "$T/port")
ACE_MODELS='
checkpoints/aio.safetensors 300000
split_files/text_encoders/te.safetensors 80000
split_files/vae/vae.safetensors 50000
'
same() { cmp -s "$1" "$2"; }

echo "# 1. 初回（Volume が空）: リダイレクト越しに全部取る"
ensure_models "$URL/redir" "$M" > "$T/out" 2>&1; rc=$?
check "成功を返す" '[ $rc -eq 0 ]'
check "split_files/ を外した置き場所に、中身どおり置かれる" 'same "$M/checkpoints/aio.safetensors" "$SRV/checkpoints/aio.safetensors" && same "$M/text_encoders/te.safetensors" "$SRV/split_files/text_encoders/te.safetensors" && same "$M/vae/vae.safetensors" "$SRV/split_files/vae/vae.safetensors"'
check ".part が残らない" '[ -z "$(find "$M" -name "*.part")" ]'
check "置かれるのはモデル3つだけ（小さいファイルを Volume に撒かない）" '[ "$(find "$M" -type f | wc -l | tr -d " ")" = 3 ]'

echo "# 2. 2回目（揃っている）: 通信せずに終わる"
: > "$LOG"; s=$(date +%s)
ensure_models "$URL/redir" "$M" > "$T/out" 2>&1; rc=$?
check "成功を返す" '[ $rc -eq 0 ] && grep -q "MODELS OK" "$T/out"'
check "HTTP リクエストが 0 回" '[ ! -s "$LOG" ]'
check "1秒以内" '[ $(( $(date +%s) - s )) -le 1 ]'

echo "# 3. 一部だけ欠けている: 欠けた分だけ取る"
rm "$M/vae/vae.safetensors"; : > "$LOG"
ensure_models "$URL/ok" "$M" > "$T/out" 2>&1; rc=$?
check "成功を返す" '[ $rc -eq 0 ] && same "$M/vae/vae.safetensors" "$SRV/split_files/vae/vae.safetensors"'
check "リクエストは vae の1回だけ" '[ "$(wc -l < "$LOG" | tr -d " ")" = 1 ] && [ "$(reqs vae)" = 1 ]'

echo "# 4. 途中で接続が切れる: .part の続きから再開する"
rm -rf "$M"; : > "$LOG"
ensure_models "$URL/cut120000" "$M" > "$T/out" 2>&1; rc=$?
check "成功を返す" '[ $rc -eq 0 ]'
check "中身が壊れていない" 'same "$M/checkpoints/aio.safetensors" "$SRV/checkpoints/aio.safetensors"'
check "2回目のリクエストは 120000 バイト目からの Range" 'grep -q "aio.safetensors range=bytes=120000-" "$LOG"'

echo "# 5. provision.sh 自体が中断された後の再実行: 前回の .part から再開する"
rm -rf "$M"; mkdir -p "$M/checkpoints"; : > "$LOG"
head -c 200000 "$SRV/checkpoints/aio.safetensors" > "$M/checkpoints/aio.safetensors.part"
ensure_models "$URL/ok" "$M" > "$T/out" 2>&1; rc=$?
check "成功を返す" '[ $rc -eq 0 ] && same "$M/checkpoints/aio.safetensors" "$SRV/checkpoints/aio.safetensors"'
check "200000 バイト目から取りに行く" 'grep -q "aio.safetensors range=bytes=200000-" "$LOG"'
check "取り切った .part は通信なしで仕上げる" 'rm "$M/vae/vae.safetensors"; cp "$SRV/split_files/vae/vae.safetensors" "$M/vae/vae.safetensors.part"; : > "$LOG"; ensure_models "$URL/ok" "$M" >/dev/null 2>&1 && [ ! -s "$LOG" ] && same "$M/vae/vae.safetensors" "$SRV/split_files/vae/vae.safetensors"'

echo "# 6. 壊れた .part（想定より大きい）/ サーバーが Range に応じない: 最初から取り直す"
rm -rf "$M"; mkdir -p "$M/vae"; head -c 60000 /dev/urandom > "$M/vae/vae.safetensors.part"
ensure_models "$URL/ok" "$M" > "$T/out" 2>&1; rc=$?
check "大きすぎる .part を捨てて取り直す" '[ $rc -eq 0 ] && same "$M/vae/vae.safetensors" "$SRV/split_files/vae/vae.safetensors"'
rm "$M/vae/vae.safetensors"; head -c 10000 "$SRV/split_files/vae/vae.safetensors" > "$M/vae/vae.safetensors.part"
ensure_models "$URL/norange" "$M" > "$T/out" 2>&1; rc=$?
check "Range 非対応でも最後は揃う（後ろに継ぎ足して壊さない）" '[ $rc -eq 0 ] && same "$M/vae/vae.safetensors" "$SRV/split_files/vae/vae.safetensors"'

echo "# 7. 同じ名前でサイズ違いのファイルがある: 取り直して差し替える"
echo broken > "$M/text_encoders/te.safetensors"
ensure_models "$URL/ok" "$M" > "$T/out" 2>&1; rc=$?
check "成功を返す・正しい中身に置き換わる" '[ $rc -eq 0 ] && same "$M/text_encoders/te.safetensors" "$SRV/split_files/text_encoders/te.safetensors"'

echo "# 8. 失敗: 失敗を返し、モデルの位置には何も置かない"
rm -rf "$M"
ACE_MODELS='
checkpoints/aio.safetensors 999999
'
ensure_models "$URL/ok" "$M" > "$T/out" 2>&1; rc=$?
check "サイズが合わなければ失敗を返す" '[ $rc -ne 0 ]'
check "サイズ違いのファイルをモデルとして置かない" '[ ! -e "$M/checkpoints/aio.safetensors" ]'
ACE_MODELS='
checkpoints/missing.safetensors 100
checkpoints/aio.safetensors 300000
'
: > "$LOG"
ensure_models "$URL/ok" "$M" > "$T/out" 2>&1; rc=$?
check "404 なら失敗を返し、後続のファイルに進まない" '[ $rc -ne 0 ] && [ "$(reqs aio)" = 0 ] && [ ! -e "$M/checkpoints/missing.safetensors" ]'
check "失敗時に再開方法を表示する" 'grep -q "続きから再開" "$T/out"'

echo "# 9. provision.sh が、失敗時に ComfyUI を起動せず止まる"
check "ensure_models の失敗で exit する行が、pip と ComfyUI 起動より前にある" '
  a=$(grep -n "^ensure_models " "$HERE/../provision.sh" | cut -d: -f1)
  b=$(grep -n "^pip install" "$HERE/../provision.sh" | head -1 | cut -d: -f1)
  c=$(grep -n "main.py --listen 0.0.0.0" "$HERE/../provision.sh" | cut -d: -f1)
  [ -n "$a" ] && [ "$a" -lt "$b" ] && [ "$a" -lt "$c" ] && sed -n "${a}p" "$HERE/../provision.sh" | grep -q "exit 1"'

[ $FAIL -eq 0 ] && echo "ALL OK" || echo "SOME FAILED"
exit $FAIL
