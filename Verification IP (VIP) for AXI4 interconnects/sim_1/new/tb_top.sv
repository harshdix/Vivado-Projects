//------------------------------------------------------------------------------
// tb_top.sv
// UVM top for the AXI4 queue (paper Fig. 4):
//   mgr_if  : VIP manager agent      <-> DUT s_axi_* (subordinate port)
//   sub_if  : VIP subordinate agent  <-> DUT m_axi_* (manager port)
// Protocol checkers are bound onto both DUT ports (see 'bind' below).
// Default test: axi_queue_base_test (override with +UVM_TESTNAME=...)
//------------------------------------------------------------------------------
module tb_top;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import axi_types_pkg::*;
  import axi_queue_tb_pkg::*;

  logic aclk = 1'b0;
  logic aresetn;
  always #5 aclk = ~aclk;   // 100 MHz

  initial begin
    aresetn = 1'b0;
    repeat (10) @(posedge aclk);
    aresetn <= 1'b1;
  end

  axi_if mgr_if (.aclk(aclk), .aresetn(aresetn));
  axi_if sub_if (.aclk(aclk), .aresetn(aresetn));

  axi4_queue #(
    .ID_W(AXI_ID_W), .ADDR_W(AXI_ADDR_W), .DATA_W(AXI_DATA_W), .DEPTH(4)
  ) dut (
    .aclk(aclk), .aresetn(aresetn),
    // subordinate port <-> mgr_if
    .s_axi_awid(mgr_if.awid),       .s_axi_awaddr(mgr_if.awaddr),   .s_axi_awlen(mgr_if.awlen),
    .s_axi_awsize(mgr_if.awsize),   .s_axi_awburst(mgr_if.awburst), .s_axi_awlock(mgr_if.awlock),
    .s_axi_awcache(mgr_if.awcache), .s_axi_awprot(mgr_if.awprot),
    .s_axi_awvalid(mgr_if.awvalid), .s_axi_awready(mgr_if.awready),
    .s_axi_wdata(mgr_if.wdata),     .s_axi_wstrb(mgr_if.wstrb),     .s_axi_wlast(mgr_if.wlast),
    .s_axi_wvalid(mgr_if.wvalid),   .s_axi_wready(mgr_if.wready),
    .s_axi_bid(mgr_if.bid),         .s_axi_bresp(mgr_if.bresp),
    .s_axi_bvalid(mgr_if.bvalid),   .s_axi_bready(mgr_if.bready),
    .s_axi_arid(mgr_if.arid),       .s_axi_araddr(mgr_if.araddr),   .s_axi_arlen(mgr_if.arlen),
    .s_axi_arsize(mgr_if.arsize),   .s_axi_arburst(mgr_if.arburst), .s_axi_arlock(mgr_if.arlock),
    .s_axi_arcache(mgr_if.arcache), .s_axi_arprot(mgr_if.arprot),
    .s_axi_arvalid(mgr_if.arvalid), .s_axi_arready(mgr_if.arready),
    .s_axi_rid(mgr_if.rid),         .s_axi_rdata(mgr_if.rdata),     .s_axi_rresp(mgr_if.rresp),
    .s_axi_rlast(mgr_if.rlast),     .s_axi_rvalid(mgr_if.rvalid),   .s_axi_rready(mgr_if.rready),
    // manager port <-> sub_if
    .m_axi_awid(sub_if.awid),       .m_axi_awaddr(sub_if.awaddr),   .m_axi_awlen(sub_if.awlen),
    .m_axi_awsize(sub_if.awsize),   .m_axi_awburst(sub_if.awburst), .m_axi_awlock(sub_if.awlock),
    .m_axi_awcache(sub_if.awcache), .m_axi_awprot(sub_if.awprot),
    .m_axi_awvalid(sub_if.awvalid), .m_axi_awready(sub_if.awready),
    .m_axi_wdata(sub_if.wdata),     .m_axi_wstrb(sub_if.wstrb),     .m_axi_wlast(sub_if.wlast),
    .m_axi_wvalid(sub_if.wvalid),   .m_axi_wready(sub_if.wready),
    .m_axi_bid(sub_if.bid),         .m_axi_bresp(sub_if.bresp),
    .m_axi_bvalid(sub_if.bvalid),   .m_axi_bready(sub_if.bready),
    .m_axi_arid(sub_if.arid),       .m_axi_araddr(sub_if.araddr),   .m_axi_arlen(sub_if.arlen),
    .m_axi_arsize(sub_if.arsize),   .m_axi_arburst(sub_if.arburst), .m_axi_arlock(sub_if.arlock),
    .m_axi_arcache(sub_if.arcache), .m_axi_arprot(sub_if.arprot),
    .m_axi_arvalid(sub_if.arvalid), .m_axi_arready(sub_if.arready),
    .m_axi_rid(sub_if.rid),         .m_axi_rdata(sub_if.rdata),     .m_axi_rresp(sub_if.rresp),
    .m_axi_rlast(sub_if.rlast),     .m_axi_rvalid(sub_if.rvalid),   .m_axi_rready(sub_if.rready)
  );

  //---------------- protocol checkers (paper Sec. IV-D) ----------------
  // 'bind' attaches a checker to BOTH AXI ports of every axi4_queue instance,
  // straight onto the RTL port names - no agent or interface needed. The same
  // two lines would check any internal AXI link of a larger design.
  bind axi4_queue axi_protocol_checker #(.NAME("DUT_S_AXI")) u_chk_s_axi (
    .aclk    (aclk),
    .aresetn (aresetn),
    .awid    (s_axi_awid),
    .awaddr  (s_axi_awaddr),
    .awlen   (s_axi_awlen),
    .awsize  (s_axi_awsize),
    .awburst (s_axi_awburst),
    .awlock  (s_axi_awlock),
    .awcache (s_axi_awcache),
    .awprot  (s_axi_awprot),
    .awvalid (s_axi_awvalid),
    .awready (s_axi_awready),
    .wdata   (s_axi_wdata),
    .wstrb   (s_axi_wstrb),
    .wlast   (s_axi_wlast),
    .wvalid  (s_axi_wvalid),
    .wready  (s_axi_wready),
    .bid     (s_axi_bid),
    .bresp   (s_axi_bresp),
    .bvalid  (s_axi_bvalid),
    .bready  (s_axi_bready),
    .arid    (s_axi_arid),
    .araddr  (s_axi_araddr),
    .arlen   (s_axi_arlen),
    .arsize  (s_axi_arsize),
    .arburst (s_axi_arburst),
    .arlock  (s_axi_arlock),
    .arcache (s_axi_arcache),
    .arprot  (s_axi_arprot),
    .arvalid (s_axi_arvalid),
    .arready (s_axi_arready),
    .rid     (s_axi_rid),
    .rdata   (s_axi_rdata),
    .rresp   (s_axi_rresp),
    .rlast   (s_axi_rlast),
    .rvalid  (s_axi_rvalid),
    .rready  (s_axi_rready)
  );

  bind axi4_queue axi_protocol_checker #(.NAME("DUT_M_AXI")) u_chk_m_axi (
    .aclk    (aclk),
    .aresetn (aresetn),
    .awid    (m_axi_awid),
    .awaddr  (m_axi_awaddr),
    .awlen   (m_axi_awlen),
    .awsize  (m_axi_awsize),
    .awburst (m_axi_awburst),
    .awlock  (m_axi_awlock),
    .awcache (m_axi_awcache),
    .awprot  (m_axi_awprot),
    .awvalid (m_axi_awvalid),
    .awready (m_axi_awready),
    .wdata   (m_axi_wdata),
    .wstrb   (m_axi_wstrb),
    .wlast   (m_axi_wlast),
    .wvalid  (m_axi_wvalid),
    .wready  (m_axi_wready),
    .bid     (m_axi_bid),
    .bresp   (m_axi_bresp),
    .bvalid  (m_axi_bvalid),
    .bready  (m_axi_bready),
    .arid    (m_axi_arid),
    .araddr  (m_axi_araddr),
    .arlen   (m_axi_arlen),
    .arsize  (m_axi_arsize),
    .arburst (m_axi_arburst),
    .arlock  (m_axi_arlock),
    .arcache (m_axi_arcache),
    .arprot  (m_axi_arprot),
    .arvalid (m_axi_arvalid),
    .arready (m_axi_arready),
    .rid     (m_axi_rid),
    .rdata   (m_axi_rdata),
    .rresp   (m_axi_rresp),
    .rlast   (m_axi_rlast),
    .rvalid  (m_axi_rvalid),
    .rready  (m_axi_rready)
  );

  initial begin
    uvm_config_db #(virtual axi_if)::set(null, "uvm_test_top", "mgr_vif", mgr_if);
    uvm_config_db #(virtual axi_if)::set(null, "uvm_test_top", "sub_vif", sub_if);
    run_test("axi_queue_base_test");
  end
endmodule
