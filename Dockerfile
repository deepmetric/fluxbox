FROM alpine:3.21

# Changes vs. original:
#  - Xvfb + x11vnc  -> single TigerVNC Xvnc process (no screen scraping)
#  - ffmpeg         -> parec + opusenc (much smaller, less RAM/CPU per listener)
#  - bash           -> /bin/sh
RUN apk add --no-cache \
    tini \
    tigervnc \
    xkbcomp \
    xkeyboard-config \
    chromium \
    pulseaudio \
    pulseaudio-utils \
    opus-tools \
    python3 \
    novnc \
    websockify \
    ttf-dejavu \
    font-noto

# ---------- Audio widget (static file, injected once at build time) ----------
RUN cat << 'JSEOF' > /usr/share/novnc/audio.js
(function () {
  var KEY = 'vnc-audio-on';
  var a = new Audio();
  a.preload = 'none';
  var on = false, retry = 0, timer = null;

  var bar = document.createElement('div');
  bar.style.cssText = 'position:fixed;bottom:10px;right:10px;z-index:9999;background:#1e1e1e;color:#fff;' +
    'padding:6px 10px;border-radius:6px;font:13px sans-serif;box-shadow:0 2px 6px rgba(0,0,0,.4);' +
    'display:flex;gap:8px;align-items:center;opacity:.85';
  var btn = document.createElement('button');
  btn.style.cssText = 'color:#fff;border:0;padding:4px 10px;border-radius:4px;cursor:pointer;font-weight:bold';
  var vol = document.createElement('input');
  vol.type = 'range'; vol.min = 0; vol.max = 1; vol.step = 0.05; vol.value = 1; vol.style.width = '70px';
  vol.oninput = function () { a.volume = +vol.value; };
  bar.appendChild(btn); bar.appendChild(vol);
  document.body.appendChild(bar);

  function paint() {
    btn.textContent = on ? 'Mute Audio' : 'Enable Audio';
    btn.style.background = on ? '#dc2626' : '#2563eb';
  }
  function remember(v) { try { localStorage.setItem(KEY, v ? '1' : '0'); } catch (e) {} }

  function start() {
    clearTimeout(timer);
    on = true; paint();
    a.src = '/audio.ogg?t=' + Date.now();
    a.play().catch(function () { on = false; paint(); });
  }
  function stop() {
    on = false; clearTimeout(timer); paint();
    a.pause(); a.removeAttribute('src'); a.load();   // closes the HTTP stream -> server kills encoder
  }
  btn.onclick = function () { if (on) { stop(); remember(false); } else { start(); remember(true); } };

  // Auto-reconnect the stream if it drops
  function drop() {
    if (!on) return;
    clearTimeout(timer);
    timer = setTimeout(start, Math.min(1000 * ++retry, 5000));
  }
  a.onerror = drop; a.onended = drop; a.onstalled = drop;
  a.onplaying = function () { retry = 0; };

  // Stay near the live edge (browsers buffer live streams and drift behind)
  setInterval(function () {
    if (!on || !a.buffered.length) return;
    var end = a.buffered.end(a.buffered.length - 1);
    if (end - a.currentTime > 1.5) a.currentTime = end - 0.3;
  }, 2000);

  // If audio was on last time, resume on the first click/keypress (autoplay policy needs a gesture)
  var wasOn = false;
  try { wasOn = localStorage.getItem(KEY) === '1'; } catch (e) {}
  if (wasOn) {
    var resume = function () {
      document.removeEventListener('pointerdown', resume, true);
      document.removeEventListener('keydown', resume, true);
      if (!on) start();
    };
    document.addEventListener('pointerdown', resume, true);
    document.addEventListener('keydown', resume, true);
  }
  paint();
})();
JSEOF

RUN sed -i 's#</body>#<script src="audio.js"></script></body>#' /usr/share/novnc/vnc.html

# ---------- Supervisor + web/audio/websocket front door ----------
RUN cat << 'PYEOF' > /server.py
import os, subprocess, threading, time, socket, select, signal, sys, glob
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler

