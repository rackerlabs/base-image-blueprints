#!/bin/bash
# fix bootable flag
parted -s /dev/sda set 1 boot on
e2label /dev/sda1 root

# update
apt-get update
apt-get -y --force-yes dist-upgrade

# custom cloud-init
#wget https://be3c4d5274cd5307ce4a-fa55afd7e9be71a29fceec8b7b5e23fe.ssl.cf2.rackcdn.com/cloud-init_0.7.5-1rackspace5_all.deb
wget http://10.69.246.205/cloud-init/cloud-init_0.7.7_upstart.deb
dpkg -i *.deb
apt-mark hold cloud-init

pip install --upgrade six

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
EOF

# cloud-init kludges
addgroup --system --quiet netdev
echo -n > /etc/udev/rules.d/70-persistent-net.rules
echo -n > /lib/udev/rules.d/75-persistent-net-generator.rules

# cloud-init must be beaten with hammer
# preseeding these values isnt working, forcing it here
#echo "cloud-init cloud-init/datasources multiselect ConfigDrive" > /tmp/tmp/debconf-selections
#/usr/bin/debconf-set-selections /tmp/tmp/debconf-selections
#dpkg-reconfigure cloud-init

# both the above and preseed values quit working :(
#cat > /etc/cloud/cloud.cfg.d/90_dpkg.cfg <<'EOF'
# to update this file, run dpkg-reconfigure cloud-init
#datasource_list: [ ConfigDrive ]
#EOF
# change this if cloud-init version is ever 7.5+
# to one below

cat > /etc/cloud/cloud.cfg.d/90_dpkg.cfg <<'EOF'
# to update this file, run dpkg-reconfigure cloud-init
datasource_list: [ ConfigDrive, None ]
EOF

# minimal network conf that doesnt dhcp
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

# our fstab is fonky
cat > /etc/fstab <<'EOF'
# /etc/fstab: static file system information.
#
# Use 'blkid' to print the universally unique identifier for a
# device; this may be used with UUID= as a more robust way to name devices
# that works even if disks are added and removed. See fstab(5).
#
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
LABEL=root	/               ext4    errors=remount-ro 0       1
EOF

# set ssh keys to regenerate at first boot if missing
# this is a fallback to catch when cloud-init fails doing the same
# it will do nothing if the keys already exist
#cat > /etc/rc.local <<'EOF'
#dpkg-reconfigure openssh-server
#echo > /etc/rc.local
#EOF

#remove mdadm.conf
rm -rf /etc/mdadm/mdadm.conf

# another teeth specific
echo "8021q" >> /etc/modules
echo "bonding" >> /etc/modules
cat > /etc/modprobe.d/blacklist-mei.conf <<'EOF'
blacklist mei_me
blacklist mei
EOF

#sed -i 's/start on.*/start on net-device-added and filesystem/g' /etc/init/network-interface.conf
sed -i 's/start on.*/start on net-device-added INTERFACE=bond0/g' /etc/init/cloud-init-local.conf

# keep grub2 from using UUIDs and regenerate config
sed -i 's/#GRUB_DISABLE_LINUX_UUID.*/GRUB_DISABLE_LINUX_UUID="true"/g' /etc/default/grub
sed -i 's/#GRUB_TERMINAL=console/GRUB_TERMINAL=/g' /etc/default/grub
#sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT.*/GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS4,115200n8 cgroup_enable=memory swapaccount=1"/g' /etc/default/grub
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT.*/GRUB_CMDLINE_LINUX_DEFAULT="cgroup_enable=memory swapaccount=1"/g' /etc/default/grub
sed -i 's/GRUB_TIMEOUT.*/GRUB_TIMEOUT=0/g' /etc/default/grub
#echo 'GRUB_SERIAL_COMMAND="serial --unit=0 --speed=115200n8 --word=8 --parity=no --stop=1"' >> /etc/default/grub
#echo 'GRUB_PRELOAD_MODULES="8021q bonding"' >> /etc/default/grub
echo "GRUB_DEVICE_LABEL=root" >> /etc/default/grub

