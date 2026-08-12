#!/usr/bin/env python3
"""配信前の音響指紋チェック（Content ID 自己検品）
使い方: python3 check_fingerprint.py <生成物フォルダ> <学習音源フォルダ>
要: fpcalc (macOS: brew install chromaprint / Ubuntu: apt install libchromaprint-tools)
判定: 0.50前後=無関係(安全) / 0.65超=配信から外す / 0.85超=Content ID一致水準(絶対NG)
"""
import subprocess, json, glob, os, sys

def fp(path, length=210):
    out = subprocess.run(["fpcalc", "-raw", "-length", str(length), "-json", path],
                         capture_output=True, text=True, timeout=120)
    return json.loads(out.stdout)["fingerprint"]

def sim(a, b):
    best = 0.0
    n, m = len(a), len(b)
    for off in range(-120, 121, 2):
        matches = total = 0
        for i in range(max(0, -off), min(n, m - off)):
            x = a[i] ^ b[i + off]
            matches += 32 - bin(x & 0xFFFFFFFF).count("1")
            total += 32
        if total >= 32 * 60:
            best = max(best, matches / total)
    return best

def audio_files(d):
    exts = ("*.mp3", "*.flac", "*.wav", "*.m4a", "*.ogg")
    return sorted(f for e in exts for f in glob.glob(os.path.join(d, e)))

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__); sys.exit(1)
    gen_dir, train_dir = sys.argv[1], sys.argv[2]
    train = [(os.path.basename(p)[:34], fp(p)) for p in audio_files(train_dir)]
    if not train:
        print("学習音源が見つかりません:", train_dir); sys.exit(1)
    print(f"学習音源 {len(train)} 曲と照合します\n")
    ng = 0
    for f in audio_files(gen_dir):
        g = fp(f)
        s, t = max((sim(g, tf), tn) for tn, tf in train)
        name = os.path.basename(f)
        if s > 0.85:   verdict = "🚫 一致水準超え（絶対に配信しない）"; ng += 1
        elif s > 0.65: verdict = "⚠️ 要注意（配信から外す）"; ng += 1
        elif s > 0.60: verdict = "△ グレー（耳で確認を）"
        else:          verdict = "OK"
        print(f"  {s:.3f}  {name:40} vs {t}  {verdict}")
    print(f"\n判定: {'全曲クリア ✅' if ng == 0 else f'{ng} 曲を配信から外してください 🚫'}")
