#!/usr/bin/env python3
import argparse
import base64
import json
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class RelayState:
    def __init__(self):
        self.lock = threading.Lock()
        self.devices = {}
        self.frames = []
        self.events = []
        self.server_seq = 0

    def _next_seq(self):
        self.server_seq += 1
        return self.server_seq

    def register(self, device_id, name):
        with self.lock:
            now = time.time()
            self.devices[device_id] = {"id": device_id, "name": name, "lastSeen": now}
            self.events.append({"seq": self._next_seq(), "type": "register", "device": device_id, "name": name, "time": now})
            return {"ok": True, "serverSeq": self.server_seq}

    def unregister(self, device_id):
        with self.lock:
            now = time.time()
            self.devices.pop(device_id, None)
            self.events.append({"seq": self._next_seq(), "type": "unregister", "device": device_id, "time": now})
            return {"ok": True, "serverSeq": self.server_seq}

    def send_frame(self, sender, frame):
        with self.lock:
            now = time.time()
            if sender in self.devices:
                self.devices[sender]["lastSeen"] = now
            item = {"seq": self._next_seq(), "from": sender, "frame": frame, "time": now}
            self.frames.append(item)
            self.events.append({"seq": item["seq"], "type": "frame", "device": sender, "frameSeq": frame.get("seq"), "time": now})
            return {"ok": True, "serverSeq": self.server_seq}

    def poll(self, device_id, after):
        with self.lock:
            now = time.time()
            if device_id in self.devices:
                self.devices[device_id]["lastSeen"] = now
            peers = [dict(d) for key, d in self.devices.items() if key != device_id]
            frames = [
                {
                    "from": item["from"],
                    "seq": item["frame"].get("seq", 0),
                    "wireDataBase64": item["frame"].get("wireDataBase64", ""),
                }
                for item in self.frames
                if item["seq"] > after and item["from"] != device_id
            ]
            return {"serverSeq": self.server_seq, "peers": peers, "frames": frames}

    def snapshot(self):
        with self.lock:
            return {
                "serverSeq": self.server_seq,
                "devices": list(self.devices.values()),
                "frameCount": len(self.frames),
                "eventCount": len(self.events),
                "events": self.events[-50:],
            }


def make_handler(state):
    class Handler(BaseHTTPRequestHandler):
        server_version = "SonarSimulatorRelay/1.0"

        def do_GET(self):
            parsed = urllib.parse.urlparse(self.path)
            if parsed.path == "/":
                self._send_html(dashboard_html())
                return
            if parsed.path == "/api/state":
                self._send_json(state.snapshot())
                return
            if parsed.path == "/api/poll":
                query = urllib.parse.parse_qs(parsed.query)
                device_id = query.get("deviceId", [""])[0]
                after = int(query.get("after", ["0"])[0] or 0)
                self._send_json(state.poll(device_id, after))
                return
            self.send_error(404)

        def do_POST(self):
            parsed = urllib.parse.urlparse(self.path)
            body = self._read_json()
            if parsed.path == "/api/register":
                self._send_json(state.register(body["id"], body["name"]))
                return
            if parsed.path == "/api/unregister":
                self._send_json(state.unregister(body["id"]))
                return
            if parsed.path == "/api/send":
                self._send_json(state.send_frame(body["from"], body["frame"]))
                return
            self.send_error(404)

        def log_message(self, fmt, *args):
            return

        def _read_json(self):
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length)
            return json.loads(raw.decode("utf-8") or "{}")

        def _send_json(self, payload, status=200):
            data = json.dumps(payload, sort_keys=True).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _send_html(self, html):
            data = html.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    return Handler


