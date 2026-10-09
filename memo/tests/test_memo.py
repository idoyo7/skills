import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SCRIPT = os.path.join(os.path.dirname(__file__), "..", "scripts", "memo.py")
TOKEN = "tok_secret_0123456789abcdef"


class State:
    def __init__(self):
        self.memos = {}
        self.requests = []
        self.mode = None
        self.seq = 0


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, obj=None, headers=None):
        body = json.dumps(obj if obj is not None else {}).encode()
        self.send_response(code)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def handle_any(self):
        st = self.server.state
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length)) if length else None
        path, _, query = self.path.partition("?")
        st.requests.append((self.command, self.path, body, self.headers.get("Authorization")))
        if self.headers.get("Authorization") != "Bearer " + TOKEN:
            return self.reply(401, {"message": "secret-body " + TOKEN})
        if st.mode == "redirect":
            return self.reply(302, headers={"Location": "/api/v1/memos/landed"})
        if st.mode == "fail500":
            return self.reply(500, {"message": "boom " + TOKEN})
        if path == "/api/v1/auth/me":
            return self.reply(404) if st.mode == "no_me" else self.reply(200, {"user": {"name": "users/1"}})
        if path == "/api/v1/memos" and self.command == "GET":
            params = dict(p.split("=", 1) for p in query.split("&") if p)
            size = int(params.get("pageSize", 20))
            start = int(params.get("pageToken") or 0)
            items = list(st.memos.values())
            chunk = items[start:start + size]
            nxt = str(start + size) if start + size < len(items) else ""
            return self.reply(200, {"memos": chunk, "nextPageToken": nxt})
        if path == "/api/v1/memos" and self.command == "POST":
            st.seq += 1
            name = "memos/m%d" % st.seq
            st.memos[name] = {"name": name, "content": body["content"], "visibility": body.get("visibility", "PRIVATE")}
            return self.reply(200, st.memos[name])
        if path.startswith("/api/v1/memos/"):
            name = path[len("/api/v1/"):]
            if name not in st.memos:
                return self.reply(404, {"message": "nope"})
            if self.command == "GET":
                return self.reply(200, st.memos[name])
            if self.command == "PATCH":
                mask = query.split("updateMask=")[1].replace("%2C", ",").split("&")[0].split(",")
                for k in mask:
                    st.memos[name][k] = body[k]
                return self.reply(200, st.memos[name])
            if self.command == "DELETE":
                del st.memos[name]
                return self.reply(200, {})
        self.reply(404)

    do_GET = do_POST = do_PATCH = do_DELETE = handle_any


class MemoTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.server.state = State()
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.tmp = tempfile.TemporaryDirectory()
        d = cls.tmp.name
        cls.token_path = os.path.join(d, "token")
        with open(cls.token_path, "w") as f:
            f.write(TOKEN + "\n")
        os.chmod(cls.token_path, 0o600)
        cls.cfg_path = os.path.join(d, "memo.json")
        cls.write_cfg({"base_url": "http://127.0.0.1:%d" % cls.server.server_port, "token_file": cls.token_path})

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.tmp.cleanup()

    @classmethod
    def write_cfg(cls, cfg):
        with open(cls.cfg_path, "w") as f:
            json.dump(cfg, f)

    def setUp(self):
        self.st = self.server.state
        self.st.memos.clear()
        self.st.requests.clear()
        self.st.mode = None
        self.write_cfg({"base_url": "http://127.0.0.1:%d" % self.server.server_port, "token_file": self.token_path})

    def run_memo(self, *args, stdin=None, cfg=None):
        env = dict(os.environ, MEMOS_CONFIG=cfg or self.cfg_path, NO_PROXY="127.0.0.1", no_proxy="127.0.0.1")
        for k in ("HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy"):
            env.pop(k, None)
        return subprocess.run([sys.executable, SCRIPT, *args], input=stdin, capture_output=True, text=True, env=env, timeout=30)

    def tmpfile(self, text):
        p = os.path.join(self.tmp.name, "in.md")
        with open(p, "w", encoding="utf-8") as f:
            f.write(text)
        return p

    def test_crud_roundtrip(self):
        r = self.run_memo("create", "--file", "-", stdin="# 제목\n본문")
        self.assertEqual(r.returncode, 0, r.stderr)
        created = json.loads(r.stdout)
        self.assertEqual(created["visibility"], "PRIVATE")
        r = self.run_memo("get", created["name"], "--content-only")
        self.assertEqual(r.stdout.strip(), "# 제목\n본문")
        r = self.run_memo("update", created["name"], "--file", self.tmpfile("바뀐 본문"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.st.memos[created["name"]]["content"], "바뀐 본문")
        r = self.run_memo("delete", created["name"])
        self.assertEqual(json.loads(r.stdout)["deleted"], created["name"])
        self.assertEqual(self.run_memo("get", created["name"]).returncode, 1)

    def test_update_preserves_visibility(self):
        self.st.memos["memos/a"] = {"name": "memos/a", "content": "x", "visibility": "PUBLIC"}
        self.run_memo("update", "memos/a", "--file", self.tmpfile("y"))
        method, path, body, _ = self.st.requests[-1]
        self.assertIn("updateMask=content", path)
        self.assertNotIn("visibility", path)
        self.assertNotIn("visibility", body)
        self.assertEqual(self.st.memos["memos/a"]["visibility"], "PUBLIC")

    def test_update_visibility_when_given(self):
        self.st.memos["memos/a"] = {"name": "memos/a", "content": "x", "visibility": "PUBLIC"}
        self.run_memo("update", "memos/a", "--file", self.tmpfile("y"), "--visibility", "PRIVATE")
        self.assertEqual(self.st.memos["memos/a"]["visibility"], "PRIVATE")

    def test_input_validation(self):
        self.assertEqual(self.run_memo("create", "--file", "-", stdin="  \n").returncode, 1)
        self.assertEqual(self.run_memo("create", "--file", "/nonexistent/x.md").returncode, 1)
        self.assertEqual(self.run_memo("get", "memos/../x").returncode, 1)
        self.assertNotEqual(self.run_memo("create", "--file", "-", "--visibility", "SECRET", stdin="a").returncode, 0)
        bad = os.path.join(self.tmp.name, "bad.bin")
        with open(bad, "wb") as f:
            f.write(b"\xff\xfe\x00")
        self.assertEqual(self.run_memo("create", "--file", bad).returncode, 1)
        self.assertEqual(self.st.requests, [])

    def test_token_masked_in_output(self):
        self.st.memos["memos/a"] = {"name": "memos/a", "content": "leak " + TOKEN, "visibility": "PRIVATE"}
        for args in (("get", "memos/a"), ("get", "memos/a", "--content-only"), ("list",), ("search", "leak")):
            r = self.run_memo(*args)
            self.assertNotIn(TOKEN, r.stdout + r.stderr)
            self.assertIn("***", r.stdout)

    def test_error_body_not_printed(self):
        self.st.mode = "fail500"
        r = self.run_memo("list")
        self.assertEqual(r.returncode, 1)
        self.assertNotIn("boom", r.stdout + r.stderr)
        self.assertNotIn(TOKEN, r.stdout + r.stderr)

    def test_status_messages(self):
        with open(self.token_path + "2", "w") as f:
            f.write("wrong\n")
        os.chmod(self.token_path + "2", 0o600)
        self.write_cfg({"base_url": "http://127.0.0.1:%d" % self.server.server_port, "token_file": self.token_path + "2"})
        r = self.run_memo("list")
        self.assertIn("401", r.stderr)
        self.assertNotIn("secret-body", r.stderr)
        self.setUp()
        r = self.run_memo("get", "memos/none")
        self.assertIn("404", r.stderr)
        self.assertIn("단정하지 않는다", r.stderr)

    def test_redirect_blocked(self):
        self.st.mode = "redirect"
        r = self.run_memo("list")
        self.assertEqual(r.returncode, 1)
        self.assertEqual(len(self.st.requests), 1)
        self.assertIn("리다이렉트", r.stderr)

    def test_no_retry(self):
        self.st.mode = "fail500"
        self.run_memo("create", "--file", "-", stdin="a")
        self.assertEqual(len(self.st.requests), 1)

    def test_search_pages(self):
        for i in range(5):
            n = "memos/m%d" % i
            self.st.memos[n] = {"name": n, "content": "Hello %d" % i if i % 2 == 0 else "other", "visibility": "PRIVATE"}
        r = json.loads(self.run_memo("search", "HELLO", "--page-size", "2").stdout)
        self.assertEqual(r["count"], 3)
        self.assertTrue(r["complete"])
        self.assertEqual(r["pages_scanned"], 3)
        r = json.loads(self.run_memo("search", "hello", "--page-size", "2", "--max-pages", "1").stdout)
        self.assertFalse(r["complete"])
        self.assertEqual(r["count"], 1)

    def test_list_pagination(self):
        for i in range(3):
            self.st.memos["memos/m%d" % i] = {"name": "memos/m%d" % i, "content": "c", "visibility": "PRIVATE"}
        r = json.loads(self.run_memo("list", "--page-size", "2").stdout)
        self.assertEqual(len(r["memos"]), 2)
        r2 = json.loads(self.run_memo("list", "--page-size", "2", "--page-token", r["next_page_token"]).stdout)
        self.assertEqual(len(r2["memos"]), 1)
        self.assertEqual(r2["next_page_token"], "")

    def test_doctor_and_fallback(self):
        r = self.run_memo("doctor")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout)["auth_endpoint"], "GET /auth/me")
        self.st.mode = "no_me"
        r = self.run_memo("doctor")
        self.assertEqual(r.returncode, 1)  # 가짜 서버엔 폴백 경로가 없다
        self.assertIn("엔드포인트", r.stderr)

    def test_config_missing(self):
        r = self.run_memo("list", cfg=os.path.join(self.tmp.name, "absent.json"))
        self.assertEqual(r.returncode, 1)
        self.assertIn("https://memos.example.com", r.stderr)
        self.assertIn("token_file", r.stderr)

    def test_config_incomplete_and_unsafe(self):
        base = "http://127.0.0.1:%d" % self.server.server_port
        cases = [
            {},
            {"base_url": base},
            {"base_url": "http://memos.example.com", "token_file": self.token_path},
            {"base_url": "https://user:pw@memos.example.com", "token_file": self.token_path},
            {"base_url": "https://memos.example.com", "token_file": self.token_path + ".missing"},
        ]
        for cfg in cases:
            self.write_cfg(cfg)
            r = self.run_memo("list")
            self.assertEqual(r.returncode, 1, cfg)
            self.assertNotIn("pw@", r.stdout)
        self.assertEqual(self.st.requests, [])

    def test_open_permission_warns_but_runs(self):
        os.chmod(self.token_path, 0o644)
        try:
            r = self.run_memo("list")
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn("경고", r.stderr)
            self.assertNotIn(TOKEN, r.stderr)
        finally:
            os.chmod(self.token_path, 0o600)


if __name__ == "__main__":
    unittest.main()
