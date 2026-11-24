FROM alpine:3.21

RUN apk add --no-cache \
    tini \
    xvfb \
    x11vnc \
    chromium \
    pulseaudio \
    pulseaudio-utils \
    ffmpeg \
    python3 \
    novnc \
    websockify \
    bash \
    ttf-dejavu \
    font-noto

RUN cat << 'EOF' > /server.py
import os, subprocess, threading, time, socket, select, signal, sys
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler

NOVNC_DIR = "/usr/share/novnc"
PORT = int(os.environ.get("PORT", 8080))
RES = os.environ.get("RESOLUTION", "800x480x16")
WIN_W, WIN_H = RES.split("x")[0], RES.split("x")[1]
START_URL = os.environ.get("START_URL", "https://app.speechify.com")

# Inject floating audio player bar into vnc.html
vnc_html = os.path.join(NOVNC_DIR, "vnc.html")
with open(vnc_html, "r", encoding="utf-8") as f:
    html = f.read()

audio_widget = """
<div id="audio-bar" style="position:fixed;bottom:10px;right:10px;z-index:9999;background:#1e1e1e;color:#fff;padding:6px 12px;border-radius:6px;font-family:sans-serif;font-size:13px;box-shadow:0 2px 6px rgba(0,0,0,0.4);">
  <button id="audio-btn" onclick="toggleAudio()" style="background:#2563eb;color:#fff;border:none;padding:4px 10px;border-radius:4px;cursor:pointer;font-weight:bold;">Enable Audio</button>
  <audio id="vnc-audio" preload="none"></audio>
</div>
<script>
let playing = false;
function toggleAudio() {
  const a = document.getElementById('vnc-audio');
  const b = document.getElementById('audio-btn');
  if (!playing) {
    a.src = '/audio.mp3?t=' + Date.now();
    a.play();
    b.textContent = 'Mute Audio';
    b.style.background = '#dc2626';
    playing = true;
  } else {
    a.pause();
    a.src = '';
    b.textContent = 'Enable Audio';
    b.style.background = '#2563eb';
    playing = false;
  }
}
</script>
</body>
"""
if 'id="audio-bar"' not in html:
    with open(vnc_html, "w", encoding="utf-8") as f:
        f.write(html.replace("</body>", audio_widget))

# Lightweight process supervisor (replaces supervisord to save ~18MB RAM)
PROCS = [
    ("pulseaudio", [
        "/usr/bin/pulseaudio", "--daemonize=no", "--exit-idle-time=-1",
        "--default-sample-rate=22050", "--default-sample-channels=1",
        "--resample-method=trivial",
        "--load=module-native-protocol-unix socket=/tmp/pulse-socket auth-anonymous=1",
        "--load=module-null-sink sink_name=virtual_speaker sink_properties=device.description=Virtual_Speaker"
    ]),
    ("xvfb", ["/usr/bin/Xvfb", ":0", "-screen", "0", RES, "-nolisten", "tcp"]),
    ("x11vnc", [
        "/usr/bin/x11vnc", "-display", ":0", "-rfbauth", "/root/.vnc/passwd",
        "-forever", "-shared", "-rfbport", "5900",
        "-wait", "100", "-defer", "100", "-ncache", "0",
        "-noxdamage", "-noxrecord", "-nodpms", "-noscr", "-nolookup"
    ]),
    ("websockify", ["/usr/bin/websockify", "127.0.0.1:6080", "localhost:5900"]),
    ("browser", [
        "/usr/bin/chromium-browser",
        "--no-sandbox", "--disable-dev-shm-usage", "--disable-gpu", "--no-zygote",
        "--renderer-process-limit=1",
        "--disable-background-timer-throttling", "--disable-background-networking",
        "--disable-extensions", "--disable-sync", "--disable-translate",
        "--disable-features=Translate,BackForwardCache,MediaRouter,OptimizationHints,CalculateNativeWinOcclusion",
        "--no-first-run", "--password-store=basic",
        "--user-data-dir=/root/.config/chromium",
        "--disk-cache-dir=/tmp/chromium-cache", "--disk-cache-size=10485760",
        f"--window-position=0,0", f"--window-size={WIN_W},{WIN_H}",
        f"--app={START_URL}",
        "--js-flags=--max-old-space-size=128"
    ])
]

