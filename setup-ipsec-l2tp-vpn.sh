#! /bin/sh
# reference url: https://raymii.org/s/tutorials/IPSEC_L2TP_vpn_with_Ubuntu_14.04.html
#

ipsec_psk=""
l2tpd_ip_range="172.16.1.100-172.16.1.200"
l2tpd_local_ip="172.16.1.1"
l2tpd_ppp_user="andrew"
l2tpd_ppp_passwd="hellovpn"
vpn_iface=$1

_show_usage () {
	cat <<EOF

Usage:
      sudo `basename $0` <vpn interface>

  <vpn interface> = { `ifconfig | grep HWaddr | awk '{print $1}' | tr '\n' ' '` }

EOF
}

do_init () {
	if [ `whoami` != "root" ]; then
		echo "Only root can do, please use sudo"
		exit 1
	fi

	if [ -z "$vpn_iface" ]; then
		_show_usage
		exit 1
	fi

	ifconfig $vpn_iface 1>/dev/null 2>&1
	if [ "$?" != "0" ]; then
		echo "There is no $vpn_iface interface"
		exit 1
	fi
}

pkg_install () {
	DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openswan xl2tpd ppp lsof
}

cfg_sysctl () {
	local config_file="/etc/sysctl.conf"
	if [ -f $config_file ] && [ ! -f ${config_file}.BAK ]; then
		cp $config_file ${config_file}.BAK
	fi
	echo "net.ipv4.ip_forward = 1" | tee -a $config_file
	echo "net.ipv4.conf.all.accept_redirects = 0"| tee -a $config_file
	echo "net.ipv4.conf.all.send_redirects = 0"| tee -a $config_file
		
	for vpn in /proc/sys/net/ipv4/conf/*; do echo 0 > $vpn/accept_redirects; echo 0 > $vpn/send_redirects; done
	sysctl -p
	ipsec verify
}

cfg_ipsec () {
	local config_file="/etc/ipsec.conf"
	if [ -f $config_file ] && [ ! -f ${config_file}.BAK ]; then
		cp $config_file ${config_file}.BAK
	fi
	cat <<EOF >$config_file
version 2

config setup
    dumpdir=/var/run/pluto/
    nat_traversal=yes
    virtual_private=%v4:10.0.0.0/8,%v4:192.168.0.0/16,%v4:172.16.0.0/12,%v6:fd00::/8,%v6:fe80::/10
    protostack=netkey
    force_keepalive=yes
    keep_alive=60

conn L2TP-PSK-noNAT
    authby=secret
    pfs=no
    auto=add
    keyingtries=3
    ikelifetime=8h
    keylife=1h
    ike=aes256-sha1,aes128-sha1,3des-sha1
    phase2alg=aes256-sha1,aes128-sha1,3des-sha1
    type=transport
    left=`ifconfig $vpn_iface | awk '/inet addr/{print substr($2,6)}'`
    leftprotoport=17/1701
    right=%any
    rightprotoport=17/%any
    dpddelay=10
    dpdtimeout=20
    dpdaction=clear
EOF

	config_file="/etc/ipsec.secrets"
	if [ -f $config_file ] && [ ! -f ${config_file}.BAK ]; then
		cp $config_file ${config_file}.BAK
	fi
	ipsec_psk=`openssl rand -hex 30`
	cat <<EOF >$config_file
`ifconfig $vpn_iface | awk '/inet addr/{print substr($2,6)}'`   %any:  PSK "$ipsec_psk"
EOF
}

cfg_l2tp () {
	local config_file="/etc/xl2tpd/xl2tpd.conf"
	if [ -f $config_file ] && [ ! -f ${config_file}.BAK ]; then
		cp $config_file ${config_file}.BAK
	fi
	cat <<EOF >$config_file
[global]
ipsec saref = yes
saref refinfo = 30

;debug avp = yes
;debug network = yes
;debug state = yes
;debug tunnel = yes

[lns default]
ip range = $l2tpd_ip_range
local ip = $l2tpd_local_ip
refuse pap = yes
require authentication = yes
;ppp debug = yes
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOF

	config_file="/etc/ppp/options.xl2tpd"
	if [ -f $config_file ] && [ ! -f ${config_file}.BAK ]; then
		cp $config_file ${config_file}.BAK
	fi
	cat <<EOF >$config_file
require-mschap-v2
ms-dns 8.8.8.8
ms-dns 8.8.4.4
auth
mtu 1200
mru 1000
crtscts
hide-password
modem
name l2tpd
proxyarp
lcp-echo-interval 30
lcp-echo-failure 4
EOF

	config_file="/etc/ppp/chap-secrets"
	if [ -f $config_file ] && [ ! -f ${config_file}.BAK ]; then
		cp $config_file ${config_file}.BAK
	fi
	cat <<EOF >$config_file
# Secrets for authentication using CHAP
# client	server	secret			IP addresses
$l2tpd_ppp_user		l2tpd	$l2tpd_ppp_passwd		*
EOF
}

serv_restart () {
	/etc/init.d/ipsec restart 
	/etc/init.d/xl2tpd restart
}

do_done () {
	echo ""
	echo "*** VPN info ***"
	test -f /etc/ipsec.conf && echo "vpn server: `cat /etc/ipsec.conf | grep left= | awk -F '=' '{print $2}'`"
	test -f /etc/ppp/chap-secrets && echo "l2tpd ppp : `cat /etc/ppp/chap-secrets | tail -n 1 | awk '{print $1}'` / `cat /etc/ppp/chap-secrets | tail -n 1 | awk '{print $3}'`"
	test -f /etc/ipsec.secrets && echo "ipsec psk : `cat /etc/ipsec.secrets | tail -n 1 | awk '{print $4}' | awk -F '"' '{print $2}'`"
	echo ""

cat <<EOF
*** warning ***
if your vpn server behind nat, you might need to setup register "AssumeUDPEncapsulationContextOnSendRule=2"
at HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Services\\PolicyAgent
	
please check the info: 
https://support.microsoft.com/zh-tw/help/926179/how-to-configure-an-l2tp-ipsec-server-behind-a-nat-t-device-in-windows

EOF
}

do_main () {
	do_init
	pkg_install
	cfg_sysctl
	cfg_ipsec
	cfg_l2tp
	serv_restart
	do_done
}

do_main

