#!/usr/bin/env python3
"""Memos(usememos) REST API 클라이언트. 표준 라이브러리만 쓴다."""
import argparse
import ipaddress
import json
import os
import re
import stat
import sys
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_CONFIG = "~/.config/memo.json"
API = "/api/v1"
VISIBILITIES = ("PRIVATE", "PROTECTED", "PUBLIC")
ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,128}$")

CONFIG_HELP = """설정 파일이 필요하다. 아래 내용으로 {path} 를 만든다 (권한 600 권장).

{{
  "base_url": "https://memos.example.com",
  "token_file": "~/.config/memos",
  "timeout_seconds": 20
}}

token_file 은 액세스 토큰 한 줄만 든 파일이다. 파일 대신 "token" 키에 직접 넣을 수도 있다.
설정 파일 경로는 환경변수 MEMOS_CONFIG 로 바꿀 수 있다."""


class MemoError(Exception):
    pass


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
    path = os.path.expanduser(os.environ.get("MEMOS_CONFIG") or DEFAULT_CONFIG)
    if not os.path.isfile(path):
        raise MemoError(CONFIG_HELP.format(path=path))
    try:
        with open(path, encoding="utf-8") as f:
            cfg = json.load(f)
    except (OSError, ValueError):
        raise MemoError("설정 파일 %s 을 JSON 으로 읽지 못했다.\n%s" % (path, CONFIG_HELP.format(path=path)))
    if not isinstance(cfg, dict):
        raise MemoError("설정 파일 %s 의 최상위는 JSON 객체여야 한다.\n%s" % (path, CONFIG_HELP.format(path=path)))

    base = cfg.get("base_url")
    if not isinstance(base, str) or not base.strip():
        raise MemoError("설정 파일 %s 에 base_url 이 없다.\n%s" % (path, CONFIG_HELP.format(path=path)))
    parts = urllib.parse.urlsplit(base.strip())
    if parts.username is not None or parts.password is not None or "@" in parts.netloc:
        raise MemoError("base_url 에 인증정보(userinfo)를 넣을 수 없다.")
    if parts.query or parts.fragment:
        raise MemoError("base_url 에는 쿼리·프래그먼트를 넣을 수 없다.")
    host = parts.hostname or ""
    if not host:
        raise MemoError("base_url 의 호스트를 읽지 못했다.")
    if parts.scheme != "https" and not (parts.scheme == "http" and is_loopback(host)):
        raise MemoError("base_url 은 https 만 허용한다 (테스트용 loopback http 제외).")
    base_url = base.strip().rstrip("/")

    token = None
    token_file = cfg.get("token_file")
    if isinstance(token_file, str) and token_file.strip():
        tpath = os.path.expanduser(token_file.strip())
        try:
            with open(tpath, encoding="utf-8") as f:
                token = f.read().strip()
        except OSError:
            raise MemoError("token_file %s 을 읽지 못했다. 토큰만 한 줄 든 파일이어야 한다." % tpath)
        warn_if_open(tpath, "token_file")
    elif isinstance(cfg.get("token"), str):
        token = cfg["token"].strip()
        warn_if_open(path, "설정 파일")
    if not token or re.search(r"\s", token):
        raise MemoError("토큰이 비었거나 공백을 포함한다. token_file(토큰 한 줄) 또는 token 을 설정한다.\n"
                        + CONFIG_HELP.format(path=path))

    timeout = cfg.get("timeout_seconds", 20)
    if isinstance(timeout, bool) or not isinstance(timeout, (int, float)) or timeout <= 0:
        raise MemoError("timeout_seconds 는 양수여야 한다.")
    return {"base_url": base_url, "token": token, "timeout": timeout}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Client:
    def __init__(self, cfg):
        self.base = cfg["base_url"] + API
        self.token = cfg["token"]
        self.timeout = cfg["timeout"]
        self.opener = urllib.request.build_opener(NoRedirect)

    def mask(self, text):
        return text.replace(self.token, "***") if self.token else text

    def request(self, method, path, query=None, body=None):
        url = self.base + path
        if query:
            url += "?" + urllib.parse.urlencode(query)
        data = None
        headers = {"Authorization": "Bearer " + self.token, "Accept": "application/json"}
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=data, method=method, headers=headers)
        try:
            with self.opener.open(req, timeout=self.timeout) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as e:
            raise MemoError(self.http_message(method, path, e.code))
        except (urllib.error.URLError, OSError) as e:
            reason = getattr(e, "reason", e)
            raise MemoError("%s %s 요청 실패: %s" % (method, path, self.mask(type(reason).__name__)))
        if not raw.strip():
            return {}
        try:
            return json.loads(raw.decode("utf-8"))
        except ValueError:
            raise MemoError("%s %s 응답이 JSON 이 아니다." % (method, path))

    @staticmethod
    def http_message(method, path, code):
        if code == 401:
            return "401: 인증이 거부됐거나 토큰이 만료됐다. 토큰을 확인한다."
        if code == 403:
            return "403: 이 토큰에 해당 작업 권한이 없다."
        if code == 404:
            return ("404: 대상 리소스가 없거나 API 경로가 다르다 (%s %s). 토큰 문제로 단정하지 않는다." % (method, path))
        if 300 <= code < 400:
            return "%d: 리다이렉트는 따라가지 않는다. base_url 을 확인한다." % code
        return "%d: 서버가 %s %s 를 처리하지 못했다. 자동 재시도하지 않는다." % (code, method, path)


