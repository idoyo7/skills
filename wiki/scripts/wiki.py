#!/usr/bin/env python3
"""Outline 위키 REST API 클라이언트. 표준 라이브러리만 쓴다."""
import argparse
import ipaddress
import json
import mimetypes
import os
import re
import secrets
import stat
import sys
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_CONFIG = "~/.config/outline.json"
API = "/api"
LAYOUTS = ("right-50", "left-50", "full-width")
ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,200}$")
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
HTML_TAG_RE = re.compile(
    r"<\s*/?\s*(?:img|div|br|span|p|table|tr|td|th|a|font|center|b|i|u|strong|em|h[1-6]|ul|ol|li|style|script)\b[^>]*>",
    re.IGNORECASE)
READ_VERBS = ("list", "info", "search", "export")
SCOPE_LIST = "collections:read collections:write documents:read documents:write attachments:read attachments:write"
PAGE_LIMIT = 100
MAX_PAGES = 1000

CONFIG_HELP = """설정 파일이 필요하다. 아래 내용으로 {path} 를 만든다 (권한 600 권장).

{{
  "base_url": "https://wiki.example.com",
  "token_file": "~/.config/outline/token",
  "timeout_seconds": 20
}}

token_file 은 Outline API 키 한 줄만 든 파일이다. 파일 대신 "token" 키에 직접 넣을 수도 있다.
API 키는 Outline 설정 → API Keys 에서 발급한다. 권장 스코프: """ + SCOPE_LIST + """
설정 파일 경로는 환경변수 OUTLINE_CONFIG 로 바꿀 수 있다."""


class WikiError(Exception):
    def __init__(self, msg, status=None):
        Exception.__init__(self, msg)
        self.status = status


def is_loopback(host):
    if host == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def warn_if_open(path, label):
    try:
        mode = os.stat(path).st_mode
    except OSError:
        return
    if mode & (stat.S_IRWXG | stat.S_IRWXO):
        print("경고: %s 권한이 group/other 에 열려 있다 (%s). chmod 600 을 권장한다."
              % (label, oct(stat.S_IMODE(mode))), file=sys.stderr)


