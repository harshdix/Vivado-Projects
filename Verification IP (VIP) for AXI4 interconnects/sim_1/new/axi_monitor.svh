//------------------------------------------------------------------------------
// axi_monitor.svh  (included by axi_vip_pkg)
// Passive monitor (one class for any AXI4 interface, paper Sec. IV-A).
// Rebuilds complete transactions from the five channels and publishes each
// one on 'ap' when it finishes (write: at B handshake, read: at RLAST).
//
// All channels are processed in ONE loop per clock edge, in the order
// AW -> W -> pair -> B -> AR -> R, so same-cycle events never race.
// Responses are matched by ID, so it also works for designs that reorder
// across IDs.
//------------------------------------------------------------------------------
class axi_wburst;                     // W beats of one burst
  bit [AXI_DATA_W-1:0] data[$];
  bit [AXI_STRB_W-1:0] strb[$];
endclass

class axi_monitor extends uvm_monitor;
  `uvm_component_utils(axi_monitor)

  axi_cfg        cfg;
  virtual axi_if vif;

  uvm_analysis_port #(axi_seq_item) ap;

  axi_seq_item aw_q[$];       // AW seen, W not complete yet
  axi_wburst   w_bursts[$];   // complete W bursts, AW not seen yet
  axi_wburst   cur_w;         // W burst being collected
  axi_seq_item wr_wait_b[$];  // address+data done, waiting for B
  axi_seq_item rd_wait_r[$];  // AR seen, collecting R beats

  int unsigned n_wr, n_rd;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    if (cfg == null) `uvm_fatal("CFG", "axi_monitor: cfg not set by agent")
  endfunction

  task run_phase(uvm_phase phase);
    vif   = cfg.vif;
    cur_w = new();
    forever begin
      @(vif.mon_cb);
      if (vif.aresetn !== 1'b1) begin
        aw_q.delete(); w_bursts.delete(); wr_wait_b.delete(); rd_wait_r.delete();
        cur_w = new();
        continue;
      end
      sample_aw();
      sample_w();
      pair_writes();
      sample_b();
      sample_ar();
      sample_r();
    end
  endtask

  function void sample_aw();
    axi_seq_item t;
    if (!(vif.mon_cb.awvalid && vif.mon_cb.awready)) return;
    t = axi_seq_item::type_id::create("mon_wr");
    t.is_write   = 1'b1;
    t.id         = vif.mon_cb.awid;     t.addr  = vif.mon_cb.awaddr;
    t.len        = vif.mon_cb.awlen;    t.size  = vif.mon_cb.awsize;
    t.burst      = axi_burst_e'(vif.mon_cb.awburst);
    t.lock       = vif.mon_cb.awlock;   t.cache = vif.mon_cb.awcache;
    t.prot       = vif.mon_cb.awprot;
    t.start_time = $time;
    aw_q.push_back(t);
  endfunction

  function void sample_w();
    if (!(vif.mon_cb.wvalid && vif.mon_cb.wready)) return;
    cur_w.data.push_back(vif.mon_cb.wdata);
    cur_w.strb.push_back(vif.mon_cb.wstrb);
    if (vif.mon_cb.wlast) begin
      w_bursts.push_back(cur_w);
      cur_w = new();
    end
  endfunction

  function void pair_writes();
    axi_seq_item t;
    axi_wburst   b;
    while (aw_q.size() > 0 && w_bursts.size() > 0) begin
      t = aw_q.pop_front();
      b = w_bursts.pop_front();
      if (b.data.size() != int'(t.len) + 1)
        `uvm_error("MON", $sformatf("[%s] W burst has %0d beats, AWLEN says %0d: %s",
                   get_full_name(), b.data.size(), int'(t.len) + 1, t.convert2string()))
      t.data = new[b.data.size()];
      t.strb = new[b.strb.size()];
      foreach (b.data[i]) begin
        t.data[i] = b.data[i];
        t.strb[i] = b.strb[i];
      end
      wr_wait_b.push_back(t);
    end
  endfunction

  function void sample_b();
    int idx[$];
    axi_seq_item t;
    if (!(vif.mon_cb.bvalid && vif.mon_cb.bready)) return;
    idx = wr_wait_b.find_first_index(x) with (x.id == vif.mon_cb.bid);
    if (idx.size() == 0) begin
      `uvm_error("MON", $sformatf("[%s] B response id=%0h with no completed write waiting",
                 get_full_name(), vif.mon_cb.bid))
      return;
    end
    t = wr_wait_b[idx[0]];
    wr_wait_b.delete(idx[0]);
    t.resp     = new[1];
    t.resp[0]  = axi_resp_e'(vif.mon_cb.bresp);
    t.end_time = $time;
    publish(t);
  endfunction

  function void sample_ar();
    axi_seq_item t;
    if (!(vif.mon_cb.arvalid && vif.mon_cb.arready)) return;
    t = axi_seq_item::type_id::create("mon_rd");
    t.is_write   = 1'b0;
    t.id         = vif.mon_cb.arid;     t.addr  = vif.mon_cb.araddr;
    t.len        = vif.mon_cb.arlen;    t.size  = vif.mon_cb.arsize;
    t.burst      = axi_burst_e'(vif.mon_cb.arburst);
    t.lock       = vif.mon_cb.arlock;   t.cache = vif.mon_cb.arcache;
    t.prot       = vif.mon_cb.arprot;
    t.start_time = $time;
    rd_wait_r.push_back(t);
  endfunction

  function void sample_r();
    int idx[$];
    axi_seq_item t;
    int n;
    if (!(vif.mon_cb.rvalid && vif.mon_cb.rready)) return;
    idx = rd_wait_r.find_first_index(x) with (x.id == vif.mon_cb.rid);
    if (idx.size() == 0) begin
      `uvm_error("MON", $sformatf("[%s] R beat id=%0h with no outstanding read",
                 get_full_name(), vif.mon_cb.rid))
      return;
    end
    t = rd_wait_r[idx[0]];
    n = t.data.size();
    t.data    = new[n + 1](t.data);
    t.resp    = new[n + 1](t.resp);
    t.data[n] = vif.mon_cb.rdata;
    t.resp[n] = axi_resp_e'(vif.mon_cb.rresp);
    if (vif.mon_cb.rlast) begin
      if (n + 1 != int'(t.len) + 1)
        `uvm_error("MON", $sformatf("[%s] read got %0d beats, ARLEN says %0d: %s",
                   get_full_name(), n + 1, int'(t.len) + 1, t.convert2string()))
      rd_wait_r.delete(idx[0]);
      t.end_time = $time;
      publish(t);
    end
  endfunction

  function void publish(axi_seq_item t);
    if (t.is_write) n_wr++; else n_rd++;
    if (cfg.trace_txn)
      `uvm_info("MON", $sformatf("[%s] %s  (%0t -> %0t)", get_full_name(),
                t.convert2string(), t.start_time, t.end_time), UVM_LOW)
    ap.write(t);
  endfunction

  // debug feature: dump internal state
  function void dump();
    `uvm_info("MON_DUMP", $sformatf("[%s] aw_q=%0d w_bursts=%0d cur_w_beats=%0d wr_wait_b=%0d rd_wait_r=%0d",
              get_full_name(), aw_q.size(), w_bursts.size(), cur_w.data.size(),
              wr_wait_b.size(), rd_wait_r.size()), UVM_NONE)
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("MON", $sformatf("[%s] observed %0d writes, %0d reads", get_full_name(), n_wr, n_rd), UVM_LOW)
    if (aw_q.size() || w_bursts.size() || cur_w.data.size() || wr_wait_b.size() || rd_wait_r.size()) begin
      dump();
      `uvm_error("MON", "incomplete transactions at end of test")
    end
  endfunction
endclass
