#! /usr/bin/env bash

set -e

user_password=123

swap_amount=64G

use_amd='1' # amd video drivers, leave empty for `no`
use_nvidia='' # nvidia video drivers, leave empty for `no`
use_intel='' # intel video drivers, leave empty for `no`

install_ucode_amd='1' # amd cpu ucode, leave empty for `no`
install_ucode_intel='' # intel cpu ucode, leave empty for `no`

minimal_install='1' # minimal install, used for debugging, leave empty for `no`

use_grub='' # leave empty for `no`
# does not work with mdadm raid0

# you want the `arch-install-scripts` package installed

# resources
#
# raid0 mdadm
# https://www.golinuxcloud.com/configure-software-raid-0-array-linux/
# https://blog.bjdean.id.au/2020/10/md-software-raid-and-lvm-logical-volume-management/#pvcreate
# (most important, almost solved my problem singlehandedly) https://www.serveradminz.com/blog/installation-of-arch-linux-using-software-raid/

DISTRO_NAME=SEXlinux$RANDOM

BOOT_PARTITION_SIZE=512MiB

SWAP_FILE=/swapfile$RANDOM

INSTALL_LOG_FILE=/install-error-log

HERE=$(dirname -- "$BASH_SOURCE")

on_exit(){
	ret_code="$?"

	log "install finished, return code is $ret_code; syncing..."
	sync
	log "synced"
	sync

	test $ret_code != 0 && {

		echo "press ctrl+c to not clear disks"
		read tmp

		umount /mnt/boot/efi || true
		umount /mnt/boot || true
		umount /mnt || true

		test "$lvm_group" != "" && {
			# deal with LVM
			vgremove --force myVolGr $lvm_group || true
		}

		test "$mdadm_device" != "" && {
			# deal with mdadm
			mdadm --stop $mdadm_device || true
			mdadm --zero-superblock $data_partitions || true
		}

	}

	umount /mnt/boot/efi || true
	umount /mnt/boot || true
	umount /mnt || true

	echo "Check \`$INSTALL_LOG_FILE\` for the install logs"

	exit ${ret_code}
}

trap on_exit EXIT

########## generic fncs

chroot_run(){
	arch-chroot /mnt "$@"
}

pkg_install(){
	chroot_run pacman --noconfirm -S --needed "$@"
}

aur_install(){
	# TODO this asks for passwd when running as non-root
	(cat << EOF
set -e
set -o xtrace
su me -c bash
set -e
set -o xtrace
echo "$user_password" | sudo -S echo gaysex
#echo "$user_password" | sudo -S -v
paru --sudoloop --noconfirm -S --needed $@
#echo "$user_password" | paru --sudoloop --noconfirm -S --needed $@
EOF
	) | chroot_run bash || {
		log "failed to install AUR package(s) \`$@\`"
	}
}

log(){
	echo "$@" | chroot_run tee -a "$INSTALL_LOG_FILE" || {
		echo "ERROR: could not log message"
	}
}

########## not so generic fncs

get_block_device(){
	prompt="$1"
	allow_none="$2"
	already_used_block_devices="$3"

	# TODO using a hack that prints to stderr

	while true; do

		>&2 echo
		>&2 lsblk
		>&2 echo

		>&2 printf "$prompt"

		test "$allow_none" == "1" && {
			>&2 printf " (leave empty for none)"
		}

		>&2 printf "\n> "

		read block_device

		if [ "$block_device" == "" ]; then
			test "$allow_none" == "1" && {
				return
			}
			>&2 echo 'invalid input: empty line'
			continue
		fi

		# check of block device exists
		test -b ${block_device} || {
			>&2 echo "invalid input: block device doesn't exist: \`$block_device\`"
			>&2 echo 'press enter'
			read tmp
			continue
		}

		# check if device already used
		if [[ "$already_used_block_devices" == *" $block_device "* ]]; then
			>&2 echo "invalid input: device already used: \`$block_device\`"
			>&2 echo 'press enter'
			read tmp
			continue
		fi

		echo "$block_device"
		return

	done
}

