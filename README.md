# Violet Root Repository

Violet is a tool that uses selective symbolic execution to automatically derive 
performance models of configuration parameters in large system and use the 
models to detect specious configuration settings. The design of Violet is 
described in our OSDI '20 [Paper](#).

The Violet tool has multiple components:

* the execution engine and tracer, which are built on top of [S2E](https://s2e.systems).
* the static analyzer, which is built on top of [LLVM](http://llvm.org).
* the trace analyzer, which is a standalone module written in C++. 
* the checker, which a standalone Python module.

Each component is held in one or multiple separate repositories. This is the 
root repository that contains the entry points for all the components.

## Usage

### 1. Clone the repository

```bash
git clone https://github.com/OrderLab/violet.git
cd violet
git submodule update --init --recursive
```

### 2. Build S2E and Violet:

```bash
$ ./build.sh
```

Note: the compilation will take a long time. The resulting repos and build in 
`workspace` will be also HUGE---more than 10GB.

### 3. Build QEMU guest images:

```bash
$ cd ~/violet/workspace
$ source s2e_activate
$ s2e image_build debian-9.2.1-x86_64
```

On a physical machine, the image build process takes about 20-30 minutes. On 
a cloud VM (with 4vCPUs and 16GB RAM), the image build process can take 3 hours
or even longer due to the lack of KVM support.

### 4. Build a target system:

Using MySQL as an example:

```bash
$ source ~/violet/workspace/s2e_activate
$ cd ~/violet/target-sys/mysql
$ ./compile.sh
$ cd build
$ make install
```

Now you should see a MySQL executable linked with Violet hooks: 

```bash
$ nm ~/violet/target-sys/mysql/dist/bin/mysqld | grep violet_init
0000000000bafa30 T violet_init
```

### 5. Create an analysis project:


#### 5.1 Initialize project 
```bash
$ s2e new_project -i debian-9.2.1-x86_64 -n mysqld ~/violet/target-sys/mysql/dist/bin/mysqld
$ cd ~/violet/workspace/projects/mysqld
```

#### 5.2 Modify configuration
Open `s2e-config.lua`, go to the `User-specific scripts` section to add Violet plugin 
config:

```
-- ========================================================================= --
-- ============== User-specific scripts begin here ========================= --
-- ========================================================================= --

add_plugin("FunctionMonitor")

pluginsConfig.FunctionMonitor = {
  monitorLocalFunctions = true,
}

add_plugin("LatencyTracker")
pluginsConfig.LatencyTracker = {
  profileAllFunction = true,
  traceSyscall = true,
  traceInstruction = false,
  entryAddress  = 0x2bab30,
}
```

#### 5.3 Link blobs

Some libraries may be missing in the guest image that would cause the target 
system to fail, even if it can successfully run natively. For MySQL specifically,
we need to add the `libaio` shared library to the guest image. We do that 
by first create a soft link in the project directory to the shared library 
in the **host machine**.

```bash
$ ln -s /lib/x86_64-linux-gnu/libaio.so.1.0.1
```

If `libaio.so.1.0.1` is somehow not available in the host machine, use the blob 
from the repo:

```bash
$ ln -s ~/violet/target-sys/blobs/libaio.so.1.0.1
```

#### 5.4 Modify bootstrap script

Then open `bootstrap.sh`, go to the end section (`execute "./mysqld"`), and change it 
to the following:

```
target_init

# Download the target file to analyze
${S2EGET} "mysqld"
${S2EGET} "libaio.so.1.0.1"

sudo mv libaio.so.1.0.1 /lib/x86_64-linux-gnu/
sudo ln -s /lib/x86_64-linux-gnu/libaio.so.1.0.1 /lib/x86_64-linux-gnu/libaio.so.1
mv mysqld /home/s2e/software/mysql/5.5.59/bin
cd /home/s2e/software/mysql/5.5.59/

# Run the analysis
execute "./mysqld"
export VIO_SYM_CONFIGS="autocommit"
./bin/mysqld --defaults-file=my.cnf --one-thread &
sleep 30
./bin/mysql -S mysqld.sock << EOF
use test;
INSERT INTO tbl(col) VALUES(31);
INSERT INTO tbl(col) VALUES(32);
INSERT INTO tbl(col) VALUES(33);
INSERT INTO tbl(col) VALUES(34);
EOF
./bin/mysqladmin -S mysqld.sock -u root shutdown
```

## Known Issues

1. AMD CPUs

The build will fail on AMD CPUs, specifically failing with `error: unknown target CPU 'i486'` error during the step of 
building `rapidjson` library:

```bash
make[2]: *** [example/CMakeFiles/filterkeydom.dir/all] Error 2
example/CMakeFiles/prettyauto.dir/build.make:62: recipe for target 'example/CMakeFiles/prettyauto.dir/prettyauto/prettyauto.cpp.o' failed
make[3]: *** [example/CMakeFiles/prettyauto.dir/prettyauto/prettyauto.cpp.o] Error 1
make[3]: Leaving directory '/data/local/ryan/violet/workspace/build/s2e/rapidjson-build'
error: unknown target CPU 'i486'
```

This is because S2E build [Makefile](https://github.com/OrderLab/violet-s2e-build-scripts/blob/violet/Makefile) directly **downloads** the 
pre-built Clang binaries from the LLVM release to save time. While there is a script to determine the proper package, the pre-built Clang 
binary in the downloaded `clang+llvm-3.9.1-x86_64-linux-gnu-ubuntu-16.04.tar.xz` does not seem to work on AMD CPUs. Fixing this requires 
building Clang and LLVM 3.9.1 from source. A more easier way is just to switch to machines with Intel CPUs.

2. Cloud VMs

Building the guest images would encounter errors in cloud VM instances because of the 
lack of KVM support:

```bash
$ s2e image_build debian-9.2.1-x86_64
INFO: [image_build] The following images will be built:
INFO: [image_build]  * debian-9.2.1-x86_64
ERROR: [image_build] KVM interface not found - check that /dev/kvm exists. Alternatively, you can disable KVM (-n option) or download pre-built images (-d option)
```

The workaround is, as hinted in the error message, to disable KVM with the `-n` option,
i.e., `s2e image_build -n debian-9.2.1-x86_64`. However, the consequence is that 
the image building will be slow. In addition, running Violet will be slow as well,
which can cause interference to the performance analysis.

A more ideal solution is to enable nested virtualization and KVM in the VM instances, 
e.g., for Google cloud, following the instruction in this [guide](https://cloud.google.com/compute/docs/instances/enable-nested-virtualization-vm-instances).
In general, it is highly recommended to run Violet in physical machines.

## Publication

* [Automated Reasoning and Detection of Specious Configuration in Large Systems with Symbolic Execution](#).
   Yigong Hu, Gongqi Huang, and Peng Huang. *14th USENIX Symposium on Operating Systems Design and Implementation* (OSDI), November 2020.
