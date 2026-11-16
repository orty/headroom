#!/usr/bin/env python3
"""Local test of the gateway's Envoy config. No Azure, no real tokens.

Needs: an `envoy` binary (ENVOY=path, default `envoy` on PATH, same major
version as the image), python3 with PyJWT and cryptography.

Starts a mock Entra JWKS endpoint (HTTPS, self-signed), a mock Headroom that
echoes the headers it received and can stream SSE slowly, renders the real
template against them, runs Envoy, and checks every routing and auth rule.
Usage: python3 test-envoy.py
"""

from __future__ import annotations

import datetime as dt
import http.client
import http.server
import json
import os
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from pathlib import Path

import jwt
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

HERE = Path(__file__).resolve().parent
TENANT = str(uuid.uuid4())
APP_ID = str(uuid.uuid4())
OTHER_APP = str(uuid.uuid4())
PROXY_TOKEN = "test-proxy-token-" + uuid.uuid4().hex
KID = "test-kid"


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


# --- keys and a self-signed cert for "localhost" (the JWKS host) -----------
signing_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
rogue_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
tls_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "localhost")])
now = dt.datetime.now(dt.timezone.utc)
cert = (
    x509.CertificateBuilder().subject_name(name).issuer_name(name)
    .public_key(tls_key.public_key()).serial_number(x509.random_serial_number())
    .not_valid_before(now - dt.timedelta(days=1)).not_valid_after(now + dt.timedelta(days=1))
    .add_extension(x509.SubjectAlternativeName([x509.DNSName("localhost")]), critical=False)
    .sign(tls_key, hashes.SHA256())
)
tmp = Path(tempfile.mkdtemp(prefix="gw-test-"))
(tmp / "cert.pem").write_bytes(cert.public_bytes(serialization.Encoding.PEM))
(tmp / "key.pem").write_bytes(tls_key.private_bytes(
    serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL, serialization.NoEncryption()))
jwk = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(signing_key.public_key()))
jwk.update({"kid": KID, "use": "sig", "alg": "RS256"})
JWKS = json.dumps({"keys": [jwk]}).encode()