def load_config():
    path = os.path.expanduser(os.environ.get("OUTLINE_CONFIG") or DEFAULT_CONFIG)
    if not os.path.isfile(path):
        raise WikiError(CONFIG_HELP.format(path=path))
    try:
        with open(path, encoding="utf-8") as f:
            cfg = json.load(f)
    except (OSError, ValueError):
        raise WikiError("설정 파일 %s 을 JSON 으로 읽지 못했다.\n%s" % (path, CONFIG_HELP.format(path=path)))
    if not isinstance(cfg, dict):
        raise WikiError("설정 파일 %s 의 최상위는 JSON 객체여야 한다.\n%s" % (path, CONFIG_HELP.format(path=path)))

    base = cfg.get("base_url")
    if not isinstance(base, str) or not base.strip():
        raise WikiError("설정 파일 %s 에 base_url 이 없다.\n%s" % (path, CONFIG_HELP.format(path=path)))
    parts = urllib.parse.urlsplit(base.strip())
    if parts.username is not None or parts.password is not None or "@" in parts.netloc:
        raise WikiError("base_url 에 인증정보(userinfo)를 넣을 수 없다.")
    if parts.query or parts.fragment:
        raise WikiError("base_url 에는 쿼리·프래그먼트를 넣을 수 없다.")
    host = parts.hostname or ""
    if not host:
        raise WikiError("base_url 의 호스트를 읽지 못했다.")
    if parts.scheme != "https" and not (parts.scheme == "http" and is_loopback(host)):
        raise WikiError("base_url 은 https 만 허용한다 (테스트용 loopback http 제외).")
    base_url = base.strip().rstrip("/")

    token = None
    token_file = cfg.get("token_file")
    if isinstance(token_file, str) and token_file.strip():
        tpath = os.path.expanduser(token_file.strip())
        try:
            with open(tpath, encoding="utf-8") as f:
                token = f.read().strip()
        except OSError:
            raise WikiError("token_file %s 을 읽지 못했다. 토큰만 한 줄 든 파일이어야 한다." % tpath)
        warn_if_open(tpath, "token_file")
    elif isinstance(cfg.get("token"), str):
        token = cfg["token"].strip()
        warn_if_open(path, "설정 파일")
    if not token or re.search(r"\s", token):
        raise WikiError("토큰이 비었거나 공백을 포함한다. token_file(토큰 한 줄) 또는 token 을 설정한다.\n"
                        + CONFIG_HELP.format(path=path))

    timeout = cfg.get("timeout_seconds", 20)
    if isinstance(timeout, bool) or not isinstance(timeout, (int, float)) or timeout <= 0:
        raise WikiError("timeout_seconds 는 양수여야 한다.")
    return {"base_url": base_url, "token": token, "timeout": timeout}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Client:
    def __init__(self, cfg):
        self.root = cfg["base_url"]
        self.base = self.root + API
        self.token = cfg["token"]
        self.timeout = cfg["timeout"]
        self.opener = urllib.request.build_opener(NoRedirect)
        self._collections = None

    def mask(self, text):
        return text.replace(self.token, "***") if self.token else text

    def call(self, method, body=None):
        """POST {base}/api/<method>. 응답 JSON 전체를 돌려준다."""
        headers = {"Authorization": "Bearer " + self.token, "Accept": "application/json",
                   "Content-Type": "application/json"}
        req = urllib.request.Request(self.base + "/" + method, data=json.dumps(body or {}).encode("utf-8"),
                                     method="POST", headers=headers)
        try:
            with self.opener.open(req, timeout=self.timeout) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as e:
            try:
                err = json.loads(e.read().decode("utf-8"))
            except (ValueError, OSError):
                err = {}
            msg = err.get("message") if isinstance(err, dict) else None
            raise WikiError(self.http_message(method, e.code, msg if isinstance(msg, str) else "",
                                              e.headers.get("Retry-After")), e.code)
        except (urllib.error.URLError, OSError) as e:
            reason = getattr(e, "reason", e)
            raise WikiError("%s 요청 실패: %s" % (method, self.mask(type(reason).__name__)))
        if not raw.strip():
            return {}
        try:
            return json.loads(raw.decode("utf-8"))
        except ValueError:
            raise WikiError("%s 응답이 JSON 이 아니다." % method)

    def http_message(self, method, code, message, retry_after=None):
        if code == 400:
            return "400: 요청이 올바르지 않다 (%s)%s" % (method, ": " + self.mask(message) if message else "")
        if code == 401:
            return "401: 인증이 거부됐거나 API 키가 만료·폐기됐다. Outline 설정 → API Keys 에서 새 키를 발급한다."
        if code == 403:
            if "api key does not have access" in message.lower():
                area, _, verb = method.partition(".")
                scope = method if area == "auth" else "%s:%s" % (area, "read" if verb in READ_VERBS else "write")
                return ("403: API 키의 스코프에 이 작업(%s)이 빠져 있다. %s 스코프를 더해 키를 새로 발급한다. "
                        "권장 전체 스코프: %s" % (method, scope, SCOPE_LIST))
            return "403: 이 계정·키에 해당 작업 권한이 없다 (%s)." % method
        if code == 404:
            return "404: 대상 리소스가 없거나 접근할 수 없다 (%s). 토큰 문제로 단정하지 않는다." % method
        if code == 429:
            return ("429: 요청 한도를 넘었다 (%s)%s. 자동 재시도하지 않는다."
                    % (method, ", %s초 뒤 다시 시도" % retry_after if retry_after else ""))
        if 300 <= code < 400:
            return "%d: 리다이렉트는 따라가지 않는다. base_url 을 확인한다." % code
        return "%d: 서버가 %s 를 처리하지 못했다. 자동 재시도하지 않는다." % (code, method)

    def paginate(self, method, body, max_items=None):
        items, offset = [], 0
        for _ in range(MAX_PAGES):
            limit = PAGE_LIMIT if max_items is None else min(PAGE_LIMIT, max_items - len(items))
            if limit <= 0:
                break
            chunk = self.call(method, dict(body, limit=limit, offset=offset)).get("data") or []
            items.extend(chunk)
            if len(chunk) < limit:
                break
            offset += limit
        return items

    def collections(self):
        if self._collections is None:
            self._collections = self.paginate("collections.list", {})
        return self._collections

    def absolute(self, url):
        return self.root + url if isinstance(url, str) and url.startswith("/") else url


