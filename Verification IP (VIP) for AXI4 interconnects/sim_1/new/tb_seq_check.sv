//------------------------------------------------------------------------------
// tb_seq_check.sv
// UVM test that checks the sequence layer ON ITS OWN (no DUT, no real driver).
// A dummy driver just collects items; the test then checks every item
// against AXI4 rules with an independent checker and prints distributions.
//
//  Phase A : 5000 random non-exclusive transactions (AXI4)
//  Phase B : "randomize -> tweak -> start" demo (paper Fig. 3)
//  Phase C : 1000 exclusive sequences (must give RD+WR pairs)
//  Phase D : 1000 AXI4-Lite transactions
//------------------------------------------------------------------------------
package seq_check_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import axi_types_pkg::*;
  import axi_vip_pkg::*;

  //--------------------------------------------------------------------------
  // Dummy driver: accepts every item immediately, stores a copy
  //--------------------------------------------------------------------------
  class chk_driver extends uvm_driver #(axi_seq_item);
    `uvm_component_utils(chk_driver)
    axi_seq_item items[$];

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      axi_seq_item it, cp;
      forever begin
        seq_item_port.get_next_item(it);
        cp = axi_seq_item::type_id::create("cp");
        cp.copy(it);
        items.push_back(cp);
        #1ns;   // advance time per item: thousands of zero-time handshakes
                // exceed xsim's delta-cycle limit (-maxdeltaid, default 10000)
        seq_item_port.item_done();
      end
    endtask
  endclass

  //--------------------------------------------------------------------------
  // Test
  //--------------------------------------------------------------------------
  class axi_seq_check_test extends uvm_test;
    `uvm_component_utils(axi_seq_check_test)

    uvm_sequencer #(axi_seq_item) sqr;
    chk_driver                    drv;

    // statistics
    int size_cnt[8];
    int burst_cnt[4];
    int len0, len_1_15, len_16_255;
    int writes, reads, nz_addr_delay;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      sqr = uvm_sequencer #(axi_seq_item)::type_id::create("sqr", this);
      drv = chk_driver::type_id::create("drv", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction

    //---------------- independent legality checker ----------------
    function int check_item(axi_seq_item t, axi_mode_e mode);
      int errs = 0;
      longint unsigned nb    = longint'(1) << t.size;
      longint unsigned total = nb * (longint'(t.len) + 1);
      longint unsigned astart;

      if (t.burst == BURST_RSVD)        begin errs++; `uvm_error("LEGAL", {"reserved burst: ", t.convert2string()}) end
      if (t.size > AXI_MAX_SIZE)        begin errs++; `uvm_error("LEGAL", {"size > bus: ", t.convert2string()}) end
      if (!axi_cache_legal(t.cache))    begin errs++; `uvm_error("LEGAL", {"illegal cache: ", t.convert2string()}) end
      if (t.burst == BURST_FIXED && t.len > 15)
                                        begin errs++; `uvm_error("LEGAL", {"FIXED len>16: ", t.convert2string()}) end
      if (t.burst == BURST_WRAP) begin
        if (!(t.len inside {1, 3, 7, 15}))  begin errs++; `uvm_error("LEGAL", {"WRAP len: ", t.convert2string()}) end
        if (t.addr % nb != 0)                begin errs++; `uvm_error("LEGAL", {"WRAP unaligned: ", t.convert2string()}) end
      end
      if (t.burst == BURST_INCR) begin
        astart = (t.addr / nb) * nb;
        if (((astart + total - 1) >> 12) != (longint'(t.addr) >> 12))
          begin errs++; `uvm_error("LEGAL", {"4KB crossing: ", t.convert2string()}) end
      end
      if (t.is_write) begin
        if (t.data.size() != t.len + 1 || t.strb.size() != t.len + 1)
          begin errs++; `uvm_error("LEGAL", {"data/strb array size: ", t.convert2string()}) end
        foreach (t.strb[i])
          if (t.strb[i] & ~axi_lane_mask(t.addr, t.len, t.size, t.burst, i))
            begin errs++; `uvm_error("LEGAL", $sformatf("strb beat %0d outside lanes: %s", i, t.convert2string())) end
      end else if (t.data.size() != 0)
          begin errs++; `uvm_error("LEGAL", {"read carries data: ", t.convert2string()}) end
      if (t.beat_delay.size() != t.len + 1)
          begin errs++; `uvm_error("LEGAL", {"beat_delay size: ", t.convert2string()}) end

      if (t.lock) begin   // exclusive rules
        if (t.len > 15)                                   begin errs++; `uvm_error("EXCL", {"len>16: ", t.convert2string()}) end
        if (!(total inside {1,2,4,8,16,32,64,128}))       begin errs++; `uvm_error("EXCL", {"bytes not pow2<=128: ", t.convert2string()}) end
        if (t.addr % total != 0)                          begin errs++; `uvm_error("EXCL", {"unaligned: ", t.convert2string()}) end
      end

      if (mode == AXI4_LITE) begin
        if (t.len != 0 || t.size != AXI_MAX_SIZE || t.lock || t.cache != 0 || t.burst != BURST_INCR)
          begin errs++; `uvm_error("LITE", {"non-Lite attribute: ", t.convert2string()}) end
      end
      return errs;
    endfunction

    function void collect_stats(axi_seq_item t);
      size_cnt[t.size]++;
      burst_cnt[t.burst]++;
      if (t.len == 0)       len0++;
      else if (t.len < 16)  len_1_15++;
      else                  len_16_255++;
      if (t.is_write) writes++; else reads++;
      if (t.addr_delay != 0) nz_addr_delay++;
    endfunction

    //---------------- run ----------------
    task run_phase(uvm_phase phase);
      axi_base_seq seq;
      axi_excl_seq xseq;
      int errs = 0;
      int n;
      phase.raise_objection(this);

      //------------ Phase A: random AXI4 ------------
      `uvm_info("TEST", "Phase A: 5000 random AXI4 sequences", UVM_LOW)
      for (int k = 0; k < 5000; k++) begin
        seq = axi_base_seq::type_id::create("seq");
        if (!seq.randomize()) `uvm_fatal("RAND", "axi_base_seq randomize failed")
        seq.start(sqr);
        if (k % 500 == 499)
          `uvm_info("TEST", $sformatf("  Phase A progress: %0d / 5000", k + 1), UVM_LOW)
      end
      foreach (drv.items[i]) begin
        errs += check_item(drv.items[i], AXI4);
        collect_stats(drv.items[i]);
      end
      `uvm_info("TEST", $sformatf("Phase A: %0d items checked", drv.items.size()), UVM_LOW)
      drv.items.delete();

      //------------ Phase B: randomize -> tweak -> start ------------
      `uvm_info("TEST", "Phase B: randomize, then override addr/len/size/burst", UVM_LOW)
      seq = axi_base_seq::type_id::create("seq_tweak");
      if (!seq.randomize() with { is_write == 1; len == 0; }) `uvm_fatal("RAND", "tweak randomize failed")
      seq.addr  = 32'h0000_2000;   // directed values on top of random ones
      seq.len   = 8'd3;            // arrays must follow (fix_arrays)
      seq.size  = 3'd4;
      seq.burst = BURST_INCR;
      seq.start(sqr);
      begin
        axi_seq_item t = drv.items[0];
        `uvm_info("TEST", {"tweaked item: ", t.convert2string()}, UVM_LOW)
        if (t.addr != 32'h2000 || t.len != 3 || t.data.size() != 4 || t.strb[3] != '1)
          begin errs++; `uvm_error("TWEAK", "tweaked values not applied correctly") end
        errs += check_item(t, AXI4);
      end
      drv.items.delete();

      //------------ Phase C: exclusive ------------
      `uvm_info("TEST", "Phase C: 1000 exclusive sequences", UVM_LOW)
      repeat (1000) begin
        xseq = axi_excl_seq::type_id::create("xseq");
        if (!xseq.randomize()) `uvm_fatal("RAND", "axi_excl_seq randomize failed")
        xseq.start(sqr);
      end
      if (drv.items.size() != 2000)
        begin errs++; `uvm_error("EXCL", $sformatf("expected 2000 items, got %0d", drv.items.size())) end
      for (int i = 0; i + 1 < drv.items.size(); i += 2) begin
        axi_seq_item r = drv.items[i];
        axi_seq_item w = drv.items[i+1];
        errs += check_item(r, AXI4);
        errs += check_item(w, AXI4);
        if (r.is_write || !w.is_write || !r.lock || !w.lock ||
            r.id != w.id || r.addr != w.addr || r.len != w.len ||
            r.size != w.size || r.burst != w.burst)
          begin errs++; `uvm_error("EXCL", $sformatf("bad pair %0d:\n  %s\n  %s",
                                    i/2, r.convert2string(), w.convert2string())) end
      end
      drv.items.delete();

      //------------ Phase D: AXI4-Lite ------------
      `uvm_info("TEST", "Phase D: 1000 AXI4-Lite sequences", UVM_LOW)
      for (int k = 0; k < 1000; k++) begin
        seq = axi_base_seq::type_id::create("lseq");
        seq.mode = AXI4_LITE;
        if (!seq.randomize()) `uvm_fatal("RAND", "Lite randomize failed")
        seq.start(sqr);
        if (k % 100 == 99)
          `uvm_info("TEST", $sformatf("  Phase D progress: %0d / 1000", k + 1), UVM_LOW)
      end
      foreach (drv.items[i]) errs += check_item(drv.items[i], AXI4_LITE);
      drv.items.delete();

      `uvm_info("TEST", $sformatf("checker found %0d violations", errs), UVM_LOW)
      phase.drop_objection(this);
    endtask

    function void report_phase(uvm_phase phase);
      uvm_report_server rs = uvm_report_server::get_server();
      $display("============ Phase A distribution (5000 AXI4 txns) ============");
      $display(" WR=%0d RD=%0d  addr_delay!=0: %0d", writes, reads, nz_addr_delay);
      $display(" burst : FIXED=%0d INCR=%0d WRAP=%0d RSVD=%0d",
               burst_cnt[0], burst_cnt[1], burst_cnt[2], burst_cnt[3]);
      $display(" len   : 0=%0d  1..15=%0d  16..255=%0d", len0, len_1_15, len_16_255);
      $display(" size  : 1B=%0d 2B=%0d 4B=%0d 8B=%0d 16B=%0d | 32B=%0d 64B=%0d 128B=%0d",
               size_cnt[0], size_cnt[1], size_cnt[2], size_cnt[3], size_cnt[4],
               size_cnt[5], size_cnt[6], size_cnt[7]);
      $display("================================================================");
      if (rs.get_severity_count(UVM_ERROR) == 0 && rs.get_severity_count(UVM_FATAL) == 0)
        $display("*** SEQ CHECK PASSED ***");
      else
        $display("*** SEQ CHECK FAILED *** (%0d UVM errors)", rs.get_severity_count(UVM_ERROR));
    endfunction
  endclass
endpackage


module tb_seq_check;
  import uvm_pkg::*;
  import seq_check_pkg::*;
  initial run_test("axi_seq_check_test");
endmodule