# setup a usable console
cat > /etc/init/ttyS0.conf <<'EOF'
# ttyS0 - getty
#
# This service maintains a getty on ttyS0 from the point the system is
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
# This service maintains a getty on ttyS4 from the point the system is
# started until it is shut down again.

start on stopped rc RUNLEVEL=[2345]
stop on runlevel [!2345]

respawn
exec /sbin/getty -L 115200 ttyS4 xterm
EOF

cat > /etc/apt/apt.conf.d/00InstallRecommends <<'EOF'
APT::Install-Recommends "true";
EOF

# fsck no autorun on reboot
sed -i 's/FSCKFIX=no/FSCKFIX=yes/g' /etc/default/rcS

# add support for Intel RSTe

#md raid rules
cat > /lib/udev/rules.d/64-md-raid.rules <<'EOF'
# do not edit this file, it will be overwritten on update

SUBSYSTEM!="block", GOTO="md_end"

# handle potential components of arrays (the ones supported by md)
IMPORT{cmdline}="nomdmonisw"
IMPORT{cmdline}="nomdmonddf"
ENV{nomdmonisw}=="1", ENV{ID_FS_TYPE}=="isw_raid_member", GOTO="md_inc_skip"
ENV{nomdmonddf}=="1", ENV{ID_FS_TYPE}=="ddf_raid_member", GOTO="md_inc_skip"
ENV{ID_FS_TYPE}=="ddf_raid_member|isw_raid_member|linux_raid_member", GOTO="md_inc"
GOTO="md_inc_skip"

LABEL="md_inc"

# remember you can limit what gets auto/incrementally assembled by
# mdadm.conf(5)'s 'AUTO' and selectively whitelist using 'ARRAY'
ACTION=="add", RUN+="/sbin/mdadm --incremental $tempnode"
ACTION=="remove", ENV{ID_PATH}=="?*", RUN+="/sbin/mdadm -If $name --path $env{ID_PATH}"
ACTION=="remove", ENV{ID_PATH}!="?*", RUN+="/sbin/mdadm -If $name"

LABEL="md_inc_skip"

# handle md arrays
ACTION!="add|change", GOTO="md_end"
KERNEL!="md*", GOTO="md_end"

# partitions have no md/{array_state,metadata_version}, but should not
# for that reason be ignored.
ENV{DEVTYPE}=="partition", GOTO="md_ignore_state"

# container devices have a metadata version of e.g. 'external:ddf' and
# never leave state 'inactive'
ATTR{md/metadata_version}=="external:[A-Za-z]*", ATTR{md/array_state}=="inactive", GOTO="md_ignore_state"
TEST!="md/array_state", GOTO="md_end"
ATTR{md/array_state}=="|clear|inactive", GOTO="md_end"
LABEL="md_ignore_state"

IMPORT{program}="/sbin/mdadm --detail --export $tempnode"
ENV{DEVTYPE}=="disk", ENV{MD_NAME}=="?*", SYMLINK+="disk/by-id/md-name-$env{MD_NAME}", OPTIONS+="string_escape=replace"
ENV{DEVTYPE}=="disk", ENV{MD_UUID}=="?*", SYMLINK+="disk/by-id/md-uuid-$env{MD_UUID}"
ENV{DEVTYPE}=="disk", ENV{MD_DEVNAME}=="?*", SYMLINK+="md/$env{MD_DEVNAME}"
ENV{DEVTYPE}=="partition", ENV{MD_NAME}=="?*", SYMLINK+="disk/by-id/md-name-$env{MD_NAME}-part%n", OPTIONS+="string_escape=replace"
ENV{DEVTYPE}=="partition", ENV{MD_UUID}=="?*", SYMLINK+="disk/by-id/md-uuid-$env{MD_UUID}-part%n"
ENV{DEVTYPE}=="partition", ENV{MD_DEVNAME}=="*[^0-9]", SYMLINK+="md/$env{MD_DEVNAME}%n"
ENV{DEVTYPE}=="partition", ENV{MD_DEVNAME}=="*[0-9]", SYMLINK+="md/$env{MD_DEVNAME}p%n"

