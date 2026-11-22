AXI4 / AXI4-Lite Verification IP (UVM)
A UVM-based Verification IP (VIP) for verifying AXI4 and AXI4-Lite interconnect blocks. It provides constrained-random stimulus, a manager and a subordinate agent, a passive monitor, a scoreboard, SystemVerilog Assertions (SVA) for protocol checking, and functional coverage collectors. It is demonstrated on an AXI4 queue (buffer) DUT.

Author: Harsh Dixit, Department of Electronics and Communication Engineering, The LNM Institute of Information Technology, Jaipur

Features
Works with both AXI4 and AXI4-Lite (selected by cfg.mode in the agent configuration object)
Standard UVM structure: agent configuration, sequence item, sequences, sequencer, drivers, monitor, coverage collectors, agents, scoreboard and tests
Separate manager and subordinate agents. The subordinate driver is a reactive AXI4 memory with random ready and response delays, exclusive-access monitor and optional error responses (err_pct). One monitor class works on any AXI interface
Constrained-random stimulus with two base sequences: non-exclusive (axi_base_seq) and exclusive (axi_excl_seq, an exclusive read followed by the matching exclusive write)
Randomize, tweak, start flow: sequences hold the randomizable variables, so a test can call randomize(), change any field, then call start(). This makes directed debugging easy
Protocol checker (axi_protocol_checker.sv): a plain module with one port per AXI signal, attached with bind to any AXI link, so it works even where there is no VIP agent. It contains 82 concurrent assertions for AXI4 (6 more when LITE = 1) covering handshake rules, address and burst rules, write-data rules and response rules. It can be switched off with enable_assertions in the config
Functional coverage with separate AXI4 (axi4_cov) and AXI4-Lite (axi4lite_cov) collectors; address, data and strobe signals are left to the DUT-specific testbench
Scoreboard that compares every transaction seen at the DUT's upstream port with the one seen at its downstream port (same content, same order)
Debug features: transaction tracing (+TRACE), dump of internal data on error, hang watchdog (hang_timeout_cycles) and adjustable UVM logging levels
Design scope and exceptions
Designed for simple interconnect blocks (resize, address translation, queues). The following AXI4 features are not supported:

Out-of-order transactions
Read data interleaving
Region and QoS signals
Testbench architecture
                 axi_queue_base_test (uvm_test)
                          |
                    axi_queue_env
        +-----------------+------------------+
        |                 |                  |
  axi_mgr_agent     axi_queue_scoreboard   axi_sub_agent
 (sqr, drv, mon)      (compare up/down)    (drv, mon)
        |                                    |
      mgr_if  ----->   axi4_queue DUT  ----->  sub_if
              (s_axi_*)               (m_axi_*)

  axi_protocol_checker is bound onto both DUT ports in tb_top.sv
Repository structure
All files are in the Vivado simulation source folder:

axi4-vip-uvm/
├── README.md
├── .gitignore
└── sim_1/new/
    ├── axi_types_pkg.sv          widths (ID 4, address 32, data 128) and enums
    ├── axi_if.sv                 AXI interface with clocking blocks
    ├── axi_vip_pkg.sv            VIP package (includes the .svh files below)
    ├── axi_utils.svh             AXI address and byte-lane math
    ├── axi_cfg.svh               agent configuration object
    ├── axi_seq_item.svh          sequence item
    ├── axi_base_seq.svh          non-exclusive random sequence
    ├── axi_excl_seq.svh          exclusive access sequence
    ├── axi_sequencer.svh
    ├── axi_mgr_driver.svh        manager driver
    ├── axi_sub_driver.svh        subordinate driver (memory model)
    ├── axi_monitor.svh           monitor
    ├── axi_mgr_agent.svh
    ├── axi_sub_agent.svh
    ├── axi4_cov.svh              AXI4 functional coverage
    ├── axi4lite_cov.svh          AXI4-Lite functional coverage
    ├── axi_protocol_checker.sv   SVA protocol checker (bound with `bind`)
    ├── axi_fifo.sv               generic FIFO with VALID/READY handshakes
    ├── axi4_queue.sv             DUT: AXI4 queue (one FIFO per channel)
    ├── axi_queue_tb_pkg.sv       scoreboard, environment and tests for the DUT
    ├── tb_top.sv                 UVM testbench top
    ├── tb_axi4_queue.sv          plain (non-UVM) self-checking test of the DUT
    ├── tb_seq_check.sv           checks the sequence layer on its own (no DUT)
    └── axi_if_smoke_tb1.sv       interface and clocking-block smoke test
