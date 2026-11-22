//------------------------------------------------------------------------------
// axi_if_smoke_tb.sv
// Sanity test for axi_if + clocking blocks with the axi4_queue DUT.
//  - mgr_if : connected to DUT s_axi_* (VIP manager will drive this)
//  - sub_if : connected to DUT m_axi_* (VIP subordinate will answer here)
// Sends 4 AW beats manager->subordinate and 4 B beats subordinate->manager,
// using ONLY clocking blocks, exactly how the UVM drivers will do it.
// The DUT hookup below is reused as-is for the UVM tb_top later.
//------------------------------------------------------------------------------
module axi_if_smoke_tb;
  import axi_types_pkg::*;

  logic aclk = 1'b0;
  logic aresetn;
  always #5 aclk = ~aclk;

  axi_if mgr_if (.aclk(aclk), .aresetn(aresetn));
  axi_if sub_if (.aclk(aclk), .aresetn(aresetn));

  //---------------- DUT hookup ----------------
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

  //---------------- Manager-side tasks (mgr_cb) ----------------
  task automatic mgr_send_aw(input logic [AXI_ID_W-1:0] id,
                             input logic [AXI_ADDR_W-1:0] addr,
                             input logic [7:0] len);
    mgr_if.mgr_cb.awid    <= id;
    mgr_if.mgr_cb.awaddr  <= addr;
    mgr_if.mgr_cb.awlen   <= len;
    mgr_if.mgr_cb.awsize  <= 3'd4;          // 16 bytes
    mgr_if.mgr_cb.awburst <= BURST_INCR;
    mgr_if.mgr_cb.awlock  <= 1'b0;
    mgr_if.mgr_cb.awcache <= 4'b0011;
    mgr_if.mgr_cb.awprot  <= 3'b000;
    mgr_if.mgr_cb.awvalid <= 1'b1;
    do @(mgr_if.mgr_cb); while (!mgr_if.mgr_cb.awready);
    mgr_if.mgr_cb.awvalid <= 1'b0;
    $display("[%0t] MGR : AW sent  id=%0h addr=%h len=%0d", $time, id, addr, len);
  endtask

  task automatic mgr_recv_b(output logic [AXI_ID_W-1:0] id, output logic [1:0] resp);
    mgr_if.mgr_cb.bready <= 1'b1;
    do @(mgr_if.mgr_cb); while (!mgr_if.mgr_cb.bvalid);
    id   = mgr_if.mgr_cb.bid;
    resp = mgr_if.mgr_cb.bresp;
    mgr_if.mgr_cb.bready <= 1'b0;
    $display("[%0t] MGR : B  recv  id=%0h resp=%0d", $time, id, resp);
  endtask

  //---------------- Subordinate-side tasks (sub_cb) ------------
  task automatic sub_recv_aw(output logic [AXI_ID_W-1:0] id,
                             output logic [AXI_ADDR_W-1:0] addr,
                             output logic [7:0] len);
    sub_if.sub_cb.awready <= 1'b1;
    do @(sub_if.sub_cb); while (!sub_if.sub_cb.awvalid);
    id   = sub_if.sub_cb.awid;
    addr = sub_if.sub_cb.awaddr;
    len  = sub_if.sub_cb.awlen;
    sub_if.sub_cb.awready <= 1'b0;
    $display("[%0t] SUB : AW recv  id=%0h addr=%h len=%0d", $time, id, addr, len);
  endtask

  task automatic sub_send_b(input logic [AXI_ID_W-1:0] id, input logic [1:0] resp);
    sub_if.sub_cb.bid    <= id;
    sub_if.sub_cb.bresp  <= resp;
    sub_if.sub_cb.bvalid <= 1'b1;
    do @(sub_if.sub_cb); while (!sub_if.sub_cb.bready);
    sub_if.sub_cb.bvalid <= 1'b0;
    $display("[%0t] SUB : B  sent  id=%0h resp=%0d", $time, id, resp);
  endtask

  //---------------- Test ----------------
  int errors = 0;

  initial begin
    // all VALID / READY low (drive through clocking blocks)
    mgr_if.mgr_cb.awvalid <= 0; mgr_if.mgr_cb.wvalid <= 0; mgr_if.mgr_cb.arvalid <= 0;
    mgr_if.mgr_cb.bready  <= 0; mgr_if.mgr_cb.rready <= 0;
    sub_if.sub_cb.awready <= 0; sub_if.sub_cb.wready <= 0; sub_if.sub_cb.arready <= 0;
    sub_if.sub_cb.bvalid  <= 0; sub_if.sub_cb.rvalid <= 0;

    aresetn = 1'b0;
    repeat (5) @(posedge aclk);
    aresetn <= 1'b1;
    // RULE: a process that drives through a clocking block must only wait on
    // that clocking block. Mixing @(posedge aclk) with @(cb) in the same time
    // step lets @(cb) return immediately with a stale sample -> false handshake.
    repeat (2) @(mgr_if.mgr_cb);

    // ---- AW: manager -> DUT -> subordinate ----
    $display("[%0t] ---- Phase 1: AW channel ----", $time);
    fork
      for (int i = 0; i < 4; i++)
        mgr_send_aw(i, 32'h1000 + i*32'h100, i);
      for (int i = 0; i < 4; i++) begin
        logic [AXI_ID_W-1:0]   id;
        logic [AXI_ADDR_W-1:0] addr;
        logic [7:0]            len;
        sub_recv_aw(id, addr, len);
        if (id !== i || addr !== 32'h1000 + i*32'h100 || len !== i) begin
          $error("AW mismatch on beat %0d", i);
          errors++;
        end
      end
    join

    // ---- B: subordinate -> DUT -> manager ----
    $display("[%0t] ---- Phase 2: B channel ----", $time);
    fork
      begin
        @(sub_if.sub_cb);            // sender syncs to ITS OWN clocking block
        for (int i = 0; i < 4; i++)
          sub_send_b(i, i[1:0]);
      end
      for (int i = 0; i < 4; i++) begin
        logic [AXI_ID_W-1:0] id;
        logic [1:0]          resp;
        mgr_recv_b(id, resp);
        if (id !== i || resp !== i[1:0]) begin
          $error("B mismatch on beat %0d", i);
          errors++;
        end
      end
    join

    repeat (3) @(posedge aclk);
    if (errors == 0) $display("*** SMOKE TEST PASSED ***");
    else             $display("*** SMOKE TEST FAILED *** errors=%0d", errors);
    $finish;
  end

  //---------------- Watchdog: never hang, report where we got stuck --------
  initial begin
    repeat (500) @(posedge aclk);   // test needs < 100 cycles
    $display("=================== WATCHDOG TIMEOUT ===================");
    $display(" time=%0t  aresetn=%b", $time, aresetn);
    $display(" mgr_if : awvalid=%b awready=%b | bvalid=%b bready=%b",
             mgr_if.awvalid, mgr_if.awready, mgr_if.bvalid, mgr_if.bready);
    $display(" sub_if : awvalid=%b awready=%b | bvalid=%b bready=%b",
             sub_if.awvalid, sub_if.awready, sub_if.bvalid, sub_if.bready);
    $display(" DUT AW fifo count=%0d  B fifo count=%0d",
             dut.u_aw_fifo.count, dut.u_b_fifo.count);
    $display(" cb samples: mgr_cb.awready=%b sub_cb.awvalid=%b mgr_cb.bvalid=%b sub_cb.bready=%b",
             mgr_if.mgr_cb.awready, sub_if.sub_cb.awvalid,
             mgr_if.mgr_cb.bvalid,  sub_if.sub_cb.bready);
    $display("========================================================");
    $fatal(1, "Smoke test hung");
  end

  // monitor clocking block check: print every AW handshake seen on sub side
  always @(sub_if.mon_cb)
    if (sub_if.mon_cb.awvalid && sub_if.mon_cb.awready)
      $display("[%0t] MON : AW handshake id=%0h", $time, sub_if.mon_cb.awid);

endmodule
