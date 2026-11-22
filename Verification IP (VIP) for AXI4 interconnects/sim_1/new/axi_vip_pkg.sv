//------------------------------------------------------------------------------
// axi_vip_pkg.sv
// The AXI4 / AXI4-Lite Verification IP package.
// Compile order: axi_types_pkg.sv -> axi_if.sv -> axi_vip_pkg.sv -> tests/tb
// The .svh files are included here (they are NOT compiled on their own).
// More files (driver, monitor, agent, coverage...) will be added below.
//------------------------------------------------------------------------------
package axi_vip_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import axi_types_pkg::*;

  `include "axi_utils.svh"
  `include "axi_cfg.svh"
  `include "axi_seq_item.svh"
  `include "axi_base_seq.svh"
  `include "axi_excl_seq.svh"
endpackage
