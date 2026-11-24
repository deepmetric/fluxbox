FROM alpine:3.21

RUN apk add --no-cache \
    xvfb \
    x11vnc \
    fluxbox \
    xterm \
    epiphany \
    gst-plugins-good \
    gst-plugins-bad \
    gst-libav \
    novnc \
    websockify \
    supervisor \
    bash \
    ttf-dejavu \
    font-noto

RUN ln -sf /usr/share/novnc/vnc.html /usr/share/novnc/index.html

RUN mkdir -p /root/.fluxbox && cat << 'EOF' > /root/.fluxbox/menu
[begin] (Fluxbox)
  [exec] (Browser) {epiphany https://m.youtube.com}
  [exec] (Terminal) {xterm}
  [restart] (Restart)
  [exit] (Exit)
[end]
EOF

ENV DISPLAY=:0 \
    RESOLUTION=1024x576x16 \
    PORT=8080 \
    VNC_PASSWORD=changeme \
    START_URL=https://m.youtube.com

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

[program:browser]
command=/usr/bin/epiphany ${START_URL}
environment=DISPLAY=":0",HOME="/root",WEBKIT_DISABLE_COMPOSITING_MODE="1",G_SLICE="always-malloc",MALLOC_ARENA_MAX="2"
autorestart=true
priority=50
CONF

exec /usr/bin/supervisord -c /etc/supervisord.conf
EOF

RUN chmod +x /entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