NOVNC_DIR = "/usr/share/novnc"
PORT = int(os.environ.get("PORT", 8080))
RES = os.environ.get("RESOLUTION", "800x480x16")
_p = RES.split("x")
WIN_W, WIN_H = _p[0], _p[1]
DEPTH = _p[2] if len(_p) > 2 else "16"
START_URL = os.environ.get("START_URL", "https://app.speechify.com")
RATE = "24000"  # a native Opus rate -> no resampling

ENV = os.environ.copy()
ENV.update({"DISPLAY": ":0", "HOME": "/root", "PULSE_SERVER": "unix:/tmp/pulse-socket"})

X_SOCK = "/tmp/.X11-unix/X0"
PULSE_SOCK = "/tmp/pulse-socket"
CHROME_DIR = "/root/.config/chromium"

# (name, command, wait-for paths, stale files to remove before each (re)start)
PROCS = [
    ("pulseaudio", [
        "/usr/bin/pulseaudio", "-n", "--daemonize=no", "--exit-idle-time=-1",
        "--realtime=no", "--high-priority=no", "--disable-shm=yes",
        "--resample-method=trivial",
        f"--load=module-native-protocol-unix socket={PULSE_SOCK} auth-anonymous=1",
        f"--load=module-null-sink sink_name=virtual_speaker rate={RATE} channels=1 "
        "sink_properties=device.description=Virtual_Speaker",
    ], [], [PULSE_SOCK]),
    ("xvnc", [
        "/usr/bin/Xvnc", ":0", "-geometry", f"{WIN_W}x{WIN_H}", "-depth", DEPTH,
        "-rfbport", "5900", "-rfbauth", "/root/.vnc/passwd",
        "-SecurityTypes", "VncAuth", "-localhost", "-AlwaysShared",
        "-FrameRate", "20", "-nolisten", "tcp",
        # every client arrives from 127.0.0.1 via websockify, so don't let one bad login lock out everyone
        "-BlacklistThreshold", "1000", "-BlacklistTimeout", "1",
    ], [], ["/tmp/.X0-lock", X_SOCK]),
    ("websockify", ["/usr/bin/websockify", "127.0.0.1:6080", "127.0.0.1:5900"], [], []),
    ("browser", [
        "/usr/bin/chromium-browser",
        "--no-sandbox", "--disable-dev-shm-usage", "--disable-gpu", "--in-process-gpu", "--no-zygote",
        "--enable-low-end-device-mode",
        "--renderer-process-limit=1",
        "--autoplay-policy=no-user-gesture-required",
        "--disable-background-timer-throttling", "--disable-background-networking",
        "--disable-extensions", "--disable-sync", "--disable-translate",
        "--disable-component-update", "--disable-breakpad", "--disable-crash-reporter",
        "--disable-domain-reliability", "--metrics-recording-only",
        "--disable-smooth-scrolling", "--force-device-scale-factor=1",
        "--overscroll-history-navigation=0",
        "--disable-features=Translate,BackForwardCache,MediaRouter,OptimizationHints,"
        "CalculateNativeWinOcclusion,IsolateOrigins,site-per-process,AudioServiceOutOfProcess",
        "--no-first-run", "--password-store=basic",
        f"--user-data-dir={CHROME_DIR}",
        "--disk-cache-dir=/tmp/chromium-cache", "--disk-cache-size=10485760",
        "--window-position=0,0", f"--window-size={WIN_W},{WIN_H}",
        f"--app={START_URL}",
        "--js-flags=--max-old-space-size=256",
    ], [X_SOCK, PULSE_SOCK], [
        f"{CHROME_DIR}/SingletonLock", f"{CHROME_DIR}/SingletonSocket", f"{CHROME_DIR}/SingletonCookie",
    ]),
]

running = []
stopping = False


def wait_for(path, timeout=30):
    end = time.time() + timeout
    while time.time() < end and not os.path.exists(path):
        time.sleep(0.1)


