//------------------------------------------------------------------------------
// axi_if.sv
// AXI4 interface (no REGION / QoS / USER, per the paper's use case).
// Three clocking blocks:
//   mgr_cb : used by the VIP MANAGER driver     (drives AW/W/AR, BREADY, RREADY)
//   sub_cb : used by the VIP SUBORDINATE driver (drives AWREADY/WREADY/ARREADY, B, R)
//   mon_cb : used by the monitor and coverage   (samples everything)
// Inputs are sampled at #1step (value just before the clock edge),
// outputs are driven #1 after the edge -> race-free TB/DUT interaction.
//------------------------------------------------------------------------------
interface axi_if
  import axi_types_pkg::*;
(
  input logic aclk,
  input logic aresetn
);

  // ---------------- Write address ----------------
  logic [AXI_ID_W-1:0]   awid;
  logic [AXI_ADDR_W-1:0] awaddr;
  logic [7:0]            awlen;
  logic [2:0]            awsize;
  logic [1:0]            awburst;
  logic                  awlock;
  logic [3:0]            awcache;
  logic [2:0]            awprot;
  logic                  awvalid;
  logic                  awready;
  // ---------------- Write data -------------------
  logic [AXI_DATA_W-1:0] wdata;
  logic [AXI_STRB_W-1:0] wstrb;
  logic                  wlast;
  logic                  wvalid;
  logic                  wready;
  // ---------------- Write response ---------------
  logic [AXI_ID_W-1:0]   bid;
  logic [1:0]            bresp;
  logic                  bvalid;
  logic                  bready;
  // ---------------- Read address -----------------
  logic [AXI_ID_W-1:0]   arid;
  logic [AXI_ADDR_W-1:0] araddr;
  logic [7:0]            arlen;
  logic [2:0]            arsize;
  logic [1:0]            arburst;
  logic                  arlock;
  logic [3:0]            arcache;
  logic [2:0]            arprot;
  logic                  arvalid;
  logic                  arready;
  // ---------------- Read data --------------------
  logic [AXI_ID_W-1:0]   rid;
  logic [AXI_DATA_W-1:0] rdata;
  logic [1:0]            rresp;
  logic                  rlast;
  logic                  rvalid;
  logic                  rready;

  // ---------------- Manager-side clocking block ----------------
  clocking mgr_cb @(posedge aclk);
    default input #1step output #1;
    output awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot, awvalid;
    input  awready;
    output wdata, wstrb, wlast, wvalid;
    input  wready;
    input  bid, bresp, bvalid;
    output bready;
    output arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot, arvalid;
    input  arready;
    input  rid, rdata, rresp, rlast, rvalid;
    output rready;
  endclocking

  // ---------------- Subordinate-side clocking block ------------
  clocking sub_cb @(posedge aclk);
    default input #1step output #1;
    input  awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot, awvalid;
    output awready;
    input  wdata, wstrb, wlast, wvalid;
    output wready;
    output bid, bresp, bvalid;
    input  bready;
    input  arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot, arvalid;
    output arready;
    output rid, rdata, rresp, rlast, rvalid;
    input  rready;
  endclocking

  // ---------------- Monitor clocking block (passive) -----------
  clocking mon_cb @(posedge aclk);
    default input #1step;
    input awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot, awvalid, awready;
    input wdata, wstrb, wlast, wvalid, wready;
    input bid, bresp, bvalid, bready;
    input arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot, arvalid, arready;
    input rid, rdata, rresp, rlast, rvalid, rready;
  endclocking

  modport MGR (clocking mgr_cb, input aclk, input aresetn);
  modport SUB (clocking sub_cb, input aclk, input aresetn);
  modport MON (clocking mon_cb, input aclk, input aresetn);

endinterface
