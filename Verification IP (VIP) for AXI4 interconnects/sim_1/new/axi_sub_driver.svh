//------------------------------------------------------------------------------
// axi_sub_driver.svh  (included by axi_vip_pkg)
// SUBORDINATE driver: a reactive AXI4 memory.
//  - random AWREADY / WREADY / ARREADY back-pressure (cfg.max_ready_delay)
//  - byte-addressed sparse memory model, FIXED / INCR / WRAP via axi_utils
//  - W beats may arrive before their AW (buffered)
//  - exclusive monitor: exclusive read reserves, exclusive write returns
//    EXOKAY (and writes) only if the reservation is still intact
//  - random B / R latencies and R beat gaps
//------------------------------------------------------------------------------
class axi_sub_driver extends uvm_component;
  `uvm_component_utils(axi_sub_driver)

  axi_cfg        cfg;
  virtual axi_if vif;

  typedef struct {
    bit [AXI_DATA_W-1:0] data;
    bit [AXI_STRB_W-1:0] strb;
    bit                  last;
  } wbeat_t;

  typedef struct {
    bit [AXI_ADDR_W-1:0] addr;
    bit [7:0]            len;
    bit [2:0]            size;
  } excl_t;

  axi_seq_item aw_q[$];     // accepted AW, waiting for W data
  wbeat_t      w_beats[$];  // accepted W beats
  axi_seq_item b_q[$];      // writes done, waiting to send B
  axi_seq_item ar_q[$];     // accepted AR, waiting to send R

  bit [7:0]    mem      [bit [AXI_ADDR_W-1:0]];
  excl_t       excl_res [bit [AXI_ID_W-1:0]];

  int unsigned n_wr, n_rd, n_excl_ok, n_excl_fail;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    if (cfg == null) `uvm_fatal("CFG", "axi_sub_driver: cfg not set by agent")
  endfunction

  task run_phase(uvm_phase phase);
    vif = cfg.vif;
    vif.sub_cb.awready <= 1'b0;
    vif.sub_cb.wready  <= 1'b0;
    vif.sub_cb.arready <= 1'b0;
    vif.sub_cb.bvalid  <= 1'b0;
    vif.sub_cb.rvalid  <= 1'b0;
    wait (vif.aresetn === 1'b1);
    @(vif.sub_cb);
    fork
      aw_accept();
      w_accept();
      write_proc();
      b_drive();
      ar_accept();
      r_drive();
    join
  endtask

  //---------------- memory model ----------------
  function bit [7:0] mem_rd_byte(bit [AXI_ADDR_W-1:0] a);
    if (mem.exists(a)) return mem[a];
    return a[7:0] ^ 8'h5A;              // deterministic content for unwritten bytes
  endfunction

  function bit [AXI_ADDR_W-1:0] bus_base(bit [AXI_ADDR_W-1:0] a);
    return a & ~(AXI_ADDR_W'(AXI_STRB_W - 1));
  endfunction

  function void do_write(axi_seq_item t, wbeat_t beats[$]);
    bit [AXI_ADDR_W-1:0] base;
    for (int i = 0; i < beats.size(); i++) begin
      base = bus_base(axi_beat_addr(t.addr, t.len, t.size, t.burst, i));
      for (int k = 0; k < AXI_STRB_W; k++)
        if (beats[i].strb[k]) mem[base + k] = beats[i].data[8*k +: 8];
    end
  endfunction

  function bit [AXI_DATA_W-1:0] read_beat(axi_seq_item t, int i);
    bit [AXI_DATA_W-1:0] d    = '0;
    bit [AXI_STRB_W-1:0] mask = axi_lane_mask(t.addr, t.len, t.size, t.burst, i);
    bit [AXI_ADDR_W-1:0] base = bus_base(axi_beat_addr(t.addr, t.len, t.size, t.burst, i));
    for (int k = 0; k < AXI_STRB_W; k++)
      if (mask[k]) d[8*k +: 8] = mem_rd_byte(base + k);
    return d;
  endfunction

  // a normal write to a reserved region breaks the reservation
  function void clear_overlapping(axi_seq_item t);
    bit [AXI_ID_W-1:0] kill[$];
    longint unsigned w_lo = t.addr;
    longint unsigned w_hi = w_lo + ((longint'(t.len) + 1) << t.size);
    foreach (excl_res[id]) begin
      longint unsigned r_lo = excl_res[id].addr;
      longint unsigned r_hi = r_lo + ((longint'(excl_res[id].len) + 1) << excl_res[id].size);
      if (w_lo < r_hi && r_lo < w_hi) kill.push_back(id);
    end
    foreach (kill[i]) excl_res.delete(kill[i]);
  endfunction

  //---------------- AW / W / AR acceptance with random back-pressure -------
  task aw_accept();
    axi_seq_item t;
    int unsigned n;
    forever begin
      n = $urandom_range(0, cfg.max_ready_delay);
      if (n > 0) begin vif.sub_cb.awready <= 1'b0; repeat (n) @(vif.sub_cb); end
      vif.sub_cb.awready <= 1'b1;
      @(vif.sub_cb);
      while (!vif.sub_cb.awvalid) @(vif.sub_cb);
      t = axi_seq_item::type_id::create("sub_aw");
      t.is_write = 1'b1;
      t.id    = vif.sub_cb.awid;    t.addr  = vif.sub_cb.awaddr;
      t.len   = vif.sub_cb.awlen;   t.size  = vif.sub_cb.awsize;
      t.burst = axi_burst_e'(vif.sub_cb.awburst);
      t.lock  = vif.sub_cb.awlock;  t.cache = vif.sub_cb.awcache;
      t.prot  = vif.sub_cb.awprot;
      aw_q.push_back(t);
    end
  endtask

  task w_accept();
    wbeat_t b;
    int unsigned n;
    forever begin
      n = $urandom_range(0, cfg.max_ready_delay);
      if (n > 0) begin vif.sub_cb.wready <= 1'b0; repeat (n) @(vif.sub_cb); end
      vif.sub_cb.wready <= 1'b1;
      @(vif.sub_cb);
      while (!vif.sub_cb.wvalid) @(vif.sub_cb);
      b.data = vif.sub_cb.wdata;
      b.strb = vif.sub_cb.wstrb;
      b.last = vif.sub_cb.wlast;
      w_beats.push_back(b);
    end
  endtask

  task ar_accept();
    axi_seq_item t;
    int unsigned n;
    forever begin
      n = $urandom_range(0, cfg.max_ready_delay);
      if (n > 0) begin vif.sub_cb.arready <= 1'b0; repeat (n) @(vif.sub_cb); end
      vif.sub_cb.arready <= 1'b1;
      @(vif.sub_cb);
      while (!vif.sub_cb.arvalid) @(vif.sub_cb);
      t = axi_seq_item::type_id::create("sub_ar");
      t.is_write = 1'b0;
      t.id    = vif.sub_cb.arid;    t.addr  = vif.sub_cb.araddr;
      t.len   = vif.sub_cb.arlen;   t.size  = vif.sub_cb.arsize;
      t.burst = axi_burst_e'(vif.sub_cb.arburst);
      t.lock  = vif.sub_cb.arlock;  t.cache = vif.sub_cb.arcache;
      t.prot  = vif.sub_cb.arprot;
      ar_q.push_back(t);
    end
  endtask

  //---------------- pair AW with its W beats, update memory ----------------
  task write_proc();
    axi_seq_item t;
    wbeat_t      beats[$];
    forever begin
      while (aw_q.size() == 0) @(vif.sub_cb);
      t = aw_q.pop_front();
      beats.delete();
      for (int i = 0; i <= int'(t.len); i++) begin
        while (w_beats.size() == 0) @(vif.sub_cb);
        beats.push_back(w_beats.pop_front());
        if (beats[i].last != (i == int'(t.len)))
          `uvm_error("SUB_DRV", $sformatf("WLAST=%b on beat %0d, expected %b for %s",
                     beats[i].last, i, (i == int'(t.len)), t.convert2string()))
      end
      t.resp = new[1];
      if (t.lock) begin
        if (excl_res.exists(t.id) && excl_res[t.id].addr == t.addr &&
            excl_res[t.id].len == t.len && excl_res[t.id].size == t.size) begin
          do_write(t, beats);
          t.resp[0] = RESP_EXOKAY;
          excl_res.delete(t.id);
          n_excl_ok++;
        end else begin
          t.resp[0] = RESP_OKAY;          // exclusive failed: memory NOT updated
          n_excl_fail++;
        end
      end else begin
        do_write(t, beats);
        t.resp[0] = RESP_OKAY;
        clear_overlapping(t);
      end
      b_q.push_back(t);
      n_wr++;
    end
  endtask

  //---------------- B channel ----------------
  task b_drive();
    axi_seq_item t;
    int unsigned d;
    forever begin
      while (b_q.size() == 0) begin vif.sub_cb.bvalid <= 1'b0; @(vif.sub_cb); end
      t = b_q.pop_front();
      d = $urandom_range(0, cfg.max_resp_delay);
      if (d > 0) begin vif.sub_cb.bvalid <= 1'b0; repeat (d) @(vif.sub_cb); end
      vif.sub_cb.bid    <= t.id;
      vif.sub_cb.bresp  <= t.resp[0];
      vif.sub_cb.bvalid <= 1'b1;
      @(vif.sub_cb);
      while (!vif.sub_cb.bready) @(vif.sub_cb);
    end
  endtask

  //---------------- R channel (in order) ----------------
  task r_drive();
    axi_seq_item t;
    int unsigned d, g;
    forever begin
      while (ar_q.size() == 0) begin vif.sub_cb.rvalid <= 1'b0; @(vif.sub_cb); end
      t = ar_q.pop_front();
      if (t.lock) excl_res[t.id] = '{addr: t.addr, len: t.len, size: t.size};
      d = $urandom_range(0, cfg.max_resp_delay);
      if (d > 0) begin vif.sub_cb.rvalid <= 1'b0; repeat (d) @(vif.sub_cb); end
      for (int i = 0; i <= int'(t.len); i++) begin
        if (i > 0) begin
          g = $urandom_range(0, cfg.max_beat_gap);
          if (g > 0) begin vif.sub_cb.rvalid <= 1'b0; repeat (g) @(vif.sub_cb); end
        end
        vif.sub_cb.rid    <= t.id;
        vif.sub_cb.rdata  <= read_beat(t, i);
        vif.sub_cb.rresp  <= t.lock ? RESP_EXOKAY : RESP_OKAY;
        vif.sub_cb.rlast  <= (i == int'(t.len));
        vif.sub_cb.rvalid <= 1'b1;
        @(vif.sub_cb);
        while (!vif.sub_cb.rready) @(vif.sub_cb);
      end
      n_rd++;
    end
  endtask

  // debug feature: dump internal state
  function void dump();
    `uvm_info("SUB_DRV_DUMP", $sformatf("aw_q=%0d w_beats=%0d b_q=%0d ar_q=%0d mem_bytes=%0d excl_res=%0d",
              aw_q.size(), w_beats.size(), b_q.size(), ar_q.size(), mem.num(), excl_res.num()), UVM_NONE)
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("SUB_DRV", $sformatf("served %0d writes, %0d reads | exclusive writes: %0d EXOKAY, %0d failed | %0d bytes in memory",
              n_wr, n_rd, n_excl_ok, n_excl_fail, mem.num()), UVM_LOW)
    if (aw_q.size() || w_beats.size() || b_q.size() || ar_q.size()) begin
      dump();
      `uvm_error("SUB_DRV", "unfinished transactions at end of test")
    end
  endfunction
endclass