def dashboard_html():
    return """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Sonar Simulator Relay</title>
<style>
body{margin:0;background:#111827;color:#e5e7eb;font:14px -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
main{max-width:1040px;margin:0 auto;padding:24px}
h1{font-size:24px;margin:0 0 4px}
.sub{color:#9ca3af;margin-bottom:20px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:12px}
.card{background:#1f2937;border:1px solid #374151;border-radius:8px;padding:14px}
.label{font-size:12px;color:#9ca3af;text-transform:uppercase;letter-spacing:.04em}
.value{font-size:22px;font-weight:700;margin-top:4px}
.device{display:flex;justify-content:space-between;gap:12px;padding:10px 0;border-top:1px solid #374151}
.device:first-child{border-top:0}
.pill{display:inline-block;background:#164e63;color:#67e8f9;border-radius:999px;padding:3px 8px;font-size:12px;font-weight:700}
pre{white-space:pre-wrap;word-break:break-word;max-height:360px;overflow:auto}
</style>
</head>
<body>
<main>
<h1>Sonar Simulator Relay</h1>
<div class="sub">Honest simulator-only transport. This is not Bluetooth, AWDL, or UWB.</div>
<div class="grid">
<section class="card"><div class="label">Devices Online</div><div id="deviceCount" class="value">0</div></section>
<section class="card"><div class="label">Frames Routed</div><div id="frameCount" class="value">0</div></section>
<section class="card"><div class="label">Server Seq</div><div id="serverSeq" class="value">0</div></section>
</div>
<section class="card" style="margin-top:12px"><div class="label">Devices</div><div id="devices"></div></section>
<section class="card" style="margin-top:12px"><div class="label">Recent Events</div><pre id="events"></pre></section>
</main>
<script>
async function refresh(){
  const state = await fetch('/api/state', {cache:'no-store'}).then(r => r.json());
  document.getElementById('deviceCount').textContent = state.devices.length;
  document.getElementById('frameCount').textContent = state.frameCount;
  document.getElementById('serverSeq').textContent = state.serverSeq;
  document.getElementById('devices').innerHTML = state.devices.map(d => {
    const age = Math.max(0, Date.now()/1000 - d.lastSeen).toFixed(1);
    return `<div class="device"><div><strong>${d.name}</strong><br><span class="sub">${d.id}</span></div><div><span class="pill">${age}s ago</span></div></div>`;
  }).join('') || '<div class="sub">No devices yet</div>';
  document.getElementById('events').textContent = JSON.stringify(state.events.slice().reverse(), null, 2);
}
refresh();
setInterval(refresh, 1000);
</script>
</body>
</html>"""


def run_server(host, port):
    state = RelayState()
    server = ThreadingHTTPServer((host, port), make_handler(state))
    return server


def post_json(base, path, payload):
    data = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        base + path,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=2) as response:
        return json.loads(response.read().decode("utf-8"))


def get_json(base, path):
    with urllib.request.urlopen(base + path, timeout=2) as response:
        return json.loads(response.read().decode("utf-8"))


def self_test():
    server = run_server("127.0.0.1", 0)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    try:
        post_json(base, "/api/register", {"id": "SIM-A-38D0B9", "name": "SIM-A"})
        post_json(base, "/api/register", {"id": "SIM-B-97D949", "name": "SIM-B"})
        poll_a = get_json(base, "/api/poll?deviceId=SIM-A-38D0B9&after=0")
        assert [p["id"] for p in poll_a["peers"]] == ["SIM-B-97D949"]

        wire = base64.b64encode(b"sonar-frame").decode("ascii")
        post_json(
            base,
            "/api/send",
            {"from": "SIM-A-38D0B9", "frame": {"from": "SIM-A-38D0B9", "seq": 7, "wireDataBase64": wire}},
        )
        poll_b = get_json(base, "/api/poll?deviceId=SIM-B-97D949&after=0")
        assert poll_b["frames"][0]["from"] == "SIM-A-38D0B9"
        assert poll_b["frames"][0]["seq"] == 7
        assert poll_b["frames"][0]["wireDataBase64"] == wire

        state = get_json(base, "/api/state")
        assert len(state["devices"]) == 2
        assert state["frameCount"] == 1
        print("self-test passed")
    finally:
        server.shutdown()
        server.server_close()


def main():
    parser = argparse.ArgumentParser(description="Sonar two-simulator relay and dashboard")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        self_test()
        return

    server = run_server(args.host, args.port)
    print(f"Sonar simulator relay listening on http://{args.host}:{server.server_address[1]}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
