# Music Factory Kit — RunPod × ACE-Step 1.5

音楽生成工場を自分で持つための3点セット。
LMSコース「自分の音楽生成工場を持つ」の配布教材です。

| ファイル | 用途 | 対応章 |
|---|---|---|
| `provision.sh` | Pod復帰ワンコマンド（ComfyUI + ACE-Step 1.5 + LoRA学習ノード） | 第3章 |
| `check_fingerprint.py` | 配信前の音響指紋チェック（Content ID 自己検品） | 第8章 |
| `master.sh` | マスタリング（EQ + コンプ + -14 LUFS 正規化） | 第8章 |

## 使い方の要点

### provision.sh
RunPod の Pod（PyTorch 公式イメージ + Network Volume を `/workspace` にマウント）で:

```bash
# 初回のみ: スクリプトをVolumeに置く
curl -sL https://raw.githubusercontent.com/Shudesu/music-factory-kit/main/provision.sh -o /workspace/provision.sh

# 毎回: Podを作るたびに1回実行（2回目以降は約10秒で完了）
bash /workspace/provision.sh
```

初回はモデル約25GBを Volume の `/workspace/models/` に自動ダウンロードします（5〜10分）。
2回目以降は揃っているか確認するだけです。途中で切れても、もう一度実行すれば続きから再開します。
完了後、Pod の 8188 ポートで ComfyUI が開きます。

| 置き場所（`/workspace/models/`） | 用途 | サイズ |
|---|---|---|
| `checkpoints/ace_step_1.5_turbo_aio.safetensors` | Turbo（AIO）: 試し曲・LoRA（第4・6・10章） | 10.0 GB |
| `diffusion_models/acestep_v1.5_xl_sft_bf16.safetensors` | XL SFT: 配信用の高品質版（第4章） | 10.0 GB |
| `text_encoders/qwen_0.6b_ace15.safetensors` | LM 0.6B | 1.2 GB |
| `text_encoders/qwen_1.7b_ace15.safetensors` | LM 1.7B（4B は使わない） | 3.7 GB |
| `vae/ace_1.5_vae.safetensors` | VAE | 0.3 GB |

キットが更新されたら、上の `curl` をもう一度実行して Volume 上の `provision.sh` を上書きしてください。
生成物は `/workspace/outputs`（Volume）に保存されます。`/root/ComfyUI/output` はそこへのリンクです。

### check_fingerprint.py
```bash
# 手元のPC（要: pip install なし / fpcalc のみ必要）
# macOS: brew install chromaprint / Ubuntu: apt install libchromaprint-tools
python3 check_fingerprint.py 生成物フォルダ/ 学習音源フォルダ/
```
一致率 0.65 超の曲は配信しない。0.85 超は Content ID 一致水準（絶対NG）。

### master.sh
```bash
bash master.sh input.flac output.mp3
```

## 前提となる考え方（コース本編参照）

- モデルは Volume、プログラムは Pod ローカル（第3章: 700倍問題）
- LM は 1.7B を使う（第4章: 4B は終盤無音バグ）
- 1 LoRA = 1 レーン（第6章）
- 尺は 210〜228 秒（第8章: 5分は音抜けする）

## ライセンス

MIT。ACE-Step 1.5 本体も MIT（商用利用可）。
モデル配布元: https://huggingface.co/Comfy-Org/ACE-Step-1.5（旧名 Comfy-Org/ace_step_1.5_ComfyUI_files）
