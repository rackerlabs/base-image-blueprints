#!/bin/bash

# fix bootable flag
parted -s /dev/sda set 1 boot on
e2label /dev/sda1 root

# replace the mdadm.conf w/ default universal config
echo "CREATE owner=root group=disk mode=0660 auto=yes" > /etc/mdadm/mdadm.conf
echo "HOMEHOST <system>" >> /etc/mdadm/mdadm.conf
echo "MAILADDR root" >> /etc/mdadm/mdadm.conf

cat > /etc/initramfs-tools/conf.d/mdadm<<'EOF'
## mdadm boot_degraded configuration
##
BOOT_DEGRADED=true
EOF

# Fix mdadm config
cp /usr/share/initramfs-tools/scripts/mdadm-functions /etc/initramfs-tools/scripts/
cp /usr/share/initramfs-tools/hooks/mdadm /etc/initramfs-tools/hooks/
cp /lib/udev/rules.d/64-md-raid-assembly.rules /etc/udev/rules.d/
cp /lib/udev/rules.d/63-md-raid-arrays.rules /etc/udev/rules.d/

wget http://KICK_HOST/misc/mdadm-init-deb -O /etc/initramfs-tools/scripts/local-top/mdadm
chmod a+x /etc/initramfs-tools/scripts/local-top/mdadm

cat > /etc/udev/rules.d/21-persistent-local.rules<<'EOF'
KERNEL=="md*p1", SUBSYSTEM=="block", SYMLINK+="disk/by-label/root"
KERNEL=="md*p2", SUBSYSTEM=="block", SYMLINK+="disk/by-label/config-2"
EOF

# Set udev rule to not add by-label symlinks for v2 blockdevs if not raid
wget http://KICK_HOST/misc/60-persistent-storage.rules-debu -O /etc/udev/rules.d/60-persistent-storage.rules
cat /etc/udev/rules.d/21-persistent-local.rules >> /etc/udev/rules.d/60-persistent-storage.rules
update-initramfs -u

# teeth cloud-init workaround, hopefully goes away with upstream cloud-init changes?
#wget http://KICK_HOST/kickstarts/Teeth-cloud-init
#cp Teeth-cloud-init /usr/share/pyshared/cloudinit/sources/DataSourceConfigDrive.py
wget http://KICK_HOST/cloud-init/cloud-init_0.7.7-py3.4-systemd.deb
dpkg -i *.deb
apt-mark hold cloud-init

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
ssh_pwauth: False
ssh_deletekeys: False
resize_rootfs: noblock
manage_etc_hosts: localhost
apt_preserve_sources_list: True
system_info:
   distro: debian
   default_user:
     name: root
     lock_passwd: True
     gecos: Debian
     shell: /bin/bash

cloud_config_modules:
 - emit_upstart
 - disk_setup
 - ssh-import-id
 - locale
 - set-passwords
 - snappy
 - grub-dpkg
 - apt-pipelining
 - apt-configure
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

# cloud-init kludges
echo -n > /etc/udev/rules.d/70-persistent-net.rules
echo -n > /lib/udev/rules.d/75-persistent-net-generator.rules

mkdir -p /etc/systemd/network
# OMv1
cat > /etc/systemd/network/10-internet.link <<'EOF'
[Match]
Path=pci-0000:03:00.0-*

[Link]
Name=eth0
EOF
cat > /etc/systemd/network/11-internet.link <<'EOF'
[Match]
Path=pci-0000:03:00.1-*

[Link]
Name=eth1
EOF

# OMv2
cat > /etc/systemd/network/12-internet.link <<'EOF'
[Match]
Path=pci-0000:08:00.0-*

[Link]
Name=eth0
EOF
cat > /etc/systemd/network/13-internet.link <<'EOF'
[Match]
Path=pci-0000:08:00.1-*

[Link]
Name=eth1
EOF

