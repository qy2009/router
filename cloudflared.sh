

# Create a folder
mkdir -p /usr/local/bin

# Download latest cloudflared (check latest version at github.com/cloudflare/cloudflared/releases)
curl -Lo /usr/local/bin/cloudflared \
 https://github.com/cloudflare/cloudflared/releases/download/2026.5.0/cloudflared-linux-arm64

chmod +x /usr/local/bin/cloudflared
export PATH=$PATH:/usr/local/bin

# Verify it works
cloudflared --version

nano /etc/init.d/cloudflared
FILE
#!/bin/sh /etc/rc.common

START=99
STOP=10
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command /usr/local/bin/cloudflared tunnel run \
        --token PUT_TOKEN_HERE
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
FILE

chmod +x /etc/init.d/cloudflared
/etc/init.d/cloudflared enable
/etc/init.d/cloudflared start


Verify it's running:
/etc/init.d/cloudflared status
logread | grep cloudflared


Step 4 — Preserve across firmware upgrades
nano /etc/sysupgrade.conf
