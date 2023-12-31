#!/bin/sh
opkg update
opkg install luci-compat luci-app-frpc openssh-sftp-server luci-app-argon-config luci-app-acme
wget --no-check-certificate -O 01_taskd_1.0.3-1_all.ipk https://raw.githubusercontent.com/qy2009/iptv//main/01_taskd_1.0.3-1_all.ipk
wget --no-check-certificate -O 02_luci-lib-xterm_4.18.0_all.ipk https://raw.githubusercontent.com/qy2009/iptv//main/02_luci-lib-xterm_4.18.0_all.ipk
wget --no-check-certificate -O 03_luci-lib-taskd_1.0.17_all.ipk https://raw.githubusercontent.com/qy2009/iptv//main/03_luci-lib-taskd_1.0.17_all.ipk
wget --no-check-certificate -O 04_luci-app-store_0.1.14-2_all.ipk https://raw.githubusercontent.com/qy2009/iptv//main/04_luci-app-store_0.1.14-2_all.ipk
wget --no-check-certificate -O OpenClash+Kernel_a53.run https://raw.githubusercontent.com/qy2009/iptv//main/OpenClash+Kernel_a53.run
opkg install 01_taskd_1.0.3-1_all.ipk
opkg install 02_luci-lib-xterm_4.18.0_all.ipk
opkg install 03_luci-lib-taskd_1.0.17_all.ipk 
opkg install 04_luci-app-store_0.1.14-2_all.ipk
uci set luci.main.mediaurlbase='/luci-static/argon'
uci commit
sh OpenClash+Kernel_a53.run