########## file editing

edit_mkinitcpio(){
	# dependencies
	pkg_install python3

	# chroot_run micro /etc/mkinitcpio.conf
	# # find "HOOKS="
	# # before "filesystem" insert "encrypt lvm2"
	# # (`encrypt` doesn't isn't needed in this case since we're not using encryption, but let's keep it here for good measure)

	(cat << EOF
import re
import sys

HOOKS_NEW = ' lvm2 mdadm_udev filesystems '

BINARIES_ORIGINAL = '\nBINARIES=()\n'
BINARIES_NEW = '\nBINARIES=(/sbin/mdmon)\n'

with open('/etc/mkinitcpio.conf', 'r') as f:
	cont = f.read()
found = re.search('\nHOOKS=\(.*\)\n', cont)
assert found != None, 'hooks line not found'
hooks = cont[found.start():found.end()]

match hooks.count(HOOKS_NEW):
	case 0:
		pass
	case 1:
		print('hooks already set up, exiting')
		sys.exit()
	case other:
		assert False, f'bad count ({other})'

count = hooks.count(' filesystems ')
assert count == 1, f'invalid number of "filesystems" found in hooks, {count=} {hooks=}'
hooks = hooks.replace(' filesystems ', HOOKS_NEW)
cont = cont[:found.start()] + hooks + cont[found.end():]

# add mdadm to binaries

count = cont.count(BINARIES_ORIGINAL)
assert count == 1, f'string "{BINARIES_ORIGINAL}" found {count} times (should have been 1)'
cont = cont.replace(BINARIES_ORIGINAL, BINARIES_NEW)

# save changes

with open('/etc/mkinitcpio.conf', 'w') as f:
	f.write(cont)

sys.exit()
EOF
	 ) | chroot_run python3
}

fix_pacman_config(){
	# enable 32 bit repo
	chroot_run sed -i -z 's%\n#\[multilib\]\n#Include = /etc/pacman.d/mirrorlist\n%\n\[multilib\]\nInclude = /etc/pacman.d/mirrorlist\n%' /etc/pacman.conf
    chroot_run pacman -Syuu
	# add color
	chroot_run sed -i -z 's%\n#Color\n%\nColor\n%' /etc/pacman.conf
	# verbose packages
	chroot_run sed -i -z 's%\n#VerbosePkgLists\n%\nVerbosePkgLists\n%' /etc/pacman.conf
	# parallel download
	chroot_run sed -i -z 's%\n#ParallelDownloads = 5\n%\nParallelDownloads = 5\n%' /etc/pacman.conf
}

set_up_aur_helper(){
	# needs to be called after the user has been created

	pkg_install base-devel
	# compilation threads (related to the AUR helper)
	chroot_run sed -i -z 's%\n#MAKEFLAGS="-j2"\n%\nMAKEFLAGS="-j$(nproc)"\n%' /etc/makepkg.conf
		# we need `base-devel` installed, otherwise the config file will not be created

	pkg_install git
	# install paru if not already installed
	(cat << EOF
set -e
paru --version && exit
cd /tmp
su me -c bash
git clone https://aur.archlinux.org/paru-bin.git
cd ./paru-bin
makepkg
exit
cd ./paru-bin
pacman --noconfirm -U paru-*.pkg.tar.zst
EOF
	 ) | chroot_run bash
	# paru settings
	chroot_run sed -i -z 's%\n#BottomUp\n%\nBottomUp\n%' /etc/paru.conf
}

config_visudo(){
	pkg_install sudo
		# this installs the `visudo` command

	chroot_run bash -c "echo -e '\n%wheel ALL=(ALL:ALL) ALL\n' | EDITOR='tee -a' visudo"
	# this is gay but it works

	# we could also try using `/etc/sudoers.d` (it's the very last line in the `visudo` file)
}

########## main

# check fi root

if [ "$EUID" -ne 0 ]; then
  echo "ERROR: you need to run this as root"
  exit 1
fi

# LVM JBOD or LVM RAID0 or mdadm RAID0

lvcreate_striped_flags=''
use_lvm=0
use_mdadm=0

