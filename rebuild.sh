#!/usr/bin/env bash
set -e

root_dir=$(cd "$(dirname "${BASH_SOURCE-$0}")"; pwd)
if [ $# -ne 0 ]; then
  dest_dir=$1
else
  dest_dir=$root_dir/workspace
fi

cd $root_dir
git pull 
git submodule update --recursive

cd $dest_dir
source s2e_activate
s2e update
s2e build

cd $root_dir
cd target-sys/mysql
./compile.sh
cd build 
make install
