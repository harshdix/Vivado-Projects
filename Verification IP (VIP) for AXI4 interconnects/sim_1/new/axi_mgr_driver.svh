//------------------------------------------------------------------------------
// axi_mgr_driver.svh  (included by axi_vip_pkg)
// MANAGER driver: turns axi_seq_items into AXI4 traffic.
//
// Five independent channel threads (AW, W, B, AR, R) so address, data and
// responses overlap like real hardware. Up to cfg.max_outstanding
// transactions can be in flight. Per-item delays (addr_delay, beat_delay[],
// resp_delay) come from the sequence (paper Sec. IV-B).
//
// Timing rule (learned in the smoke test): every thread drives AND waits only
// through vif.mgr_cb, and drives each signal at most once per clock edge.
//------------------------------------------------------------------------------
class axi_mgr_driver extends uvm_driver #(axi_seq_item);
  `uvm_component_utils(axi_mgr_driver)

  axi_cfg        cfg;
  virtual axi_if vif;

  // per-channel work queues (same item handle goes into several queues)
  axi_seq_item aw_q[$], w_q[$], b_q[$], ar_q[$], r_q[$];

  int unsigned outstanding;
  int unsigned n_wr_done, n_rd_done;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    if (cfg == null) `uvm_fatal("CFG", "axi_mgr_driver: cfg not set by agent")
  endfunction

  task run_phase(uvm_phase phase);
    vif = cfg.vif;
    // idle values (applied at the first clock edge)
    vif.mgr_cb.awvalid <= 1'b0;
    vif.mgr_cb.wvalid  <= 1'b0;
    vif.mgr_cb.arvalid <= 1'b0;
    vif.mgr_cb.bready  <= 1'b0;
    vif.mgr_cb.rready  <= 1'b0;
    wait (vif.aresetn === 1'b1);
    @(vif.mgr_cb);
    fork
      get_loop();
      aw_loop();
      w_loop();
      b_loop();
      ar_loop();
      r_loop();
    join
  endtask

  //---------------- accept items from the sequencer ----------------
  task get_loop();
    forever begin
      seq_item_port.get_next_item(req);
      while (outstanding >= cfg.max_outstanding) @(vif.mgr_cb);
      if (req.is_write && req.data.size() != int'(req.len) + 1)
        `uvm_fatal("MGR_DRV", {"write data array size != len+1: ", req.convert2string()})
      outstanding++;
      if (cfg.trace_txn)
        `uvm_info("MGR_DRV", {"queued: ", req.convert2string()}, UVM_LOW)
      if (req.is_write) begin
        aw_q.push_back(req);
        w_q.push_back(req);
        b_q.push_back(req);
      end else begin
        ar_q.push_back(req);
        r_q.push_back(req);
      end
      seq_item_port.item_done();
    end
  endtask

  //---------------- AW channel ----------------
  task aw_loop();
    axi_seq_item t;
    forever begin
      while (aw_q.size() == 0) begin vif.mgr_cb.awvalid <= 1'b0; @(vif.mgr_cb); end
      t = aw_q.pop_front();
      if (t.addr_delay > 0) begin
        vif.mgr_cb.awvalid <= 1'b0;
        repeat (t.addr_delay) @(vif.mgr_cb);
      end
      vif.mgr_cb.awid    <= t.id;
      vif.mgr_cb.awaddr  <= t.addr;
      vif.mgr_cb.awlen   <= t.len;
      vif.mgr_cb.awsize  <= t.size;
      vif.mgr_cb.awburst <= t.burst;
      vif.mgr_cb.awlock  <= t.lock;
      vif.mgr_cb.awcache <= t.cache;
      vif.mgr_cb.awprot  <= t.prot;
      vif.mgr_cb.awvalid <= 1'b1;
      @(vif.mgr_cb);
      while (!vif.mgr_cb.awready) @(vif.mgr_cb);
    end
  endtask

  //---------------- W channel (may run ahead of AW - legal in AXI4) --------
  task w_loop();
    axi_seq_item t;
    forever begin
      while (w_q.size() == 0) begin vif.mgr_cb.wvalid <= 1'b0; @(vif.mgr_cb); end
      t = w_q.pop_front();
      for (int i = 0; i <= int'(t.len); i++) begin
        if (t.beat_delay[i] > 0) begin
          vif.mgr_cb.wvalid <= 1'b0;
          repeat (t.beat_delay[i]) @(vif.mgr_cb);
        end
        vif.mgr_cb.wdata  <= t.data[i];
        vif.mgr_cb.wstrb  <= t.strb[i];
        vif.mgr_cb.wlast  <= (i == int'(t.len));
        vif.mgr_cb.wvalid <= 1'b1;
        @(vif.mgr_cb);
        while (!vif.mgr_cb.wready) @(vif.mgr_cb);
      end
    end
  endtask

  //---------------- B channel ----------------
  task b_loop();
    axi_seq_item t;
    forever begin
      while (b_q.size() == 0) begin vif.mgr_cb.bready <= 1'b0; @(vif.mgr_cb); end
      t = b_q[0];
      if (t.resp_delay > 0) begin
        vif.mgr_cb.bready <= 1'b0;
        repeat (t.resp_delay) @(vif.mgr_cb);
      end
      vif.mgr_cb.bready <= 1'b1;
      @(vif.mgr_cb);
      while (!vif.mgr_cb.bvalid) @(vif.mgr_cb);
      void'(b_q.pop_front());
      if (vif.mgr_cb.bid !== t.id)
        `uvm_error("MGR_DRV", $sformatf("BID %0h != expected %0h for %s",
                                        vif.mgr_cb.bid, t.id, t.convert2string()))
      t.resp    = new[1];
      t.resp[0] = axi_resp_e'(vif.mgr_cb.bresp);
      outstanding--;
      n_wr_done++;
    end
  endtask

  //---------------- AR channel ----------------
  task ar_loop();
    axi_seq_item t;
    forever begin
      while (ar_q.size() == 0) begin vif.mgr_cb.arvalid <= 1'b0; @(vif.mgr_cb); end
      t = ar_q.pop_front();
      if (t.addr_delay > 0) begin
        vif.mgr_cb.arvalid <= 1'b0;
        repeat (t.addr_delay) @(vif.mgr_cb);
      end
      vif.mgr_cb.arid    <= t.id;
      vif.mgr_cb.araddr  <= t.addr;
      vif.mgr_cb.arlen   <= t.len;
      vif.mgr_cb.arsize  <= t.size;
      vif.mgr_cb.arburst <= t.burst;
      vif.mgr_cb.arlock  <= t.lock;
      vif.mgr_cb.arcache <= t.cache;
      vif.mgr_cb.arprot  <= t.prot;
      vif.mgr_cb.arvalid <= 1'b1;
      @(vif.mgr_cb);
      while (!vif.mgr_cb.arready) @(vif.mgr_cb);
    end
  endtask

  //---------------- R channel (in order; DUT has no reordering) -----------
  task r_loop();
    axi_seq_item t;
    forever begin
      while (r_q.size() == 0) begin vif.mgr_cb.rready <= 1'b0; @(vif.mgr_cb); end
      t      = r_q[0];
      t.data = new[int'(t.len) + 1];
      t.resp = new[int'(t.len) + 1];
      for (int i = 0; i <= int'(t.len); i++) begin
        if (t.beat_delay[i] > 0) begin
          vif.mgr_cb.rready <= 1'b0;
          repeat (t.beat_delay[i]) @(vif.mgr_cb);
        end
        vif.mgr_cb.rready <= 1'b1;
        @(vif.mgr_cb);
        while (!vif.mgr_cb.rvalid) @(vif.mgr_cb);
        if (vif.mgr_cb.rid !== t.id)
          `uvm_error("MGR_DRV", $sformatf("RID %0h != expected %0h (beat %0d) for %s",
                                          vif.mgr_cb.rid, t.id, i, t.convert2string()))
        if (vif.mgr_cb.rlast !== (i == int'(t.len)))
          `uvm_error("MGR_DRV", $sformatf("RLAST=%b wrong on beat %0d for %s",
                                          vif.mgr_cb.rlast, i, t.convert2string()))
        t.data[i] = vif.mgr_cb.rdata;
        t.resp[i] = axi_resp_e'(vif.mgr_cb.rresp);
      end
      void'(r_q.pop_front());
      outstanding--;
      n_rd_done++;
    end
  endtask

  //---------------- helpers for tests ----------------
  // wait until all queued transactions completed (with hang watchdog)
  task wait_idle();
    int unsigned cycles = 0;
    while (outstanding != 0) begin
      @(vif.mgr_cb);
      if (++cycles > cfg.hang_timeout_cycles) begin
        dump();
        `uvm_fatal("MGR_DRV", $sformatf("wait_idle: %0d transactions still outstanding after %0d cycles",
                                        outstanding, cycles))
      end
    end
  endtask

  // debug feature: dump internal state
  function void dump();
    `uvm_info("MGR_DRV_DUMP", $sformatf("outstanding=%0d  aw_q=%0d w_q=%0d b_q=%0d ar_q=%0d r_q=%0d  done: wr=%0d rd=%0d",
              outstanding, aw_q.size(), w_q.size(), b_q.size(), ar_q.size(), r_q.size(),
              n_wr_done, n_rd_done), UVM_NONE)
    if (b_q.size() > 0) `uvm_info("MGR_DRV_DUMP", {"  waiting B for: ", b_q[0].convert2string()}, UVM_NONE)
    if (r_q.size() > 0) `uvm_info("MGR_DRV_DUMP", {"  waiting R for: ", r_q[0].convert2string()}, UVM_NONE)
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("MGR_DRV", $sformatf("completed %0d writes, %0d reads", n_wr_done, n_rd_done), UVM_LOW)
  endfunction
endclass
