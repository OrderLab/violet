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

Table of Contents
=================
* [Requirements](#requirements)
* [Usage](#usage)
   * [1. Clone the repository](#1-clone-the-repository)
   * [2. Build S2E and Violet:](#2-build-s2e-and-violet)
   * [3. Build QEMU guest images:](#3-build-qemu-guest-images)
   * [4. Build a target system:](#4-build-a-target-system)
   * [5. Create an analysis project:](#5-create-an-analysis-project)
      * [5.1 Initialize project](#51-initialize-project)
      * [5.2 Modify configuration](#52-modify-configuration)
      * [5.3 Link blobs](#53-link-blobs)
      * [5.4 Modify bootstrap script](#54-modify-bootstrap-script)
      * [5.5 Symbolic execution](#55-symbolic-execution)
   * [6. Trace Analysis](#6-trace-analysis)
      * [6.1 Build the trace analyzer](#61-build-the-trace-analyzer)
      * [6.2 Run on collected traces](#62-run-on-collected-traces)
   * [7. Re-run Symbolic Execution and Trace Analysis.](#7-re-run-symbolic-execution-and-trace-analysis)
   * [8. Re-run Symbolic Execution with related configurations.](#8-re-run-symbolic-execution-with-related-configurations)
      * [8.1 Get related configuration file](#81-get-related-configuration-file)
      * [8.2 Build the static analyzer](#82-build-the-static-analyzer)
      * [8.3 Build and run normal MySQL to get configuration metadata](#83-build-and-run-normal-mysql-to-get-configuration-metadata)
      * [8.4 Run the static analyzer to get related configuration file](#84-run-the-static-analyzer-to-get-related-configuration-file)
      * [8.5 Modify bootstrap to copy related configuration file to guest](#85-modify-bootstrap-to-copy-related-configuration-file-to-guest)
      * [8.6 Re-run symbolic execution](#86-re-run-symbolic-execution)
* [Known Issues](#known-issues)
* [Publication](#publication)

## Requirements

Violet is tested to work under Ubuntu 16.04. Running it in Ubuntu 18.04 is 
possible but requires extra hassles. The `build.sh` script in this repository 
is only tested in Ubuntu 16.04.

It is also recommended to run Violet in physical machine if possible for reasons
outlined in the [Known Issues](#known-issues) section.

## Usage

### 1. Clone the repository

```bash
git clone https://github.com/OrderLab/violet.git
cd violet
git submodule update --init --recursive
```

### 2. Build S2E and Violet:

Put the following to `.bashrc` so that later the `s2e` command built to the 
local path can be found. 

```bash
export PATH=$HOME/.local/bin:$PATH
```
Re-login the shell for it to take effect. Invoke the build script:

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
  profileAllFunction = false,
  traceSyscall = true,
  traceFileIO = true,
  traceFunctionCall = true,
  traceInstruction = false,
  printTrace = false,
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
export VIO_SYM_CONFIGS="autocommit"
./bin/mysqld --defaults-file=my.cnf --one-thread &
sleep 40
./bin/mysql -S mysqld.sock << EOF
use test;
INSERT INTO tbl(col) VALUES(31);
INSERT INTO tbl(col) VALUES(32);
INSERT INTO tbl(col) VALUES(33);
INSERT INTO tbl(col) VALUES(34);
EOF
./bin/mysqladmin -S mysqld.sock -u root shutdown
```

In this case, we are testing making the MySQL configuration parameter `autocommit` 
symbolic.

#### 5.5 Symbolic execution

Finally, we can symbolically execute the target system:

```bash
$ ./launch-s2e.sh
```

The execution should explore two states, with output of something like the following:

```
...
20 [State 0] BaseInstructions: Message from guest (0x7ffc4e255440): will make the following configs symbolic: autocommit
20 [State 0] BaseInstructions: Message from guest (0x7ffc4e255440): finish checking the result configuration: autocommit
20 [State 0] BaseInstructions: Message from guest (0x7ffc4e255440): found target sys_var autocommit
20 [State 0] BaseInstructions: Message from guest (0x7ffc4e2553c0): will make autocommit symbolic: 1 bytes starting at 0x7ffc4e2559df
20 [State 0] BaseInstructions:  the namestr is autocommit
20 [State 0] BaseInstructions: Inserted symbolic data @0x7ffc4e2559df of size 0x1: autocommit='\x01' pc=0xbafd10
20 [State 0] BaseInstructions: Message from guest (0x7ffc4e2556c0): actually called S2E to make autocommit symbolic!!!!
20 [State 0] Forking state 0 at pc = 0x70c67e at pagedir = 0x139228000
    state 0
    state 1
...
34 [State 1] Switching from state 1 to state 0
39 [State 0] Switching from state 0 to state 1
40 [State 1] LinuxMonitor: mmap pid=0x4f5 addr=0x7f9f826c2000 size=0x1301000 prot=0x3 flag=0x22 pgoff=0x0
40 [State 1] LinuxMonitor: munmap pid=0x4f5 start=0x7f9f826c2000 end=0x7f9f839c3000
...
40 [State 1] LinuxMonitor: mprotect pid=0x501 start=0x7f9f7c000000 size=0x21000 prot=0x3
49 [State 1] Switching from state 1 to state 0
...
83 [State 1] BaseInstructions: Killing state 1
83 [State 1] Terminating state: State was terminated by opcode
            message: "bootstrap terminated"
            status: 0x0
83 [State 1] TestCaseGenerator: generating test case at address 0x804989b; the number of instruction 0; the number of syscall 225;
83 [State 1] LatencyTracker: read 561 bytes through 6 read call, read 32804 bytes through 4 pread calls, write 688 bytes through 29 write calls, write 0 bytes through 0 pwrite calls
83 [State 1] LatencyTracker: the constraints name is autocommit the target configuration is autocommit
83 [State 1] LatencyTracker: 1 0 0 1
83 [State 1] TestCaseGenerator:      v0_autocommit_0 = {0x0}; (string) "."
All states were terminated
s2e-block: dirty sectors on close:584
Terminating node id 0 (instance slot 0)
Engine terminated.
```

### 6. Trace Analysis

#### 6.1 Build the trace analyzer

```bash
$ cd ~/violet/trace-analyzer
$ mkdir build 
$ cd build && cmake .. && make -j4 && cd ..
```

Test it with the sample trace data from MySQL:

```bash
$ build/bin/trace_analyzer -i test/LatencyTrace1_autocommit.dat -s test/mysqld.sym -o test_result.txt
```
The trace would find the path 0 is slower than path 1, with the output like following 

```
[State 0] critical path (compared to state 1) :                                                                                                            =>  => 
   => function @0x602435<mysql_parse(THD*, char*, unsigned int, Parser_state*)>,caller @0x5f51be<dispatch_command(enum_server_command, THD*, char*, unsigned int)>,activity_id 244,parent_id 0,execution time 320.297ms,diff time 279.075ms  
   => function @0x5f7e31<mysql_execute_command(THD*)>,caller @0x602435<mysql_parse(THD*, char*, unsigned int, Parser_state*)>,activity_id 1412,parent_id 244,execution time 313.127ms,diff time 278.881ms                                                                                                            =>     
   => function @0x5dec2a<mysql_insert(THD*, TABLE_LIST*, List<Item>&, List<List<Item> >&, List<Item>&, List<Item>&, enum_duplicates, bool)>,caller @0x5f7e31<mysql_execute_command(THD*)>,activity_id 1616,parent_id 1412,execution time 290.047ms,diff time 262.022ms 
...
[State 0] => the number of instruction is 0,the number of syscall is 0, the total execution time 2098.92ms                                               
[State 1] => the number of instruction is 0,the number of syscall is 0, the total execution time 1582.26ms 
```
#### 6.2 Run on collected traces

Run the trace analyzer on the traces from the symbolic execution, the result is in mysql_result.txt file:

```bash
$ build/bin/trace_analyzer -e ~/violet/target-sys/mysql/dist/bin/mysqld -i ~/violet/workspace/projects/mysqld/s2e-last/LatencyTracer.dat -o mysql_result.txt
```

### 7. Re-run Symbolic Execution and Trace Analysis.

We can re-run the symbolic execution and trace analysis. For example, we can now 
test symbolic execution of the configuration parameter together with workload template. 
To do this, we need to go to 5.4 and modify the bootstrap script. In particular, 
replace the concrete queries part with a symbolic query token that we used -- `@@`:

```bash
# Run the analysis
export VIO_SYM_CONFIGS="autocommit"
./bin/mysqld --defaults-file=my.cnf --one-thread &
sleep 60
./bin/mysql -S mysqld.sock << EOF
use test;
@@;
EOF
./bin/mysqladmin -S mysqld.sock -u root shutdown
```

Now, call the launch script again:

```bash
$ ./launch-s2e.sh
```

You should see more than two states being explored now.

```
271 [State 21] TestCaseGenerator: generating test case at address 0x804976b; the number of instruction 1366900227; the number of syscall 38;
271 [State 21] LatencyTracker: read 65 bytes through 1 read call, read 0 bytes through 0 pread calls, write 612 bytes through 6 write calls, write 0 bytes through 0 pwrite calls
271 [State 21] LatencyTracker: the constraints name is autocommit the target configuration is autocommit
...
271 [State 21] TestCaseGenerator:      v0_autocommit_0 = {0x1}; (string) "."
          v1_index_2 = {0x0, 0x0, 0x0, 0x0}; (int32_t) 0, (string) "...."
          v2_index_5 = {0x0, 0x0, 0x0, 0x0}; (int32_t) 0, (string) "...."
All states were terminated
```

Repeat 6.2 to analyze the new trace data:

```
$ cd ~/violet/trace-analyzer
$ build/bin/trace_analyzer -i ~/violet/workspace/projects/mysqld/s2e-last/LatencyTracer.dat -o mysql_result.txt
```
### 8. Re-run Symbolic Execution with related configurations.
#### 8.1 Get related configuration file
  We provide a stock related configuration file in the target-sys folder for test the symbolic engine with relatedtion configuration in case the user doesn't want to run the static analyzer to get the file. To do this, the user just need to copy the related_configurations.log file into the project repo and run the experiment.
```
$ cd ~/violet/workspace/projects/mysqld
$ cp ~/violet/target-sys/mysql/related_configuration.log .
$ ./launch-s2e.sh
```

#### 8.2 Build the static analyzer 
If you want to use static analyzer to get the result, you need to build the static analyzer and llvm: 

```bash
$ cd ~/violet/static-analyzer
# If LLVM 3.8 is not installed, install it.
# $ ./install-llvm.sh 3.8.1 ~/llvm

$ mkdir build 
$ cd build && cmake .. && make -j4 && cd ..
```

#### 8.3 Build and run normal MySQL to get configuration metadata

```bash
# Build a normal MySQL
$ unset S2EDIR
$ cd ~/violet/target-sys/mysql/5.5.59
$ ./compile.sh normal
$ cd normal/build
$ make install

# Run the normal MySQL
$ cd ..
$ ../init_db.sh
$ cd dist
$ ./bin/mysqld --defaults-file=support-files/my-huge.cnf --one-thread &
$ ./bin/mysqladmin -S mysqld.sock -u root shutdown
```

There should be a `configuration.log` file in `dist`.

#### 8.4 Run the static analyzer to get related configuration file

```bash
$ cd  ~/violet/static-analyzer
$ cp ~/violet/target-sys/mysql/5.5.59/normal/dist/configuraitons.log .
$ cp ~/violet/target-sys/mysql/mysqld.bc .
$ opt -load build/dependencyAnalysis/libdependencyAnalyzer.so -analyzer -t calculate_offset -e mysql -i mysql_config_raw.log  <../mysqld.bc> /dev/null
$ opt -load build/dependencyAnalysis/libdependencyAnalyzer.so -analyzer -t dependency_analysis -e mysql -i mysql_config.log  <../mysqld.bc> /dev/null
$ cd ~/violet/workspace/projects/mysqld
$ cp ~/violet/static-analyzer/mysql_result.log related_configuration.log .
```

#### 8.5 Modify bootstrap to copy related configuration file to guest

Similar to 5.4, in which we download the built `mysqld` to the guest image with 
`s2eget`, modify the bootstrap script as follows:

```bash
# Download the target file to analyze
${S2EGET} "mysqld"
${S2EGET} "libaio.so.1.0.1"
${S2EGET} "related_configuration.log"

sudo mv libaio.so.1.0.1 /lib/x86_64-linux-gnu/
sudo ln -s /lib/x86_64-linux-gnu/libaio.so.1.0.1 /lib/x86_64-linux-gnu/libaio.so.1
mv mysqld /home/s2e/software/mysql/5.5.59/bin
mv related_configuration.log /home/s2e/software/mysql/5.5.59
cd /home/s2e/software/mysql/5.5.59/

...
```

#### 8.6 Re-run symbolic execution

```bash
$./launch-s2e.sh
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

3. 0-sized LatencyTrace.dat

This might occur because the target system startup takes longer than expected. 
In MySQL's case, the boostrap command is `./bin/mysqld --defaults-file=my.cnf 
--one-thread &`. We wait for 40 seconds before executing the MySQL client.
But this wait time may not be enough and thus `./bin/mysql -S mysqld.sock`
would fail because MySQL server is not ready for connection. You can bump
the sleep time up. In other times, this is typically because of some specific
errors that are better troubleshooted with QEMU graphics output in order to 
view the error messages in the guest.

## Publication

* [Automated Reasoning and Detection of Specious Configuration in Large Systems with Symbolic Execution](#).
   Yigong Hu, Gongqi Huang, and Peng Huang. *14th USENIX Symposium on Operating Systems Design and Implementation* (OSDI), November 2020.
