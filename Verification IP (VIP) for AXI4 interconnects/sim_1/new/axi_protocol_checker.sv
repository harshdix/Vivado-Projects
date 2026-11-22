//------------------------------------------------------------------------------
// axi_protocol_checker.sv
// AXI4 / AXI4-Lite protocol checker (paper Sec. IV-D).
// A plain module with one port per AXI signal, so it can be attached with
// 'bind' to ANY AXI link in any RTL - including internal links that have no
// VIP agent on them. Rules follow ARM IHI0022 and the ARM AXI4 Protocol
// Assertions guide (DUI0534).
//
// 82 concurrent assertions for AXI4 (+6 more when LITE = 1):
//   - handshake : VALID held until READY, every payload signal stable while
//                 stalled, no X/Z on VALID / READY / payload   (5 channels)
//   - address   : reserved burst, size vs bus, WRAP length + alignment,
//                 FIXED length, 4 KB boundary, AxCACHE legality,
//                 exclusive length / size / alignment            (AW and AR)
//   - reset     : all VALIDs low during reset
//   - ordering  : WLAST on the right beat, B only after AW + last W,
//                 BID / RID match an outstanding request, RLAST on the right
//                 beat, EXOKAY only for exclusive accesses
//   - timeout   : no handshake stalls longer than MAX_WAIT cycles
// Failures are reported with `uvm_error, so they make the UVM test FAIL.
//
// Switches:
//   +AXI_ASSERT_OFF                      plusarg: all checkers off
//   uvm_config_db #(bit) "axi_assert_en" set by the test from cfg.enable_assertions
//   uvm_config_db #(bit) "axi_lite_mode" set by a Lite test: turns on Lite checks
//------------------------------------------------------------------------------
module axi_protocol_checker
  import axi_types_pkg::*;