running = []
stopping = False

def supervise(name, cmd):
    env = os.environ.copy()
    env.update({"DISPLAY": ":0", "HOME": "/root", "PULSE_SERVER": "unix:/tmp/pulse-socket", "MALLOC_ARENA_MAX": "2"})
    while not stopping:
        p = subprocess.Popen(cmd, env=env)
        running.append(p)
        p.wait()
        if p in running:
            running.remove(p)
        if not stopping:
            time.sleep(1)

def shutdown(signum, frame):
    global stopping
    stopping = True
    for p in list(running):
        try: p.terminate()
        except Exception: pass
    sys.exit(0)

signal.signal(signal.SIGTERM, shutdown)
signal.signal(signal.SIGINT, shutdown)

for name, cmd in PROCS:
    threading.Thread(target=supervise, args=(name, cmd), daemon=True).start()
    time.sleep(0.4)

class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=NOVNC_DIR, **kwargs)

    def do_GET(self):
        if self.path == "/":
            self.send_response(302)
            self.send_header("Location", "/vnc.html?autoconnect=true&resize=scale")
            self.end_headers()
            return

        if self.path.startswith("/audio.mp3"):
            self.send_response(200)
            self.send_header("Content-Type", "audio/mpeg")
            self.send_header("Cache-Control", "no-cache, no-store")
            self.end_headers()
            cmd = [
                "ffmpeg", "-loglevel", "quiet", "-threads", "1",
                "-f", "pulse", "-i", "virtual_speaker.monitor",
                "-ac", "1", "-ar", "22050", "-b:a", "48k", "-compression_level", "9",
                "-f", "mp3", "-"
            ]
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE)
            try:
                while True:
                    chunk = proc.stdout.read(2048)
                    if not chunk: break
                    self.wfile.write(chunk)
                    self.wfile.flush()
            except Exception:
                pass
            finally:
                proc.kill()
            return

        if self.headers.get("Upgrade", "").lower() == "websocket":
            upstream = socket.create_connection(("127.0.0.1", 6080))
            req_line = f"{self.command} {self.path} {self.request_version}\r\n".encode()
            headers = b"".join(f"{k}: {v}\r\n".encode() for k, v in self.headers.items()) + b"\r\n"
            upstream.sendall(req_line + headers)
            client = self.connection
            while True:
                r, _, _ = select.select([client, upstream], [], [], 60)
                if not r: break
                if client in r:
                    data = client.recv(8192)
                    if not data: break
                    upstream.sendall(data)
                if upstream in r:
                    data = upstream.recv(8192)
                    if not data: break
                    client.sendall(data)
            upstream.close()
            return

        super().do_GET()

    def log_message(self, format, *args):
        pass

ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
EOF

ENV DISPLAY=:0 \
    RESOLUTION=800x480x16 \
    PORT=8080 \
    VNC_PASSWORD=changeme \
    START_URL=https://app.speechify.com

RUN cat << 'EOF' > /entrypoint.sh
#!/bin/bash
set -e
mkdir -p /root/.vnc /tmp/chromium-cache /root/.config/chromium/Default
x11vnc -storepasswd "$VNC_PASSWORD" /root/.vnc/passwd

if [ -n "$SESSION_B64" ]; then
    echo "$SESSION_B64" | base64 -d | tar -xzf - -C /root/.config/chromium/Default 2>/dev/null || true
fi

exec /sbin/tini -- /usr/bin/python3 /server.py
EOF

RUN chmod +x /entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
