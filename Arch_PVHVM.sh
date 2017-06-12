IMGDIR=$1
if [ -z "$IMGDIR" ]; then
    echo "ERROR: usage is $0 <target_directory>"
    exit 1
fi

LABEL=Arch_PVHVM
IMGDIR=${IMGDIR}/$LABEL
[ ! -d $IMGDIR ] && mkdir -p $IMGDIR

[ -f $IMGDIR/image.img ] && rm -f $IMGDIR/image.raw
dd if=/dev/zero of=$IMGDIR/image.raw bs=1M count=2048
losetup /dev/loop0 $IMGDIR/image.raw
if [ $? -gt 0 ]; then
   echo "Error setting up loopback device.  Exiting!"
   exit 1
fi

# partition and filesystem bits
parted -s /dev/loop0 mklabel msdos
parted -s --align=none /dev/loop0 mkpart primary 2048s 100%
parted /dev/loop0 set 1 boot on
mkfs.ext4 -L / /dev/loop0p1

[ ! -d /mnt/arch ] && mkdir /mnt/arch
mount /dev/loop0p1 /mnt/arch
if [ $? -gt 0 ]; then
   echo "ERROR: mount on /mnt/arch failed.  Exiting!"
   exit 1
fi

latest_bootstrap=$(curl -s http://mirror.rackspace.com/archlinux/iso/latest/ | grep -oE 'href="archlinux-bootstrap-.+?-x86_64.tar.gz"' | grep -oE '".+"' | tr -d /\"/)
wget -N http://mirror.rackspace.com/archlinux/iso/latest/$latest_bootstrap
tar xfCz archlinux-bootstrap-*.tar.gz /mnt/arch --strip-components=1
rm -f /mnt/arch/README
cp -f /etc/resolv.conf /mnt/arch/etc/resolv.conf
echo 'Server = http://mirror.rackspace.com/archlinux/$repo/os/$arch' > /mnt/arch/etc/pacman.d/mirrorlist

# chroot into install
echo "Chroot into new system"
mount -t proc none /mnt/arch/proc
mount --rbind /sys /mnt/arch/sys
mount --rbind /dev /mnt/arch/dev
mount --rbind /run /mnt/arch/run
wget http://KICK_HOST/kickstarts/Arch_PVHVM-2.sh -O /mnt/arch/Arch_PVHVM-2.sh
chmod +x /mnt/arch/Arch_PVHVM-2.sh
chroot /mnt/arch /bin/bash -c "/Arch_PVHVM-2.sh"

grub-install --verbose -s -d /mnt/arch/usr/lib/grub/i386-pc/ --modules part_msdos --boot-directory /mnt/arch/boot /dev/loop0

rm -f /mnt/arch/Arch_PVHVM-2.sh
rm -f archlinux-bootstrap-*.tar.gz

cd
umount -l /mnt/arch/dev{/shm,/pts,}
umount -l /mnt/arch{/proc,/run,/sys}
fuser -k /mnt/arch
umount -l /mnt/arch
losetup -d /dev/loop0
