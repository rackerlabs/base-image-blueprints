#!/bin/bash

# set rackspace mirrors up
echo "Setting up Rackspace mirrors"
sed -i 's/mirror.centos.org/mirror.rackspace.com/g' /etc/yum.repos.d/CentOS-Base.repo
sed -i 's%baseurl.*%baseurl=http://mirror.rackspace.com/epel/6/x86_64/%g' /etc/yum.repos.d/epel.repo
sed -i '/baseurl/s/# *//' /etc/yum.repos.d/CentOS-Base.repo
sed -i '/baseurl/s/# *//' /etc/yum.repos.d/epel.repo
sed -i '/mirrorlist/s/^/#/' /etc/yum.repos.d/CentOS-Base.repo
sed -i '/mirrorlist/s/^/#/' /etc/yum.repos.d/epel.repo

# update all
echo "Installing all updates"
yum -y update

# Ensure that the kernel does not get upgraded
echo "exclude=kernel*" >> /etc/yum.conf

# teeth specific initrd
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

echo -n "Network fixes"
# initscripts don't like this file to be missing.
cat > /etc/sysconfig/network << EOF
NETWORKING=yes
NOZEROCONF=yes
EOF

# IPv6 does not come up on first boot unless you restart networking.
echo -n "Writing initial network restart script"
mkdir -p /var/lib/cloud/scripts/per-instance
cat > /var/lib/cloud/scripts/per-instance/restartnetworkip6.sh <<'EOF'
#!/bin/sh
# IPv6 does not come up on first boot on CentOS 6 without a network restart.
# This may be kernel related.
# Revisit this if we unpin the kernel from 2.6.32-504.30.3.el6.x86_64
sleep 12
service network restart
EOF
chmod a+x /var/lib/cloud/scripts/per-instance/restartnetworkip6.sh

cat > /etc/init.d/network-fix <<'EOF'
#!/bin/sh
#
# set ethernet devices to promiscuous mode
#
# chkconfig:   2345 15 85
# description: Sets ethernet devices to promiscuous mode

### BEGIN INIT INFO
# Provides:
# Required-Start:    $local_fs $network $named $remote_fs cloud-init-local
# Required-Stop:
# Should-Start:
# Should-Stop:
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Sets ethernet devices to promiscuous mode
# Description:       Sets ethernet devices to promiscuous mode so that bonding will work
### END INIT INFO

# Source function library.
. /etc/rc.d/init.d/functions

loglevel="info"

start() {
    [ -x $exec ] || exit 5
    INTERFACES=`/sbin/ip link | /bin/awk -F: '$0 !~ "lo|vir|wl|@|^[^0-9]"{print $2;getline}'`
    for interface in $INTERFACES; do /sbin/ip link set $interface promisc on; done
    retval=$?
    echo "Networks set to promiscuous mode"
    return $retval
}

case "$1" in
    start)
        $1
        ;;
    *)
        echo $"Usage: $0 {start|stop|status|restart|condrestart|try-restart|reload|force-reload}"
        exit 2
        ;;
esac
exit $?
EOF

chmod a+x /etc/init.d/network-fix
chkconfig network-fix on
# Change cloud-init startup script to start after the network fix
sed -i 's/remote_fs cloud-init-local/remote_fs network-fix cloud-init-local/' /etc/init.d/cloud-init

# For cloud images, 'eth0' _is_ the predictable device name, since
# we don't want to be tied to specific virtual (!) hardware
cat > /etc/udev/rules.d/70-persistent-net.rules <<'EOF'
#OnMetal v1
SUBSYSTEM=="net", ACTION=="add", KERNELS=="0000:08:00.0", NAME="eth0"
SUBSYSTEM=="net", ACTION=="add", KERNELS=="0000:08:00.1", NAME="eth1"

#OnMetal v2
SUBSYSTEM=="net", ACTION=="add", KERNELS=="0000:03:00.0", NAME="eth0"
SUBSYSTEM=="net", ACTION=="add", KERNELS=="0000:03:00.1", NAME="eth1"
EOF

# generic localhost names
cat > /etc/hosts << EOF
127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4
::1         localhost localhost.localdomain localhost6 localhost6.localdomain6
EOF

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

# install custom cloud-init and lock version
wget http://KICK_HOST/pyserial/pyserial-3.1.1.tar.gz
tar xvfz pyserial-3.1.1.tar.gz
cd pyserial-3.1.1 && python setup.py install
cd ..
rpm -Uvh --nodeps http://KICK_HOST/cloud-init/cloud-init-0.7.7-bzr1117.el6.noarch.rpm
yum versionlock add cloud-init
chkconfig cloud-init on
sed -i '/import sys/a reload(sys)\nsys.setdefaultencoding("Cp1252")' /usr/lib/python2.6/site-packages/configobj.py

# more cloud-init logging
sed -i 's/WARNING/DEBUG/g' /etc/cloud/cloud.cfg.d/05_logging.cfg

# hack for teeth sd* labeling
tune2fs -L / /dev/sda1
cat > /etc/fstab <<'EOF'
LABEL=/ / ext4 errors=remount-ro,noatime 0 1
EOF

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
  - yum-add-repo
  - package-update-upgrade-install
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
sed -i 's%root=.*%root=LABEL=/ 8250.nr_uarts=5 modprobe.blacklist=mei_me acpi=noirq noapic selinux=0 console=ttyS0,57600n8%g' /boot/grub/grub.conf
sed -i '/splashimage/d' /boot/grub/grub.conf
sed -i 'g/SELINUX=*/SELINUX=disabled/s' /etc/selinux/config

# clean up
yum clean all
passwd -d root
passwd -l root
rm -f /etc/ssh/ssh_host_*
rm -f /root/.bash_history
rm -f /root/.nano_history
rm -f /root/.lesshst
rm -f /root/.ssh/known_hosts
rm -f /root/anaconda-ks.cfg
rm -rf /tmp/tmp
truncate -s 0 /etc/resolv.conf
find /tmp -type f -delete
find /root -type f ! -iname ".*" -delete
find /var/log -type f -exec truncate -s 0 {} \;
