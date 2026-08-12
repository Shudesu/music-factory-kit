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

初回はモデル約20GBを自動ダウンロードします（5〜10分）。
完了後、Pod の 8188 ポートで ComfyUI が開きます。

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
モデル配布元: https://huggingface.co/Comfy-Org/ace_step_1.5_ComfyUI_files
