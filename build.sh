#!/usr/bin/env bash
set -e

sudo apt-get update
sudo apt-get install -y git gcc python-dev python-pip
pip install --upgrade pip
export PATH=$HOME/.local/bin:$PATH
sudo apt-get install -y repo
root_dir=$(cd "$(dirname "${BASH_SOURCE-$0}")"; pwd)
cd env
python -m pip install --user .
if [ $# -ne 0 ]; then
  dest_dir=$1
else
  dest_dir=$root_dir/workspace
fi
# clean up old pyopenssl and reinstall 'pyopenssl' to fix "'module ' object has no attribute 'SSL_ST_INIT'" error
sudo rm -rf /usr/lib/python2.7/dist-packages/OpenSSL
sudo rm -rf /usr/lib/python2.7/dist-packages/pyOpenSSL-0.15.1.egg-info
sudo pip install -U pyopenssl
s2e init $dest_dir
cd $dest_dir
source s2e_activate
s2e build
s2e image_build debian-9.2.1-x86_64
