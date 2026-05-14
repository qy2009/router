#!/bin/sh
opkg update
opkg install zram-swap nano luci-compat luci-app-frpc openssh-sftp-server luci-app-p910nd luci-app-lucky luci-theme-argon
wget --no-check-certificate -O 01_taskd.ipk https://cdn.jsdelivr.net/gh/qy2009/iptv@master/taskd_1.0.3-2_all.ipk
wget --no-check-certificate -O 02_luci-lib-xterm.ipk https://cdn.jsdelivr.net/gh/qy2009/iptv@master/02_luci-lib-xterm_4.18.0_all.ipk
wget --no-check-certificate -O 03_luci-lib-taskd.ipk https://cdn.jsdelivr.net/gh/qy2009/iptv@master/luci-lib-taskd_1.0.25_all.ipk
wget --no-check-certificate -O 04_luci-app-store.ipk https://cdn.jsdelivr.net/gh/qy2009/iptv@master/luci-app-store_0.1.32-1_all.ipk
wget --no-check-certificate -O OpenClash.run https://cdn.jsdelivr.net/gh/qy2009/iptv@master/OpenClash_0.47.075+aarch64_core.run
opkg install 01_taskd.ipk
opkg install 02_luci-lib-xterm.ipk
opkg install 03_luci-lib-taskd.ipk 
opkg install 04_luci-app-store.ipk
sh OpenClash.run