printf 'Leave line empty for `raid0`, otherwise `jbod` will be selected\n> '
read use_jbod
if [ "$use_jbod" != "" ]; then # jbod
	use_lvm=1
	use_mdadm=0
else # raid0
	printf 'Select raid0 provider: leave line empty for `mdadm`, otherwise `lvm` will be selected (size will be limited by smallest disk but expansion might be easier)\n> '
	read use_raid0_lvm
	if [ "${use_raid0_lvm}" != "" ]; then # striped lvm
		use_lvm=1
		use_mdadm=0
		printf "Select stripe number (you might want to set the number of disks you intend to use here): \n> "
		read stripe_number
		lvcreate_striped_flags="${lvcreate_striped_flags}-i${stripe_number}"
	else # mdadm
		use_lvm=0
		use_mdadm=1
	fi
fi

data_part_type=''
if [ $use_lvm == 1 ]; then # lvm
	data_part_type=lvm
else # mdadm
	data_part_type=raid
fi

# select disks

number_of_disks=1

boot_disk=$(get_block_device 'Enter boot disk (example: /dev/sda)' 0 '')

# let user select additional disks
additional_disks=""
while true; do
	disk=$(get_block_device 'Enter additional disks (example: /dev/sdb)' 1 "$boot_disk $additional_disks")
	test -z "${disk}" && break

	additional_disks="${additional_disks} ${disk}"
	let 'number_of_disks+=1'
done

# enable debug output from now on
set -o xtrace
# you can disable this with `set +o xtrace`

# format boot disk
parted -s ${boot_disk} mklabel gpt

parted -s ${boot_disk} mkpart primary fat32 0% $BOOT_PARTITION_SIZE
parted -s ${boot_disk} set 1 esp on

parted -s ${boot_disk} mkpart primary ext4 $BOOT_PARTITION_SIZE 100%
parted -s ${boot_disk} set 2 $data_part_type on

# format other disks
for disk in ${additional_disks}; do
	parted -s ${disk} mklabel gpt
	parted -s ${disk} mkpart primary ext4 0% 100%
	parted -s ${disk} set 1 $data_part_type on
done

boot_partition=${boot_disk}1
# TODO if use is using SSD this will be `}p1` and not just `}1`
# same goes for the line on the bottom

export data_partitions=${boot_disk}2
for disk in ${additional_disks}; do
	export data_partitions="${data_partitions} ${disk}1"
done

# format boot part
mkfs.fat -F32 ${boot_partition}

if [ $use_lvm == 1 ]; then

	export lvm_group=myVolGr$RANDOM

	# activate
	for part in ${data_partitions}; do
		pvcreate ${part}
	done

	vgcreate $lvm_group ${data_partitions}

	# create logical volume
	lvcreate --yes -l 100%FREE $lvm_group -n myRootVol ${lvcreate_striped_flags}

	# format
	mkfs.ext4 -F /dev/mapper/${lvm_group}-myRootVol
		# `-F` so that there are no confirmation prompts from the user

	mount /dev/mapper/${lvm_group}-myRootVol /mnt

else # mdadm

	export mdadm_device=/dev/md0

	mdadm -Cv -R $mdadm_device -l0 -n$number_of_disks $data_partitions
		# `-R` supresses confirmation prompt

	parted -s $mdadm_device mklabel gpt

	parted -s $mdadm_device mkpart primary ext4 0% 100%
	mkfs.ext4 -F ${mdadm_device}p1 # `-F` so that there are no confirmation prompts from the user

	mount ${mdadm_device}p1 /mnt

fi

if [ "$use_grub" != "" ]; then # grub
	mkdir -p /mnt/boot/efi
	mount ${boot_partition} /mnt/boot/efi
else # systemd-boot
	# systemd-boot requires you to mount the f32 part in `/boot`
	mkdir -p /mnt/boot
	mount ${boot_partition} /mnt/boot
fi

mkdir /mnt/etc

