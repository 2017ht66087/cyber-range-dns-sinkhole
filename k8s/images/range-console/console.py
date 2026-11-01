#!/usr/bin/env python3
"""
range-console: authenticated web console for custom cyber-range scenarios (:8090).

A scenario sets the malicious C2 domains, attacker IP, sinkhole on/off + IP,
benign domain, beacon interval and number of infected endpoints. Launching a
scenario rewrites the range-mode ConfigMaps in cyber-range and dns-system,
scales infected-pc and rolls the range deployments - the same mechanism the
toggle-variant.sh script uses, driven through the Kubernetes API with a
namespaced ServiceAccount.

Custom scenarios live in ConfigMap range-admin/range-scenarios. The login is
checked against Secret range-admin/console-auth (PBKDF2-SHA256 hash).
"""
import base64
import hashlib
import hmac
import ipaddress
import json
import os
import re
import secrets
import ssl
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.getenv("CONSOLE_PORT", "8090"))
ADMIN_NS = os.getenv("ADMIN_NAMESPACE", "range-admin")
RANGE_NS = "cyber-range"
DNS_NS = "dns-system"
SCENARIO_CM = "range-scenarios"
AUTH_SECRET = "console-auth"
SINKHOLE_API = os.getenv("SINKHOLE_API", "http://sinkhole.cyber-range.svc.cluster.local:8080/api/captures")
FAKE_NET_NS = "fake-internet"
CORP_NS = "corp"
FAKE_NET_API = os.getenv("FAKE_NET_API", "http://fake-internet-dashboard.fake-internet.svc.cluster.local:8081/api")
SESSION_TTL = 8 * 3600
PBKDF2_ITERS = 260000

API = "https://kubernetes.default.svc"
SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
UI_HTML = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "ui.html"), encoding="utf-8").read()

# Every component of the range: (namespace, deployment / app label).
COMPONENTS = {
    "infected-pc": (RANGE_NS, "infected-pc"),
    "firewall-sim": (RANGE_NS, "firewall-sim"),
    "sinkhole": (RANGE_NS, "sinkhole"),
    "internal-dns": (DNS_NS, "internal-dns"),
    "external-dns": (DNS_NS, "external-dns"),
    "fake-internet": (FAKE_NET_NS, "fake-internet"),
    "dc01": (CORP_NS, "dc01"),
    "dc02": (CORP_NS, "dc02"),
    "db01": (CORP_NS, "db01"),
    "db02": (CORP_NS, "db02"),
    "web01": (CORP_NS, "web01"),
    "web02": (CORP_NS, "web02"),
}

BUILTIN_SCENARIOS = [
    {
        "id": "baseline-contained",
        "name": "Baseline - sinkhole ON (contained)",
        "description": "Single infected PC beacons to teq.xyz.com; the firewall sinkholes it.",
        "sinkhole_enabled": True, "sinkhole_ip": "10.255.255.10",
        "malicious_domains": ["teq.xyz.com"], "attacker_ip": "203.0.113.66",
        "benign_domain": "abc.com", "benign_ip": "10.0.0.50",
        "beacon_interval": 20, "infected_endpoints": 1, "builtin": True,
    },
    {
        "id": "baseline-uncontained",
        "name": "Baseline - sinkhole OFF (uncontained)",
        "description": "Same beacon with no sinkhole: it resolves to the attacker C2.",
        "sinkhole_enabled": False, "sinkhole_ip": "10.255.255.10",
        "malicious_domains": ["teq.xyz.com"], "attacker_ip": "203.0.113.66",
        "benign_domain": "abc.com", "benign_ip": "10.0.0.50",
        "beacon_interval": 20, "infected_endpoints": 1, "builtin": True,
    },
    {
        "id": "botnet-multi-c2",
        "name": "Botnet - 3 hosts, 3 C2 domains (contained)",
        "description": "Three infected PCs rotate across three C2 domains; sinkhole ON.",
        "sinkhole_enabled": True, "sinkhole_ip": "10.255.255.10",
        "malicious_domains": ["update.evil-c2.lab", "cdn.badexfil.lab", "teq.xyz.com"],
        "attacker_ip": "203.0.113.66",
        "benign_domain": "abc.com", "benign_ip": "10.0.0.50",
        "beacon_interval": 15, "infected_endpoints": 3, "builtin": True,
    },
]