Tests
Test	What it does
axi_queue_base_test (default)	Random mix of non-exclusive and exclusive sequences through the queue, with the scoreboard checking every transaction
axi_queue_assert_demo_test	Sends deliberately illegal transactions to prove the protocol checkers flag them on both DUT ports
axi_queue_lite_test	Same flow in AXI4-Lite mode
axi_seq_check_test (tb_seq_check)	Checks 5000 random AXI4 transactions, the randomize-tweak-start flow, 1000 exclusive sequences and 1000 AXI4-Lite transactions with an independent rule checker
Plusargs for the queue tests: +NUM_TXN=<n> (default 1000), +EXCL_PCT=<0..100> (default 10), +ERR_PCT=<0..100> (default 3), +ADDR_MAX=<hex>, +TRACE.

Requirements
Xilinx / AMD Vivado 2026.2 (latest release at the time of writing). The Vivado simulator (xsim) includes UVM 1.2.
SystemVerilog (IEEE 1800)
How to run
Option 1: Vivado GUI
Create a new RTL project (no constraints needed) and add everything from sim_1/new/ as simulation sources.
Make sure the .svh files are file type SystemVerilog Header (right-click the file, Set File Type). They are included by axi_vip_pkg.sv and must not be compiled on their own.
Right-click tb_top under Simulation Sources and choose Set as Top. The other test benches (tb_axi4_queue, tb_seq_check, axi_if_smoke_tb) are separate tops.
Open Settings > Simulation > Compilation and add -L uvm to the xvlog options. Under Elaboration add -L uvm to the xelab options.
Open Settings > Simulation > Simulation and, in xsim.simulate.xsim.more_options, add the plusargs, for example: -testplusarg UVM_TESTNAME=axi_queue_base_test -testplusarg NUM_TXN=100000
Click Run Simulation > Run Behavioral Simulation, then run until the end. The log finishes with *** TEST PASSED *** when the scoreboard sees no mismatches.
Option 2: Command line (xsim)
Run from inside sim_1/new/. The order matters because the packages must compile first:

xvlog -sv -L uvm -i . axi_types_pkg.sv axi_if.sv axi_vip_pkg.sv \
      axi_fifo.sv axi4_queue.sv axi_protocol_checker.sv \
      axi_queue_tb_pkg.sv tb_top.sv
xelab -L uvm tb_top -s tb_top_sim --debug typical
xsim tb_top_sim -runall -testplusarg UVM_TESTNAME=axi_queue_base_test -testplusarg NUM_TXN=100000
To run another test, change UVM_TESTNAME (for example axi_queue_assert_demo_test or axi_queue_lite_test).

Results
The AXI4 queue DUT (128-bit data bus, 32-bit address, depth 4) was simulated with this VIP using 10^5 write and 10^5 read transactions:

Metric	Result
Write transactions	10^5
Read transactions	10^5
Code coverage (statement, condition, toggle)	100%
Functional coverage, AW and AR channels	95.83%
Functional coverage, W, B and R channels	100%
Scoreboard mismatches	0
These results match the figures reported in the reference paper [1].

The functional coverage on the address channels is below 100% because the 128-bit DUT cannot accept transfers larger than 16 bytes per beat, so the larger size and burst-length bins are never hit.

Future work
DUT-specific coverage collectors (addresses, data and strobes)
Support for out-of-order transactions and read data interleaving
AXI4-Stream support
A reference model for DUT functionality
References
P. Sydanmaa, J. Ashraf and S. M. Abbas, "Novel Verification IP (VIP) for AXI4 interconnects employing Universal Verification Methodology (UVM)," 2025 IEEE Nordic Circuits and Systems Conference (NorCAS), DOI: 10.1109/NORCAS66540.2025.11231284
AMBA AXI and ACE Protocol Specification, Arm (IHI 0022)
AMBA 4 AXI4, AXI4-Lite and AXI4-Stream Protocol Assertions User Guide, Arm (DUI 0534)
Universal Verification Methodology (UVM) 1.2 User's Guide, Accellera