def doc_ref(value):
    v = value.strip()
    if re.match(r"^https?://", v, re.IGNORECASE):
        m = re.search(r"/doc/([^/?#]+)", urllib.parse.urlsplit(v).path)
        if not m:
            raise WikiError("URL 에서 문서를 찾지 못했다: /doc/<slug> 형태여야 한다.")
        v = m.group(1)
    if not ID_RE.match(v):
        raise WikiError("문서 지정이 올바르지 않다: UUID, urlId, 문서 URL 중 하나여야 한다.")
    return v


def doc_info(c, ref):
    return c.call("documents.info", {"id": doc_ref(ref)}).get("data") or {}


def resolve_collection(c, value):
    if UUID_RE.match(value):
        return value.lower()
    cols = c.collections()
    hits = [x for x in cols if x.get("name") == value]
    if not hits:
        hits = [x for x in cols if (x.get("name") or "").casefold() == value.casefold()]
    if not hits:
        raise WikiError("컬렉션을 찾지 못했다: %s (collections 명령으로 목록을 확인한다)" % value)
    if len(hits) > 1:
        raise WikiError("같은 이름의 컬렉션이 %d개다. id 로 지정한다: %s"
                        % (len(hits), ", ".join(x["id"] for x in hits)))
    return hits[0]["id"]


def read_text(path):
    try:
        if path == "-":
            raw = sys.stdin.buffer.read()
        else:
            with open(os.path.expanduser(path), "rb") as f:
                raw = f.read()
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        raise WikiError("입력은 UTF-8 텍스트여야 한다.")
    except OSError:
        raise WikiError("입력 파일을 읽지 못했다: %s" % path)
    if not text.strip():
        raise WikiError("본문이 비어 있다.")
    if "\x00" in text:
        raise WikiError("본문에 NUL 문자가 있다. 바이너리는 지원하지 않는다.")
    return text


def warn_html(text):
    plain = re.sub(r"```.*?```|~~~.*?~~~", "", text, flags=re.DOTALL)
    plain = re.sub(r"`[^`\n]*`", "", plain)
    tags = sorted({m.group(0)[:40] for m in HTML_TAG_RE.finditer(plain)})
    if tags:
        print("경고: 본문에 HTML 태그가 있다 (%s 등). Outline 은 마크다운 안의 HTML 을 렌더링하지 않고 "
              "글자 그대로 보여 준다. 그대로 올린다." % ", ".join(tags[:3]), file=sys.stderr)


def summary(c, d):
    out = {"id": d.get("id"), "urlId": d.get("urlId"), "title": d.get("title"),
           "parentDocumentId": d.get("parentDocumentId"), "collectionId": d.get("collectionId"),
           "updatedAt": d.get("updatedAt"), "url": c.absolute(d.get("url"))}
    if d.get("deletedAt"):
        out["deletedAt"] = d["deletedAt"]
    return out


def parent_id(c, value):
    return doc_info(c, value).get("id") if value else None


def cmd_doctor(c, a):
    note = None
    try:
        info = c.call("auth.info").get("data") or {}
    except WikiError as e:
        if e.status != 403:
            raise
        # 권장 스코프에는 auth.info 가 없다. 인증은 아래 collections.list 로 확인한다.
        info, note = {}, "auth.info 스코프가 없어 사용자·팀 이름은 생략했다 (키에 auth.info 를 더하면 표시된다)."
    cols = c.collections()
    out = {"ok": True, "authenticated": True,
           "user": (info.get("user") or {}).get("name"), "team": (info.get("team") or {}).get("name"),
           "collections_readable": True, "collection_count": len(cols), "write_checked": False}
    if note:
        out["note"] = note
    return out


def cmd_collections(c, a):
    return [{"id": x.get("id"), "name": x.get("name"), "permission": x.get("permission")} for x in c.collections()]


def cmd_collection_create(c, a):
    body = {"name": a.name, "permission": "read_write" if a.public else None, "sharing": False}
    x = c.call("collections.create", body).get("data") or {}
    c._collections = None
    return {"id": x.get("id"), "name": x.get("name"), "permission": x.get("permission")}


def cmd_list(c, a):
    body = {}
    if a.collection:
        body["collectionId"] = resolve_collection(c, a.collection)
    if a.parent:
        body["parentDocumentId"] = parent_id(c, a.parent)
    return [summary(c, d) for d in c.paginate("documents.list", body)]


