#!/usr/bin/env python3
"""Server Google Drive tiruan untuk tes fitur Tim (tanpa akun Google sungguhan).

Token = "tok-<email>". Aturan meniru scope drive.file: pemilik selalu bisa membuka filenya;
akun lain butuh izin (permission) DAN sudah "memilih" file lewat Picker (POST /pick).

    python3 scripts/mock-drive.py 127.0.0.1 8790
    curl -X POST 'http://127.0.0.1:8790/pick?email=budi@x.com&file=<id>'
"""
import json
import re
import sys
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

FILES = {}   # id -> {name, mime, owner, data, perms: {pid: {email, role}}, trashed, props}
PICKED = set()  # (email, file_id)


def can_open(email, f, fid):
    if f["trashed"]:
        return False
    if f["owner"] == email:
        return True
    shared = any(p["email"] == email for p in f["perms"].values())
    return shared and (email, fid) in PICKED


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, body=b"", ctype="application/json"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def err(self, code, msg):
        self.reply(code, {"error": {"code": code, "message": msg}})

    def who(self):
        a = self.headers.get("Authorization", "")
        return a[len("Bearer tok-"):] if a.startswith("Bearer tok-") else None

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def handle_any(self, method):
        u = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        path = u.path
        if method == "POST" and path == "/pick":
            PICKED.add((q["email"], q["file"]))
            return self.reply(200, {"ok": True})
        if method == "GET" and path == "/debug":
            return self.reply(200, {k: {**v, "data": v["data"].decode("utf-8", "replace")} for k, v in FILES.items()})
        email = self.who()
        if not email:
            return self.err(401, "Invalid Credentials")

        if method == "POST" and path == "/upload/drive/v3/files":
            raw = self.body()
            boundary = re.search(r"boundary=(\S+)", self.headers["Content-Type"]).group(1).encode()
            parts = [p for p in raw.split(b"--" + boundary) if p.strip() not in (b"", b"--")]
            meta = json.loads(parts[0].split(b"\r\n\r\n", 1)[1].strip())
            data = parts[1].split(b"\r\n\r\n", 1)[1]
            data = data[:-2] if data.endswith(b"\r\n") else data
            fid = uuid.uuid4().hex[:16]
            FILES[fid] = {"name": meta["name"], "mime": meta.get("mimeType"), "owner": email, "data": data,
                          "perms": {}, "trashed": False, "props": meta.get("appProperties", {})}
            return self.reply(200, {"id": fid})

        m = re.fullmatch(r"/upload/drive/v3/files/(\w+)", path)
        if method == "PATCH" and m:
            f = FILES.get(m.group(1))
            if not f or not can_open(email, f, m.group(1)):
                return self.err(404, "File not found")
            f["data"] = self.body()
            return self.reply(200, {"id": m.group(1)})

        if method == "GET" and path == "/drive/v3/files":
            mime = re.search(r"mimeType = '([^']+)'", q.get("q", ""))
            out = [{"id": fid, "name": f["name"], "owners": [{"emailAddress": f["owner"]}]}
                   for fid, f in FILES.items()
                   if can_open(email, f, fid) and (not mime or f["mime"] == mime.group(1))]
            return self.reply(200, {"files": out})

        m = re.fullmatch(r"/drive/v3/files/(\w+)", path)
        if m:
            fid = m.group(1)
            f = FILES.get(fid)
            if not f or not can_open(email, f, fid):
                return self.err(404, "File not found")
            if method == "GET" and q.get("alt") == "media":
                return self.reply(200, f["data"], "application/octet-stream")
            if method == "PATCH":
                if f["owner"] != email:
                    return self.err(403, "The user does not have sufficient permissions for this file.")
                f.update(json.loads(self.body() or b"{}"))
                return self.reply(200, {"id": fid})

        m = re.fullmatch(r"/drive/v3/files/(\w+)/permissions(?:/(\w+))?", path)
        if m:
            fid, pid = m.groups()
            f = FILES.get(fid)
            if not f or not can_open(email, f, fid):
                return self.err(404, "File not found")
            if method == "POST":
                if f["owner"] != email:
                    return self.err(403, "The user does not have sufficient permissions for this file.")
                b = json.loads(self.body())
                new = uuid.uuid4().hex[:8]
                f["perms"][new] = {"email": b["emailAddress"].lower(), "role": b["role"], "message": q.get("emailMessage")}
                return self.reply(200, {"id": new})
            if method == "GET":
                perms = [{"id": "owner", "emailAddress": f["owner"], "role": "owner"}] + \
                        [{"id": k, "emailAddress": v["email"], "role": v["role"]} for k, v in f["perms"].items()]
                return self.reply(200, {"permissions": perms})
            if method == "DELETE":
                p = f["perms"].get(pid)
                if not p:
                    return self.err(404, "Permission not found")
                if f["owner"] != email and p["email"] != email:
                    return self.err(403, "The user does not have sufficient permissions for this file.")
                del f["perms"][pid]
                return self.reply(204)
        return self.err(404, "Not found: " + method + " " + path)

    def do_GET(self): self.handle_any("GET")
    def do_POST(self): self.handle_any("POST")
    def do_PATCH(self): self.handle_any("PATCH")
    def do_DELETE(self): self.handle_any("DELETE")


if __name__ == "__main__":
    host, port = (sys.argv[1], int(sys.argv[2])) if len(sys.argv) > 2 else ("127.0.0.1", 8790)
    print(f"mock drive on {host}:{port}", flush=True)
    ThreadingHTTPServer((host, port), H).serve_forever()
