//------------------------------------------------------------------------------
// axi_queue_tb_pkg.sv
// DUT-specific testbench for the AXI4 queue (paper Sec. V, Fig. 4):
//   manager agent  -> [ axi4_queue ] -> subordinate agent
//   scoreboard: every transaction seen on the upstream side must equal the
//   one seen downstream (the queue must pass everything through unchanged
//   and in order).
//------------------------------------------------------------------------------
package axi_queue_tb_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import axi_types_pkg::*;
  import axi_vip_pkg::*;

  `uvm_analysis_imp_decl(_up)
  `uvm_analysis_imp_decl(_dn)

  //==========================================================================
  // Scoreboard
  //==========================================================================
  class axi_queue_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(axi_queue_scoreboard)

    uvm_analysis_imp_up #(axi_seq_item, axi_queue_scoreboard) up_imp;  // DUT s_axi side
    uvm_analysis_imp_dn #(axi_seq_item, axi_queue_scoreboard) dn_imp;  // DUT m_axi side

    axi_seq_item up_wr[$], up_rd[$], dn_wr[$], dn_rd[$];
    int unsigned n_match_wr, n_match_rd, n_mismatch;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      up_imp = new("up_imp", this);
      dn_imp = new("dn_imp", this);
    endfunction

    function void write_up(axi_seq_item t);
      if (t.is_write) up_wr.push_back(t); else up_rd.push_back(t);
      compare_all();
    endfunction

    function void write_dn(axi_seq_item t);
      if (t.is_write) dn_wr.push_back(t); else dn_rd.push_back(t);
      compare_all();
    endfunction

    function void compare_all();
      axi_seq_item a, b;
      while (up_wr.size() > 0 && dn_wr.size() > 0) begin
        a = up_wr.pop_front();  b = dn_wr.pop_front();
        if (a.compare(b)) n_match_wr++;
        else begin
          n_mismatch++;
          `uvm_error("SB", {"WRITE mismatch\n  upstream  : ", a.convert2string(),
                            "\n  downstream: ", b.convert2string()})
        end
      end
      while (up_rd.size() > 0 && dn_rd.size() > 0) begin
        a = up_rd.pop_front();  b = dn_rd.pop_front();
        if (a.compare(b)) n_match_rd++;
        else begin
          n_mismatch++;
          `uvm_error("SB", {"READ mismatch\n  upstream  : ", a.convert2string(),
                            "\n  downstream: ", b.convert2string()})
        end
      end
    endfunction

    function void check_phase(uvm_phase phase);
      if (up_wr.size() || up_rd.size() || dn_wr.size() || dn_rd.size())
        `uvm_error("SB", $sformatf("unmatched at end: up_wr=%0d up_rd=%0d dn_wr=%0d dn_rd=%0d",
                   up_wr.size(), up_rd.size(), dn_wr.size(), dn_rd.size()))
    endfunction

    function void report_phase(uvm_phase phase);
      `uvm_info("SB", $sformatf("matched %0d writes, %0d reads, %0d mismatches",
                n_match_wr, n_match_rd, n_mismatch), UVM_LOW)
    endfunction
  endclass

  //==========================================================================
  // Environment
  //==========================================================================
  class axi_queue_env extends uvm_env;
    `uvm_component_utils(axi_queue_env)

    axi_cfg              mgr_cfg, sub_cfg;   // set by the test before build
    axi_mgr_agent        mgr_agt;
    axi_sub_agent        sub_agt;
    axi_queue_scoreboard sb;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      if (mgr_cfg == null || sub_cfg == null) `uvm_fatal("CFG", "env: cfgs not set by test")
      mgr_agt     = axi_mgr_agent::type_id::create("mgr_agt", this);
      mgr_agt.cfg = mgr_cfg;
      sub_agt     = axi_sub_agent::type_id::create("sub_agt", this);
      sub_agt.cfg = sub_cfg;
      sb          = axi_queue_scoreboard::type_id::create("sb", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      mgr_agt.mon.ap.connect(sb.up_imp);
      sub_agt.mon.ap.connect(sb.dn_imp);
    endfunction
  endclass

  //==========================================================================
  // Base test: random mix of non-exclusive and exclusive sequences
  //   plusargs: +NUM_TXN=<n>  +EXCL_PCT=<0..100>  +ERR_PCT=<0..100>
  //             +ADDR_MAX=<hex>  +TRACE
  //==========================================================================
  class axi_queue_base_test extends uvm_test;
    `uvm_component_utils(axi_queue_base_test)

    axi_queue_env env;
    axi_cfg       mgr_cfg, sub_cfg;
    int unsigned  num_txn  = 1000;
    int unsigned  excl_pct = 10;
    int unsigned  err_pct  = 3;
    // keep addresses in a 1 MB window: bounds the subordinate's memory model
    // on long runs and makes reads hit previously written data
    bit [AXI_ADDR_W-1:0] addr_max = 32'h000F_FFFF;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      void'($value$plusargs("NUM_TXN=%d", num_txn));
      void'($value$plusargs("EXCL_PCT=%d", excl_pct));
      void'($value$plusargs("ERR_PCT=%d", err_pct));
      void'($value$plusargs("ADDR_MAX=%h", addr_max));

      mgr_cfg         = axi_cfg::type_id::create("mgr_cfg");
      mgr_cfg.role    = AXI_MANAGER;
      sub_cfg         = axi_cfg::type_id::create("sub_cfg");
      sub_cfg.role    = AXI_SUBORDINATE;
      sub_cfg.err_pct = err_pct;
      if ($test$plusargs("TRACE")) begin
        mgr_cfg.trace_txn = 1;
        sub_cfg.trace_txn = 1;
      end
      // protocol checkers (bound in tb_top) read this switch at reset release
      uvm_config_db #(bit)::set(null, "", "axi_assert_en", mgr_cfg.enable_assertions);
      if (!uvm_config_db #(virtual axi_if)::get(this, "", "mgr_vif", mgr_cfg.vif))
        `uvm_fatal("VIF", "mgr_vif not found in config_db")
      if (!uvm_config_db #(virtual axi_if)::get(this, "", "sub_vif", sub_cfg.vif))
        `uvm_fatal("VIF", "sub_vif not found in config_db")

      env         = axi_queue_env::type_id::create("env", this);
      env.mgr_cfg = mgr_cfg;
      env.sub_cfg = sub_cfg;
    endfunction

    function void end_of_elaboration_phase(uvm_phase phase);
      uvm_top.print_topology();
    endfunction

    task run_phase(uvm_phase phase);
      axi_base_seq seq;
      phase.raise_objection(this);
      `uvm_info("TEST", $sformatf("Running %0d sequences (%0d%% exclusive pairs, %0d%% error responses, addr <= %h)",
                num_txn, excl_pct, err_pct, addr_max), UVM_LOW)
      for (int k = 0; k < num_txn; k++) begin
        if ($urandom_range(0, 99) < excl_pct)
          seq = axi_excl_seq::type_id::create("excl_seq");
        else
          seq = axi_base_seq::type_id::create("seq");
        seq.addr_max = addr_max;
        if (!seq.randomize()) `uvm_fatal("RAND", "sequence randomize failed")
        seq.start(env.mgr_agt.sqr);
        if ((k + 1) % (num_txn / 10 > 0 ? num_txn / 10 : 1) == 0)
          `uvm_info("TEST", $sformatf("  progress: %0d / %0d sequences started", k + 1, num_txn), UVM_LOW)
      end
      env.mgr_agt.drv.wait_idle();
      #200ns;   // let the last monitor/scoreboard updates settle
      phase.drop_objection(this);
    endtask

    function void report_phase(uvm_phase phase);
      uvm_report_server rs = uvm_report_server::get_server();
      if (rs.get_severity_count(UVM_ERROR) == 0 && rs.get_severity_count(UVM_FATAL) == 0)
        $display("\n*** TEST PASSED : %s ***\n", get_type_name());
      else
        $display("\n*** TEST FAILED : %s (%0d errors) ***\n", get_type_name(),
                 rs.get_severity_count(UVM_ERROR));
    endfunction
  endclass

  //==========================================================================
  // Assertion demo test: proves the protocol checkers catch violations.
  // Uses the paper's "randomize -> tweak -> start" flow to push a few
  // deliberately ILLEGAL transactions through the queue. Each one must be
  // flagged by the checkers on BOTH DUT ports (the queue forwards it as-is).
  //   +UVM_TESTNAME=axi_queue_assert_demo_test
  //==========================================================================
  class axi_queue_assert_demo_test extends axi_queue_base_test;
    `uvm_component_utils(axi_queue_assert_demo_test)

    int unsigned n_bad;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      sub_cfg.err_pct = 0;   // keep responses clean, only our bugs should fire
    endfunction

    task send_bad(bit wr, axi_burst_e burst, bit [AXI_ADDR_W-1:0] addr,
                  bit [7:0] len, bit [2:0] size, string expect_id);
      axi_base_seq seq = axi_base_seq::type_id::create("bad_seq");
      if (!seq.randomize()) `uvm_fatal("RAND", "randomize failed")
      seq.is_write = wr;            // tweak step: overwrite with illegal values
      seq.burst    = burst;
      seq.addr     = addr;
      seq.len      = len;
      seq.size     = size;
      seq.lock     = 1'b0;
      `uvm_info("DEMO", $sformatf("sending ILLEGAL %s (expect %s): addr=%h len=%0d size=%0d burst=%s",
                wr ? "write" : "read", expect_id, addr, len, size, burst.name()), UVM_LOW)
      seq.start(env.mgr_agt.sqr);
      env.mgr_agt.drv.wait_idle();
      n_bad++;
    endtask

    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      #300ns;
      send_bad(1, BURST_WRAP,  32'h0000_1000,  8'd5, 3'd2, "a_aw_wrap_len");
      send_bad(1, BURST_INCR,  32'h0000_0FF0,  8'd3, 3'd4, "a_aw_4kb");
      send_bad(0, BURST_FIXED, 32'h0000_2000, 8'd20, 3'd2, "a_ar_fixed_len");
      send_bad(1, BURST_INCR,  32'h0000_3000,  8'd0, 3'd5, "a_aw_size_bus");
      send_bad(0, BURST_WRAP,  32'h0000_4002,  8'd3, 3'd2, "a_ar_wrap_align");
      #200ns;
      phase.drop_objection(this);
    endtask

    function void report_phase(uvm_phase phase);
      uvm_report_server rs = uvm_report_server::get_server();
      int chk   = rs.get_id_count("AXI_CHK");
      int other = rs.get_severity_count(UVM_ERROR) - chk;
      $display("\n=========== ASSERTION DEMO ===========");
      $display(" illegal transactions sent     : %0d", n_bad);
      $display(" protocol checker errors seen  : %0d (expected >= %0d: each bug on both DUT ports)",
               chk, 2 * n_bad);
      $display(" other (non-checker) errors    : %0d", other);
      if (chk >= 2 * n_bad && other == 0)
        $display("*** ASSERTION DEMO PASSED: every illegal transaction was caught ***");
      else
        $display("*** ASSERTION DEMO FAILED ***");
      $display("======================================\n");
    endfunction
  endclass

  //==========================================================================
  // AXI4-Lite test (paper Sec. IV-C): both agents configured as AXI4-Lite.
  //  - config object mode = AXI4_LITE -> agents build axi4lite_cov instead of
  //    axi4_cov, so the report only lists Lite features
  //  - sequences run in Lite mode (single beat, full width, no exclusive)
  //  - protocol checkers additionally apply the AXI4-Lite rules
  //   +UVM_TESTNAME=axi_queue_lite_test   (+NUM_TXN=<n>, default 1000)
  //==========================================================================
  class axi_queue_lite_test extends axi_queue_base_test;
    `uvm_component_utils(axi_queue_lite_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);          // creates cfgs + env (env builds later)
      mgr_cfg.mode = AXI4_LITE;
      sub_cfg.mode = AXI4_LITE;
      excl_pct     = 0;                  // no exclusive accesses in AXI4-Lite
      uvm_config_db #(bit)::set(null, "", "axi_lite_mode", 1'b1);
    endfunction

    task run_phase(uvm_phase phase);
      axi_base_seq seq;
      phase.raise_objection(this);
      `uvm_info("TEST", $sformatf("AXI4-Lite: running %0d sequences (%0d%% error responses)",
                num_txn, err_pct), UVM_LOW)
      for (int k = 0; k < num_txn; k++) begin
        seq          = axi_base_seq::type_id::create("lite_seq");
        seq.mode     = AXI4_LITE;
        seq.addr_max = addr_max;
        if (!seq.randomize()) `uvm_fatal("RAND", "Lite sequence randomize failed")
        seq.start(env.mgr_agt.sqr);
        if ((k + 1) % (num_txn / 10 > 0 ? num_txn / 10 : 1) == 0)
          `uvm_info("TEST", $sformatf("  progress: %0d / %0d", k + 1, num_txn), UVM_LOW)
      end
      env.mgr_agt.drv.wait_idle();
      #200ns;
      phase.drop_objection(this);
    endtask
  endclass

endpackage