genfstab -U -p /mnt >> /mnt/etc/fstab
# if [ "$use_mdadm" != "" ]; then
# 	# TODO this should be automated
# 	pacman -S --needed micro
# 	micro /mnt/etc/fstab
# fi

pacstrap /mnt base

log "starting installation"

fix_pacman_config

pkg_install linux-zen linux-zen-headers linux-firmware micro base-devel networkmanager dialog
pkg_install lvm2 # needed only for lvm
pkg_install mdadm # needed only for mdadm

# swap
(cat << EOF
set -e
set -o xtrace
fallocate -l $swap_amount $SWAP_FILE
chmod 0600 $SWAP_FILE
mkswap -U clear $SWAP_FILE
swapon $SWAP_FILE
swapoff $SWAP_FILE
echo -e '\n$SWAP_FILE none swap defaults 0 0' >> /etc/fstab
EOF
) | chroot_run bash

chroot_run systemctl enable NetworkManager
# also install some wifi tools
pkg_install wpa_supplicant wireless_tools netctl

if [ "$use_mdadm" == "1" ]; then
	mdadm --detail --scan --verbose >> /mnt/etc/mdadm.conf
fi

edit_mkinitcpio
chroot_run mkinitcpio -p linux-zen

(cat << EOF
set -e

echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen
locale-gen

echo 'LANG=en_US.UTF-8' > /etc/locale.conf
EOF
) | chroot_run bash

echo "root:${user_password}" | chroot_run chpasswd

chroot_run useradd -m -g users -G wheel me
echo "me:${user_password}" | chroot_run chpasswd
	# TODO this fails with error `user not known to the underlying authentication module`

config_visudo

set_up_aur_helper

chroot_run ln -sf /usr/share/zoneinfo/Europe/Sofia /etc/localtime

chroot_run hwclock --systohc

(cat << EOF
set -e
echo 'navi' > /etc/hostname
	# TODO ask user
echo '127.0.0.1 localhost' > /etc/hosts
echo '::1 localhost' >> /etc/hosts
echo '127.0.1.1 navi.localdomain navi' >> /etc/hosts
# use static instead of 127.0.0.1
EOF
) | chroot_run bash

# cpu ucode
if [ "$install_ucode_amd" != "" ]; then
	pkg_install amd-ucode
fi
if [ "$install_ucode_intel" != "" ]; then
	pkg_install intel-ucode
fi

##### bootloader

pkg_install efibootmgr dosfstools os-prober mtools openssh
# os-prober -> if multiple OS-es

if [ "$use_grub" != "" ]; then # use grub
	pkg_install grub

	# seems like all of this is needed only if u use encryption
		#micro /etc/default/grub
		# change GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet"
		#
		# to GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 cryptdevice=/dev/sda2:myVolGr:allow-discards"
		# to GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 cryptdevice=/dev/sdb2:myVolGr:allow-discards"
		#
		# uncomment "#GRUB_ENABLE_CRYPTODISK=y"

	#aur_install downgrade
	#chroot_run downgrade --version # make sure it's installed
	#chroot_run downgrade --ala-only --ignore always grub=2:2.06.r456.g65bc45963-1

	# install grub
	chroot_run grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="$DISTRO_NAME" --recheck
	#chroot_run grub-mkconfig -o /boot/grub/grub.cfg
	# grub settings
	chroot_run sed -i -z 's%\nGRUB_TIMEOUT=5\n%\nGRUB_TIMEOUT=1\n%' /etc/default/grub
	# TODO make `quiet` into `noquiet`
		# sudo_replace_string(GRUB_CONF_PATH,# TODO fix if not the first item
		#     '\nGRUB_CMDLINE_LINUX_DEFAULT="quiet ',
		#     '\nGRUB_CMDLINE_LINUX_DEFAULT="noquiet ')
	# update-grub
	chroot_run grub-mkconfig -o /boot/grub/grub.cfg