DOMAIN_RE = re.compile(r"^(?=.{1,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)(\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$")
CLUSTER_NETS = [ipaddress.ip_network("10.42.0.0/16"), ipaddress.ip_network("10.43.0.0/16")]

STATE_LOCK = threading.Lock()
SESSIONS = {}          # token -> (username, expires_at)
FAILED_LOGINS = {}     # client ip -> (count, locked_until)


def log(msg):
    print(f"[range-console] {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')} {msg}", flush=True)


# --------------------------------------------------------------------------- k8s
class KubeError(Exception):
    def __init__(self, code, detail):
        super().__init__(f"kubernetes API {code}: {detail}")
        self.code = code


_SSL = ssl.create_default_context(cafile=os.path.join(SA_DIR, "ca.crt")) if os.path.exists(SA_DIR) else None


def kube(method, path, body=None, ctype="application/json", raw=False):
    with open(os.path.join(SA_DIR, "token")) as f:
        token = f.read().strip()
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method,
                                 headers={"Authorization": "Bearer " + token, "Accept": "application/json"})
    if data is not None:
        req.add_header("Content-Type", ctype)
    try:
        with urllib.request.urlopen(req, context=_SSL, timeout=20) as r:
            out = r.read()
    except urllib.error.HTTPError as e:
        raise KubeError(e.code, e.read().decode(errors="replace")[:300])
    if raw:
        return out.decode(errors="replace")
    return json.loads(out or b"{}")


def get_cm(ns, name):
    try:
        return kube("GET", f"/api/v1/namespaces/{ns}/configmaps/{name}").get("data") or {}
    except KubeError as e:
        if e.code == 404:
            return None
        raise


