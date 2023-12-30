#!/bin/sh
opkg update
opkg install luci-compat luci-app-frpc openssh-sftp-server
wget --no-check-certificate -O taskd_1.0.3-1_all.ipk https://raw.githubusercontent.com/ylx2016/Linux-NetSpeed/master/tcpx.sh