class Jwks(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.end_headers()
        self.wfile.write(JWKS)

    def log_message(self, *a):
        pass


class Upstream(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _echo(self):
        length = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(length) if length else b""
        if self.path.startswith("/v1/messages") and b'"stream": true' in body:
            self.send_response(200)
            self.send_header("content-type", "text/event-stream")
            self.send_header("transfer-encoding", "chunked")
            self.end_headers()
            for i in range(3):
                chunk = f"event: ping\ndata: {i} {time.time()}\n\n".encode()
                self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
                self.wfile.flush()
                time.sleep(1.0)
            self.wfile.write(b"0\r\n\r\n")
            return
        out = json.dumps({"path": self.path, "method": self.command,
                          "headers": {k.lower(): v for k, v in self.headers.items()}}).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(out)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(out)

    do_GET = do_POST = do_HEAD = _echo  # noqa: N815

    def log_message(self, *a):
        pass


def serve(handler, port, tls=False):
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", port), handler)
    if tls:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(tmp / "cert.pem", tmp / "key.pem")
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def token(*, v=2, aud=None, scp=None, roles=None, key=signing_key, exp=600, tenant=TENANT, **extra):
    t = int(time.time())
    claims = {"aud": aud or APP_ID, "iat": t, "nbf": t, "exp": t + exp, "oid": str(uuid.uuid4()), "tid": tenant}
    if v == 2:
        claims["iss"] = f"https://login.microsoftonline.com/{tenant}/v2.0"
        claims["azp"] = OTHER_APP
        if scp is not None:  # app-only tokens carry no user name
            claims["preferred_username"] = "alice@example.test"
    else:
        claims["iss"] = f"https://sts.windows.net/{tenant}/"
        claims["appid"] = OTHER_APP
        if scp is not None:
            claims["upn"] = "bob@example.test"
    if scp is not None:
        claims["scp"] = scp
    if roles is not None:
        claims["roles"] = roles
    claims.update(extra)
    return jwt.encode(claims, key, algorithm="RS256", headers={"kid": KID})


def main() -> int:
    jwks_port, up_port, gw_port = free_port(), free_port(), free_port()
    serve(Jwks, jwks_port, tls=True)
    serve(Upstream, up_port)

    env = dict(os.environ, TENANT=TENANT, APP_ID=APP_ID, UPSTREAM_HOST="127.0.0.1",
               UPSTREAM_PORT=str(up_port), JWKS_HOST="localhost", JWKS_PORT=str(jwks_port),
               CA_FILE=str(tmp / "cert.pem"), DASHBOARD_HOSTS="127.0.0.1,dashboard.example.test")
    rendered = subprocess.run(["bash", str(HERE / "render-envoy.sh")], env=env, check=True,
                              capture_output=True, text=True).stdout
    rendered = rendered.replace("port_value: 8080", f"port_value: {gw_port}")
    cfg = tmp / "envoy.yaml"
    cfg.write_text(rendered)

    envoy = os.environ.get("ENVOY", "envoy")
    v = subprocess.run([envoy, "--mode", "validate", "-c", str(cfg), "-l", "error"],
                       capture_output=True, text=True)
    if v.returncode:
        print("FAIL envoy --mode validate\n" + v.stdout + v.stderr)
        return 1
    log = open(tmp / "envoy.log", "w")
    proc = subprocess.Popen([envoy, "-c", str(cfg), "-l", "warn", "--base-id", str(gw_port)],
                            env=dict(os.environ, HEADROOM_PROXY_TOKEN=PROXY_TOKEN),
                            stdout=log, stderr=subprocess.STDOUT)
    fails = 0
    try:
        for _ in range(100):
            try:
                socket.create_connection(("127.0.0.1", gw_port), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.1)

        def call(method, path, headers=None, body=None):
            c = http.client.HTTPConnection("127.0.0.1", gw_port, timeout=30)
            c.request(method, path, body=body, headers=headers or {})
            r = c.getresponse()
            data = r.read()
            c.close()
            try:
                return r.status, json.loads(data)
            except ValueError:
                return r.status, data

        def check(label, cond, detail=""):
            nonlocal fails
            print(("PASS " if cond else "FAIL ") + label + ("" if cond else f"  -> {detail}"))
            fails += 0 if cond else 1

        anth = {"authorization": "Bearer sk-ant-oat01-fake", "content-type": "application/json"}
        user = token(scp="access_as_user")

        # Browser routes
        s, b = call("GET", "/", {"cookie": "AppServiceAuthSession=x", "authorization": "Bearer y"})
        check("GET / -> /dashboard with proxy token, no cookie/authorization",
              s == 200 and b["path"] == "/dashboard" and b["headers"].get("x-headroom-proxy-token") == PROXY_TOKEN
              and "cookie" not in b["headers"] and "authorization" not in b["headers"], (s, b))
        for p in ("/dashboard", "/dashboard/", "/dashboard/static/app.js", "/stats", "/stats-history",
                  "/stats-lifetime", "/health"):
            s, b = call("GET", p)
            check(f"GET {p} -> headroom", s == 200 and b["path"] == p, (s, b))
        for m, p in (("HEAD", "/dashboard"), ("POST", "/stats"), ("GET", "/settings/schema"),
                     ("GET", "/transformations/feed"), ("GET", "/statsX"), ("GET", "/livez")):
            s, _ = call(m, p)
            check(f"{m} {p} -> 404", s == 404, s)

        # API: authentication
        s, _ = call("POST", "/v1/messages", anth, b"{}")
        check("POST /v1/messages without token -> 401", s == 401, s)
        s, _ = call("GET", "/v1/models", {"x-headroom-gateway-token": "garbage"})
        check("garbage token -> 401", s == 401, s)
        s, _ = call("POST", "/v1/messages", {**anth, "x-headroom-gateway-token": token(aud=str(uuid.uuid4()), scp="access_as_user")}, b"{}")
        check("wrong audience -> 403 (jwt_authn: audience not allowed)", s == 403, s)
        for label, t in (("other tenant", token(tenant=str(uuid.uuid4()), scp="access_as_user")),
                         ("bad signature", token(scp="access_as_user", key=rogue_key)),
                         ("expired", token(scp="access_as_user", exp=-120))):
            s, _ = call("POST", "/v1/messages", {**anth, "x-headroom-gateway-token": t}, b"{}")
            check(f"{label} -> 401", s == 401, s)

        # API: authorization (scope / app role)
        for label, t in (("no scope or role", token()),
                         ("other scope", token(scp="Walter.Read")),
                         ("scope substring", token(scp="access_as_user_x")),
                         ("scope prefix", token(scp="xaccess_as_user")),
                         ("other role", token(roles=["Walter.User"]))):
            s, _ = call("POST", "/v1/messages", {**anth, "x-headroom-gateway-token": t}, b"{}")
            check(f"{label} -> 403", s == 403, s)

        hdrs = {**anth, "x-headroom-gateway-token": user, "x-headroom-user": "mallory@evil",
                "x-headroom-proxy-token": "spoofed", "x-headroom-session-id": "s1"}
        s, b = call("POST", "/v1/messages?beta=true", hdrs, b"{}")
        h = b["headers"] if isinstance(b, dict) else {}
        check("user token (v2) -> 200", s == 200, (s, b))
        check("  Authorization (Anthropic credential) kept", h.get("authorization") == anth["authorization"], h)
        check("  gateway token removed", "x-headroom-gateway-token" not in h, h)
        check("  proxy token injected, spoof replaced", h.get("x-headroom-proxy-token") == PROXY_TOKEN, h)
        check("  user tag from token, spoof dropped", h.get("x-headroom-user") == "alice@example.test", h)
        check("  principal and app tags set", bool(h.get("x-headroom-principal")) and h.get("x-headroom-app") == OTHER_APP, h)
        check("  other x-headroom-* headers kept", h.get("x-headroom-session-id") == "s1", h)
        check("  host rewritten to the upstream", h.get("host", "").startswith("127.0.0.1"), h)

        s, b = call("POST", "/v1/messages", {**anth, "x-headroom-gateway-token": token(scp="openid access_as_user")}, b"{}")
        check("scope among several -> 200", s == 200, s)
        s, b = call("POST", "/v1/messages", {**anth, "x-headroom-gateway-token": token(v=1, scp="access_as_user")}, b"{}")
        check("user token (v1) -> 200, upn tag", s == 200 and b["headers"].get("x-headroom-user") == "bob@example.test", (s, b))
        s, b = call("POST", "/v1/messages", {**anth, "x-headroom-gateway-token": token(roles=["Headroom.Proxy"])}, b"{}")
        check("service token with app role -> 200, no user tag",
              s == 200 and "x-headroom-user" not in b["headers"] and b["headers"].get("x-headroom-principal"), (s, b))
        s, b = call("POST", "/v1/messages", {**anth, "x-headroom-gateway-token": token(aud=f"api://{APP_ID}", scp="access_as_user")}, b"{}")
        check("audience as App ID URI -> 200", s == 200, s)
        s, b = call("GET", "/api/oauth/profile", {"x-headroom-gateway-token": user})
        check("GET /api/* with token -> 200", s == 200, s)
        s, _ = call("GET", "/api/oauth/profile")
        check("GET /api/* without token -> 401", s == 401, s)
        s, b = call("HEAD", "/api/hello")
        check("HEAD /api/hello without token -> 200 (preconnect)", s == 200, s)
        s, b = call("GET", "/stats", {"x-headroom-gateway-token": user})
        check("token on a browser route is not forwarded",
              s == 200 and "x-headroom-gateway-token" not in b["headers"], b)

        # Dashboard only on its own hostnames; any other name gets the API only.
        s, b = call("GET", "/dashboard", {"host": "dashboard.example.test"})
        check("GET /dashboard on a dashboard hostname -> 200", s == 200, s)
        for p in ("/", "/dashboard", "/stats", "/health"):
            s, _ = call("GET", p, {"host": "headroom.example.test"})
            check(f"GET {p} on another hostname -> 404", s == 404, s)
        s, b = call("POST", "/v1/messages", {**anth, "host": "headroom.example.test", "x-headroom-gateway-token": user}, b"{}")
        check("API on another hostname -> 200, same rules", s == 200 and b["headers"].get("x-headroom-proxy-token") == PROXY_TOKEN, s)
        s, _ = call("POST", "/v1/messages", {**anth, "host": "headroom.example.test"}, b"{}")
        check("API on another hostname without token -> 401", s == 401, s)

        # Streaming: first event must arrive long before the stream ends.
        c = http.client.HTTPConnection("127.0.0.1", gw_port, timeout=30)
        t0 = time.time()
        c.request("POST", "/v1/messages", body=b'{"stream": true}', headers={**anth, "x-headroom-gateway-token": user})
        r = c.getresponse()
        first = r.read1(4096)
        t_first = time.time() - t0
        rest = r.read()
        t_all = time.time() - t0
        c.close()
        check(f"SSE streamed (first chunk {t_first:.2f}s, end {t_all:.2f}s)",
              r.status == 200 and first.startswith(b"event: ping") and t_first < 0.8 and t_all > 2.5
              and rest.count(b"event: ping") == 2, (r.status, t_first, t_all))

        logs = (tmp / "envoy.log").read_text()
        check("access log never contains a token",
              PROXY_TOKEN not in logs and user not in logs and '"event":"gateway_access"' in logs.replace(" ", ""), logs[-500:])
    finally:
        proc.terminate()
        proc.wait(5)
    print("ALL PASS" if fails == 0 else f"{fails} FAILED")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