else # use systemd-boot

	chroot_run bootctl --path=/boot/ install

	chroot_run bash -c 'echo timeout 8 > /boot/loader/loader.conf'

	# systemd_boot_distro_config_file=/boot/loader/entries/SEXlinux.conf

	# chroot_run bash -c "echo title SEXlinux > $systemd_boot_distro_config_file"
	# chroot_run bash -c "echo linux /vmlinuz-linux-zen >> $systemd_boot_distro_config_file"

	# test "$install_ucode_amd" != "" && chroot_run bash -c "echo initrd /amd-ucode.img >> $systemd_boot_distro_config_file"
	# test "$install_ucode_intel" != "" && chroot_run bash -c "echo initrd /intel-ucode.img >> $systemd_boot_distro_config_file"

	# chroot_run bash -c "echo initrd /initramfs-linux-zen.img >> $systemd_boot_distro_config_file"

	# if both are on, something went wrong
	# test "$lvm_group" != "" && chroot_run bash -c "echo options root=/dev/mapper/${lvm_group}-myRootVol rw >> $systemd_boot_distro_config_file"
	# test "$mdadm_device" != "" && chroot_run bash -c "echo options root=$mdadm_device rw >> $systemd_boot_distro_config_file"

	cat << EOF > /mnt/boot/loader/entries/SEXlinux-zen.conf
title SEXlinux (linux-zen)
linux /vmlinuz-linux-zen
$(test "$install_ucode_amd" != "" && echo initrd /amd-ucode.img)
$(test "$install_ucode_intel" != "" && echo initrd /intel-ucode.img)
initrd /initramfs-linux-zen.img
$(test "$lvm_group" != "" && echo options root=/dev/mapper/${lvm_group}-myRootVol rw)
$(test "$mdadm_device" != "" && echo options root=${mdadm_device}p1 rw)
EOF

fi

if [ "$minimal_install" != "" ]; then
	exit 0
fi

# display server
pkg_install xorg-server

# `xclip` for `micro`
pkg_install xclip

# terminal
pkg_install xfce4-terminal

# shell
pkg_install fish
# TODo we can probably replace this vvvv with a regular `bash -c`
# (cat << EOF
# chsh -s \$(which fish) me
# exit
# EOF
# ) | chroot_run bash
chroot_run bash -c 'chsh -s $(which fish) me'

# fonts
pkg_install noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra

# TODO
# # ssh stuff
# pkg_install('openssh') # TODO? check for alternative
# if not (os.path.isfile(os.path.expanduser('~/.ssh/id_rsa')) and os.path.isfile(os.path.expanduser('~/.ssh/id_rsa.pub'))):
# 	term(['ssh-keygen', '-f', os.path.expanduser('~/.ssh/id_rsa'), '-N', ''])
# with open(os.path.expanduser('~/.ssh/config'), 'a') as f:
# 	f.write('\nForwardX11 yes\n')

# git
pkg_install git
pkg_install git-delta
# https://dandavison.github.io/delta/get-started.html
chroot_run git config --global core.pager delta
chroot_run git config --global interactive.diffFilter delta --color-only
chroot_run git config --global delta.navigate true
chroot_run git config --global merge.conflictstyle diff3
chroot_run git config --global diff.colorMoved default

# video drivers

if [ "$use_amd" != "" ]; then
	pkg_install lib32-mesa vulkan-radeon lib32-vulkan-radeon vulkan-icd-loader lib32-vulkan-icd-loader
fi

if [ "$use_nvidia" != "" ]; then
	pkg_install nvidia-dkms nvidia-utils lib32-nvidia-utils nvidia-settings vulkan-icd-loader lib32-vulkan-icd-loader
fi

if [ "$use_intel" != "" ]; then
	pkg_install lib32-mesa vulkan-intel lib32-vulkan-intel vulkan-icd-loader lib32-vulkan-icd-loader
fi

