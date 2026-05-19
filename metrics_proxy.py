import argparse
import http.server
import socketserver
import urllib.error
import urllib.request


class MetricsProxyHandler(http.server.BaseHTTPRequestHandler):
    upstream_url = "http://127.0.0.1:18100"

    def do_GET(self):
        self.proxy_request()

    def do_HEAD(self):
        self.proxy_request(head_only=True)

    def proxy_request(self, head_only=False):
        url = self.upstream_url
        if self.path and self.path != "/":
            url = self.upstream_url.rstrip("/") + self.path

        try:
            req = urllib.request.Request(url, method="GET")
            with urllib.request.urlopen(req, timeout=30) as resp:
                body = resp.read()
                self.send_response(resp.status)
                for key, value in resp.headers.items():
                    if key.lower() in {"connection", "transfer-encoding"}:
                        continue
                    self.send_header(key, value)
                self.end_headers()
                if not head_only:
                    self.wfile.write(body)
        except urllib.error.HTTPError as exc:
            body = exc.read()
            self.send_response(exc.code)
            self.end_headers()
            if not head_only:
                self.wfile.write(body)
        except Exception as exc:
            body = f"metrics proxy upstream error: {exc}\n".encode()
            self.send_response(502)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if not head_only:
                self.wfile.write(body)

    def log_message(self, fmt, *args):
        return


class ThreadingTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen-host", default="0.0.0.0")
    parser.add_argument("--listen-port", type=int, required=True)
    parser.add_argument("--upstream", required=True)
    args = parser.parse_args()

    MetricsProxyHandler.upstream_url = args.upstream.rstrip("/")
    with ThreadingTCPServer((args.listen_host, args.listen_port), MetricsProxyHandler) as httpd:
        httpd.serve_forever()


if __name__ == "__main__":
    main()
