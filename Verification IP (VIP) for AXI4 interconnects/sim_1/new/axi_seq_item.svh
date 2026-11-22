//------------------------------------------------------------------------------
// axi_seq_item.svh  (included by axi_vip_pkg)
// One complete AXI4 transaction (address + all data beats + response).
// NOTE (paper Sec. IV-B): fields here are NOT rand. Randomization lives in the
// sequence; the sequence copies its values into this item before sending.
//------------------------------------------------------------------------------
class axi_seq_item extends uvm_sequence_item;
  `uvm_object_utils(axi_seq_item)

  // ---- transaction attributes ----
  bit                     is_write;
  bit [AXI_ID_W-1:0]      id;
  bit [AXI_ADDR_W-1:0]    addr;
  bit [7:0]               len;       // beats - 1
  bit [2:0]               size;      // log2(bytes per beat)
  axi_burst_e             burst;
  bit                     lock;      // 1 = exclusive
  bit [3:0]               cache;
  bit [2:0]               prot;

  // ---- payload ----
  bit [AXI_DATA_W-1:0]    data[];    // write: from seq, read: filled by monitor
  bit [AXI_STRB_W-1:0]    strb[];
  axi_resp_e              resp[];    // write: 1 entry (B), read: one per beat (R)

  // ---- timing (driver behaviour) ----
  int unsigned            addr_delay;    // cycles before AxVALID
  int unsigned            beat_delay[];  // write: gap before each WVALID
                                         // read : gap before RREADY per beat
  int unsigned            resp_delay;    // write: cycles before BREADY

  // ---- filled by monitor ----
  time                    start_time, end_time;
  int                     w_order = -1;  // write: 0=W data before AW, 1=same cycle, 2=AW first

  function new(string name = "axi_seq_item");
    super.new(name);
  endfunction

  function int unsigned num_beats();  return int'(len) + 1;     endfunction
  function int unsigned num_bytes();  return 1 << size;         endfunction

  virtual function void do_copy(uvm_object rhs);
    axi_seq_item t;
    if (!$cast(t, rhs)) `uvm_fatal("CAST", "do_copy: wrong type")
    super.do_copy(rhs);
    is_write   = t.is_write;  id    = t.id;    addr  = t.addr;
    len        = t.len;       size  = t.size;  burst = t.burst;
    lock       = t.lock;      cache = t.cache; prot  = t.prot;
    data       = t.data;      strb  = t.strb;  resp  = t.resp;
    addr_delay = t.addr_delay; beat_delay = t.beat_delay; resp_delay = t.resp_delay;
    start_time = t.start_time; end_time   = t.end_time;
    w_order    = t.w_order;
  endfunction

  // compares protocol content only (not delays / timestamps)
  virtual function bit do_compare(uvm_object rhs, uvm_comparer comparer);
    axi_seq_item t;
    if (!$cast(t, rhs)) return 0;
    if (is_write != t.is_write || id != t.id || addr != t.addr || len != t.len ||
        size != t.size || burst != t.burst || lock != t.lock ||
        cache != t.cache || prot != t.prot)                      return 0;
    if (data.size() != t.data.size() || resp.size() != t.resp.size()) return 0;
    foreach (data[i]) if (data[i] != t.data[i] || strb[i] != t.strb[i]) return 0;
    foreach (resp[i]) if (resp[i] != t.resp[i])                         return 0;
    return 1;
  endfunction

  virtual function string convert2string();
    string s;
    s = $sformatf("%s id=%0h addr=%h len=%0d size=%0d(%0dB) burst=%s lock=%0b cache=%h prot=%h",
                  is_write ? "WR" : "RD", id, addr, len, size, num_bytes(),
                  burst.name(), lock, cache, prot);
    if (data.size() > 0)
      s = {s, $sformatf(" data[0]=%h strb[0]=%h", data[0], strb[0])};
    if (resp.size() > 0)
      s = {s, $sformatf(" resp[0]=%s", resp[0].name())};
    return s;
  endfunction
endclass
