//------------------------------------------------------------------------------
// axi4lite_cov.svh  (included by axi_vip_pkg)
// AXI4-Lite functional coverage collector (paper Sec. IV-C).
// Separate from axi4_cov so Lite reports contain only Lite features: no
// burst / len / size / lock / cache / id bins that would need manual exclusion.
// EXOKAY is illegal in AXI4-Lite (no exclusive accesses) -> illegal_bins.
//------------------------------------------------------------------------------
class axi4lite_cov extends uvm_subscriber #(axi_seq_item);
  `uvm_component_utils(axi4lite_cov)

  bit [2:0] prot;
  bit [1:0] resp;
  int       w_order;

  int unsigned n_wr, n_rd;

  covergroup cg_aw;
    option.per_instance = 1;
    cp_prot : coverpoint prot { bins p[] = {[0:7]}; }
  endgroup

  covergroup cg_w;
    option.per_instance = 1;
    cp_w_order : coverpoint w_order { bins data_first = {0};
                                      bins same_cycle = {1};
                                      bins addr_first = {2}; }
  endgroup

  covergroup cg_b;
    option.per_instance = 1;
    cp_bresp : coverpoint resp { bins okay = {0}; bins slverr = {2}; bins decerr = {3};
                                 illegal_bins exokay = {1}; }
  endgroup

  covergroup cg_ar;
    option.per_instance = 1;
    cp_prot : coverpoint prot { bins p[] = {[0:7]}; }
  endgroup

  covergroup cg_r;
    option.per_instance = 1;
    cp_rresp : coverpoint resp { bins okay = {0}; bins slverr = {2}; bins decerr = {3};
                                 illegal_bins exokay = {1}; }
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cg_aw = new();
    cg_w  = new();
    cg_b  = new();
    cg_ar = new();
    cg_r  = new();
  endfunction

  function void build_phase(uvm_phase phase);
    cg_aw.set_inst_name({get_full_name(), ".cg_aw"});
    cg_w.set_inst_name ({get_full_name(), ".cg_w"});
    cg_b.set_inst_name ({get_full_name(), ".cg_b"});
    cg_ar.set_inst_name({get_full_name(), ".cg_ar"});
    cg_r.set_inst_name ({get_full_name(), ".cg_r"});
  endfunction

  function void write(axi_seq_item t);
    prot = t.prot;
    resp = (t.resp.size() > 0) ? t.resp[0] : 2'b00;
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
    `uvm_info("COV", $sformatf({"\n[%s] AXI4-Lite functional coverage (%0d writes, %0d reads)\n",
              "   Address Write (AW) : %6.2f %%\n",
              "   Write         (W)  : %6.2f %%\n",
              "   Write Resp    (B)  : %6.2f %%\n",
              "   Address Read  (AR) : %6.2f %%\n",
              "   Read          (R)  : %6.2f %%"},
              get_full_name(), n_wr, n_rd,
              cg_aw.get_inst_coverage(), cg_w.get_inst_coverage(), cg_b.get_inst_coverage(),
              cg_ar.get_inst_coverage(), cg_r.get_inst_coverage()), UVM_LOW)
  endfunction
endclass