IMPORT{program}="/sbin/blkid -o udev -p $tempnode"
OPTIONS+="link_priority=100"
OPTIONS+="watch"
ENV{ID_FS_USAGE}=="filesystem|other|crypto", ENV{ID_FS_UUID_ENC}=="?*", SYMLINK+="disk/by-uuid/$env{ID_FS_UUID_ENC}"
ENV{ID_FS_USAGE}=="filesystem|other", ENV{ID_FS_LABEL_ENC}=="?*", SYMLINK+="disk/by-label/$env{ID_FS_LABEL_ENC}"

LABEL="md_end"
EOF

cat > /usr/share/initramfs-tools/scripts/mdadm-functions <<'EOF'
#!/bin/sh

txt_message ()
{
        if [ -x /bin/plymouth ] && plymouth --ping; then
        return 0
        else
                echo "$@" >&2
        fi
        return 0
}

message()
{
        if [ -x /bin/plymouth ] && plymouth --ping; then
                plymouth message --text="$@"
        else
                echo "$@" >&2
        fi
        return 0
}


mountroot_fail()
{
    message "Incrementally starting RAID arrays..."
    if mdadm --incremental --run --scan; then
    message "Incrementally started RAID arrays."
    return 0
    else    
    if mdadm --assemble --scan --run; then
        message "Assembled and started RAID arrays."
        return 0
    else
        message "Could not start RAID arrays in degraded mode."
    fi
    fi
    return 1
}
EOF

cat > /usr/share/initfamfs-tools/scripts/init-premount/mdadm <<'EOF'
#!/bin/sh

# init-premount script for mdadm.

PREREQS="udev"

prereqs()
{
    echo $PREREQS
}

[ "$1" = "prereqs" ] || . /scripts/mdadm-functions

case $1 in
# get pre-requisites
prereqs)
    prereqs
    exit 0
    ;;
mountfail)
    mountroot_fail
    exit $?
    ;;
esac

. /scripts/functions

add_mountroot_fail_hook "10-mdadm"

exit 0
EOF

sed -i 's#copy_exec#copy_exec /sbin/mdmon /sbin\ncopy_exec#g' /usr/share/initramfs-hooks/mdadm
sed -i 's/BOOT_DEGRADED=false/BOOT_DEGRADED=true/g' /etc/initramfs-tools/conf.d/mdadm
rm -rf /usr/share/initramfs-tools/scripts/local-premount/mdadm

update-initramfs -u -k all
update-grub

# log packages
wget http://10.69.246.205/kickstarts/package_postback.sh
bash package_postback.sh Ubuntu_12.04_Teeth

# clean up
passwd -d root
passwd -l root
apt-get -y clean
#apt-get -y autoremove
sed -i '/.*cdrom.*/d' /etc/apt/sources.list
rm -f /etc/ssh/ssh_host_*
rm -f /var/cache/apt/archives/*.deb
rm -f /var/cache/apt/*cache.bin
rm -f /var/lib/apt/lists/*_Packages
# breaks newest nova-agent if removed
#rm -f /etc/resolv.conf
# this file copies the installer's /etc/network/interfaces to the VM
# but we want to overwrite that with a "clean" file instead
# so we must disable that copying action in kickstart/preseed
rm -f /usr/lib/finish-install.d/55netcfg-copy-config
rm -f /root/.bash_history
rm -f /root/.nano_history
rm -f /root/.lesshst
rm -f /root/.ssh/known_hosts
rm -rf /tmp/tmp
for k in $(find /var/log -type f); do echo > $k; done
for k in $(find /tmp -type f); do rm -f $k; done
for k in $(find /root -type f \( ! -iname ".*" \)); do rm -f $k; done
