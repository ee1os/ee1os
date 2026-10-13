"""Stand-in for GitHub releases and os.ivan.gg/api/report in the install script tests.

   python3 server.py <root> <port>
GET serves files under <root>; POST /api/report saves the body to <root>/report.txt and
answers R-TEST.
"""
import http.server
import os
import sys

root, port = sys.argv[1], int(sys.argv[2])


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=root, **kw)

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
