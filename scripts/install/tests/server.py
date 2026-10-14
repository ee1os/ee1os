"""Stand-in for GitHub releases and os.ivan.gg/api/report in the install script tests.

   python3 server.py <root> <port>
GET serves files under <root>; like GitHub, /releases/... answers with a redirect to the
file's real address (/dl/releases/...), so the scripts must follow redirects. POST /api/report saves the body to <root>/report.txt and
answers R-TEST.
"""
import http.server
import os
import sys

root, port = sys.argv[1], int(sys.argv[2])


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=root, **kw)

    def do_GET(self):
        if self.path.startswith("/releases/"):
            self.send_response(302)
            self.send_header("Location", "/dl" + self.path)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path.startswith("/dl/"):
            self.path = self.path[3:]
        super().do_GET()

    def do_POST(self):
        if self.path != "/api/report":
            self.send_error(404)
            return
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(os.path.join(root, "report.txt"), "wb") as f:
            f.write(body)
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"R-TEST\n")

    def log_message(self, *a):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