# minimal network conf that doesnt dhcp
# causes boot delay if left out, no bueno
cat > /etc/network/interfaces <<'EOF'
auto lo
iface lo inet loopback
EOF

cat > /etc/hosts <<'EOF'
127.0.0.1	localhost

# The following lines are desirable for IPv6 capable hosts
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
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
vm.dirty_ratio=5
EOF

# keep grub2 from using UUIDs and regenerate config
sed -i 's/#GRUB_DISABLE_LINUX_UUID.*/GRUB_DISABLE_LINUX_UUID="true"/g' /etc/default/grub
#sed -i 's/#GRUB_TERMINAL=console/GRUB_TERMINAL=console/g' /etc/default/grub
sed -i 's/#GRUB_TERMINAL=console/GRUB_TERMINAL=/g' /etc/default/grub
#sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT.*/GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS4,115200n8 8250.nr_uarts=5 splash quiet"/g' /etc/default/grub
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT.*/GRUB_CMDLINE_LINUX_DEFAULT="rd.fstab=no acpi=ht noapic 8250.nr_uarts=5 quiet"/g' /etc/default/grub
sed -i 's/GRUB_TIMEOUT.*/GRUB_TIMEOUT=0/g' /etc/default/grub
#echo 'GRUB_SERIAL_COMMAND="serial --unit=0 --speed=115200n8 --word=8 --parity=no --stop=1"' >> /etc/default/grub
update-grub
sed -i 's#/dev/sda1#LABEL=root#g' /etc/fstab
# TODO: make update-grub handle this
sed -i 's#/dev/sda1#LABEL=root#g' /boot/grub/grub.cfg

#add this to make sure it gets copied to initrd
echo "INITRDSTART='all'" >> /etc/default/mdadm

echo "sleep 9" > /etc/initramfs-tools/scripts/init-premount/delay_for_raid
chmod a+x /etc/initramfs-tools/scripts/init-premount/delay_for_raid

# fix growpart for raid
#wget http://KICK_HOST/misc/growroot -O /usr/share/initramfs-tools/scripts/local-bottom/growroot
#chmod a+x /usr/share/initramfs-tools/scripts/local-bottom/growroot
#wget http://KICK_HOST/misc/growpart -O /usr/bin/growpart
#chmod a+x /usr/bin/growpart

# another teeth specific
echo "bonding" >> /etc/modules
echo "8021q" >> /etc/modules
cat > /etc/modprobe.d/blacklist-mei.conf <<'EOF'
blacklist mei_me
EOF
update-initramfs -u -k all

# more teeth console changes
cat >> /etc/inittab <<'EOF'
T0:23:respawn:/sbin/getty -L ttyS0 115200 xterm
T4:23:respawn:/sbin/getty -L ttyS4 115200 xterm
EOF

# fsck no autorun on reboot
sed -i 's/#FSCKFIX=no/FSCKFIX=yes/g' /etc/default/rcS

# cloud-init doesn't generate a ssh_host_ed25519_key
cat > /etc/rc.local <<'EOF'
#!/bin/bash
dpkg-reconfigure openssh-server
echo '#!/bin/bash' > /etc/rc.local
echo 'exit 0' >> /etc/rc.local
EOF

# log packages
wget http://KICK_HOST/kickstarts/package_postback.sh
bash package_postback.sh Debian_Unstable_Teeth

# clean up
passwd -d root
passwd -l root
apt-get -y clean
apt-get -y autoremove
rm -f /etc/ssh/ssh_host_*
rm -f /var/cache/apt/archives/*.deb
rm -f /var/cache/apt/*cache.bin
rm -f /var/lib/apt/lists/*_Packages
echo "" > /etc/resolv.conf
rm -f /root/.bash_history
rm -f /root/.nano_history
rm -f /root/.lesshst
rm -f /root/.ssh/known_hosts
for k in $(find /var/log -type f); do echo > $k; done
for k in $(find /tmp -type f); do rm -f $k; done