def supervise(name, cmd, waits, stale):
    while not stopping:
        for w in waits:
            wait_for(w)
        for pat in stale:
            for f in glob.glob(pat):
                try: os.remove(f)
                except OSError: pass
        p = subprocess.Popen(cmd, env=ENV)
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

for name, cmd, waits, stale in PROCS:
    threading.Thread(target=supervise, args=(name, cmd, waits, stale), daemon=True).start()
    time.sleep(0.2)


def nodelay(*socks):
    for s in socks:
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=NOVNC_DIR, **kwargs)

    def do_GET(self):
        if self.path == "/":
            self.send_response(302)
            self.send_header(
                "Location",
                "/vnc.html?autoconnect=true&resize=scale&reconnect=true&reconnect_delay=1000&show_dot=true")
            self.end_headers()
            return

        if self.path.startswith("/audio"):
            self.send_response(200)
            self.send_header("Content-Type", "audio/ogg")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            nodelay(self.connection)
            rec = subprocess.Popen(
                ["parec", "--device=virtual_speaker.monitor", "--format=s16le",
                 f"--rate={RATE}", "--channels=1", "--latency-msec=40"],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=ENV)
            enc = subprocess.Popen(
                ["opusenc", "--quiet", "--raw", "--raw-bits", "16", "--raw-rate", RATE,
                 "--raw-chan", "1", "--speech", "--bitrate", "24", "--comp", "3",
                 "--max-delay", "100", "-", "-"],
                stdin=rec.stdout, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            rec.stdout.close()
            fd = enc.stdout.fileno()
            try:
                while True:
                    chunk = os.read(fd, 4096)   # returns as soon as any data is ready
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
            except OSError:
                pass
            finally:
                for p in (enc, rec):
                    try: p.kill()
                    except Exception: pass
                    p.wait()
            return

        if self.headers.get("Upgrade", "").lower() == "websocket":
            self.close_connection = True
            client = self.connection
            try:
                upstream = socket.create_connection(("127.0.0.1", 6080), timeout=5)
            except OSError:
                self.send_error(502)
                return
            upstream.settimeout(None)
            nodelay(client, upstream)
            try:
                req_line = f"{self.command} {self.path} {self.request_version}\r\n".encode()
                headers = b"".join(f"{k}: {v}\r\n".encode() for k, v in self.headers.items()) + b"\r\n"
                upstream.sendall(req_line + headers)
                while True:
                    # no idle timeout: a static screen sends nothing for long stretches
                    r, _, _ = select.select([client, upstream], [], [])
                    for s in r:
                        data = s.recv(65536)
                        if not data:
                            return
                        (upstream if s is client else client).sendall(data)
            except OSError:
                pass
            finally:
                upstream.close()
            return

        super().do_GET()

    def log_message(self, format, *args):
        pass


ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
PYEOF

ENV RESOLUTION=800x480x16 \
    PORT=8080 \
    VNC_PASSWORD=changeme \
    START_URL=https://app.speechify.com \
    PYTHONUNBUFFERED=1

RUN cat << 'SHEOF' > /entrypoint.sh
#!/bin/sh
set -e
mkdir -p /root/.vnc /tmp/chromium-cache /root/.config/chromium/Default
# VNC auth only uses the first 8 characters of the password
printf '%s' "$VNC_PASSWORD" | vncpasswd -f > /root/.vnc/passwd
chmod 600 /root/.vnc/passwd

if [ -n "$SESSION_B64" ]; then
    echo "$SESSION_B64" | base64 -d | tar -xzf - -C /root/.config/chromium/Default 2>/dev/null || true
fi

exec /sbin/tini -- /usr/bin/python3 -O /server.py
SHEOF

RUN chmod +x /entrypoint.sh

HEALTHCHECK --interval=60s --timeout=5s CMD wget -q --spider http://127.0.0.1:${PORT}/vnc.html || exit 1

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
