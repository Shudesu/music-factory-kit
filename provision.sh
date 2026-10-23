#!/bin/bash
# ACE-Step 1.5 + ComfyUI プロビジョニング v3（新Pod作成のたびに1回実行）
set -uo pipefail

# ComfyUI 内のディレクトリ $1 を、Volume 上のディレクトリ $2 へのシンボリックリンクにする。
# clone 直後の ComfyUI は models/* や output/ にプレースホルダのファイルが入っていて rmdir できないため、
# 中身を Volume 側へ移してから置き換える（同名ファイルは上書きせず、残った分は *.local-backup-* に退避）。
# 何度実行しても同じ結果になる。リンクにできなければ失敗を返す。
link_to_volume() {
  local src=$1 dst=$2 l
  mkdir -p "$dst" || return 1
  if [ -L "$src" ]; then
    rm -f "$src"
  elif [ -d "$src" ]; then
    find "$src" -mindepth 1 -maxdepth 1 -type f \( -name 'put_*_here' -o -name '_output_images_will_be_put_here' \) -delete
    # v2 までの不具合で中に作られた「Volume へのリンク」は移さずに消す（Volume 側で自己参照になるため）
    while IFS= read -r -d '' l; do
      [ "$(readlink -f "$l")" = "$(readlink -f "$dst")" ] && rm -f "$l"
    done < <(find "$src" -mindepth 1 -maxdepth 1 -type l -print0)
    while IFS= read -r -d '' l; do
      if [ -e "$dst/${l##*/}" ] || [ -L "$dst/${l##*/}" ]; then continue; fi  # 同名は上書きせず残す
      mv "$l" "$dst"/ || return 1  # Volume が満杯・読み取り専用などで移せなければ、置き換えずに中断
    done < <(find "$src" -mindepth 1 -maxdepth 1 -print0)
    rmdir "$src" 2>/dev/null || mv "$src" "$src.local-backup-$(date +%Y%m%d%H%M%S)" || return 1
  elif [ -e "$src" ]; then
    mv "$src" "$src.local-backup-$(date +%Y%m%d%H%M%S)" || return 1
  fi
  ln -s "$dst" "$src" && [ "$(readlink -f "$src")" = "$(readlink -f "$dst")" ]
}