def memo_id(value):
    v = value[len("memos/"):] if value.startswith("memos/") else value
    if not ID_RE.match(v):
        raise MemoError("메모 ID 형식이 올바르지 않다: memos/ID 또는 ID 만 허용한다.")
    return v


def read_content(path):
    try:
        if path == "-":
            raw = sys.stdin.buffer.read()
        else:
            with open(os.path.expanduser(path), "rb") as f:
                raw = f.read()
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        raise MemoError("입력은 UTF-8 텍스트여야 한다.")
    except OSError:
        raise MemoError("입력 파일을 읽지 못했다: %s" % path)
    if not text.strip():
        raise MemoError("본문이 비어 있다.")
    if "\x00" in text:
        raise MemoError("본문에 NUL 문자가 있다. 바이너리는 지원하지 않는다.")
    return text


def cmd_doctor(c, a):
    auth = None
    tried = []
    for method, path in (("GET", "/auth/me"), ("POST", "/auth/status"), ("GET", "/auth/sessions/current")):
        try:
            c.request(method, path, body={} if method == "POST" else None)
            auth = "%s %s" % (method, path)
            break
        except MemoError as e:
            tried.append("%s %s -> %s" % (method, path, str(e)[:3]))
            # 401/403 은 경로 차이가 아니므로 폴백하지 않는다
            if str(e)[:3] in ("401", "403"):
                raise
    if auth is None:
        raise MemoError("인증 확인 엔드포인트를 찾지 못했다: " + "; ".join(tried))
    res = c.request("GET", "/memos", {"pageSize": 1})
    return {"ok": True, "authenticated": True, "auth_endpoint": auth,
            "memos_readable": isinstance(res.get("memos", []), list),
            "write_checked": False}


def cmd_list(c, a):
    q = {"pageSize": a.page_size}
    if a.page_token:
        q["pageToken"] = a.page_token
    res = c.request("GET", "/memos", q)
    return {"memos": res.get("memos", []), "next_page_token": res.get("nextPageToken", "")}


def cmd_search(c, a):
    needle = a.query.casefold()
    matches, token, pages, complete = [], "", 0, False
    while pages < a.max_pages:
        q = {"pageSize": a.page_size}
        if token:
            q["pageToken"] = token
        res = c.request("GET", "/memos", q)
        pages += 1
        for m in res.get("memos", []):
            if needle in (m.get("content") or "").casefold():
                matches.append(m)
        token = res.get("nextPageToken", "")
        if not token:
            complete = True
            break
    return {"query": a.query, "pages_scanned": pages, "complete": complete, "count": len(matches), "memos": matches}


def cmd_get(c, a):
    return c.request("GET", "/memos/" + memo_id(a.id))


def cmd_create(c, a):
    content = read_content(a.file)
    return c.request("POST", "/memos", body={"content": content, "visibility": a.visibility})


def cmd_update(c, a):
    mid = memo_id(a.id)
    body = {"name": "memos/" + mid, "content": read_content(a.file)}
    mask = ["content"]
    if a.visibility:
        body["visibility"] = a.visibility
        mask.append("visibility")
    return c.request("PATCH", "/memos/" + mid, {"updateMask": ",".join(mask)}, body)


def cmd_delete(c, a):
    mid = memo_id(a.id)
    c.request("DELETE", "/memos/" + mid)
    return {"deleted": "memos/" + mid}


def positive(s):
    n = int(s)
    if n < 1:
        raise argparse.ArgumentTypeError("1 이상이어야 한다")
    return n


def build_parser():
    p = argparse.ArgumentParser(description="Memos 클라이언트")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("doctor", help="설정·인증·조회 확인 (읽기 전용)").set_defaults(fn=cmd_doctor)
    s = sub.add_parser("list", help="메모 목록")
    s.add_argument("--page-size", type=positive, default=20)
    s.add_argument("--page-token", default="")
    s.set_defaults(fn=cmd_list)
    s = sub.add_parser("search", help="본문 로컬 검색 (대소문자 무시)")
    s.add_argument("query")
    s.add_argument("--page-size", type=positive, default=100)
    s.add_argument("--max-pages", type=positive, default=20)
    s.set_defaults(fn=cmd_search)
    s = sub.add_parser("get", help="메모 조회")
    s.add_argument("id")
    s.add_argument("--content-only", action="store_true")
    s.set_defaults(fn=cmd_get)
    s = sub.add_parser("create", help="메모 생성")
    s.add_argument("--file", required=True, help="본문 파일 경로, - 는 stdin")
    s.add_argument("--visibility", choices=VISIBILITIES, default="PRIVATE")
    s.set_defaults(fn=cmd_create)
    s = sub.add_parser("update", help="메모 본문 교체")
    s.add_argument("id")
    s.add_argument("--file", required=True)
    s.add_argument("--visibility", choices=VISIBILITIES, default=None)
    s.set_defaults(fn=cmd_update)
    s = sub.add_parser("delete", help="메모 삭제")
    s.add_argument("id")
    s.set_defaults(fn=cmd_delete)
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    client = None
    try:
        client = Client(load_config())
        result = args.fn(client, args)
        if args.cmd == "get" and args.content_only:
            out = result.get("content", "")
        else:
            out = json.dumps(result, ensure_ascii=False, indent=2)
        sys.stdout.write(client.mask(out) + "\n")
        return 0
    except MemoError as e:
        msg = client.mask(str(e)) if client else str(e)
        print("오류: " + msg, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
