#!/bin/bash
# ACE-Step 1.5 + ComfyUI プロビジョニング v2（新Pod作成のたびに1回実行）
set -uo pipefail
[ -d /root/ComfyUI ] || git clone --depth 1 -q https://github.com/comfyanonymous/ComfyUI.git /root/ComfyUI
cd /root/ComfyUI
for d in diffusion_models vae text_encoders loras checkpoints; do
  mkdir -p /workspace/models/$d
  rmdir models/$d 2>/dev/null
  ln -sfn /workspace/models/$d models/$d
done
mkdir -p /workspace/outputs
rmdir output 2>/dev/null
ln -sfn /workspace/outputs output
pip install --break-system-packages --no-cache-dir -q -r requirements.txt numpy 2>&1 | tail -1

# FL LoRA training node（comfy起動より前に入れる）
if [ ! -d /root/ComfyUI/custom_nodes/ComfyUI-FL-AceStep-Training ]; then
  git clone --depth 1 -q https://github.com/filliptm/ComfyUI-FL-AceStep-Training.git /root/ComfyUI/custom_nodes/ComfyUI-FL-AceStep-Training
  pip install --break-system-packages --no-cache-dir -q -r /root/ComfyUI/custom_nodes/ComfyUI-FL-AceStep-Training/requirements.txt 2>&1 | tail -1
fi

OLD=$(pgrep -f "main.py --listen" | head -1); [ -n "${OLD:-}" ] && kill -9 $OLD; sleep 2
cd /root/ComfyUI && setsid nohup python main.py --listen 0.0.0.0 --port 8188 </dev/null >/root/comfy.log 2>&1 & disown
for i in $(seq 1 60); do
  sleep 5
  curl -s -m 4 http://127.0.0.1:8188/system_stats >/dev/null 2>&1 && { echo "COMFY READY ($((i*5))s)"; exit 0; }
done
echo "COMFY FAILED"; tail -20 /root/comfy.log; exit 1