# ACE-Step 1.5 のモデル（Comfy-Org 公式配布）。1行に「HF 上のパス サイズ(バイト)」。
# 置き場所は先頭の split_files/ を外したパス（例: split_files/vae/x → /workspace/models/vae/x）。
# 第4章・第10章の構成: AIO turbo（試し曲・LoRA）/ XL SFT（配信用）/ LM 0.6B + 1.7B（4B は使わない）/ VAE。
# サイズは MODEL_BASE のコミット時点で HF API から確認した値。変えるときは両方そろえて更新する。
ACE_MODELS='
checkpoints/ace_step_1.5_turbo_aio.safetensors 10025478736
split_files/diffusion_models/acestep_v1.5_xl_sft_bf16.safetensors 9974719930
split_files/text_encoders/qwen_0.6b_ace15.safetensors 1191588248
split_files/text_encoders/qwen_1.7b_ace15.safetensors 3708523360
split_files/vae/ace_1.5_vae.safetensors 337431732
'
MODEL_BASE=${MFK_MODEL_BASE:-https://huggingface.co/Comfy-Org/ACE-Step-1.5/resolve/6707deb277e9e0907fd9c14ce6b6f1d695c6a3fc}

fsize() { stat -c %s "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null; }

# URL $1 のファイルを、サイズ $3 バイトとして $2 に置く。既に同じサイズで揃っていれば何もしない。
# 隣の $2.part に書いてサイズが合ってから mv するので、途中で切れても中途半端なモデルは置かれず、
# 次の試行（provision.sh の再実行でも）は .part の続きから再開する。揃わなければ失敗を返す。
download_model() {
  local url=$1 dst=$2 size=$3 part=$2.part have try rc progress=(-sS)
  [ "$(fsize "$dst")" = "$size" ] && return 0
  [ -t 2 ] && progress=(--progress-bar)
  mkdir -p "${dst%/*}" || return 1
  for try in 1 2 3 4 5; do
    have=$(fsize "$part"); have=${have:-0}
    [ "$have" -gt "$size" ] && { rm -f "$part"; have=0; }  # 想定より大きい .part は壊れているので捨てる
    if [ "$have" -lt "$size" ]; then
      echo "  ${dst##*/}: $((have / 1000000)) / $((size / 1000000)) MB から取得（試行 ${try}）"
      curl -fL --connect-timeout 20 --speed-limit 102400 --speed-time 60 -C - "${progress[@]}" -o "$part" "$url"; rc=$?
      [ "$rc" -eq 33 ] && rm -f "$part"  # サーバーが続きからの取得に応じなかった → 次は最初から
    fi
    if [ "$(fsize "$part")" = "$size" ]; then
      mv -f "$part" "$dst" && return 0
      return 1
    fi
    [ "$try" -lt 5 ] && sleep "${MFK_RETRY_WAIT:-5}"
  done
  echo "  ${dst##*/}: $size バイトそろわず（今 $(fsize "$part") バイト。もう一度実行すると続きから再開）"
  return 1
}

# ACE_MODELS のうち $2（モデル置き場）に無いものだけ、$1 を起点に取得する。揃っていれば stat だけで終わる。
ensure_models() {
  local base=$1 root=$2 path size need=0 n=0
  while read -r path size <&3; do
    [ -n "$path" ] || continue
    [ "$(fsize "$root/${path#split_files/}")" = "$size" ] || { need=$((need + size)); n=$((n + 1)); }
  done 3<<< "$ACE_MODELS"
  [ "$n" -eq 0 ] && { echo "MODELS OK"; return 0; }
  echo "MODELS: $n 個・約 $((need / 1000000000)).$((need / 100000000 % 10)) GB をダウンロードします（初回のみ。5〜10分）"
  while read -r path size <&3; do
    [ -n "$path" ] || continue
    download_model "$base/$path" "$root/${path#split_files/}" "$size" || return 1
  done 3<<< "$ACE_MODELS"
  echo "MODELS OK"
}

[ -d /root/ComfyUI ] || git clone --depth 1 -q https://github.com/comfyanonymous/ComfyUI.git /root/ComfyUI
cd /root/ComfyUI || { echo "COMFY FAILED: /root/ComfyUI がありません"; exit 1; }
for d in diffusion_models vae text_encoders loras checkpoints; do
  link_to_volume models/$d /workspace/models/$d || { echo "LINK FAILED: models/$d"; exit 1; }
done
link_to_volume output /workspace/outputs || { echo "LINK FAILED: output（生成物がPodローカルに保存されるため中断）"; exit 1; }
ensure_models "$MODEL_BASE" /workspace/models || { echo "MODEL DOWNLOAD FAILED（ComfyUI は起動しません。もう一度実行すると続きから再開します）"; exit 1; }
pip install --break-system-packages --no-cache-dir -q -r requirements.txt numpy 2>&1 | tail -1

# FL LoRA training node（comfy起動より前に入れる）
if [ ! -d /root/ComfyUI/custom_nodes/ComfyUI-FL-AceStep-Training ]; then
  git clone --depth 1 -q https://github.com/filliptm/ComfyUI-FL-AceStep-Training.git /root/ComfyUI/custom_nodes/ComfyUI-FL-AceStep-Training
  pip install --break-system-packages --no-cache-dir -q -r /root/ComfyUI/custom_nodes/ComfyUI-FL-AceStep-Training/requirements.txt 2>&1 | tail -1
fi

# ComfyUI は CORS 無効時、Sec-Fetch-Site: cross-site のリクエストを 403 で拒否する。
# RunPod 管理画面のリンクから https://<pod-id>-8188.proxy.runpod.net を開くと cross-site 扱いになるため、
# --enable-cors-header でこのチェックを外す（他サイトからの POST も通るようになるが、プロキシURLはもともと
# 認証なしで公開されており、URL を知っていれば直接操作できるので守れる範囲は変わらない）。
# 指定したオリジン以外のサイトにはレスポンスを読ませないよう、自分のプロキシURLを指定する（Pod ID が取れなければ *）。
CORS_ORIGIN="*"
[ -n "${RUNPOD_POD_ID:-}" ] && CORS_ORIGIN="https://${RUNPOD_POD_ID}-8188.proxy.runpod.net"

OLD=$(pgrep -f "main.py --listen" | head -1); [ -n "${OLD:-}" ] && kill -9 "$OLD"; sleep 2
cd /root/ComfyUI && setsid nohup python main.py --listen 0.0.0.0 --port 8188 \
  --enable-cors-header "$CORS_ORIGIN" --output-directory /workspace/outputs \
  </dev/null >/root/comfy.log 2>&1 & disown
for i in $(seq 1 60); do
  sleep 5
  curl -s -m 4 http://127.0.0.1:8188/system_stats >/dev/null 2>&1 && { echo "COMFY READY ($((i*5))s)"; exit 0; }
done
echo "COMFY FAILED"; tail -20 /root/comfy.log; exit 1
