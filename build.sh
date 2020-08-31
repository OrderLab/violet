#!/usr/bin/env bash
set -e

root_dir=$(cd "$(dirname "${BASH_SOURCE-$0}")"; pwd)
if [ $# -ne 0 ]; then
  dest_dir=$1
else
  dest_dir=$root_dir/workspace
fi

sudo apt-get update
sudo apt-get install -y git gcc python-dev python-pip
pip install --upgrade pip
export PATH=$HOME/.local/bin:$PATH
sudo apt-get install -y repo
cd env
python -m pip install --user .
# clean up old pyopenssl and reinstall 'pyopenssl' to fix "'module ' object has no attribute 'SSL_ST_INIT'" error
sudo rm -rf /usr/lib/python2.7/dist-packages/OpenSSL
sudo rm -rf /usr/lib/python2.7/dist-packages/pyOpenSSL-0.*.egg-info
sudo pip install -U pyopenssl


# Create a Violet workspace
s2e init $dest_dir
cd $dest_dir
source s2e_activate
# Build the core S2E and Violet plugins
s2e build

# This is necessary for guestfish to work
sudo chmod +r /boot/vmlinuz*
# Adding current user to Docker and KVM group
sudo usermod -a -G docker $(whoami)
sudo usermod -a -G kvm $(whoami)
# Re-login for the new group to take effect
sudo su - $(whoami)
# Restart docker
sudo systemctl restart docker

# We've logged out, reactivate the env
cd $dest_dir
source s2e_activate

# Now try building the image
s2e image_build debian-9.2.1-x86_64
