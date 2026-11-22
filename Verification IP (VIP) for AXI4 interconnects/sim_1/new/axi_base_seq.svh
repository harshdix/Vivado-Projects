//------------------------------------------------------------------------------
// axi_base_seq.svh  (included by axi_vip_pkg)
// NON-EXCLUSIVE random transaction sequence (paper Sec. IV-B, Fig. 3).
//
// Usage from a test:
//   seq = axi_base_seq::type_id::create("seq");
//   seq.mode = AXI4;                       // knobs BEFORE randomize
//   if (!seq.randomize()) `uvm_fatal(...)  // 1) randomize the SEQUENCE
//   seq.addr = 32'h2000;                   // 2) optional: tweak any field
//   seq.start(sequencer);                  // 3) copies vars into one item
//
// Tweaking after randomize is safe: body() calls fix_arrays() so data/strb/
// delay arrays follow a changed len/is_write and strobes are re-masked.
//------------------------------------------------------------------------------
class axi_base_seq extends uvm_sequence #(axi_seq_item);
  `uvm_object_utils(axi_base_seq)

  // ---------------- knobs (set before randomize) ----------------
  axi_mode_e           mode      = AXI4;
  bit [AXI_ADDR_W-1:0] addr_min  = '0;
  bit [AXI_ADDR_W-1:0] addr_max  = '1;
  int unsigned         max_delay = 4;      // must be >= 1

  // ---------------- randomized transaction variables ------------
  rand bit                  is_write;
  rand bit [AXI_ID_W-1:0]   id;
  rand bit [AXI_ADDR_W-1:0] addr;
  rand bit [7:0]            len;
  rand bit [2:0]            size;
  rand axi_burst_e          burst;
  rand bit                  lock;
  rand bit [3:0]            cache;
  rand bit [2:0]            prot;
  rand bit [AXI_DATA_W-1:0] data[];
  rand bit [AXI_STRB_W-1:0] strb[];
  rand int unsigned         addr_delay;
  rand int unsigned         beat_delay[];
  rand int unsigned         resp_delay;

  // ---------------- AXI4 legality constraints -------------------
  constraint c_addr_range { addr inside {[addr_min : addr_max]}; }

  // never wider than the data bus (128-bit -> max 16 bytes, size <= 4)
  constraint c_size  { size <= AXI_MAX_SIZE; }

  constraint c_burst { burst != BURST_RSVD; }

  constraint c_len_dist {
    len dist { 0 := 20, [1:15] :/ 50, [16:255] :/ 30 };
  }

  constraint c_fixed { burst == BURST_FIXED -> len <= 15; }

  constraint c_wrap {
    burst == BURST_WRAP -> (len inside {1, 3, 7, 15}) &&
                           ((addr % (32'd1 << size)) == 0);
  }

  // INCR burst must not cross a 4 KB boundary
  constraint c_4kb {
    burst == BURST_INCR ->
      (((addr % 32'd4096) & ~((32'd1 << size) - 32'd1)) +
       ((32'(len) + 32'd1) << size)) <= 32'd4096;
  }

  constraint c_cache { (cache[3:2] != 2'b00) -> (cache[1] == 1'b1); }

  // overridden (same name) in axi_excl_seq
  constraint c_nonexcl { lock == 1'b0; }

  // AXI4-Lite: single beat, full bus width, no burst/lock/cache features
  constraint c_lite {
    (mode == AXI4_LITE) -> (len == 0 && size == AXI_MAX_SIZE &&
                            burst == BURST_INCR && lock == 0 && cache == 0 &&
                            (addr % AXI_STRB_W) == 0);
  }

  constraint c_arrays {
    data.size()       == (is_write ? (int'(len) + 1) : 0);
    strb.size()       == data.size();
    beat_delay.size() == int'(len) + 1;
  }

  constraint c_delays {
    addr_delay dist { 0 := 6, [1:max_delay] :/ 4 };
    resp_delay dist { 0 := 6, [1:max_delay] :/ 4 };
    foreach (beat_delay[i]) beat_delay[i] dist { 0 := 7, [1:max_delay] :/ 3 };
  }

  constraint c_order { solve is_write, len before data, strb, beat_delay; }

  function new(string name = "axi_base_seq");
    super.new(name);
  endfunction

  function void post_randomize();
    fix_arrays();
  endfunction

  // keep arrays consistent with len/is_write and apply legal strobe lanes
  function void fix_arrays();
    int n = int'(len) + 1;
    int old;
    if (is_write) begin
      if (data.size() != n) begin
        old  = data.size();
        data = new[n](data);
        strb = new[n](strb);
        for (int i = old; i < n; i++) begin
          data[i] = axi_rand_data();
          strb[i] = '1;
        end
      end
    end else begin
      data.delete();
      strb.delete();
    end
    if (beat_delay.size() != n) begin
      old        = beat_delay.size();
      beat_delay = new[n](beat_delay);
      for (int i = old; i < n; i++) beat_delay[i] = 0;
    end
    foreach (strb[i]) strb[i] &= axi_lane_mask(addr, len, size, burst, i);
  endfunction

  function void copy_to_item(axi_seq_item t);
    t.is_write   = is_write;  t.id    = id;    t.addr  = addr;
    t.len        = len;       t.size  = size;  t.burst = burst;
    t.lock       = lock;      t.cache = cache; t.prot  = prot;
    t.data       = data;      t.strb  = strb;
    t.addr_delay = addr_delay;
    t.beat_delay = beat_delay;
    t.resp_delay = resp_delay;
  endfunction

  virtual task body();
    axi_seq_item item;
    fix_arrays();
    item = axi_seq_item::type_id::create("item");
    start_item(item);
    copy_to_item(item);
    finish_item(item);
    `uvm_info(get_type_name(), {"sent: ", item.convert2string()}, UVM_HIGH)
  endtask
endclass