#(
  parameter string NAME     = "AXI",
  parameter bit    LITE     = 0,
  parameter int    MAX_WAIT = 1000
)(
  input logic                  aclk,
  input logic                  aresetn,
  input logic [AXI_ID_W-1:0]   awid,
  input logic [AXI_ADDR_W-1:0] awaddr,
  input logic [7:0]            awlen,
  input logic [2:0]            awsize,
  input logic [1:0]            awburst,
  input logic                  awlock,
  input logic [3:0]            awcache,
  input logic [2:0]            awprot,
  input logic                  awvalid,
  input logic                  awready,
  input logic [AXI_DATA_W-1:0] wdata,
  input logic [AXI_STRB_W-1:0] wstrb,
  input logic                  wlast,
  input logic                  wvalid,
  input logic                  wready,
  input logic [AXI_ID_W-1:0]   bid,
  input logic [1:0]            bresp,
  input logic                  bvalid,
  input logic                  bready,
  input logic [AXI_ID_W-1:0]   arid,
  input logic [AXI_ADDR_W-1:0] araddr,
  input logic [7:0]            arlen,
  input logic [2:0]            arsize,
  input logic [1:0]            arburst,
  input logic                  arlock,
  input logic [3:0]            arcache,
  input logic [2:0]            arprot,
  input logic                  arvalid,
  input logic                  arready,
  input logic [AXI_ID_W-1:0]   rid,
  input logic [AXI_DATA_W-1:0] rdata,
  input logic [1:0]            rresp,
  input logic                  rlast,
  input logic                  rvalid,
  input logic                  rready
);
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  //---------------- enable switch ----------------
  bit en = 1'b1;
  initial if ($test$plusargs("AXI_ASSERT_OFF")) en = 1'b0;
  // the test publishes cfg.enable_assertions during build (before reset ends)
  always @(posedge aresetn) begin
    bit v;
    if (!$test$plusargs("AXI_ASSERT_OFF") &&
        uvm_config_db #(bit)::get(null, "", "axi_assert_en", v))
      en = v;
  end

  // Lite-only checks: on if LITE = 1, or if the test sets "axi_lite_mode"
  bit lite_rt = 1'b0;
  always @(posedge aresetn) begin
    bit v;
    if (uvm_config_db #(bit)::get(null, "", "axi_lite_mode", v)) lite_rt = v;
  end

  // cycle counter so the reset check skips the first edges (signals still X)
  int unsigned cyc = 0;
  always @(posedge aclk) if (cyc < 3) cyc++;

  //---------------- helper functions ----------------
  function automatic bit f_aligned(bit [AXI_ADDR_W-1:0] a, bit [2:0] size);
    longint unsigned nb = longint'(1) << size;
    return (longint'(a) % nb) == 0;
  endfunction

  function automatic bit f_cross4k(bit [AXI_ADDR_W-1:0] a, bit [7:0] len,
                                   bit [2:0] size, bit [1:0] burst);
    longint unsigned nb    = longint'(1) << size;
    longint unsigned start = (longint'(a) / nb) * nb;
    longint unsigned last  = start + nb * (longint'(len) + 1) - 1;
    if (burst != 2'b01) return 1'b0;            // only INCR bursts can cross
    return (last >> 12) != (longint'(a) >> 12);
  endfunction

  function automatic bit f_excl_pow2(bit [7:0] len, bit [2:0] size);
    longint unsigned total = (longint'(len) + 1) << size;
    return total inside {1, 2, 4, 8, 16, 32, 64, 128};
  endfunction

  function automatic bit f_excl_aligned(bit [AXI_ADDR_W-1:0] a, bit [7:0] len, bit [2:0] size);
    longint unsigned total = (longint'(len) + 1) << size;
    return (longint'(a) % total) == 0;
  endfunction

  //---------------- transaction model (for the ordering checks) -------------
  // Updated at each rising edge. Responses are processed BEFORE requests of
  // the same edge, so a response in the same cycle as its request is flagged.
  // Each e_* flag is high for one cycle and is checked by an assertion below.
  typedef struct { bit [AXI_ID_W-1:0] id; bit [7:0] len; bit lock; int beats; } rd_t;
  typedef struct { bit [AXI_ID_W-1:0] id; bit [7:0] len; bit lock; }            aw_t;
  typedef struct { bit [AXI_ID_W-1:0] id; bit lock; }                           wd_t;

  aw_t         aw_q[$];        // AW seen, W burst not complete yet
  int unsigned wburst_q[$];    // beat counts of complete W bursts, AW not seen yet
  int unsigned w_cnt;          // beats of the W burst in progress
  wd_t         wr_done[$];     // AW + last W done, waiting for B
  rd_t         rd_q[$];        // AR seen, waiting for R

  bit e_wlast, e_w_overrun, e_b_early, e_b_exokay, e_r_unexp, e_rlast, e_r_exokay;
  int unsigned     stall_aw, stall_w, stall_b, stall_ar, stall_r;
  longint unsigned n_aw, n_w, n_b, n_ar, n_r;   // handshakes checked

  always @(posedge aclk) begin
    int idx;
    aw_t a;
    int unsigned n;
    e_wlast = 0; e_w_overrun = 0; e_b_early = 0; e_b_exokay = 0;
    e_r_unexp = 0; e_rlast = 0; e_r_exokay = 0;
    if (aresetn !== 1'b1) begin
      aw_q.delete(); wburst_q.delete(); wr_done.delete(); rd_q.delete();
      w_cnt = 0;
      stall_aw = 0; stall_w = 0; stall_b = 0; stall_ar = 0; stall_r = 0;
    end else begin
      // ---- stall counters ----
      stall_aw = (awvalid && !awready) ? stall_aw + 1 : 0;
      stall_w  = (wvalid  && !wready ) ? stall_w  + 1 : 0;
      stall_b  = (bvalid  && !bready ) ? stall_b  + 1 : 0;
      stall_ar = (arvalid && !arready) ? stall_ar + 1 : 0;
      stall_r  = (rvalid  && !rready ) ? stall_r  + 1 : 0;

      // ---- B: must match a completed write ----
      if (bvalid && bready) begin
        n_b++;
        idx = -1;
        for (int i = 0; i < wr_done.size(); i++)
          if (wr_done[i].id == bid) begin idx = i; break; end
        if (idx < 0) e_b_early = 1;
        else begin
          if (bresp == 2'b01 && !wr_done[idx].lock) e_b_exokay = 1;
          wr_done.delete(idx);
        end
      end

      // ---- R: must match an outstanding read, RLAST on the right beat ----
      if (rvalid && rready) begin
        n_r++;
        idx = -1;
        for (int i = 0; i < rd_q.size(); i++)
          if (rd_q[i].id == rid) begin idx = i; break; end
        if (idx < 0) e_r_unexp = 1;
        else begin
          rd_t r;
          r = rd_q[idx];
          r.beats++;
          if (rlast != (r.beats == int'(r.len) + 1)) e_rlast = 1;
          if (rresp == 2'b01 && !r.lock) e_r_exokay = 1;
          if (rlast || r.beats >= int'(r.len) + 1) rd_q.delete(idx);
          else                                     rd_q[idx] = r;
        end
      end

      // ---- AW ----
      if (awvalid && awready) begin
        n_aw++;
        a.id = awid; a.len = awlen; a.lock = awlock;
        aw_q.push_back(a);
      end

      // ---- W ----
      if (wvalid && wready) begin
        n_w++;
        w_cnt++;
        if (wlast) begin
          wburst_q.push_back(w_cnt);
          w_cnt = 0;
        end else if (w_cnt >= 256) begin
          e_w_overrun = 1;
          w_cnt = 0;
        end
      end

      // ---- pair AW with W bursts (in order) -> write complete ----
      while (aw_q.size() > 0 && wburst_q.size() > 0) begin
        wd_t d;
        a = aw_q.pop_front();
        n = wburst_q.pop_front();
        if (n != int'(a.len) + 1) e_wlast = 1;
        d.id = a.id; d.lock = a.lock;
        wr_done.push_back(d);
      end

      // ---- AR ----
      if (arvalid && arready) begin
        rd_t r;
        n_ar++;
        r.id = arid; r.len = arlen; r.lock = arlock; r.beats = 0;
        rd_q.push_back(r);
      end
    end
  end

  //============================ ASSERTIONS ===================================

  //---------------- AW channel: handshake, stability, X ----------------
  a_aw_valid_stable: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (awvalid && !awready) |=> awvalid)
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_aw_valid_stable: AWVALID deasserted before AWREADY", NAME))
  a_aw_awid_stable: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (awvalid && !awready) |=> $stable(awid))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_aw_awid_stable: AWID changed while AWVALID=1 and AWREADY=0", NAME))
  a_aw_awaddr_stable: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (awvalid && !awready) |=> $stable(awaddr))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_aw_awaddr_stable: AWADDR changed while AWVALID=1 and AWREADY=0", NAME))
  a_aw_awlen_stable: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (awvalid && !awready) |=> $stable(awlen))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_aw_awlen_stable: AWLEN changed while AWVALID=1 and AWREADY=0", NAME))
  a_aw_awsize_stable: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (awvalid && !awready) |=> $stable(awsize))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_aw_awsize_stable: AWSIZE changed while AWVALID=1 and AWREADY=0", NAME))
  a_aw_awburst_stable: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (awvalid && !awready) |=> $stable(awburst))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_aw_awburst_stable: AWBURST changed while AWVALID=1 and AWREADY=0", NAME))
  a_aw_awlock_stable: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (awvalid && !awready) |=> $stable(awlock))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_aw_awlock_stable: AWLOCK changed while AWVALID=1 and AWREADY=0", NAME))
  a_aw_awcache_stable: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (awvalid && !awready) |=> $stable(awcache))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_aw_awcache_stable: AWCACHE changed while AWVALID=1 and AWREADY=0", NAME))
  a_aw_awprot_stable: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (awvalid && !awready) |=> $stable(awprot))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_aw_awprot_stable: AWPROT changed while AWVALID=1 and AWREADY=0", NAME))
  a_aw_valid_x: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      !$isunknown(awvalid))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_aw_valid_x: AWVALID is X/Z", NAME))
  a_aw_ready_x: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      !$isunknown(awready))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_aw_ready_x: AWREADY is X/Z", NAME))
  a_aw_payload_x: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      awvalid |-> !$isunknown({awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot}))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_aw_payload_x: X/Z on AW payload while AWVALID=1", NAME))

  //---------------- AW channel: burst / size / cache / exclusive rules ----------------
  a_aw_burst_rsvd: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      awvalid |-> (awburst != 2'b11))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_aw_burst_rsvd: reserved AWBURST value 2'b11", NAME))
  a_aw_size_bus: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      awvalid |-> (awsize <= AXI_MAX_SIZE))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_aw_size_bus: AWSIZE wider than the data bus", NAME))
  a_aw_wrap_len: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (awvalid && awburst == 2'b10) |-> (awlen inside {1, 3, 7, 15}))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_aw_wrap_len: WRAP burst length must be 2, 4, 8 or 16", NAME))
  a_aw_wrap_align: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (awvalid && awburst == 2'b10) |-> f_aligned(awaddr, awsize))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_aw_wrap_align: WRAP burst start address not aligned to AWSIZE", NAME))
  a_aw_fixed_len: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (awvalid && awburst == 2'b00) |-> (awlen <= 15))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_aw_fixed_len: FIXED burst longer than 16 beats", NAME))
  a_aw_4kb: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      awvalid |-> !f_cross4k(awaddr, awlen, awsize, awburst))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_aw_4kb: INCR burst crosses a 4 KB boundary", NAME))
  a_aw_cache: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      awvalid |-> !((awcache[3:2] != 2'b00) && !awcache[1]))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_aw_cache: illegal AWCACHE (bits[3:2] set without Modifiable bit[1])", NAME))
  a_aw_excl_len: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (awvalid && awlock) |-> (awlen <= 15))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_aw_excl_len: exclusive burst longer than 16 beats", NAME))
  a_aw_excl_bytes: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (awvalid && awlock) |-> f_excl_pow2(awlen, awsize))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_aw_excl_bytes: exclusive transfer size not a power of 2 up to 128 bytes", NAME))
  a_aw_excl_align: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (awvalid && awlock) |-> f_excl_aligned(awaddr, awlen, awsize))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_aw_excl_align: exclusive address not aligned to total transfer size", NAME))

  //---------------- W channel: handshake, stability, X ----------------
  a_w_valid_stable: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (wvalid && !wready) |=> wvalid)
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_w_valid_stable: WVALID deasserted before WREADY", NAME))
  a_w_wdata_stable: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (wvalid && !wready) |=> $stable(wdata))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_w_wdata_stable: WDATA changed while WVALID=1 and WREADY=0", NAME))
  a_w_wstrb_stable: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (wvalid && !wready) |=> $stable(wstrb))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_w_wstrb_stable: WSTRB changed while WVALID=1 and WREADY=0", NAME))
  a_w_wlast_stable: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (wvalid && !wready) |=> $stable(wlast))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_w_wlast_stable: WLAST changed while WVALID=1 and WREADY=0", NAME))
  a_w_valid_x: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      !$isunknown(wvalid))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_w_valid_x: WVALID is X/Z", NAME))
  a_w_ready_x: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      !$isunknown(wready))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_w_ready_x: WREADY is X/Z", NAME))
  a_w_payload_x: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      wvalid |-> !$isunknown({wdata, wstrb, wlast}))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_w_payload_x: X/Z on W payload while WVALID=1", NAME))

  //---------------- B channel: handshake, stability, X ----------------
  a_b_valid_stable: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (bvalid && !bready) |=> bvalid)
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_b_valid_stable: BVALID deasserted before BREADY", NAME))
  a_b_bid_stable: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (bvalid && !bready) |=> $stable(bid))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_b_bid_stable: BID changed while BVALID=1 and BREADY=0", NAME))
  a_b_bresp_stable: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (bvalid && !bready) |=> $stable(bresp))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_b_bresp_stable: BRESP changed while BVALID=1 and BREADY=0", NAME))
  a_b_valid_x: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      !$isunknown(bvalid))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_b_valid_x: BVALID is X/Z", NAME))
  a_b_ready_x: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      !$isunknown(bready))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_b_ready_x: BREADY is X/Z", NAME))
  a_b_payload_x: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      bvalid |-> !$isunknown({bid, bresp}))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_b_payload_x: X/Z on B payload while BVALID=1", NAME))

  //---------------- AR channel: handshake, stability, X ----------------
  a_ar_valid_stable: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (arvalid && !arready) |=> arvalid)
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_ar_valid_stable: ARVALID deasserted before ARREADY", NAME))
  a_ar_arid_stable: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (arvalid && !arready) |=> $stable(arid))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_ar_arid_stable: ARID changed while ARVALID=1 and ARREADY=0", NAME))
  a_ar_araddr_stable: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (arvalid && !arready) |=> $stable(araddr))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_ar_araddr_stable: ARADDR changed while ARVALID=1 and ARREADY=0", NAME))
  a_ar_arlen_stable: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (arvalid && !arready) |=> $stable(arlen))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_ar_arlen_stable: ARLEN changed while ARVALID=1 and ARREADY=0", NAME))
  a_ar_arsize_stable: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (arvalid && !arready) |=> $stable(arsize))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_ar_arsize_stable: ARSIZE changed while ARVALID=1 and ARREADY=0", NAME))
  a_ar_arburst_stable: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (arvalid && !arready) |=> $stable(arburst))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_ar_arburst_stable: ARBURST changed while ARVALID=1 and ARREADY=0", NAME))
  a_ar_arlock_stable: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (arvalid && !arready) |=> $stable(arlock))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_ar_arlock_stable: ARLOCK changed while ARVALID=1 and ARREADY=0", NAME))
  a_ar_arcache_stable: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (arvalid && !arready) |=> $stable(arcache))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_ar_arcache_stable: ARCACHE changed while ARVALID=1 and ARREADY=0", NAME))
  a_ar_arprot_stable: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (arvalid && !arready) |=> $stable(arprot))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_ar_arprot_stable: ARPROT changed while ARVALID=1 and ARREADY=0", NAME))
  a_ar_valid_x: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      !$isunknown(arvalid))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_ar_valid_x: ARVALID is X/Z", NAME))
  a_ar_ready_x: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      !$isunknown(arready))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_ar_ready_x: ARREADY is X/Z", NAME))
  a_ar_payload_x: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      arvalid |-> !$isunknown({arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot}))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_ar_payload_x: X/Z on AR payload while ARVALID=1", NAME))

  //---------------- AR channel: burst / size / cache / exclusive rules ----------------
  a_ar_burst_rsvd: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      arvalid |-> (arburst != 2'b11))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_ar_burst_rsvd: reserved ARBURST value 2'b11", NAME))
  a_ar_size_bus: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      arvalid |-> (arsize <= AXI_MAX_SIZE))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_ar_size_bus: ARSIZE wider than the data bus", NAME))
  a_ar_wrap_len: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (arvalid && arburst == 2'b10) |-> (arlen inside {1, 3, 7, 15}))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_ar_wrap_len: WRAP burst length must be 2, 4, 8 or 16", NAME))
  a_ar_wrap_align: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (arvalid && arburst == 2'b10) |-> f_aligned(araddr, arsize))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_ar_wrap_align: WRAP burst start address not aligned to ARSIZE", NAME))
  a_ar_fixed_len: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (arvalid && arburst == 2'b00) |-> (arlen <= 15))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_ar_fixed_len: FIXED burst longer than 16 beats", NAME))
  a_ar_4kb: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      arvalid |-> !f_cross4k(araddr, arlen, arsize, arburst))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_ar_4kb: INCR burst crosses a 4 KB boundary", NAME))
  a_ar_cache: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      arvalid |-> !((arcache[3:2] != 2'b00) && !arcache[1]))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_ar_cache: illegal ARCACHE (bits[3:2] set without Modifiable bit[1])", NAME))
  a_ar_excl_len: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (arvalid && arlock) |-> (arlen <= 15))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_ar_excl_len: exclusive burst longer than 16 beats", NAME))
  a_ar_excl_bytes: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (arvalid && arlock) |-> f_excl_pow2(arlen, arsize))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_ar_excl_bytes: exclusive transfer size not a power of 2 up to 128 bytes", NAME))
  a_ar_excl_align: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (arvalid && arlock) |-> f_excl_aligned(araddr, arlen, arsize))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_ar_excl_align: exclusive address not aligned to total transfer size", NAME))

  //---------------- R channel: handshake, stability, X ----------------
  a_r_valid_stable: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (rvalid && !rready) |=> rvalid)
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_r_valid_stable: RVALID deasserted before RREADY", NAME))
  a_r_rid_stable: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (rvalid && !rready) |=> $stable(rid))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_r_rid_stable: RID changed while RVALID=1 and RREADY=0", NAME))
  a_r_rdata_stable: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (rvalid && !rready) |=> $stable(rdata))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_r_rdata_stable: RDATA changed while RVALID=1 and RREADY=0", NAME))
  a_r_rresp_stable: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (rvalid && !rready) |=> $stable(rresp))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_r_rresp_stable: RRESP changed while RVALID=1 and RREADY=0", NAME))
  a_r_rlast_stable: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      (rvalid && !rready) |=> $stable(rlast))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_r_rlast_stable: RLAST changed while RVALID=1 and RREADY=0", NAME))
  a_r_valid_x: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      !$isunknown(rvalid))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_r_valid_x: RVALID is X/Z", NAME))
  a_r_ready_x: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      !$isunknown(rready))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_r_ready_x: RREADY is X/Z", NAME))
  a_r_payload_x: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      rvalid |-> !$isunknown({rid, rdata, rresp, rlast}))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_r_payload_x: X/Z on R payload while RVALID=1", NAME))

  //---------------- reset: all VALIDs low while ARESETn is low ----------------
  a_rst_awvalid: assert property (@(posedge aclk) disable iff (!en)
      (!aresetn && cyc >= 2) |-> !awvalid)
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_rst_awvalid: AWVALID high during reset", NAME))
  a_rst_wvalid: assert property (@(posedge aclk) disable iff (!en)
      (!aresetn && cyc >= 2) |-> !wvalid)
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_rst_wvalid: WVALID high during reset", NAME))
  a_rst_bvalid: assert property (@(posedge aclk) disable iff (!en)
      (!aresetn && cyc >= 2) |-> !bvalid)
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_rst_bvalid: BVALID high during reset", NAME))
  a_rst_arvalid: assert property (@(posedge aclk) disable iff (!en)
      (!aresetn && cyc >= 2) |-> !arvalid)
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_rst_arvalid: ARVALID high during reset", NAME))
  a_rst_rvalid: assert property (@(posedge aclk) disable iff (!en)
      (!aresetn && cyc >= 2) |-> !rvalid)
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_rst_rvalid: RVALID high during reset", NAME))

  //---------------- transaction ordering (flags come from the model above) ----------------
  a_w_wlast: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      !e_wlast)
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_w_wlast: WLAST not on the beat given by AWLEN", NAME))
  a_w_overrun: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      !e_w_overrun)
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_w_overrun: more than 256 W beats without WLAST", NAME))
  a_b_early: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      !e_b_early)
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_b_early: B response with no completed write (AW + last W) for that BID", NAME))
  a_b_exokay: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      !e_b_exokay)
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_b_exokay: EXOKAY on B for a non-exclusive write", NAME))
  a_r_unexpected: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      !e_r_unexp)
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_r_unexpected: R beat with no outstanding read for that RID", NAME))
  a_r_rlast: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      !e_rlast)
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_r_rlast: RLAST not on the beat given by ARLEN", NAME))
  a_r_exokay: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      !e_r_exokay)
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_r_exokay: EXOKAY on R for a non-exclusive read", NAME))

  //---------------- handshake timeout: VALID waiting longer than MAX_WAIT cycles ----------------
  a_aw_timeout: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      stall_aw <= MAX_WAIT)
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_aw_timeout: AWVALID waited more than MAX_WAIT cycles for AWREADY", NAME))
  a_w_timeout: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      stall_w <= MAX_WAIT)
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_w_timeout: WVALID waited more than MAX_WAIT cycles for WREADY", NAME))
  a_b_timeout: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      stall_b <= MAX_WAIT)
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_b_timeout: BVALID waited more than MAX_WAIT cycles for BREADY", NAME))
  a_ar_timeout: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      stall_ar <= MAX_WAIT)
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_ar_timeout: ARVALID waited more than MAX_WAIT cycles for ARREADY", NAME))
  a_r_timeout: assert property (@(posedge aclk) disable iff (!aresetn || !en)
      stall_r <= MAX_WAIT)
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_r_timeout: RVALID waited more than MAX_WAIT cycles for RREADY", NAME))

  //---------------- AXI4-Lite only (LITE = 1 or "axi_lite_mode" set) ----------------
  a_lite_awlen: assert property (@(posedge aclk) disable iff (!aresetn || !en || !(LITE || lite_rt))
      awvalid |-> (awlen == 0))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_lite_awlen: AXI4-Lite allows single-beat writes only", NAME))
  a_lite_arlen: assert property (@(posedge aclk) disable iff (!aresetn || !en || !(LITE || lite_rt))
      arvalid |-> (arlen == 0))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_lite_arlen: AXI4-Lite allows single-beat reads only", NAME))
  a_lite_awlock: assert property (@(posedge aclk) disable iff (!aresetn || !en || !(LITE || lite_rt))
      awvalid |-> !awlock)
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_lite_awlock: AXI4-Lite has no exclusive accesses", NAME))
  a_lite_arlock: assert property (@(posedge aclk) disable iff (!aresetn || !en || !(LITE || lite_rt))
      arvalid |-> !arlock)
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_lite_arlock: AXI4-Lite has no exclusive accesses", NAME))
  a_lite_bresp: assert property (@(posedge aclk) disable iff (!aresetn || !en || !(LITE || lite_rt))
      bvalid |-> (bresp != 2'b01))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_lite_bresp: EXOKAY is not allowed in AXI4-Lite", NAME))
  a_lite_rresp: assert property (@(posedge aclk) disable iff (!aresetn || !en || !(LITE || lite_rt))
      rvalid |-> (rresp != 2'b01))
    else `uvm_error("AXI_CHK", $sformatf("[%s] a_lite_rresp: EXOKAY is not allowed in AXI4-Lite", NAME))

  //---------------- summary (debug feature) ----------------
  final
    $display("[%s] protocol checker %s%s: handshakes checked AW=%0d W=%0d B=%0d AR=%0d R=%0d | still open: wr=%0d rd=%0d",
             NAME, en ? "ON" : "OFF", (LITE || lite_rt) ? " (AXI4-Lite rules on)" : "", n_aw, n_w, n_b, n_ar, n_r,
             aw_q.size() + wr_done.size(), rd_q.size());

endmodule
