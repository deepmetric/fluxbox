FROM alpine:3.21

RUN apk add --no-cache \
    xvfb \
    x11vnc \
    fluxbox \
    xterm \
    falkon \
    mesa-gl \
    novnc \
    websockify \
    supervisor \
    bash \
    ttf-dejavu \
    font-noto

RUN ln -sf /usr/share/novnc/vnc.html /usr/share/novnc/index.html

RUN mkdir -p /root/.fluxbox && cat << 'EOF' > /root/.fluxbox/menu
[begin] (Fluxbox)
  [exec] (Falkon) {falkon --no-sandbox}
  [exec] (Terminal) {xterm}
  [restart] (Restart)
  [exit] (Exit)
[end]
EOF

ENV DISPLAY=:0 \
    RESOLUTION=1280x720x16 \
    PORT=8080 \
    VNC_PASSWORD=changeme \
    START_URL=https://www.youtube.com

RUN cat << 'EOF' > /entrypoint.sh
#!/bin/bash
set -e

mkdir -p /root/.vnc
x11vnc -storepasswd "$VNC_PASSWORD" /root/.vnc/passwd

cat << CONF > /etc/supervisord.conf
[supervisord]
nodaemon=true
logfile=/dev/null
logfile_maxbytes=0

[program:xvfb]
command=/usr/bin/Xvfb :0 -screen 0 ${RESOLUTION}
autorestart=true
priority=10

[program:wm]
command=/usr/bin/fluxbox
environment=DISPLAY=":0"
autorestart=true
priority=20

[program:x11vnc]
command=/usr/bin/x11vnc -display :0 -rfbauth /root/.vnc/passwd -forever -shared -rfbport 5900
autorestart=true
priority=30

[program:novnc]
command=/usr/bin/websockify --web=/usr/share/novnc/ ${PORT} localhost:5900
autorestart=true
priority=40

[program:falkon]
command=/usr/bin/falkon --no-sandbox ${START_URL}
environment=DISPLAY=":0",HOME="/root",QTWEBENGINE_DISABLE_SANDBOX="1",QTWEBENGINE_CHROMIUM_FLAGS="--disable-dev-shm-usage --disable-gpu"
autorestart=true
priority=50
CONF

exec /usr/bin/supervisord -c /etc/supervisord.conf
EOF

RUN chmod +x /entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