# wine
pkg_install wine-staging giflib lib32-giflib libpng lib32-libpng libldap lib32-libldap gnutls lib32-gnutls mpg123 lib32-mpg123 openal lib32-openal v4l-utils lib32-v4l-utils libpulse lib32-libpulse libgpg-error lib32-libgpg-error alsa-plugins lib32-alsa-plugins alsa-lib lib32-alsa-lib libjpeg-turbo lib32-libjpeg-turbo sqlite lib32-sqlite libxcomposite lib32-libxcomposite libxinerama lib32-libgcrypt libgcrypt lib32-libxinerama ncurses lib32-ncurses opencl-icd-loader lib32-opencl-icd-loader libxslt lib32-libxslt libva lib32-libva gtk3 lib32-gtk3 gst-plugins-base-libs lib32-gst-plugins-base-libs vulkan-icd-loader lib32-vulkan-icd-loader

# ok version of java since some apps may require java (ewwww)
pkg_install jre11-openjdk

# audio server
pkg_install pipewire lib32-pipewire wireplumber pipewire-pulse pipewire-jack
chroot_run sudo su me -c 'systemctl --user enable pipewire.service'
pkg_install alsa-utils # setting and getting volume programatically
pkg_install pavucontrol # GUI volume control

# DE
pkg_install i3
aur_install xkblayout-state-git # keyboard language switcher
pkg_install python-psutil # needed to determine weather laptop or not
pkg_install python-i3ipc
pkg_install dex # autostart
pkg_install network-manager-applet
pkg_install rofi # menu
pkg_install spectacle # screenshooter
pkg_install mate-polkit # polkit
pkg_install pacman-contrib # needed for `checkupdates`

##### terminal utilities

pkg_install sysstat # utilities for system stats
#aur_install bootiso # safer dd alternative
pkg_install fd # find alternative
pkg_install bat # cat alternative
#pkg_install bottom # system monitor
pkg_install tldr # man alternative
pkg_install duf # better du
#pkg_install lsd # better ls
pkg_install poppler # pdf combiner
pkg_install pdftk bcprov java-commons-lang # pdf cutter
aur_install pirate-get-git # torrent browser
pkg_install yt-dlp # video downloader
pkg_install htop # system monitor
#pkg_install w3m # web browser
#aur_install minq-xvideos-git # xvideos browser
#aur_install minq-nhentai-git python-minq-caching-thing-git # nhentai browser
pkg_install trash-cli # trash manager
#pkg_install streamlink # enables watching streams (examples: yt, twitch)
aur_install ani-cli-git # anime watcher
pkg_install imagemagick # image converter
aur_install timeshift-bin # backup
pkg_install man

##### additional programs

aur_install mangohud lib32-mangohud # gayming overlay
#aur_install freezer-appimage # music # commented out due to slow download
aur_install nuclear-player-bin # music
#aur_install mcomix-git # .cbr file reader (manga) (Junji Ito)
pkg_install gnome-disk-utility
	pkg_install ntfs-3g # allows for formatting to ntfs
pkg_install baobab # disk usage analyzer
pkg_install gparted
pkg_install transmission-gtk # torrent
	# qbittorrent causes PC to lag, also has a weird bug where it refuses to download torrents
	# update LVM: qbittorrent's GUI freezes
pkg_install tigervnc # vnc
pkg_install ksysguard # task manager
pkg_install songrec # find a song by sample
pkg_install pluma # text editor
pkg_install code # FOSS vscode # IDE
aur_install rustdesk-bin # remote desktop
pkg_install mpv # video player
# image viewer
	#aur_install nomacs # wtf download is broken
	pkg_install deepin-image-viewer
# browser
	pkg_install firefox # main browser
		pkg_install firefox-i18n-en-us firefox-i18n-bg # spelling
	aur_install thorium-browser-bin # chromium browser (for the sites that require that)
pkg_install obs-studio # screen sharing
# latex editor
	pkg_install gummi # works, but no features
	pkg_install texworks # can navigate from editor to PDF and reverse, but refuses to compile from time to tike
	pkg_install texmaker # best
	pkg_install texlive-lang # non-english support
aur_install flashpoint-launcher-bin # flash games
# voice chat and messaging
	pkg_install mumble
	pkg_install discord

# file manager
pkg_install thunar thunar-archive-plugin gvfs
pkg_install tumbler # thumbnails
	pkg_install ffmpegthumbnailer # video
	pkg_install poppler-glib # pdf
	pkg_install libgsf # odf
	pkg_install libgepub # epub
	pkg_install libopenraw # raw
	pkg_install freetype2 # font
