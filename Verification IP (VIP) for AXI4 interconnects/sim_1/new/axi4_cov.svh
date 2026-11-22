//------------------------------------------------------------------------------
// axi4_cov.svh  (included by axi_vip_pkg)
// AXI4 functional coverage collector (paper Sec. IV-C, Table I).
// One covergroup per channel -> per-channel coverage like Table I.
// 23 coverage items in total:
//   AW (9) : id, len, size, burst, lock, cache, prot, burst x len, lock x burst
//   AR (9) : same as AW
//   W  (1) : ordering of W data vs AW (data first / same cycle / address first)
//   B  (2) : bid, bresp
//   R  (2) : rid, rresp
// Address, data and strobe are NOT covered: their meaning depends on the DUT,
// so (as in the paper) that coverage belongs in the DUT testbench.
//
// Expected result on the 128-bit queue: size bins 32B/64B/128B can never be
// hit (bus is 16 bytes) -> AW and AR = (8 + 5/8) / 9 = 95.83 %.
//------------------------------------------------------------------------------
class axi4_cov extends uvm_subscriber #(axi_seq_item);
  `uvm_component_utils(axi4_cov)

  // sampled values
  bit [AXI_ID_W-1:0] id;
  bit [7:0]          len;
  bit [2:0]          size;
  bit [1:0]          burst;
  bit                lock;
  bit [3:0]          cache;
  bit [2:0]          prot;
  bit [1:0]          resp;
  int                w_order;

  int unsigned n_wr, n_rd;

  //---------------- write address ----------------
  covergroup cg_aw;
    option.per_instance = 1;
    cp_id      : coverpoint id;
    cp_len     : coverpoint len   { bins l[] = {[0:255]}; }
    cp_len_bkt : coverpoint len   { option.weight = 0;           // only used by the cross
                                    bins b_one   = {0};
                                    bins b_short = {[1:15]};
                                    bins b_long  = {[16:255]}; }
    cp_size    : coverpoint size  { bins s[] = {[0:7]}; }
    cp_burst   : coverpoint burst { bins fixed = {0}; bins incr = {1}; bins wrap = {2};
                                    illegal_bins rsvd = {3}; }
    cp_lock    : coverpoint lock  { bins normal = {0}; bins exclusive = {1}; }
    cp_cache   : coverpoint cache { bins legal[] = {0, 1, 2, 3, 6, 7, 10, 11, 14, 15};
                                    illegal_bins bad = {4, 5, 8, 9, 12, 13}; }
    cp_prot    : coverpoint prot  { bins p[] = {[0:7]}; }
    x_burst_len  : cross cp_burst, cp_len_bkt {
      ignore_bins wrap_one   = binsof(cp_burst.wrap)  && binsof(cp_len_bkt.b_one);
      ignore_bins wrap_long  = binsof(cp_burst.wrap)  && binsof(cp_len_bkt.b_long);
      ignore_bins fixed_long = binsof(cp_burst.fixed) && binsof(cp_len_bkt.b_long);
    }
    x_lock_burst : cross cp_lock, cp_burst;
  endgroup

  //---------------- read address (same items as AW) ----------------
  covergroup cg_ar;
    option.per_instance = 1;
    cp_id      : coverpoint id;
    cp_len     : coverpoint len   { bins l[] = {[0:255]}; }
    cp_len_bkt : coverpoint len   { option.weight = 0;
                                    bins b_one   = {0};
                                    bins b_short = {[1:15]};
                                    bins b_long  = {[16:255]}; }
    cp_size    : coverpoint size  { bins s[] = {[0:7]}; }
    cp_burst   : coverpoint burst { bins fixed = {0}; bins incr = {1}; bins wrap = {2};
                                    illegal_bins rsvd = {3}; }
    cp_lock    : coverpoint lock  { bins normal = {0}; bins exclusive = {1}; }
    cp_cache   : coverpoint cache { bins legal[] = {0, 1, 2, 3, 6, 7, 10, 11, 14, 15};
                                    illegal_bins bad = {4, 5, 8, 9, 12, 13}; }
    cp_prot    : coverpoint prot  { bins p[] = {[0:7]}; }
    x_burst_len  : cross cp_burst, cp_len_bkt {
      ignore_bins wrap_one   = binsof(cp_burst.wrap)  && binsof(cp_len_bkt.b_one);
      ignore_bins wrap_long  = binsof(cp_burst.wrap)  && binsof(cp_len_bkt.b_long);
      ignore_bins fixed_long = binsof(cp_burst.fixed) && binsof(cp_len_bkt.b_long);
    }
    x_lock_burst : cross cp_lock, cp_burst;
  endgroup

  //---------------- write data ----------------
  covergroup cg_w;
    option.per_instance = 1;
    cp_w_order : coverpoint w_order { bins data_first = {0};
                                      bins same_cycle = {1};
                                      bins addr_first = {2}; }
  endgroup

  //---------------- write response ----------------
  covergroup cg_b;
    option.per_instance = 1;
    cp_bid   : coverpoint id;
    cp_bresp : coverpoint resp { bins okay = {0}; bins exokay = {1};
                                 bins slverr = {2}; bins decerr = {3}; }
  endgroup

  //---------------- read data ----------------
  covergroup cg_r;
    option.per_instance = 1;
    cp_rid   : coverpoint id;
    cp_rresp : coverpoint resp { bins okay = {0}; bins exokay = {1};
                                 bins slverr = {2}; bins decerr = {3}; }
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cg_aw = new();
    cg_ar = new();
    cg_w  = new();
    cg_b  = new();
    cg_r  = new();
  endfunction

  function void build_phase(uvm_phase phase);
    cg_aw.set_inst_name({get_full_name(), ".cg_aw"});
    cg_ar.set_inst_name({get_full_name(), ".cg_ar"});
    cg_w.set_inst_name ({get_full_name(), ".cg_w"});
    cg_b.set_inst_name ({get_full_name(), ".cg_b"});
    cg_r.set_inst_name ({get_full_name(), ".cg_r"});
  endfunction

  function void write(axi_seq_item t);
    id    = t.id;
    len   = t.len;
    size  = t.size;
    burst = t.burst;
    lock  = t.lock;
    cache = t.cache;
    prot  = t.prot;
    resp  = (t.resp.size() > 0) ? t.resp[0] : 2'b00;
    if (t.is_write) begin
      n_wr++;
      w_order = t.w_order;
      cg_aw.sample();
      cg_w.sample();
      cg_b.sample();
    end else begin
      n_rd++;
      cg_ar.sample();
      cg_r.sample();
    end
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("COV", $sformatf({"\n[%s] AXI4 functional coverage (%0d writes, %0d reads)\n",
              "   Address Write (AW) : %6.2f %%\n",
              "   Write         (W)  : %6.2f %%\n",
              "   Write Resp    (B)  : %6.2f %%\n",
              "   Address Read  (AR) : %6.2f %%\n",
              "   Read          (R)  : %6.2f %%\n",
              "   -- AW detail: len %6.2f%%  size %6.2f%%  burst x len %6.2f%%  lock x burst %6.2f%%"},
              get_full_name(), n_wr, n_rd,
              cg_aw.get_inst_coverage(), cg_w.get_inst_coverage(), cg_b.get_inst_coverage(),
              cg_ar.get_inst_coverage(), cg_r.get_inst_coverage(),
              cg_aw.cp_len.get_inst_coverage(), cg_aw.cp_size.get_inst_coverage(),
              cg_aw.x_burst_len.get_inst_coverage(), cg_aw.x_lock_burst.get_inst_coverage()),
              UVM_LOW)
  endfunction
endclass
