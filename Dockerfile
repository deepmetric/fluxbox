FROM alpine:3.21

# Install Xvfb, x11vnc, IceWM, noVNC, websockify, terminal, and supervisor
RUN apk add --no-cache \
    xvfb \
    x11vnc \
    icewm \
    xterm \
    novnc \
    websockify \
    supervisor \
    bash \
    ttf-dejavu

# Redirect root path (/) directly to noVNC auto-connect UI
RUN ln -sf /usr/share/novnc/vnc.html /usr/share/novnc/index.html

# Default environment variables (Render overrides PORT automatically)
ENV DISPLAY=:0 \
    RESOLUTION=1280x720x16 \
    PORT=8080 \
    VNC_PASSWORD=changeme

# Create startup script to configure VNC password and launch supervisord
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
command=/usr/bin/icewm-session
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
CONF

exec /usr/bin/supervisord -c /etc/supervisord.conf
EOF

RUN chmod +x /entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