#caja caja-open-terminal
chroot_run xdg-mime default thunar.desktop inode/directory
	# set as default file browser
	# TODO maybe this needs to be executed as the user

# archiver manager
pkg_install xarchiver # gui
pkg_install bzip2 gzip p7zip tar unrar unzip xz zip zstd # some formats

pkg_install steam
pkg_install lib32-libappindicator-gtk2 # makes it so that the taskbar menu follows the system theme; does not always work

# file sync

	pkg_install syncthing
	# TODO
		# if not LAPTOP:
		#     service_start_and_enable(f'syncthing@{USERNAME}')

	pkg_install unison

# power manager
# TODO
    # if LAPTOP:
    #     pkg_force_install('tlp')
    #     sudo_replace_string(TLP_CONF_PATH,
    #         '\n#STOP_CHARGE_TRESH_BAT0=80\n',
    #         '\nSTOP_CHARGE_TRESH_BAT0=1\n',)
    #     service_start_and_enable('tlp')

# vmware
# TODO
	# VMWARE_PREFERENCES_PATH = os.path.expanduser('~/.vmware/preferences')
    # if (not LAPTOP) and INSTALL_VMWARE:
    #     if not os.path.isdir(VMWARE_VMS_PATH):
    #         os.makedirs(VMWARE_VMS_PATH)
    #     if is_btrfs(VMWARE_VMS_PATH):
    #         term(['chattr', '-R', '+C', VMWARE_VMS_PATH])
    #         #term(['chattr', '+C', VMWARE_VMS_PATH])
    #     aur_install('vmware-workstation')
    #     term(['sudo', 'modprobe', '-a', 'vmw_vmci', 'vmmon'])
    #     service_start_and_enable('vmware-networks')
    #     if not os.path.isdir(os.path.dirname(VMWARE_PREFERENCES_PATH)):
    #         os.makedirs(os.path.dirname(VMWARE_PREFERENCES_PATH))
    #     if os.path.isfile(VMWARE_PREFERENCES_PATH): mode = 'w'
    #     else: mode = 'a'
    #     with open(VMWARE_PREFERENCES_PATH, mode) as f: # TODO check if exists first
    #         f.write('\nmks.gl.allowBlacklistedDrivers = "TRUE"\n')

# TODO
    # # unify theme # we could also install adwaita-qt and adwaita-qt6
    #     # themes can be found in `/usr/share/themes` (or at lean on ubuntu)
    #     # docs on xsettings `https://wiki.archlinux.org/title/Xsettingsd`
    # pkg_install('lxappearance-gtk3') # GTK theme control panel

    # aur_install('paper-icon-theme')

# install adwaita for gtk3
pkg_install gtk3
# install adwaita for gtk2
pkg_install gnome-themes-extra
# install adwaita for qt
pkg_install adwaita-qt5 adwaita-qt6
# an alternative is
    # themes can be found in `/usr/share/themes` (or at lean on ubuntu)
    # docs on xsettings `https://wiki.archlinux.org/title/Xsettingsd`
# you can also install theme setter for qt
	# pkg_install qt5ct qt6ct

# TODO set up `sync-config`
# this will also set up the env vars for the dark theme

# VM
pkg_install virtualbox virtualbox-host-dkms
pkg_install virtualbox-guest-iso
	# this is the guest additions disk
	# .iso file is located at `/usr/lib/virtualbox/additions/VBoxGuestAdditions.iso`
chroot_run usermod -a -G vboxusers me
	# allows for accesing USB devices
#chroot_run modprobe vboxdrv
	# no need to activate it right away
	# the user will be restarting the machine anyways

# login manager
pkg_install lightdm lightdm-gtk-greeter
chroot_run sed -i -z 's%\n#autologin-user=\n%\nautologin-user=me\n%' /etc/lightdm/lightdm.conf
chroot_run groupadd -r autologin
chroot_run gpasswd -a me autologin
chroot_run systemctl enable lightdm