def cmd_tree(c, a):
    cols = list(c.collections())
    if a.collection:
        cid = resolve_collection(c, a.collection)
        cols = [x for x in cols if x["id"] == cid] or [{"id": cid, "name": a.collection}]
    lines = []
    for col in cols:
        docs = c.paginate("documents.list", {"collectionId": col["id"]})
        ids = {d["id"] for d in docs}
        kids = {}
        for d in docs:
            p = d.get("parentDocumentId")
            kids.setdefault(p if p in ids else None, []).append(d)
        lines.append(col.get("name") or col["id"])

        def walk(parent, depth):
            for d in kids.get(parent, []):
                lines.append("%s- %s [%s]" % ("  " * depth, d.get("title"), d.get("urlId")))
                walk(d["id"], depth + 1)
        walk(None, 1)
    return "\n".join(lines)


def cmd_search(c, a):
    body = {"query": a.query}
    if a.collection:
        body["collectionId"] = resolve_collection(c, a.collection)
    results = c.paginate("documents.search", body, max_items=a.limit)
    out = []
    for r in results:
        item = summary(c, r.get("document") or {})
        item["context"] = r.get("context")
        out.append(item)
    return out


def cmd_get(c, a):
    d = doc_info(c, a.doc)
    if a.markdown:
        return d.get("text") or ""
    out = summary(c, d)
    out["text"] = d.get("text")
    return out


def cmd_export(c, a):
    d = doc_info(c, a.doc)
    return c.call("documents.export", {"id": d["id"]}).get("data") or ""


def cmd_create(c, a):
    text = read_text(a.file)
    warn_html(text)
    body = {"collectionId": resolve_collection(c, a.collection), "title": a.title, "text": text, "publish": True}
    if a.parent:
        body["parentDocumentId"] = parent_id(c, a.parent)
    return summary(c, c.call("documents.create", body).get("data") or {})


def cmd_update(c, a):
    text = read_text(a.file)
    warn_html(text)
    body = {"id": doc_info(c, a.doc)["id"], "text": text, "publish": True}
    if a.title:
        body["title"] = a.title
    return summary(c, c.call("documents.update", body).get("data") or {})


def cmd_upsert(c, a):
    text = read_text(a.file)
    warn_html(text)
    cid = resolve_collection(c, a.collection)
    pid = parent_id(c, a.parent)
    lb = {"collectionId": cid}
    if pid:
        lb["parentDocumentId"] = pid
    hits = [d for d in c.paginate("documents.list", lb)
            if d.get("title") == a.title and (d.get("parentDocumentId") or None) == pid]
    if len(hits) > 1:
        raise WikiError("같은 제목의 문서가 %d개다. id 로 update 한다: %s"
                        % (len(hits), ", ".join(d["id"] for d in hits)))
    if hits:
        res = c.call("documents.update", {"id": hits[0]["id"], "text": text, "publish": True})
        action = "updated"
    else:
        body = {"collectionId": cid, "title": a.title, "text": text, "publish": True}
        if pid:
            body["parentDocumentId"] = pid
        res = c.call("documents.create", body)
        action = "created"
    return dict(summary(c, res.get("data") or {}), action=action)


def cmd_move(c, a):
    if not a.collection and not a.parent:
        raise WikiError("--collection 또는 --parent 중 하나는 필요하다.")
    d = doc_info(c, a.doc)
    body = {"id": d["id"]}
    if a.parent:
        p = doc_info(c, a.parent)
        body["parentDocumentId"] = p["id"]
        body["collectionId"] = resolve_collection(c, a.collection) if a.collection else p.get("collectionId")
    else:
        body["collectionId"] = resolve_collection(c, a.collection)
    c.call("documents.move", body)
    return summary(c, doc_info(c, d["id"]))


def cmd_delete(c, a):
    d = doc_info(c, a.doc)
    c.call("documents.delete", {"id": d["id"]})
    try:
        after = doc_info(c, d["id"])
        verified = "deletedAt" if after.get("deletedAt") else "not-verified"
    except WikiError as e:
        verified = "404" if e.status == 404 else "not-verified"
    return {"deleted": d["id"], "title": d.get("title"), "verified": verified}


