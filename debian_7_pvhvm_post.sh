#!/bin/bash

# fix boot flag
parted -s /dev/xvda set 1 boot on

# Debian puts these in the wrong order from what we need
# should be ConfigDrive, None but preseed populates with
# None, Configdrive which breaks user-data scripts
cat > /etc/cloud/cloud.cfg.d/90_dpkg.cfg <<'EOF'
# to update this file, run dpkg-reconfigure cloud-init
datasource_list: [ ConfigDrive, None ]
EOF

# our cloud-init config
cat > /etc/cloud/cloud.cfg.d/10_rackspace.cfg <<'EOF'
disable_root: False
ssh_pwauth: True
ssh_deletekeys: False
resize_rootfs: noblock
apt_preserve_sources_list: True
manage-resolv-conf: False
manage_etc_hosts: localhost
EOF

# cloud-init kludges
echo -n > /etc/udev/rules.d/70-persistent-net.rules
echo -n > /lib/udev/rules.d/75-persistent-net-generator.rules

# minimal network conf that doesnt dhcp
# causes boot delay if left out, no bueno
cat > /etc/network/interfaces <<'EOF'
auto lo
iface lo inet loopback
EOF

cat > /etc/hosts <<'EOF'
127.0.0.1 localhost

# The following lines are desirable for IPv6 capable hosts
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

# set some stuff
echo 'net.ipv4.conf.eth0.arp_notify = 1' >> /etc/sysctl.conf
echo 'vm.swappiness = 0' >> /etc/sysctl.conf

cat >> /etc/sysctl.conf <<'EOF'
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
EOF

# our fstab is fonky
cat > /etc/fstab <<'EOF'
# /etc/fstab: static file system information.
#
# Use 'blkid' to print the universally unique identifier for a
# device; this may be used with UUID= as a more robust way to name devices
# that works even if disks are added and removed. See fstab(5).
#
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
/dev/xvda1  /               ext4    errors=remount-ro,noatime,barrier=0 0       1
#/dev/xvdc1 none            swap    sw              0       0
EOF

# keep grub2 from using UUIDs and regenerate config
sed -i 's/#GRUB_DISABLE_LINUX_UUID.*/GRUB_DISABLE_LINUX_UUID="true"/g' /etc/default/grub
update-grub

# remove cd-rom from sources.list
sed -i '/.*cdrom.*/d' /etc/apt/sources.list

# Make change to xe-linux-distribution init file
sed -i 's/XenServer Virtual Machine Tools/xe-linux-distribution/g' /etc/init.d/xe-linux-distribution
insserv xe-linux-distribution
insserv python-nova-agent

# Ensure cloud-init starts after python-nova-agent - Added X-Start-After header only
cat > /etc/init.d/cloud-init-local <<'EOF'
#! /bin/sh
### BEGIN INIT INFO
# Provides:          cloud-init-local
# Required-Start:    $local_fs $remote_fs $network
# Required-Stop:
# X-Start-After:     python-nova-agent
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Cloud init local
# Description:       Cloud configuration initialization
### END INIT INFO

# Authors: Julien Danjou <acid@debian.org>
#          Juerg Haefliger <juerg.haefliger@hp.com>

PATH=/sbin:/usr/sbin:/bin:/usr/bin
DESC="Cloud service"
NAME=cloud-init
DAEMON=/usr/bin/$NAME
DAEMON_ARGS="init --local"
SCRIPTNAME=/etc/init.d/$NAME

# Exit if the package is not installed
[ -x "$DAEMON" ] || exit 0

# Read configuration variable file if it is present
[ -r /etc/default/$NAME ] && . /etc/default/$NAME

# Define LSB log_* functions.
# Depend on lsb-base (>= 3.2-14) to ensure that this file is present
# and status_of_proc is working.
. /lib/lsb/init-functions

if init_is_upstart; then
	case "$1" in
	stop)
		exit 0
	;;
	*)
		exit 1
	;;
	esac
fi

case "$1" in
start)
	log_daemon_msg "Starting $DESC" "$NAME"
	$DAEMON ${DAEMON_ARGS}
	case "$?" in
		0|1) log_end_msg 0 ;;
		2) log_end_msg 1 ;;
	esac
;;
stop|restart|force-reload)
	echo "Error: argument '$1' not supported" >&2
	exit 3
;;
*)
	echo "Usage: $SCRIPTNAME {start}" >&2
	exit 3
;;
esac

:
EOF
insserv cloud-init-local

# do this here so we have our mirror set
cat > /etc/apt/sources.list <<'EOF'
deb http://mirror.rackspace.com/debian wheezy main
deb-src http://mirror.rackspace.com/debian wheezy main

deb http://mirror.rackspace.com/debian/ wheezy-backports main

deb http://mirror.rackspace.com/debian-security/ wheezy/updates main
deb-src http://mirror.rackspace.com/debian-security/ wheezy/updates main
EOF

# Make sure everything is up to date
apt-get update && apt-get -y dist-upgrade

# clean up
passwd -d root
apt-get -y clean
apt-get -y autoremove
rm -f /etc/ssh/ssh_host_*
rm -f /var/cache/apt/archives/*.deb
rm -f /var/cache/apt/*cache.bin
rm -f /var/lib/apt/lists/*_Packages
rm -f /root/.bash_history
rm -f /root/.nano_history
rm -f /root/.lesshst
rm -f /root/.ssh/known_hosts
for k in $(find /var/log -type f); do echo > $k; done
for k in $(find /tmp -type f); do rm -f $k; done
