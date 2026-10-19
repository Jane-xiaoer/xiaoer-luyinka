"""80 端口只做一件事：把 http://luyinka.xiaoeromia.com 跳到 https://…:8443（443 被 sing-box 占着）。"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        host = (self.headers.get("Host") or "luyinka.xiaoeromia.com").split(":")[0]
        self.send_response(301)
        self.send_header("Location", f"https://{host}:8443{self.path}")
        self.send_header("Content-Length", "0")
        self.end_headers()

    do_HEAD = do_GET

    def log_message(self, *a):
        pass


ThreadingHTTPServer(("0.0.0.0", 80), H).serve_forever()
