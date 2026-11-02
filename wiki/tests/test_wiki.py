import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from email.parser import BytesParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SCRIPT = os.path.join(os.path.dirname(__file__), "..", "scripts", "wiki.py")
TOKEN = "ol_api_secret_0123456789abcdef"
COL = "11111111-1111-4111-8111-111111111111"
COL2 = "22222222-2222-4222-8222-222222222222"


class State:
    def __init__(self):
        self.reset()

    def reset(self):
        self.cols = [{"id": COL, "name": "Notes", "permission": None},
                     {"id": COL2, "name": "Other", "permission": "read"}]
        self.docs = {}
        self.requests = []
        self.uploads = []
        self.mode = None
        self.upload_url = None
        self.seq = 0


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, obj=None, raw=None, headers=None):
        body = raw if raw is not None else json.dumps(obj if obj is not None else {}).encode()
        self.send_response(code)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def find(self, ref):
        for d in self.server.state.docs.values():
            if ref in (d["id"], d["urlId"]) or ref.endswith("-" + d["urlId"]):  # Outline 은 slug-urlId 도 받는다
                return d
        return None

    def handle_upload(self, st, data):
        ctype = self.headers.get("Content-Type", "")
        msg = BytesParser().parsebytes(b"Content-Type: " + ctype.encode() + b"\r\n\r\n" + data)
        parts = [(p.get_param("name", header="content-disposition"), p.get_payload(decode=True),
                  p.get("Content-Disposition")) for p in msg.get_payload()]
        st.uploads.append({"parts": parts, "auth": self.headers.get("Authorization"), "path": self.path})
        if st.mode == "s3error":
            xml = b"<Error><Code>AccessDenied</Code><Message>Policy expired</Message></Error>"
            return self.reply(403, raw=xml)
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_POST(self):
        st = self.server.state
        length = int(self.headers.get("Content-Length") or 0)
        data = self.rfile.read(length)
        if self.path.startswith("/upload"):
            return self.handle_upload(st, data)
        body = json.loads(data) if data else {}
        method = self.path[len("/api/"):]
        st.requests.append((method, body, self.headers.get("Authorization")))
        if self.headers.get("Authorization") != "Bearer " + TOKEN:
            return self.reply(401, {"error": "authentication_required", "message": "secret-body " + TOKEN})
        if st.mode == "redirect":
            return self.reply(302, headers={"Location": "/api/landed"})
        if st.mode == "rate":
            return self.reply(429, {"error": "rate_limit_exceeded", "message": TOKEN}, headers={"Retry-After": "7"})
        if st.mode == "fail500":
            return self.reply(500, {"message": "boom " + TOKEN})
        if st.mode == "no_auth_scope" and method == "auth.info":
            return self.reply(403, {"error": "authorization_error", "message": "API key does not have access to this resource"})
        if st.mode == "scope":
            return self.reply(403, {"error": "authorization_error", "message": "API key does not have access to this resource"})
        if method == "auth.info":
            return self.reply(200, {"data": {"user": {"name": "Tester"}, "team": {"name": "Team"}}})
        if method == "collections.list":
            return self.paged(st.cols, body)
        if method == "collections.create":
            c = {"id": "33333333-3333-4333-8333-333333333333", "name": body["name"], "permission": body["permission"]}
            st.cols.append(c)
            return self.reply(200, {"data": c})
        if method == "documents.list":
            docs = [d for d in st.docs.values() if not d.get("deletedAt")]
            if body.get("collectionId"):
                docs = [d for d in docs if d["collectionId"] == body["collectionId"]]
            if body.get("parentDocumentId"):
                docs = [d for d in docs if d["parentDocumentId"] == body["parentDocumentId"]]
            return self.paged(docs, body)
        if method == "documents.search":
            hits = [{"document": d, "context": "...%s..." % body["query"]} for d in st.docs.values()
                    if body["query"] in d["title"] + d["text"]]
            return self.paged(hits, body)
        if method == "documents.create":
            st.seq += 1
            d = {"id": "d0000000-0000-4000-8000-%012d" % st.seq, "urlId": "u%d" % st.seq, "title": body["title"],
                 "text": body["text"], "collectionId": body["collectionId"],
                 "parentDocumentId": body.get("parentDocumentId"), "url": "/doc/t-u%d" % st.seq,
                 "updatedAt": "2026-01-01T00:00:00Z"}
            st.docs[d["id"]] = d
            return self.reply(200, {"data": d})
        if method == "attachments.create":
            host = "http://127.0.0.1:%d" % self.server.server_port
            url = st.upload_url or "/upload"
            if url == "ABS":
                url = "http://localhost:%d/upload" % self.server.server_port
            return self.reply(200, {"data": {
                "uploadUrl": url, "form": {"key": "uploads/x/y/p.jpg", "Content-Disposition": 'inline; filename="p.jpg"',
                                           "policy": "a;b=\"c\""},
                "attachment": {"url": "/api/attachments.redirect?id=att1"}}})
        d = self.find(body.get("id", ""))
        if d is None:
            return self.reply(404, {"error": "not_found", "message": "Resource not found"})
        if method == "documents.info":
            return self.reply(200, {"data": d})
        if method == "documents.update":
            for k in ("title", "text"):
                if k in body:
                    d[k] = body[k]
            return self.reply(200, {"data": d})
        if method == "documents.move":
            d["collectionId"] = body["collectionId"]
            d["parentDocumentId"] = body.get("parentDocumentId")
            return self.reply(200, {"data": {"documents": [d], "collections": []}})
        if method == "documents.delete":
            d["deletedAt"] = "2026-01-02T00:00:00Z"
            return self.reply(200, {"success": True})
        if method == "documents.export":
            return self.reply(200, {"data": "# " + d["title"] + "\n\n" + d["text"]})
        self.reply(404, {"message": "no method"})

    def paged(self, items, body):
        off, lim = body.get("offset", 0), body.get("limit", 25)
        self.server.state.last_limit = lim
        self.reply(200, {"data": items[off:off + lim], "pagination": {"limit": lim, "offset": off}})


class WikiTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.server.state = State()
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.tmp = tempfile.TemporaryDirectory()
        cls.token_path = os.path.join(cls.tmp.name, "token")
        with open(cls.token_path, "w") as f:
            f.write(TOKEN + "\n")
        os.chmod(cls.token_path, 0o600)
        cls.cfg_path = os.path.join(cls.tmp.name, "outline.json")
        cls.img = os.path.join(cls.tmp.name, "p.jpg")
        with open(cls.img, "wb") as f:
            f.write(b"\xff\xd8\xff\xe0JPEGDATA\r\n--not-a-boundary")

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
        self.st.reset()
        self.write_cfg({"base_url": "http://127.0.0.1:%d" % self.server.server_port, "token_file": self.token_path})

    def run_wiki(self, *args, stdin=None, cfg=None):
        env = dict(os.environ, OUTLINE_CONFIG=cfg or self.cfg_path, NO_PROXY="127.0.0.1,localhost",
                   no_proxy="127.0.0.1,localhost")
        for k in ("HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy"):
            env.pop(k, None)
        return subprocess.run([sys.executable, SCRIPT, *args], input=stdin, capture_output=True, text=True,
                              env=env, timeout=30)

    def tmpfile(self, text, name="in.md"):
        p = os.path.join(self.tmp.name, name)
        with open(p, "w", encoding="utf-8") as f:
            f.write(text)
        return p

    def add_doc(self, title, text="body", parent=None, col=COL):
        r = self.run_wiki("create", "--collection", col, "--title", title, "--file", self.tmpfile(text),
                          *(["--parent", parent] if parent else []))
        self.assertEqual(r.returncode, 0, r.stderr)
        return json.loads(r.stdout)

    def test_doctor(self):
        r = self.run_wiki("doctor")
        self.assertEqual(r.returncode, 0, r.stderr)
        out = json.loads(r.stdout)
        self.assertEqual((out["user"], out["team"], out["collection_count"]), ("Tester", "Team", 2))
        self.assertNotIn(TOKEN, r.stdout + r.stderr)

    def test_collections_and_create(self):
        out = json.loads(self.run_wiki("collections").stdout)
        self.assertEqual([c["name"] for c in out], ["Notes", "Other"])
        r = self.run_wiki("collection-create", "Priv")
        self.assertIsNone(json.loads(r.stdout)["permission"])
        body = [b for m, b, _ in self.st.requests if m == "collections.create"][0]
        self.assertEqual(body, {"name": "Priv", "permission": None, "sharing": False})

    def test_crud_roundtrip(self):
        c = self.add_doc("제목", "# 제목\n본문")
        self.assertEqual(c["url"], "http://127.0.0.1:%d/doc/t-u1" % self.server.server_port)
        self.assertTrue([b for m, b, _ in self.st.requests if m == "documents.create"][0]["publish"])
        r = self.run_wiki("get", c["urlId"], "--markdown")
        self.assertEqual(r.stdout, "# 제목\n본문\n")
        r = self.run_wiki("update", c["id"], "--file", self.tmpfile("바뀐 본문"), "--title", "새 제목")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.st.docs[c["id"]]["text"], "바뀐 본문")
        self.assertEqual(self.st.docs[c["id"]]["title"], "새 제목")
        r = self.run_wiki("export", c["id"])
        self.assertTrue(r.stdout.startswith("# 새 제목"))
        r = self.run_wiki("delete", c["urlId"])
        self.assertEqual(json.loads(r.stdout)["verified"], "deletedAt")

    def test_get_by_url(self):
        c = self.add_doc("t")
        r = self.run_wiki("get", "https://wiki.example.com/doc/slug-words-%s?x=1" % c["urlId"])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.st.requests[-1][1]["id"], "slug-words-" + c["urlId"])
        # 형식 오류는 요청 전에 걸러낸다
        self.assertEqual(self.run_wiki("get", "https://wiki.example.com/other/x").returncode, 1)
        self.assertEqual(self.run_wiki("get", "a/b").returncode, 1)

    def test_collection_resolution(self):
        self.add_doc("n1")
        self.assertEqual(len(json.loads(self.run_wiki("list", "--collection", "Notes").stdout)), 1)
        self.assertEqual(len(json.loads(self.run_wiki("list", "--collection", COL2).stdout)), 0)
        r = self.run_wiki("list", "--collection", "Nope")
        self.assertEqual(r.returncode, 1)
        self.st.cols.append({"id": "44444444-4444-4444-8444-444444444444", "name": "Notes", "permission": None})
        r = self.run_wiki("list", "--collection", "Notes")
        self.assertEqual(r.returncode, 1)
        self.assertIn("2개", r.stderr)

    def test_pagination(self):
        self.st.cols = [{"id": "00000000-0000-4000-8000-%012d" % i, "name": "c%d" % i, "permission": None}
                        for i in range(230)]
        out = json.loads(self.run_wiki("collections").stdout)
        self.assertEqual(len(out), 230)
        offsets = [b["offset"] for m, b, _ in self.st.requests if m == "collections.list"]
        self.assertEqual(offsets, [0, 100, 200])
        self.assertTrue(all(b["limit"] == 100 for m, b, _ in self.st.requests))

    def test_tree_and_parent_list(self):
        p = self.add_doc("부모")
        self.add_doc("자식", parent=p["urlId"])
        r = self.run_wiki("tree", "--collection", "Notes")
        self.assertEqual(r.stdout.splitlines(), ["Notes", "  - 부모 [u1]", "    - 자식 [u2]"])
        kids = json.loads(self.run_wiki("list", "--parent", p["id"]).stdout)
        self.assertEqual([k["title"] for k in kids], ["자식"])

    def test_search(self):
        self.add_doc("alpha", "needle here")
        self.add_doc("beta", "nothing")
        out = json.loads(self.run_wiki("search", "needle", "--limit", "3").stdout)
        self.assertEqual([o["title"] for o in out], ["alpha"])
        self.assertIn("needle", out[0]["context"])
        self.assertEqual([b for m, b, _ in self.st.requests if m == "documents.search"][0]["limit"], 3)

    def test_upsert(self):
        p = self.add_doc("부모")
        r = json.loads(self.run_wiki("upsert", "--collection", "Notes", "--title", "이력서", "--file",
                                     self.tmpfile("v1")).stdout)
        self.assertEqual(r["action"], "created")
        r2 = json.loads(self.run_wiki("upsert", "--collection", "Notes", "--title", "이력서", "--file",
                                      self.tmpfile("v2")).stdout)
        self.assertEqual((r2["action"], r2["id"]), ("updated", r["id"]))
        self.assertEqual(self.st.docs[r["id"]]["text"], "v2")
        # 같은 제목이라도 부모가 다르면 새 문서
        r3 = json.loads(self.run_wiki("upsert", "--collection", "Notes", "--title", "이력서", "--file",
                                      self.tmpfile("v3"), "--parent", p["id"]).stdout)
        self.assertEqual(r3["action"], "created")
        self.assertEqual(r3["parentDocumentId"], p["id"])
        self.assertEqual(len([d for d in self.st.docs.values() if d["title"] == "이력서"]), 2)

    def test_move(self):
        a, b = self.add_doc("a"), self.add_doc("b")
        r = json.loads(self.run_wiki("move", a["id"], "--parent", b["urlId"]).stdout)
        self.assertEqual(r["parentDocumentId"], b["id"])
        mv = [x for m, x, _ in self.st.requests if m == "documents.move"][0]
        self.assertEqual(mv["collectionId"], COL)
        r = json.loads(self.run_wiki("move", a["id"], "--collection", "Other").stdout)
        self.assertEqual((r["collectionId"], r["parentDocumentId"]), (COL2, None))
        self.assertEqual(self.run_wiki("move", a["id"]).returncode, 1)

    def test_upload_image_multipart(self):
        d = self.add_doc("t")
        r = self.run_wiki("upload-image", d["urlId"], self.img, "--layout", "right-50", "--width", "120", "--alt", "사진")
        self.assertEqual(r.returncode, 0, r.stderr)
        out = json.loads(r.stdout)
        self.assertEqual(out["markdown"], '![사진](/api/attachments.redirect?id=att1 "right-50 =120x")')
        up = self.st.uploads[0]
        names = [p[0] for p in up["parts"]]
        self.assertEqual(names[-1], "file")
        self.assertEqual(names[:-1], ["key", "Content-Disposition", "policy"])
        by = {p[0]: p for p in up["parts"]}
        self.assertEqual(by["Content-Disposition"][1], b'inline; filename="p.jpg"')
        self.assertEqual(by["policy"][1], b'a;b="c"')
        self.assertEqual(by["file"][1], b"\xff\xd8\xff\xe0JPEGDATA\r\n--not-a-boundary")
        ac = [b for m, b, _ in self.st.requests if m == "attachments.create"][0]
        self.assertEqual((ac["contentType"], ac["preset"], ac["documentId"]), ("image/jpeg", "documentAttachment", d["id"]))
        self.assertEqual(ac["size"], len(by["file"][1]))
        self.assertEqual(self.st.docs[d["id"]]["text"], "body")  # upload-image 는 문서를 건드리지 않는다

    def test_upload_token_not_sent_to_other_host(self):
        d = self.add_doc("t")
        self.assertEqual(self.run_wiki("upload-image", d["id"], self.img).returncode, 0)
        self.assertEqual(self.st.uploads[0]["auth"], "Bearer " + TOKEN)  # 상대 경로 = 같은 서버
        self.st.upload_url = "ABS"  # localhost != 127.0.0.1 이라 다른 호스트
        self.assertEqual(self.run_wiki("upload-image", d["id"], self.img).returncode, 0)
        self.assertIsNone(self.st.uploads[1]["auth"])

    def test_upload_s3_error(self):
        d = self.add_doc("t")
        self.st.mode = "s3error"
        r = self.run_wiki("upload-image", d["id"], self.img)
        self.assertEqual(r.returncode, 1)
        self.assertIn("AccessDenied", r.stderr)
        self.assertIn("Policy expired", r.stderr)

    def test_upload_rejects_non_image(self):
        d = self.add_doc("t")
        n = len(self.st.requests)
        r = self.run_wiki("upload-image", d["id"], self.tmpfile("x", "a.txt"))
        self.assertEqual(r.returncode, 1)
        self.assertEqual(len(self.st.requests), n)  # 이미지가 아니면 API 를 부르기 전에 거절한다

    def test_insert_image(self):
        d = self.add_doc("t", "# 이력서\n본문 첫줄\n\n```\n# 코드\n```")
        r = self.run_wiki("insert-image", d["id"], self.img, "--alt", "x", "--after-heading")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.st.docs[d["id"]]["text"],
                         '# 이력서\n\n![x](/api/attachments.redirect?id=att1)\n\n본문 첫줄\n\n```\n# 코드\n```')

    def test_insert_image_skips_fence_and_no_h1(self):
        d = self.add_doc("t", "```\n# in fence\n```\ntext")
        self.run_wiki("insert-image", d["id"], self.img, "--alt", "x")
        self.assertTrue(self.st.docs[d["id"]]["text"].startswith("![x](/api/attachments.redirect?id=att1)\n\n```"))

    def test_html_warning(self):
        r = self.run_wiki("create", "--collection", "Notes", "--title", "h", "--file",
                          self.tmpfile('<img src="a.jpg">\n\n`<br>` 와 ```\n<div>\n``` 는 코드'))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("HTML", r.stderr)
        self.assertIn("<img", r.stderr)
        self.assertEqual(len(self.st.docs), 1)  # 경고하되 업로드는 한다
        r = self.run_wiki("create", "--collection", "Notes", "--title", "h2", "--file", self.tmpfile("`<br>` 만 코드"))
        self.assertNotIn("경고", r.stderr)

    def test_input_validation(self):
        self.assertEqual(self.run_wiki("create", "--collection", "Notes", "--title", "x", "--file", "-", stdin=" \n").returncode, 1)
        self.assertEqual(self.run_wiki("create", "--collection", "Notes", "--title", "x", "--file", "/nonexistent.md").returncode, 1)
        bad = os.path.join(self.tmp.name, "bad.bin")
        with open(bad, "wb") as f:
            f.write(b"\xff\xfe\x00")
        self.assertEqual(self.run_wiki("create", "--collection", "Notes", "--title", "x", "--file", bad).returncode, 1)
        self.assertNotIn("documents.create", [m for m, _, _ in self.st.requests])

    def test_stdin(self):
        r = self.run_wiki("create", "--collection", "Notes", "--title", "s", "--file", "-", stdin="# s\n본문")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(list(self.st.docs.values())[0]["text"], "# s\n본문")

    def test_token_masked_in_output(self):
        self.add_doc("leak", "leak " + TOKEN)
        for args in (("get", "u1"), ("get", "u1", "--markdown"), ("export", "u1")):
            r = self.run_wiki(*args)
            self.assertNotIn(TOKEN, r.stdout + r.stderr)
            self.assertIn("***", r.stdout)

    def test_error_body_not_printed(self):
        self.st.mode = "fail500"
        r = self.run_wiki("collections")
        self.assertEqual(r.returncode, 1)
        self.assertNotIn("boom", r.stdout + r.stderr)
        self.assertNotIn(TOKEN, r.stdout + r.stderr)

    def test_status_messages(self):
        with open(self.token_path + "2", "w") as f:
            f.write("wrong\n")
        os.chmod(self.token_path + "2", 0o600)
        self.write_cfg({"base_url": "http://127.0.0.1:%d" % self.server.server_port, "token_file": self.token_path + "2"})
        r = self.run_wiki("collections")
        self.assertIn("401", r.stderr)
        self.assertNotIn("secret-body", r.stderr)
        self.setUp()
        r = self.run_wiki("get", "nonexistent")
        self.assertIn("404", r.stderr)
        self.assertIn("단정하지 않는다", r.stderr)

    def test_scope_message(self):
        self.st.mode = "scope"
        r = self.run_wiki("collections")
        self.assertEqual(r.returncode, 1)
        self.assertIn("403", r.stderr)
        self.assertIn("collections:read", r.stderr)
        self.st.mode = "scope"
        r = self.run_wiki("create", "--collection", COL, "--title", "x", "--file", self.tmpfile("a"))
        self.assertIn("documents:write", r.stderr)

    def test_doctor_without_auth_info_scope(self):
        self.st.mode = "no_auth_scope"
        r = self.run_wiki("doctor")
        self.assertEqual(r.returncode, 0, r.stderr)
        out = json.loads(r.stdout)
        self.assertIsNone(out["user"])
        self.assertEqual(out["collection_count"], 2)
        self.assertIn("auth.info", out["note"])

    def test_rate_limit(self):
        self.st.mode = "rate"
        r = self.run_wiki("collections")
        self.assertEqual(r.returncode, 1)
        self.assertIn("429", r.stderr)
        self.assertIn("7초", r.stderr)
        self.assertNotIn(TOKEN, r.stdout + r.stderr)
        self.assertEqual(len(self.st.requests), 1)

    def test_redirect_blocked(self):
        self.st.mode = "redirect"
        r = self.run_wiki("collections")
        self.assertEqual(r.returncode, 1)
        self.assertEqual(len(self.st.requests), 1)
        self.assertIn("리다이렉트", r.stderr)

    def test_no_retry(self):
        self.st.mode = "fail500"
        self.run_wiki("create", "--collection", COL, "--title", "x", "--file", "-", stdin="a")
        self.assertEqual(len(self.st.requests), 1)

    def test_config_missing(self):
        r = self.run_wiki("collections", cfg=os.path.join(self.tmp.name, "absent.json"))
        self.assertEqual(r.returncode, 1)
        self.assertIn("https://wiki.example.com", r.stderr)
        self.assertIn("token_file", r.stderr)
        self.assertIn("documents:write", r.stderr)

    def test_config_incomplete_and_unsafe(self):
        base = "http://127.0.0.1:%d" % self.server.server_port
        cases = [
            {},
            {"base_url": base},
            {"base_url": "http://wiki.example.com", "token_file": self.token_path},
            {"base_url": "https://user:pw@wiki.example.com", "token_file": self.token_path},
            {"base_url": "https://wiki.example.com", "token_file": self.token_path + ".missing"},
        ]
        for cfg in cases:
            self.write_cfg(cfg)
            r = self.run_wiki("collections")
            self.assertEqual(r.returncode, 1, cfg)
            self.assertNotIn("pw@", r.stdout)
        self.assertEqual(self.st.requests, [])

    def test_inline_token_key(self):
        self.write_cfg({"base_url": "http://127.0.0.1:%d" % self.server.server_port, "token": TOKEN})
        os.chmod(self.cfg_path, 0o600)
        self.assertEqual(self.run_wiki("collections").returncode, 0)

    def test_open_permission_warns_but_runs(self):
        os.chmod(self.token_path, 0o644)
        try:
            r = self.run_wiki("collections")
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn("경고", r.stderr)
            self.assertNotIn(TOKEN, r.stderr)
        finally:
            os.chmod(self.token_path, 0o600)

    def test_help(self):
        for sub in ("doctor", "upsert", "insert-image", "upload-image", "move"):
            r = subprocess.run([sys.executable, SCRIPT, sub, "--help"], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, sub)


if __name__ == "__main__":
    unittest.main()