def put_cm_data(ns, name, data):
    """Replace a ConfigMap's data (create it when missing)."""
    if get_cm(ns, name) is None:
        kube("POST", f"/api/v1/namespaces/{ns}/configmaps",
             {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": name}, "data": data})
        return
    current = get_cm(ns, name) or {}
    patch = {k: None for k in current if k not in data}
    patch.update(data)
    kube("PATCH", f"/api/v1/namespaces/{ns}/configmaps/{name}", {"data": patch},
         ctype="application/merge-patch+json")


def roll_deployment(ns, name, replicas=None):
    spec = {"template": {"metadata": {"annotations": {
        "range-console/restartedAt": datetime.now(timezone.utc).isoformat()}}}}
    if replicas is not None:
        spec["replicas"] = replicas
    kube("PATCH", f"/apis/apps/v1/namespaces/{ns}/deployments/{name}", {"spec": spec},
         ctype="application/strategic-merge-patch+json")


def deployment_status(ns, name):
    try:
        d = kube("GET", f"/apis/apps/v1/namespaces/{ns}/deployments/{name}")
    except KubeError as e:
        return {"name": name, "namespace": ns, "error": str(e)}
    st = d.get("status", {})
    return {
        "name": name, "namespace": ns,
        "desired": d.get("spec", {}).get("replicas", 0),
        "ready": st.get("readyReplicas", 0) or 0,
        "updated": st.get("updatedReplicas", 0) or 0,
    }


def pods_for(ns, app):
    q = urllib.parse.quote(f"app={app}")
    items = kube("GET", f"/api/v1/namespaces/{ns}/pods?labelSelector={q}").get("items", [])
    out = []
    for p in items:
        cs = (p.get("status", {}).get("containerStatuses") or [{}])[0]
        out.append({
            "name": p["metadata"]["name"],
            "phase": p.get("status", {}).get("phase", "?"),
            "ready": bool(cs.get("ready")),
            "restarts": cs.get("restartCount", 0),
            "deleting": "deletionTimestamp" in p["metadata"],
        })
    return out


def component_logs(component, tail=100):
    ns, app = COMPONENTS[component]
    chunks = []
    for p in pods_for(ns, app):
        if p["deleting"]:
            continue
        try:
            text = kube("GET", f"/api/v1/namespaces/{ns}/pods/{p['name']}/log?tailLines={int(tail)}", raw=True)
        except KubeError as e:
            text = f"(logs unavailable: {e})"
        chunks.append({"pod": p["name"], "log": text})
    return chunks


# --------------------------------------------------------------------- scenarios
def load_custom():
    data = get_cm(ADMIN_NS, SCENARIO_CM) or {}
    try:
        items = json.loads(data.get("scenarios.json", "[]"))
    except ValueError:
        items = []
    return items, data.get("active", "")


def save_custom(items, active):
    put_cm_data(ADMIN_NS, SCENARIO_CM, {"scenarios.json": json.dumps(items, indent=1), "active": active})


def all_scenarios():
    custom, active = load_custom()
    return [dict(s) for s in BUILTIN_SCENARIOS] + custom, active


def find_scenario(sid):
    items, _ = all_scenarios()
    return next((s for s in items if s["id"] == sid), None)


def _ip(value, field, errors):
    try:
        ip = ipaddress.IPv4Address(str(value).strip())
    except ValueError:
        errors.append(f"{field}: not a valid IPv4 address")
        return None
    if not ip.is_private:
        errors.append(f"{field}: must be a lab-only address (RFC1918 / TEST-NET), not a routable one")
    elif any(ip in n for n in CLUSTER_NETS):
        errors.append(f"{field}: collides with the cluster pod/service range (10.42/16, 10.43/16)")
    return str(ip)


def validate_scenario(raw):
    errors = []
    name = str(raw.get("name", "")).strip()
    if not 1 <= len(name) <= 60:
        errors.append("name: 1-60 characters")
    desc = str(raw.get("description", "")).strip()[:300]

    doms = raw.get("malicious_domains", [])
    if isinstance(doms, str):
        doms = re.split(r"[\s,]+", doms)
    doms = [d.strip().rstrip(".").lower() for d in doms if str(d).strip()]
    doms = list(dict.fromkeys(doms))
    if not 1 <= len(doms) <= 10:
        errors.append("malicious_domains: 1-10 domains")
    for d in doms:
        if not DOMAIN_RE.match(d):
            errors.append(f"malicious_domains: '{d}' is not a valid domain")

    benign = str(raw.get("benign_domain", "")).strip().rstrip(".").lower()
    if not DOMAIN_RE.match(benign):
        errors.append("benign_domain: not a valid domain")
    elif any(benign == d or benign.endswith("." + d) or d.endswith("." + benign) for d in doms):
        errors.append("benign_domain: must not overlap a malicious domain")

    attacker_ip = _ip(raw.get("attacker_ip"), "attacker_ip", errors)
    sinkhole_ip = _ip(raw.get("sinkhole_ip"), "sinkhole_ip", errors)
    benign_ip = _ip(raw.get("benign_ip"), "benign_ip", errors)
    if attacker_ip and attacker_ip == sinkhole_ip:
        errors.append("attacker_ip and sinkhole_ip must differ")

    try:
        interval = int(raw.get("beacon_interval", 20))
        if not 5 <= interval <= 600:
            raise ValueError
    except (TypeError, ValueError):
        errors.append("beacon_interval: 5-600 seconds")
        interval = 20
    try:
        endpoints = int(raw.get("infected_endpoints", 1))
        if not 1 <= endpoints <= 5:
            raise ValueError
    except (TypeError, ValueError):
        errors.append("infected_endpoints: 1-5")
        endpoints = 1

    sid = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")[:40] or "scenario"
    return errors, {
        "id": str(raw.get("id") or sid),
        "name": name, "description": desc,
        "sinkhole_enabled": bool(raw.get("sinkhole_enabled")),
        "sinkhole_ip": sinkhole_ip, "malicious_domains": doms, "attacker_ip": attacker_ip,
        "benign_domain": benign, "benign_ip": benign_ip,
        "beacon_interval": interval, "infected_endpoints": endpoints, "builtin": False,
    }


def launch_scenario(s, clear_captures):
    put_cm_data(RANGE_NS, "range-mode", {
        "SINKHOLE_ENABLED": "true" if s["sinkhole_enabled"] else "false",
        "SINKHOLE_IP": s["sinkhole_ip"],
        "MALICIOUS_DOMAIN": ",".join(s["malicious_domains"]),
        "ALT_DOMAIN": s["benign_domain"],
        "BEACON_INTERVAL": str(s["beacon_interval"]),
        "SCENARIO_ID": s["id"],
    })
    put_cm_data(DNS_NS, "range-mode", {
        "MALICIOUS_DOMAIN": ",".join(s["malicious_domains"]),
        "ATTACKER_IP": s["attacker_ip"],
        "ALT_DOMAIN": s["benign_domain"],
        "BENIGN_IP": s["benign_ip"],
        "BENIGN_PUBLIC_IP": "93.184.216.34",
    })
    roll_deployment(DNS_NS, "internal-dns")
    roll_deployment(DNS_NS, "external-dns")
    roll_deployment(RANGE_NS, "firewall-sim")
    roll_deployment(RANGE_NS, "infected-pc", replicas=s["infected_endpoints"])
    if clear_captures:
        sinkhole_clear()
        try:
            fake_net_clear()
        except Exception as e:
            log(f"fake-internet clear failed: {e}")
    custom, _ = load_custom()
    save_custom(custom, s["id"])
    log(f"launched scenario {s['id']} (sinkhole={'on' if s['sinkhole_enabled'] else 'off'}, "
        f"domains={len(s['malicious_domains'])}, endpoints={s['infected_endpoints']})")


# ---------------------------------------------------------------------- sinkhole
def sinkhole_captures():
    with urllib.request.urlopen(SINKHOLE_API, timeout=5) as r:
        return json.loads(r.read() or b"[]")


def sinkhole_clear():
    req = urllib.request.Request(SINKHOLE_API, method="DELETE")
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.loads(r.read() or b"{}")


def fake_net_checkins():
    with urllib.request.urlopen(FAKE_NET_API + "/checkins", timeout=5) as r:
        return json.loads(r.read() or b"[]")


def fake_net_clear():
    req = urllib.request.Request(FAKE_NET_API + "/all", method="DELETE")
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.loads(r.read() or b"{}")


# ------------------------------------------------------------------------ status
VERDICT_RE = re.compile(r"\[(CONTAINED|UNCONTAINED)\] (\S+) -> (\S+)")


def range_status():
    mode = get_cm(RANGE_NS, "range-mode") or {}
    dns_mode = get_cm(DNS_NS, "range-mode") or {}
    _, active = load_custom()
    deployments = [deployment_status(ns, name) for ns, name in COMPONENTS.values()]

    contained = uncontained = 0
    latest = []
    for chunk in component_logs("infected-pc", tail=60):
        for line in chunk["log"].splitlines():
            m = VERDICT_RE.search(line)
            if m:
                if m.group(1) == "CONTAINED":
                    contained += 1
                else:
                    uncontained += 1
                latest.append({"pod": chunk["pod"], "verdict": m.group(1),
                               "domain": m.group(2), "resolved": m.group(3)})
    try:
        caps = sinkhole_captures()
        capture_count, sinkhole_err = len(caps), ""
    except Exception as e:
        capture_count, sinkhole_err = None, str(e)
    try:
        c2_checkins = len(fake_net_checkins())
    except Exception:
        c2_checkins = None

    return {
        "active_scenario": mode.get("SCENARIO_ID") or active or "(set by script)",
        "range_mode": mode, "dns_mode": dns_mode,
        "deployments": deployments,
        "verdicts": {"contained": contained, "uncontained": uncontained, "latest": latest[-12:]},
        "captures": capture_count, "sinkhole_error": sinkhole_err,
        "c2_checkins": c2_checkins,
    }


# -------------------------------------------------------------------------- auth
def _auth_record():
    sec = kube("GET", f"/api/v1/namespaces/{ADMIN_NS}/secrets/{AUTH_SECRET}")
    d = sec.get("data", {})
    return (base64.b64decode(d.get("username", "")).decode(),
            base64.b64decode(d.get("password_hash", "")).decode())


def hash_password(pw, salt=None, iters=PBKDF2_ITERS):
    salt = salt or secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac("sha256", pw.encode(), bytes.fromhex(salt), iters).hex()
    return f"pbkdf2_sha256${iters}${salt}${digest}"


def verify_password(pw, stored):
    try:
        algo, iters, salt, digest = stored.split("$")
    except ValueError:
        return False
    if algo != "pbkdf2_sha256":
        return False
    candidate = hash_password(pw, salt, int(iters)).split("$")[3]
    return hmac.compare_digest(candidate, digest)


def check_login(user, pw):
    try:
        real_user, stored = _auth_record()
    except KubeError as e:
        log(f"auth secret unreadable: {e}")
        return False
    return hmac.compare_digest(user.encode(), real_user.encode()) and verify_password(pw, stored)


def set_password(new_pw):
    kube("PATCH", f"/api/v1/namespaces/{ADMIN_NS}/secrets/{AUTH_SECRET}",
         {"data": {"password_hash": base64.b64encode(hash_password(new_pw).encode()).decode()}},
         ctype="application/merge-patch+json")


def new_session(user):
    token = secrets.token_urlsafe(32)
    with STATE_LOCK:
        SESSIONS[token] = (user, time.time() + SESSION_TTL)
    return token


def session_user(cookie_header):
    if not cookie_header:
        return None
    for part in cookie_header.split(";"):
        k, _, v = part.strip().partition("=")
        if k == "rc_session":
            with STATE_LOCK:
                rec = SESSIONS.get(v)
                if rec and rec[1] > time.time():
                    return rec[0]
                SESSIONS.pop(v, None)
    return None


def login_locked(ip):
    with STATE_LOCK:
        count, until = FAILED_LOGINS.get(ip, (0, 0))
        return until > time.time()


def record_login(ip, ok):
    with STATE_LOCK:
        if ok:
            FAILED_LOGINS.pop(ip, None)
            return
        count, _ = FAILED_LOGINS.get(ip, (0, 0))
        count += 1
        until = time.time() + 60 if count >= 5 else 0
        FAILED_LOGINS[ip] = (0 if until else count, until)


LOGIN_PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>Cyber Range Console - Sign in</title>
<style>body{{font-family:system-ui,Segoe UI,Arial;background:#0b1021;color:#e6e6e6;display:grid;place-items:center;height:100vh;margin:0}}
form{{background:#141b33;padding:2rem;border-radius:8px;width:300px}}h1{{color:#5cd6ff;font-size:1.2rem;margin:0 0 1rem}}
label{{display:block;font-size:.8rem;color:#9aa4b2;margin-top:.75rem}}input{{width:100%;box-sizing:border-box;padding:.5rem;margin-top:.25rem;background:#0b1021;border:1px solid #263042;color:#e6e6e6;border-radius:4px}}
button{{margin-top:1.25rem;width:100%;padding:.6rem;background:#5cd6ff;border:0;border-radius:4px;font-weight:600;cursor:pointer}}.e{{color:#ff7a7a;font-size:.85rem;margin-top:.75rem}}</style></head>
<body><form method="post" action="/login"><h1>Cyber Range Console</h1>
<label>Username<input name="username" autocomplete="username" required autofocus></label>
<label>Password<input name="password" type="password" autocomplete="current-password" required></label>
<button type="submit">Sign in</button>{error}</form></body></html>"""


# ------------------------------------------------------------------------ server
class Handler(BaseHTTPRequestHandler):
    server_version = "range-console"

    def log_message(self, *args):
        pass

    def _send(self, code, body, ctype="application/json", headers=None):
        payload = body if isinstance(body, bytes) else (
            body.encode() if isinstance(body, str) else json.dumps(body).encode())
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy",
                         "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(payload)

    def _body(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        if n > 64 * 1024:
            raise ValueError("request too large")
        return self.rfile.read(n) if n else b""

    def _json(self):
        try:
            return json.loads(self._body().decode() or "{}")
        except ValueError:
            return None

    def _user(self):
        return session_user(self.headers.get("Cookie"))

    def _api_guard(self, mutating):
        user = self._user()
        if not user:
            self._send(401, {"error": "not signed in"})
            return None
        if mutating and self.headers.get("X-Requested-With") != "range-console":
            self._send(403, {"error": "missing request header"})
            return None
        return user

    # ---- GET
    def do_GET(self):
        path = urllib.parse.urlparse(self.path)
        if path.path == "/healthz":
            return self._send(200, {"ok": True})
        if path.path == "/":
            if not self._user():
                return self._send(200, LOGIN_PAGE.format(error=""), "text/html; charset=utf-8")
            return self._send(200, UI_HTML, "text/html; charset=utf-8")
        if not path.path.startswith("/api/"):
            return self._send(404, {"error": "not found"})
        if not self._api_guard(False):
            return
        qs = urllib.parse.parse_qs(path.query)
        try:
            if path.path == "/api/status":
                return self._send(200, range_status())
            if path.path == "/api/scenarios":
                items, active = all_scenarios()
                return self._send(200, {"scenarios": items, "active": active})
            if path.path == "/api/logs":
                comp = (qs.get("component") or ["infected-pc"])[0]
                if comp not in COMPONENTS:
                    return self._send(400, {"error": "unknown component"})
                tail = max(10, min(int((qs.get("tail") or ["100"])[0]), 500))
                return self._send(200, {"component": comp, "pods": component_logs(comp, tail)})
            if path.path == "/api/captures":
                return self._send(200, {"captures": sinkhole_captures()[-200:][::-1]})
        except KubeError as e:
            return self._send(502, {"error": str(e)})
        except Exception as e:
            return self._send(500, {"error": str(e)})
        return self._send(404, {"error": "not found"})

    # ---- POST
    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        ip = self.client_address[0]
        if path == "/login":
            if login_locked(ip):
                return self._send(429, LOGIN_PAGE.format(
                    error='<div class="e">Too many attempts. Wait a minute.</div>'), "text/html; charset=utf-8")
            form = urllib.parse.parse_qs(self._body().decode(errors="replace"))
            user = (form.get("username") or [""])[0]
            pw = (form.get("password") or [""])[0]
            ok = check_login(user, pw)
            record_login(ip, ok)
            if not ok:
                log(f"failed login for '{user[:40]}' from {ip}")
                return self._send(401, LOGIN_PAGE.format(
                    error='<div class="e">Invalid username or password.</div>'), "text/html; charset=utf-8")
            token = new_session(user)
            log(f"login '{user}' from {ip}")
            return self._send(303, b"", "text/plain", {
                "Location": "/",
                "Set-Cookie": f"rc_session={token}; HttpOnly; SameSite=Strict; Path=/; Max-Age={SESSION_TTL}"})
        if path == "/logout":
            cookie = self.headers.get("Cookie") or ""
            for part in cookie.split(";"):
                k, _, v = part.strip().partition("=")
                if k == "rc_session":
                    with STATE_LOCK:
                        SESSIONS.pop(v, None)
            return self._send(303, b"", "text/plain", {
                "Location": "/", "Set-Cookie": "rc_session=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0"})

        user = self._api_guard(True)
        if not user:
            return
        body = self._json()
        if body is None:
            return self._send(400, {"error": "invalid JSON"})
        try:
            if path == "/api/scenarios":
                errors, s = validate_scenario(body)
                if any(b["id"] == s["id"] for b in BUILTIN_SCENARIOS):
                    errors.append("id: built-in scenarios cannot be overwritten - use a different name")
                if errors:
                    return self._send(400, {"errors": errors})
                custom, active = load_custom()
                custom = [c for c in custom if c["id"] != s["id"]] + [s]
                if len(custom) > 50:
                    return self._send(400, {"errors": ["at most 50 custom scenarios"]})
                save_custom(custom, active)
                log(f"{user} saved scenario {s['id']}")
                return self._send(200, {"saved": s})
            m = re.fullmatch(r"/api/scenarios/([a-z0-9-]{1,60})/launch", path)
            if m:
                s = find_scenario(m.group(1))
                if not s:
                    return self._send(404, {"error": "scenario not found"})
                launch_scenario(s, bool(body.get("clear_captures")))
                return self._send(200, {"launched": s["id"]})
            if path == "/api/captures/clear":
                return self._send(200, sinkhole_clear())
            if path == "/api/password":
                cur, new = str(body.get("current", "")), str(body.get("new", ""))
                real_user, stored = _auth_record()
                if not verify_password(cur, stored):
                    return self._send(400, {"errors": ["current password is wrong"]})
                if len(new) < 10:
                    return self._send(400, {"errors": ["new password must be at least 10 characters"]})
                set_password(new)
                with STATE_LOCK:
                    SESSIONS.clear()
                log(f"{user} changed the console password")
                return self._send(200, {"changed": True})
        except KubeError as e:
            return self._send(502, {"error": str(e)})
        except Exception as e:
            return self._send(500, {"error": str(e)})
        return self._send(404, {"error": "not found"})

    # ---- DELETE
    def do_DELETE(self):
        path = urllib.parse.urlparse(self.path).path
        user = self._api_guard(True)
        if not user:
            return
        m = re.fullmatch(r"/api/scenarios/([a-z0-9-]{1,60})", path)
        if not m:
            return self._send(404, {"error": "not found"})
        sid = m.group(1)
        if any(b["id"] == sid for b in BUILTIN_SCENARIOS):
            return self._send(400, {"errors": ["built-in scenarios cannot be deleted"]})
        try:
            custom, active = load_custom()
            if not any(c["id"] == sid for c in custom):
                return self._send(404, {"error": "scenario not found"})
            save_custom([c for c in custom if c["id"] != sid], active)
        except KubeError as e:
            return self._send(502, {"error": str(e)})
        log(f"{user} deleted scenario {sid}")
        return self._send(200, {"deleted": sid})


def main():
    log(f"listening on :{PORT}")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
