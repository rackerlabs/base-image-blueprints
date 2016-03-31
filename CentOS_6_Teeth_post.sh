#!/bin/bash

#centos 6 specific, pin the kernel by downloading old one and removing current version
KERNELREMOVE=$(uname -r)
rpm -ivh --oldpackage http://vault.centos.org/6.6/updates/x86_64/Packages/kernel-2.6.32-504.30.3.el6.x86_64.rpm
rpm -e kernel-$KERNELREMOVE
sed -i 's/'$KERNELREMOVE'/2.6.32-504.30.3.el6.x86_64/g' /boot/grub/grub.conf
echo "exclude=kernel*" >> /etc/yum.conf

# update all
yum -y update
yum -y upgrade

# setup systemd to boot to the right runlevel
echo -n "Setting default runlevel to multiuser text mode"
rm -f /etc/systemd/system/default.target
ln -s /lib/systemd/system/multi-user.target /etc/systemd/system/default.target

# If you want to remove rsyslog and just use journald, remove this!
echo -n "Disabling persistent journal"
rmdir /var/log/journal/

# Non-firewalld-firewall
echo -n "Writing static firewall"
cat > /etc/sysconfig/iptables <<'EOF'
# Simple static firewall loaded by iptables.service. Replace
# this with your own custom rules, run lokkit, or switch to
# shorewall or firewalld as your needs dictate.
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A INPUT -p icmp -j ACCEPT
-A INPUT -i lo -j ACCEPT
-A INPUT -m conntrack --ctstate NEW -m tcp -p tcp --dport 22 -j ACCEPT
-A INPUT -j REJECT --reject-with icmp-host-prohibited
-A FORWARD -j REJECT --reject-with icmp-host-prohibited
COMMIT
EOF

echo -n "Getty fixes"
# although we want console output going to the serial console, we don't
# actually have the opportunity to login there. FIX.
# we don't really need to auto-spawn _any_ gettys.
#sed -i '/^#NAutoVTs=.*/ a\
#NAutoVTs=0' /etc/systemd/logind.conf

echo -n "Network fixes"
# initscripts don't like this file to be missing.
cat > /etc/sysconfig/network << EOF
NETWORKING=yes
NOZEROCONF=yes
EOF

# For cloud images, 'eth0' _is_ the predictable device name, since
# we don't want to be tied to specific virtual (!) hardware
#echo -n > /etc/udev/rules.d/70-persistent-net.rules
#echo -n > /lib/udev/rules.d/75-persistent-net-generator.rules
#ln -s /dev/null /etc/udev/rules.d/80-net-name-slot.rules
cat > /etc/udev/rules.d/70-persistent-net.rules <<'EOF'
#OnMetal v1
SUBSYSTEM=="net", ACTION=="add", KERNELS=="0000:08:00.0", NAME="eth0"
SUBSYSTEM=="net", ACTION=="add", KERNELS=="0000:08:00.1", NAME="eth1"

#OnMetal v2
SUBSYSTEM=="net", ACTION=="add", KERNELS=="0000:03:00.0", NAME="eth0"
SUBSYSTEM=="net", ACTION=="add", KERNELS=="0000:03:00.1", NAME="eth1"
EOF

# simple eth0 config, again not hard-coded to the build hardware
#cat > /etc/sysconfig/network-scripts/ifcfg-eth0 << EOF
#DEVICE="eth0"
#BOOTPROTO="static"
#ONBOOT="yes"
#TYPE="Ethernet"
#EOF

# generic localhost names
cat > /etc/hosts << EOF
127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4
::1         localhost localhost.localdomain localhost6 localhost6.localdomain6
EOF

# Because memory is scarce resource in most cloud/virt environments,
# and because this impedes forensics, we are differing from the Fedora
# default of having /tmp on tmpfs.
echo "Disabling tmpfs for /tmp."
systemctl mask tmp.mount

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
vm.dirty_ratio=5
EOF

# disable auto fsck on boot
cat > /etc/sysconfig/autofsck << EOF
AUTOFSCK_DEF_CHECK=yes
PROMPT=no
AUTOFSCK_OPT="-y"
AUTOFSCK_TIMEOUT=10
EOF

