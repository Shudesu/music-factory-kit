"""tests/test_download_models.sh 用のローカル HTTP サーバー（Range 対応・障害の再現つき）。

使い方: python3 range_server.py <配信ディレクトリ> <ポート番号を書くファイル> <リクエストログ>
URL の先頭の1段でふるまいを切り替える（残りが配信ディレクトリ内のパス）:
  /ok/...        普通に返す（Range: bytes=N- に 206 で応じる）
  /redir/...     302 で /ok/... へ飛ばす（HF の resolve → CDN の再現）
  /cut<N>/...    そのファイルへの最初のリクエストだけ、N バイト送って接続を切る
  /norange/...   Range を無視して常に 200 で全体を返す
"""
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT, PORT_FILE, LOG = sys.argv[1], sys.argv[2], sys.argv[3]
cut_done = set()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        with open(LOG, "a") as f:
            f.write(f"{self.path} range={self.headers.get('Range', '-')}\n")
        mode, _, rel = self.path.lstrip("/").partition("/")
        if mode == "redir":
            self.send_response(302)
            self.send_header("Location", "/ok/" + rel)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        path = os.path.join(ROOT, rel)
        if not os.path.isfile(path):
            self.send_error(404)
            return
        size = os.path.getsize(path)
        start = 0
        m = re.fullmatch(r"bytes=(\d+)-", self.headers.get("Range", ""))
        if m and mode != "norange":
            start = int(m.group(1))
            if start >= size:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{size - 1}/{size}")
        else:
            self.send_response(200)
        self.send_header("Content-Length", str(size - start))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        with open(path, "rb") as f:
            f.seek(start)
            data = f.read()
        c = re.fullmatch(r"cut(\d+)", mode)
        if c and rel not in cut_done:
            cut_done.add(rel)
            self.wfile.write(data[: int(c.group(1))])
            self.wfile.flush()
            self.close_connection = True
            return
        self.wfile.write(data)


srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE + ".tmp", "w") as f:
    f.write(str(srv.server_address[1]))
os.replace(PORT_FILE + ".tmp", PORT_FILE)
srv.serve_forever()
