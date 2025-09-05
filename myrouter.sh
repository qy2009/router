#!/bin/sh
opkg update
opkg install nano luci-compat luci-app-frpc openssh-sftp-server luci-app-acme
wget --no-check-certificate -O 01_taskd_1.0.3-1_all.ipk https://cdn.jsdelivr.net/gh/qy2009/iptv@master/01_taskd_1.0.3-1_all.ipk
wget --no-check-certificate -O 02_luci-lib-xterm_4.18.0_all.ipk https://cdn.jsdelivr.net/gh/qy2009/iptv@master/02_luci-lib-xterm_4.18.0_all.ipk
wget --no-check-certificate -O 03_luci-lib-taskd_1.0.17_all.ipk https://cdn.jsdelivr.net/gh/qy2009/iptv@master/03_luci-lib-taskd_1.0.17_all.ipk
wget --no-check-certificate -O 04_luci-app-store_0.1.14-2_all.ipk https://cdn.jsdelivr.net/gh/qy2009/iptv@master/04_luci-app-store_0.1.14-2_all.ipk
#wget --no-check-certificate -O OpenClash.run https://cdn.jsdelivr.net/gh/qy2009/iptv@master/OpenClash_0.46.014+aarch_64_core.run
opkg install 01_taskd_1.0.3-1_all.ipk
opkg install 02_luci-lib-xterm_4.18.0_all.ipk
opkg install 03_luci-lib-taskd_1.0.17_all.ipk 
opkg install 04_luci-app-store_0.1.14-2_all.ipk
#sh OpenClash.run
