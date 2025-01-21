#!/usr/bin/env bash

set -euxo pipefail

sudo nft flush ruleset
sudo tee /etc/systemd/network/10-router-lan.network <<EOF
[Match]
Name=router-lan

[Network]
DHCP=yes
EOF

sudo systemctl restart systemd-networkd
sudo apt update
sudo apt install -y \
  sudo incus \
  incus-migrate \
  qemu-system

# sg and newgrp require password to run
# https://github.com/actions/runner-images/issues/9932#issuecomment-2145088186
#sudo gpasswd -a "${USER}" incus-admin
#sudo gpasswd -r incus-admin
#newgrp incus-admin
sudo incus admin init --auto

sudo incus profile create router-wan
sudo incus profile edit router-wan <<EOF
config: {}
description: "Router wan network"
devices:
  eth1:
    name: eth1
    network: incusbr0
    type: nic
name: router-wan
used_by: []
project: default
EOF

sudo incus profile create router-lan
sudo incus profile edit router-lan <<EOF
config: {}
description: "Router lan network"
devices:
  eth0:
    host_name: router-lan
    name: eth0
    nictype: p2p
    type: nic
name: router-lan
used_by: []
project: default
EOF

#sudo incus network create lan.openwrt
#sudo incus network edit lan.openwrt <<EOF
#config:
#  ipv4.nat: "false"
#  ipv6.nat: "false"
#description: "Lan network for openwrt"
#name: lan.openwrt
#type: bridge
#used_by: []
#managed: true
#status: Created
#locations:
#- none
#EOF

#sudo incus profile create openwrt-client
#sudo incus profile edit openwrt-client <<EOF
#config: {}
#description: "openwrt lan network for clients"
#devices:
#  eth0:
#    name: eth0
#    network: lan.openwrt
#    type: nic
#name: openwrt-client
#used_by: []
#project: default
#EOF

wget "https://downloads.openwrt.org/snapshots/targets/x86/64/openwrt-x86-64-generic-squashfs-combined-efi.img.gz"
gunzip openwrt-x86-64-generic-squashfs-combined-efi.img.gz || true
sudo incus-migrate <<ANSWERS
yes
2
openwrt
openwrt-x86-64-generic-squashfs-combined-efi.img
yes
no
2
default router-wan router-lan
1
ANSWERS
sudo incus start openwrt
# Function to check for the presence of a value in a command
check_value() {
  local run="${1}"
  local value_to_find="${2}"

  # Infinite loop
  while true; do
    # Check if the value is present
    if "${run}" | grep -q "${value_to_find}"; then
      echo "The value '${value_to_find}' was found!"
      break  # Exit the loop if the value is found
    fi
    # Wait for an interval before checking again
    echo "The value '${value_to_find}' was not found!"
    sleep "10"
  done
}
#check_value "sudo incus info openwrt" "inet:"
while true; do
  # Check if the value is present
  value_to_find1="inet:"
  if sudo incus info openwrt | grep -q "${value_to_find1}"; then
    echo "The value '${value_to_find1}' was found!"
    break  # Exit the loop if the value is found
  fi
  # Wait for an interval before checking again
  echo "The value '${value_to_find1}' was not found!"
  sleep "10"
done
#sudo incus launch images:alpine/3.21 client -p default -p openwrt-client
#check_value "client" "192.168.1.*/24"
#sudo incus exec client -- apk update
#sudo incus exec client -- apk add dropbear-ssh
#sudo incus exec client -- apk add openssh
#sudo incus exec client -- sudo --login --user debian
#sudo incus exec client -- ssh -o StrictHostKeyChecking=no root@192.168.1.1
while true; do
  # Check if the value is present
  value_to_find2="inet 192.168.1.*/24"
  if ip a | grep -q "${value_to_find2}"; then
    echo "The value '${value_to_find2}' was found!"
    break  # Exit the loop if the value is found
  fi
  # Wait for an interval before checking again
  echo "The value '${value_to_find2}' was not found!"
  sleep "10"
done
ssh -o StrictHostKeyChecking=no root@192.168.1.1 <<EOF
ls -la /tmp
EOF