def build_multipart(fields, filename, content_type, data):
    boundary = "----wikipy" + secrets.token_hex(16)
    out = []
    for k, v in fields:
        out.append(('--%s\r\nContent-Disposition: form-data; name="%s"\r\n\r\n%s\r\n'
                    % (boundary, k.replace('"', "%22"), v)).encode("utf-8"))
    safe = filename.replace('"', "%22").replace("\r", "").replace("\n", "")
    out.append(('--%s\r\nContent-Disposition: form-data; name="file"; filename="%s"\r\n'
                'Content-Type: %s\r\n\r\n' % (boundary, safe, content_type)).encode("utf-8"))
    out.append(data)
    out.append(("\r\n--%s--\r\n" % boundary).encode("utf-8"))
    return "multipart/form-data; boundary=" + boundary, b"".join(out)


def image_markdown(alt, url, layout, width):
    parts = []
    if layout:
        parts.append(layout)
    if width:
        parts.append("=%dx" % width)
    title = ' "%s"' % " ".join(parts) if parts else ""
    return "![%s](%s%s)" % (re.sub(r"[\[\]\n]", " ", alt), url, title)


def upload_image(c, a):
    path = os.path.expanduser(a.path)
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        raise WikiError("이미지 파일을 읽지 못했다: %s" % a.path)
    if not data:
        raise WikiError("이미지 파일이 비어 있다.")
    name = os.path.basename(path)
    ctype = mimetypes.guess_type(name)[0] or ""
    if not ctype.startswith("image/"):
        raise WikiError("이미지 파일(확장자로 판별)만 올릴 수 있다: %s" % name)
    doc = doc_info(c, a.doc)
    res = c.call("attachments.create", {"name": name, "contentType": ctype, "size": len(data),
                                         "documentId": doc["id"], "preset": "documentAttachment"}).get("data") or {}
    upload_url, form = res.get("uploadUrl"), res.get("form") or {}
    att_url = (res.get("attachment") or {}).get("url")
    if not upload_url or not att_url:
        raise WikiError("attachments.create 응답에 uploadUrl 또는 attachment.url 이 없다.")
    if upload_url.startswith("/"):
        upload_url = c.root + upload_url
    ctype_header, body = build_multipart([(k, str(v)) for k, v in form.items()], name, ctype, data)
    headers = {"Content-Type": ctype_header}
    if upload_url.startswith(c.root + "/"):
        headers["Authorization"] = "Bearer " + c.token  # 같은 서버로 올릴 때만 토큰을 보낸다
    req = urllib.request.Request(upload_url, data=body, method="POST", headers=headers)
    try:
        with c.opener.open(req, timeout=c.timeout) as resp:
            code = resp.status
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        code_m, msg_m = re.search(r"<Code>(.*?)</Code>", raw), re.search(r"<Message>(.*?)</Message>", raw)
        detail = " ".join(m.group(1) for m in (code_m, msg_m) if m)
        raise WikiError("이미지 업로드 실패 (%d)%s" % (e.code, ": " + c.mask(detail) if detail else ""), e.code)
    except (urllib.error.URLError, OSError) as e:
        raise WikiError("이미지 업로드 요청 실패: %s" % c.mask(type(getattr(e, "reason", e)).__name__))
    if not 200 <= code < 300:
        raise WikiError("이미지 업로드 실패 (%d)" % code, code)
    alt = a.alt if a.alt is not None else os.path.splitext(name)[0]
    return doc, {"url": att_url, "markdown": image_markdown(alt, att_url, a.layout, a.width)}


def cmd_upload_image(c, a):
    return upload_image(c, a)[1]


def insert_after_h1(text, md):
    lines, fence, idx = text.split("\n"), None, None
    for i, line in enumerate(lines):
        m = re.match(r"^\s*(```|~~~)", line)
        if m:
            fence = None if fence == m.group(1) else (fence or m.group(1))
        elif fence is None and re.match(r"^# \S", line):
            idx = i
            break
    if idx is None:
        return md + "\n\n" + text.lstrip("\n")
    rest = lines[idx + 1:]
    while rest and not rest[0].strip():
        rest.pop(0)
    return "\n".join(lines[:idx + 1] + ["", md, ""] + rest)


def cmd_insert_image(c, a):
    doc, res = upload_image(c, a)
    text = c.call("documents.info", {"id": doc["id"]}).get("data", {}).get("text") or ""
    new = insert_after_h1(text, res["markdown"])
    c.call("documents.update", {"id": doc["id"], "text": new, "publish": True})
    return dict(res, inserted=True)


