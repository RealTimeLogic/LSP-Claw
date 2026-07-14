import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/user":
            self.send_error(404)
            return
        valid = self.headers.get("Authorization") == "Bearer valid-test-token"
        body = json.dumps(
            {"login": "token-ui-test"} if valid else {"message": "Bad credentials"}
        ).encode("utf-8")
        self.send_response(200 if valid else 401)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *_args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
