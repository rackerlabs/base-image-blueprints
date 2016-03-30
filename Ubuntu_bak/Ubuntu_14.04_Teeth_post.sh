#!/bin/bash

# update
apt-get update
apt-get -y dist-upgrade

# fix bootable flag
parted -s /dev/sda set 1 boot on

#install dep removed from packages
pip install python-jwt

# custom teeth cloud-init bit
#wget https://e0399644aa2564da8102-cbe1f047c5bc5210015df7087c6eeb9e.ssl.cf5.rackcdn.com/cloud-init_0.7.5-1rackspace4_all.deb
wget http://10.69.246.205/cloud-init/cloud-init_0.7.7_systemd.deb
dpkg -i *.deb
apt-mark hold cloud-init
# breaks networking if missing
#mkdir -p /run/network

# cloud-init kludges
addgroup --system --quiet netdev
#echo -n > /etc/udev/rules.d/70-persistent-net.rules
#echo -n > /lib/udev/rules.d/75-persistent-net-generator.rules
#ln -s /dev/null /etc/udev/rules.d/80-net-name-slot.rules


# cloud-init debug logging
sed -i 's/WARNING/DEBUG/g' /etc/cloud/cloud.cfg.d/05_logging.cfg

# our cloud-init config
cat > /etc/cloud/cloud.cfg.d/10_rackspace.cfg <<'EOF'
disable_root: False
ssh_pwauth: False
ssh_deletekeys: False
resize_rootfs: noblock
manage_etc_hosts: localhost
apt_preserve_sources_list: True
system_info:
   distro: ubuntu
   default_user:
     name: root
     lock_passwd: True
     gecos: Ubuntu
     shell: /bin/bash
bootcmd:
  - /bin/sh -ec 'for i in $(ifquery --list --exclude lo --allow auto); do INTERFACES="$INTERFACES$i "; done; [ -n "$INTERFACES" ] || exit 0; while ! ifquery --state $INTERFACES >/dev/null; do sleep 1; done; for i in $INTERFACES; do while [ -e /run/network/ifup-$i.pid ]; do sleep 0.2; done; done'
EOF

# preseeds/debconf do not work for this anymore :(
cat > /etc/cloud/cloud.cfg.d/90_dpkg.cfg <<'EOF'
# to update this file, run dpkg-reconfigure cloud-init
datasource_list: [ ConfigDrive, None ]
EOF

# minimal network conf
# causes boot delay if left out, no bueno
cat > /etc/network/interfaces <<'EOF'
auto lo
iface lo inet loopback
EOF

# stage a clean hosts file
cat > /etc/hosts <<'EOF'
# The following lines are desirable for IPv6 capable hosts
::1     ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
127.0.0.1 localhost
EOF

# set some stuff
#echo 'net.ipv4.conf.eth0.arp_notify = 1' >> /etc/sysctl.conf
#echo 'vm.swappiness = 0' >> /etc/sysctl.conf

cat >> /etc/sysctl.conf <<'EOF'
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
EOF

# add support for Intel RSTe
# note: may need to add in additional commands for v1 support
e2label /dev/sda1 root
# think this should already be done in kickstart:
# apt-get install -y mdadm
rm /etc/mdadm/mdadm.conf
cat /dev/null > /etc/default/grub.d/dmraid2mdadm.cfg
echo "GRUB_DEVICE_LABEL=root" >> /etc/default/grub
echo "GRUB_RECORDFAIL_TIMEOUT=0" >> /etc/default/grub
sed -i 's#/dev/sda1#LABEL=root#g' /etc/fstab
# note: update-grub and update-initramfs will be done shortly

# another teeth specific
echo "bonding" >> /etc/modules
echo "8021q" >> /etc/modules
#echo 'OPTIONS="--hintpolicy=ignore"' >> /etc/default/irqbalance
cat > /etc/modprobe.d/blacklist-mei.conf <<'EOF'
blacklist mei_me
EOF
update-initramfs -u

# keep grub2 from using UUIDs and regenerate config
sed -i 's/#GRUB_DISABLE_LINUX_UUID.*/GRUB_DISABLE_LINUX_UUID="true"/g' /etc/default/grub
sed -i 's/#GRUB_TERMINAL=console/GRUB_TERMINAL=/g' /etc/default/grub
#sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT.*/GRUB_CMDLINE_LINUX_DEFAULT="net.ifnames=0 biosdevname=0 cgroup_enable=memory swapaccount=1 quiet"/g' /etc/default/grub
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT.*/GRUB_CMDLINE_LINUX_DEFAULT="cgroup_enable=memory swapaccount=1 quiet"/g' /etc/default/grub
sed -i 's/GRUB_TIMEOUT.*/GRUB_TIMEOUT=0/g' /etc/default/grub
#echo 'GRUB_SERIAL_COMMAND="serial --unit=0 --speed=115200n8 --word=8 --parity=no --stop=1"' >> /etc/default/grub
update-grub
# Fix grub config laid onto disk
sed -i 's/root=\/dev\/sda1/root=LABEL=root/g' /boot/grub/grub.cfg

# setup a usable console
cat > /etc/init/ttyS0.conf <<'EOF'
# ttyS0 - getty
#
# This service maintains a getty on ttyS1 from the point the system is
# started until it is shut down again.

start on stopped rc RUNLEVEL=[2345]
stop on runlevel [!2345]

respawn
exec /sbin/getty -L 115200 ttyS0 xterm
EOF

# setup a usable console
cat > /etc/init/ttyS4.conf <<'EOF'
# ttyS4 - getty
#
# This service maintains a getty on ttyS1 from the point the system is
# started until it is shut down again.

start on stopped rc RUNLEVEL=[2345]
stop on runlevel [!2345]

respawn
exec /sbin/getty -L 115200 ttyS4 xterm
EOF

cat > /etc/rc.local <<'EOF'
#!/bin/sh -e
#
# rc.local
#
# This script is executed at the end of each multiuser runlevel.
# Make sure that the script will "exit 0" on success or any other
# value on error.
#
# In order to enable or disable this script just change the execution
# bits.
#
# By default this script does nothing.
#
### rackspace note ###
# final network restart is a workaround for bug causing no network on reboot
# hopefully this goes away one day, sorry
/etc/init.d/networking restart
exit 0
EOF

# fsck no autorun on reboot
sed -i 's/#FSCKFIX=no/FSCKFIX=yes/g' /etc/default/rcS

# log packages
wget http://10.69.246.205/kickstarts/package_postback.sh
bash package_postback.sh Ubuntu_14.04_Teeth

# clean up
passwd -d root
passwd -l root
apt-get -y clean
apt-get -y autoremove
sed -i '/.*cdrom.*/d' /etc/apt/sources.list
# this file copies the installer's /etc/network/interfaces to the VM
# but we want to overwrite that with a "clean" file instead
# so we must disable that copying action in kickstart/preseed
rm -f /usr/lib/finish-install.d/55netcfg-copy-config
rm -f /etc/ssh/ssh_host_*
rm -f /var/cache/apt/archives/*.deb
rm -f /var/cache/apt/*cache.bin
rm -f /var/lib/apt/lists/*_Packages
rm -f /root/.bash_history
rm -f /root/.nano_history
rm -f /root/.lesshst
rm -f /root/.ssh/known_hosts
rm -rf /tmp/tmp
for k in $(find /var/log -type f); do echo > $k; done
for k in $(find /tmp -type f); do rm -f $k; done
for k in $(find /root -type f \( ! -iname ".*" \)); do rm -f $k; done
