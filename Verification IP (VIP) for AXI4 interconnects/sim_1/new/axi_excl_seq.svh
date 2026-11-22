//------------------------------------------------------------------------------
// axi_excl_seq.svh  (included by axi_vip_pkg)
// EXCLUSIVE access sequence (paper Sec. IV-B): randomizes ONE set of exclusive
// attributes and issues two dependent transactions with them:
//   1) exclusive READ   2) exclusive WRITE to the same id/addr/len/size/burst
// AXI4 exclusive rules (IHI0022 A7.2.4):
//   - total bytes (len+1)*2^size is a power of 2, <= 128
//   - address aligned to total bytes
//   - burst length <= 16 beats
//   - not supported in AXI4-Lite
//------------------------------------------------------------------------------
class axi_excl_seq extends axi_base_seq;
  `uvm_object_utils(axi_excl_seq)

  // overrides parent's c_nonexcl (same name)
  constraint c_nonexcl { lock == 1'b1; }

  // randomize write data once; the read pair reuses the attributes
  constraint c_dir { is_write == 1'b1; }

  constraint c_excl {
    mode == AXI4;
    len <= 15;
    ((32'(len) + 32'd1) << size) inside {1, 2, 4, 8, 16, 32, 64, 128};
    (addr % ((32'(len) + 32'd1) << size)) == 0;
  }

  function new(string name = "axi_excl_seq");
    super.new(name);
  endfunction

  virtual task body();
    axi_seq_item rd, wr;
    fix_arrays();

    // ---- exclusive read ----
    rd = axi_seq_item::type_id::create("excl_rd");
    start_item(rd);
    copy_to_item(rd);
    rd.is_write = 1'b0;
    rd.data.delete();
    rd.strb.delete();
    finish_item(rd);
    `uvm_info(get_type_name(), {"sent: ", rd.convert2string()}, UVM_HIGH)

    // ---- matching exclusive write ----
    wr = axi_seq_item::type_id::create("excl_wr");
    start_item(wr);
    copy_to_item(wr);
    wr.is_write = 1'b1;
    finish_item(wr);
    `uvm_info(get_type_name(), {"sent: ", wr.convert2string()}, UVM_HIGH)
  endtask
endclass