def positive(s):
    n = int(s)
    if n < 1:
        raise argparse.ArgumentTypeError("1 이상이어야 한다")
    return n


def add_image_opts(s):
    s.add_argument("--layout", choices=LAYOUTS, default=None)
    s.add_argument("--width", type=positive, default=None, help="=Nx 로 들어갈 가로 크기(px)")
    s.add_argument("--alt", default=None, help="대체 텍스트 (기본: 파일명)")


def build_parser():
    p = argparse.ArgumentParser(description="Outline 위키 클라이언트")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("doctor", help="설정·인증·조회 확인 (읽기 전용)").set_defaults(fn=cmd_doctor)
    sub.add_parser("collections", help="컬렉션 목록").set_defaults(fn=cmd_collections)
    s = sub.add_parser("collection-create", help="컬렉션 생성 (기본 비공개)")
    s.add_argument("name")
    s.add_argument("--public", action="store_true", help="팀 전체 읽기·쓰기 (기본은 비공개)")
    s.set_defaults(fn=cmd_collection_create)
    s = sub.add_parser("list", help="문서 목록")
    s.add_argument("--collection")
    s.add_argument("--parent", help="상위 문서 (UUID·urlId·URL)")
    s.set_defaults(fn=cmd_list)
    s = sub.add_parser("tree", help="제목 트리 (텍스트)")
    s.add_argument("--collection")
    s.set_defaults(fn=cmd_tree)
    s = sub.add_parser("search", help="문서 검색")
    s.add_argument("query")
    s.add_argument("--collection")
    s.add_argument("--limit", type=positive, default=25)
    s.set_defaults(fn=cmd_search)
    s = sub.add_parser("get", help="문서 조회")
    s.add_argument("doc", help="UUID·urlId·문서 URL")
    s.add_argument("--markdown", action="store_true", help="본문 마크다운만 출력")
    s.set_defaults(fn=cmd_get)
    s = sub.add_parser("export", help="문서를 마크다운으로 내보내기 (documents.export)")
    s.add_argument("doc")
    s.set_defaults(fn=cmd_export)
    s = sub.add_parser("create", help="문서 생성")
    s.add_argument("--collection", required=True)
    s.add_argument("--title", required=True)
    s.add_argument("--file", required=True, help="본문 파일 경로, - 는 stdin")
    s.add_argument("--parent")
    s.set_defaults(fn=cmd_create)
    s = sub.add_parser("update", help="문서 본문 교체")
    s.add_argument("doc")
    s.add_argument("--file", required=True)
    s.add_argument("--title")
    s.set_defaults(fn=cmd_update)
    s = sub.add_parser("upsert", help="같은 제목이 있으면 갱신, 없으면 생성")
    s.add_argument("--collection", required=True)
    s.add_argument("--title", required=True)
    s.add_argument("--file", required=True)
    s.add_argument("--parent")
    s.set_defaults(fn=cmd_upsert)
    s = sub.add_parser("move", help="문서 이동")
    s.add_argument("doc")
    s.add_argument("--collection")
    s.add_argument("--parent")
    s.set_defaults(fn=cmd_move)
    s = sub.add_parser("delete", help="문서 삭제 (휴지통)")
    s.add_argument("doc")
    s.set_defaults(fn=cmd_delete)
    s = sub.add_parser("upload-image", help="이미지 업로드 후 마크다운 출력 (문서는 수정하지 않음)")
    s.add_argument("doc")
    s.add_argument("path")
    add_image_opts(s)
    s.set_defaults(fn=cmd_upload_image)
    s = sub.add_parser("insert-image", help="이미지 업로드 후 첫 H1 바로 아래에 삽입")
    s.add_argument("doc")
    s.add_argument("path")
    add_image_opts(s)
    s.add_argument("--after-heading", action="store_true",
                   help="첫 H1 바로 아래에 넣는다 (기본 동작과 같다. H1 이 없으면 맨 위)")
    s.set_defaults(fn=cmd_insert_image)
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    client = None
    try:
        client = Client(load_config())
        result = args.fn(client, args)
        out = result if isinstance(result, str) else json.dumps(result, ensure_ascii=False, indent=2)
        sys.stdout.write(client.mask(out) + "\n")
        return 0
    except WikiError as e:
        msg = client.mask(str(e)) if client else str(e)
        print("오류: " + msg, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
