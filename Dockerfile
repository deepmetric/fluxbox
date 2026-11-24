FROM alpine:3.21

RUN apk add --no-cache \
    xvfb \
    x11vnc \
    chromium \
    pulseaudio \
    pulseaudio-utils \
    ffmpeg \
    python3 \
    novnc \
    websockify \
    supervisor \
    bash \
    ttf-dejavu \
    font-noto

# Create a single-port reverse proxy / audio streamer + noVNC wrapper in Python
# Serves noVNC static files, proxies /websockify to 6080, and streams /audio.mp3 from PulseAudio
RUN cat << 'EOF' > /server.py
import os, subprocess, threading
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
import socket, select

NOVNC_DIR = "/usr/share/novnc"
PORT = int(os.environ.get("PORT", 8080))

# Inject floating audio player bar into vnc.html once at build/startup
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
if "id=\"audio-bar\"" not in html:
    html = html.replace("</body>", audio_widget)
    with open(vnc_html, "w", encoding="utf-8") as f:
        f.write(html)

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
                "ffmpeg", "-loglevel", "quiet",
                "-f", "pulse", "-i", "virtual_speaker.monitor",
                "-ac", "1", "-ar", "22050", "-b:a", "64k",
                "-f", "mp3", "-"
            ]
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE)
            try:
                while True:
                    chunk = proc.stdout.read(2048)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
            except Exception:
                pass
            finally:
                proc.kill()
            return

        # Upgrade WebSocket requests (/websockify) directly to local websockify on 6080
        if self.headers.get("Upgrade", "").lower() == "websocket":
            upstream = socket.create_connection(("127.0.0.1", 6080))
            req_line = f"{self.command} {self.path} {self.request_version}\r\n".encode()
            headers = b"".join(f"{k}: {v}\r\n".encode() for k, v in self.headers.items()) + b"\r\n"
            upstream.sendall(req_line + headers)
            client = self.connection
            while True:
                r, _, _ = select.select([client, upstream], [], [], 60)
                if not r:
                    break
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
    RESOLUTION=1024x576x16 \
    PORT=8080 \
    VNC_PASSWORD=changeme \
    START_URL=https://app.speechify.com \
    PULSE_SERVER=unix:/tmp/pulse-socket

RUN cat << 'EOF' > /entrypoint.sh
#!/bin/bash
set -e

mkdir -p /root/.vnc /tmp/chromium-cache /root/.config/chromium/Default
x11vnc -storepasswd "$VNC_PASSWORD" /root/.vnc/passwd

# Restore Speechify session cookies/localStorage if SESSION_B64 is provided
if [ -n "$SESSION_B64" ]; then
    echo "$SESSION_B64" | base64 -d | tar -xzf - -C /root/.config/chromium/Default 2>/dev/null || true
fi

cat << CONF > /etc/supervisord.conf
[supervisord]
nodaemon=true
logfile=/dev/null
logfile_maxbytes=0

[program:pulseaudio]
command=/usr/bin/pulseaudio --daemonize=no --exit-idle-time=-1 --load="module-native-protocol-unix socket=/tmp/pulse-socket auth-anonymous=1" --load="module-null-sink sink_name=virtual_speaker sink_properties=device.description=Virtual_Speaker"
autorestart=true
priority=5

[program:xvfb]
command=/usr/bin/Xvfb :0 -screen 0 ${RESOLUTION} -nolisten tcp
autorestart=true
priority=10

[program:x11vnc]
command=/usr/bin/x11vnc -display :0 -rfbauth /root/.vnc/passwd -forever -shared -rfbport 5900 -wait 50 -defer 50 -noxdamage -nolookup
autorestart=true
priority=20

[program:websockify]
command=/usr/bin/websockify 127.0.0.1:6080 localhost:5900
autorestart=true
priority=30

[program:web]
command=/usr/bin/python3 /server.py
autorestart=true
priority=35

[program:browser]
command=/usr/bin/chromium-browser \
  --no-sandbox \
  --disable-dev-shm-usage \
  --disable-gpu \
  --no-zygote \
  --renderer-process-limit=1 \
  --disable-background-timer-throttling \
  --disable-background-networking \
  --disable-extensions \
  --disable-sync \
  --disable-translate \
  --no-first-run \
  --password-store=basic \
  --user-data-dir=/root/.config/chromium \
  --disk-cache-dir=/tmp/chromium-cache \
  --disk-cache-size=10485760 \
  --window-position=0,0 \
  --window-size=1024,576 \
  --app=${START_URL} \
  --js-flags="--max-old-space-size=160"
environment=DISPLAY=":0",HOME="/root",PULSE_SERVER="unix:/tmp/pulse-socket",MALLOC_ARENA_MAX="2"
autorestart=true
priority=40
CONF

exec /usr/bin/supervisord -c /etc/supervisord.conf
EOF

RUN chmod +x /entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