# set rackspace mirrors
sed -i 's/mirror.centos.org/mirror.rackspace.com/g' /etc/yum.repos.d/CentOS-Base.repo
sed -i 's%baseurl.*%baseurl=http://mirror.rackspace.com/epel/6/x86_64/%g' /etc/yum.repos.d/epel.repo
sed -i '/baseurl/s/# *//' /etc/yum.repos.d/CentOS-Base.repo
sed -i '/baseurl/s/# *//' /etc/yum.repos.d/epel.repo
sed -i '/mirrorlist/s/^/#/' /etc/yum.repos.d/CentOS-Base.repo
sed -i '/mirrorlist/s/^/#/' /etc/yum.repos.d/epel.repo

# install custom cloud-init and lock version
#wget http://559bf13610f1c068ef67-1f39c9b68192359d629954d9e4642580.r76.cf2.rackcdn.com/cloud-init-0.7.5-14rackspace.x86_64.rpm
wget http://KICK_HOST/cloud-init/cloud-init-0.7.7-el6.fc22.noarch.rpm
rpm -Uvh --nodeps cloud*.rpm
yum versionlock add cloud-init
cp -r /usr/lib/python2.7/site-packages/cloud* /usr/lib/python2.6/site-packages/
pip install pyserial
chkconfig cloud-init on
sed -i '/import sys/a reload(sys)\nsys.setdefaultencoding("Cp1252")' /usr/lib/python2.6/site-packages/configobj.py

# more cloud-init logging
sed -i 's/WARNING/DEBUG/g' /etc/cloud/cloud.cfg.d/05_logging.cfg

# hack for teeth sd* labeling
tune2fs -L / /dev/sda1
cat > /etc/fstab <<'EOF'
LABEL=/ / ext3 errors=remount-ro,noatime 0 1
EOF

# another teeth specific
cat > /etc/sysconfig/modules/onmetal.modules <<'EOF'
#!/bin/sh
exec /sbin/modprobe bonding >/dev/null 2>&1
exec /sbin/modprobe 8021q >/dev/null 2>&1
EOF
chmod +x /etc/sysconfig/modules/onmetal.modules
#
cat > /etc/modprobe.d/blacklist-mei.conf <<'EOF'
blacklist mei_me
EOF
dracut -f

# our cloud-init config
cat > /etc/cloud/cloud.cfg.d/10_rackspace.cfg <<'EOF'
datasource_list: [ ConfigDrive, None ]
disable_root: False
ssh_pwauth: True
ssh_deletekeys: False
resize_rootfs: noblock
manage_etc_hosts: True
growpart:
  mode: auto
  devices: ['/']
system_info:
  distro: rhel
  ssh_svcname: sshd
  default_user:
    name: root
    lock_passwd: True
    gecos: CentOS cloud-init user
    shell: /bin/bash
cloud_config_modules:
 - disk_setup
 - ssh-import-id
 - locale
 - set-passwords
 - package-update-upgrade-install
 - landscape
 - timezone
 - puppet
 - chef
 - salt-minion
 - mcollective
 - disable-ec2-metadata
 - runcmd
 - byobu
EOF

# force grub to use generic disk labels, bootloader above does not do this
#sed -i 's%root=.*%root=LABEL=/ console=ttyS4,115200n8 8250.nr_uarts=5 modprobe.blacklist=mei_me selinux=0%g' /boot/grub/grub.conf
sed -i 's%root=.*%root=LABEL=/ 8250.nr_uarts=5 modprobe.blacklist=mei_me acpi=noirq noapic selinux=0%g' /boot/grub/grub.conf
sed -i '/splashimage/d' /boot/grub/grub.conf
sed -i 'g/SELINUX=*/SELINUX=permissive/s' /etc/selinux/config

# log packages
wget http://KICK_HOST/kickstarts/package_postback.sh
bash package_postback.sh CentOS_6_Teeth

# clean up
yum clean all
passwd -d root
passwd -l root
truncate -c -s 0 /var/log/yum.log
rm -f /etc/ssh/ssh_host_*
rm -f /etc/resolv.conf
rm -f /root/.bash_history
rm -f /root/.nano_history
rm -f /root/.lesshst
rm -f /root/.ssh/known_hosts
rm -f /root/anaconda-ks.cfg
rm -rf /tmp/tmp
for k in $(find /tmp -type f); do rm -f $k; done
for k in $(find /root -type f \( ! -iname ".*" \)); do rm -f $k; done
for k in $(find /var/log -type f); do echo > $k; done
