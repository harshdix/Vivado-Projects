//------------------------------------------------------------------------------
// tb_axi4_queue.sv
// Simple self-checking (non-UVM) testbench for axi4_queue.
// Purpose: prove the DUT is correct BEFORE we build the UVM VIP.
//
// For each of the 5 channels a chan_tester:
//   - drives random payloads into the FIFO input with random VALID gaps,
//     holding VALID + data stable until READY (AXI handshake rule)
//   - drives random READY on the FIFO output
//   - checks every output beat against an expected queue (in-order, no loss)
//   - asserts output VALID/data stay stable while stalled
//------------------------------------------------------------------------------

//==============================================================================
// Generic channel tester
//==============================================================================
module chan_tester #(
  parameter int    W       = 8,
  parameter int    N       = 2000,  // beats to send
  parameter string NAME    = "CH",
  parameter int    SRC_PCT = 70,    // % chance source sends without an idle gap
  parameter int    SNK_PCT = 60     // % chance sink READY is high in a cycle
)(
  input  logic         clk,
  input  logic         rst_n,
  // source side -> DUT FIFO input
  output logic         src_valid,
  input  logic         src_ready,
  output logic [W-1:0] src_data,
  // DUT FIFO output -> sink side
  input  logic         snk_valid,
  output logic         snk_ready,
  input  logic [W-1:0] snk_data,
  // status
  output logic         done,
  output int           errors,
  output int           stall_cycles
);

  logic [W-1:0] exp_q[$];
  int sent = 0;
  int rcvd = 0;

  function automatic logic [W-1:0] rand_word();
    logic [W-1:0] w = '0;
    for (int i = 0; i < (W + 31) / 32; i++)
      w = {w, 32'($urandom)};
    return w;
  endfunction

  //---------------- Source ----------------
  initial begin
    src_valid = 1'b0;
    src_data  = '0;
    wait (rst_n === 1'b1);
    @(posedge clk);
    for (int i = 0; i < N; i++) begin
      if ($urandom_range(0, 99) >= SRC_PCT)
        repeat ($urandom_range(1, 3)) @(posedge clk);   // idle gap
      src_valid <= 1'b1;
      src_data  <= rand_word();
      do @(posedge clk); while (!src_ready);           // hold until handshake
      exp_q.push_back(src_data);
      sent++;
      src_valid <= 1'b0;   // overridden if next beat starts in same timestep
    end
  end

  //---------------- Sink ----------------
  always @(posedge clk) begin
    if (!rst_n) begin
      snk_ready <= 1'b0;
    end else begin
      if (snk_valid && snk_ready) begin
        if (exp_q.size() == 0) begin
          $error("[%s] Unexpected beat %h (nothing was sent)", NAME, snk_data);
          errors++;
        end else begin
          logic [W-1:0] exp;
          exp = exp_q.pop_front();
          if (snk_data !== exp) begin
            $error("[%s] Beat %0d mismatch: got %h exp %h", NAME, rcvd, snk_data, exp);
            errors++;
          end
        end
        rcvd++;
      end
      snk_ready <= ($urandom_range(0, 99) < SNK_PCT);
    end
  end

  // count backpressure (FIFO full) cycles so we know it was exercised
  always @(posedge clk)
    if (rst_n && src_valid && !src_ready) stall_cycles++;

  initial begin errors = 0; stall_cycles = 0; end

  assign done = (sent == N) && (rcvd == N);

  //---------------- Output-side protocol check ----------------
  a_stable: assert property (@(posedge clk) disable iff (!rst_n)
      (snk_valid && !snk_ready) |=> (snk_valid && $stable(snk_data)))
    else $error("[%s] VALID dropped or data changed while stalled", NAME);

endmodule


//==============================================================================
// Top-level testbench
//==============================================================================
module tb_axi4_queue;

  localparam int ID_W   = 4;
  localparam int ADDR_W = 32;
  localparam int DATA_W = 128;
  localparam int STRB_W = DATA_W/8;
  localparam int DEPTH  = 4;
  localparam int N      = 2000;

  localparam int AX_W = ID_W + ADDR_W + 8 + 3 + 2 + 1 + 4 + 3;
  localparam int W_W  = DATA_W + STRB_W + 1;
  localparam int B_W  = ID_W + 2;
  localparam int R_W  = ID_W + DATA_W + 2 + 1;

  //---------------- Clock / reset ----------------
  logic aclk = 1'b0;
  logic aresetn;
  always #5 aclk = ~aclk;   // 100 MHz

  //---------------- DUT signals ----------------
  logic [ID_W-1:0]   s_axi_awid,    m_axi_awid;
  logic [ADDR_W-1:0] s_axi_awaddr,  m_axi_awaddr;
  logic [7:0]        s_axi_awlen,   m_axi_awlen;
  logic [2:0]        s_axi_awsize,  m_axi_awsize;
  logic [1:0]        s_axi_awburst, m_axi_awburst;
  logic              s_axi_awlock,  m_axi_awlock;
  logic [3:0]        s_axi_awcache, m_axi_awcache;
  logic [2:0]        s_axi_awprot,  m_axi_awprot;
  logic              s_axi_awvalid, m_axi_awvalid;
  logic              s_axi_awready, m_axi_awready;

  logic [DATA_W-1:0] s_axi_wdata,   m_axi_wdata;
  logic [STRB_W-1:0] s_axi_wstrb,   m_axi_wstrb;
  logic              s_axi_wlast,   m_axi_wlast;
  logic              s_axi_wvalid,  m_axi_wvalid;
  logic              s_axi_wready,  m_axi_wready;

  logic [ID_W-1:0]   s_axi_bid,     m_axi_bid;
  logic [1:0]        s_axi_bresp,   m_axi_bresp;
  logic              s_axi_bvalid,  m_axi_bvalid;
  logic              s_axi_bready,  m_axi_bready;

  logic [ID_W-1:0]   s_axi_arid,    m_axi_arid;
  logic [ADDR_W-1:0] s_axi_araddr,  m_axi_araddr;
  logic [7:0]        s_axi_arlen,   m_axi_arlen;
  logic [2:0]        s_axi_arsize,  m_axi_arsize;
  logic [1:0]        s_axi_arburst, m_axi_arburst;
  logic              s_axi_arlock,  m_axi_arlock;
  logic [3:0]        s_axi_arcache, m_axi_arcache;
  logic [2:0]        s_axi_arprot,  m_axi_arprot;
  logic              s_axi_arvalid, m_axi_arvalid;
  logic              s_axi_arready, m_axi_arready;

  logic [ID_W-1:0]   s_axi_rid,     m_axi_rid;
  logic [DATA_W-1:0] s_axi_rdata,   m_axi_rdata;
  logic [1:0]        s_axi_rresp,   m_axi_rresp;
  logic              s_axi_rlast,   m_axi_rlast;
  logic              s_axi_rvalid,  m_axi_rvalid;
  logic              s_axi_rready,  m_axi_rready;

  //---------------- DUT ----------------
  axi4_queue #(
    .ID_W(ID_W), .ADDR_W(ADDR_W), .DATA_W(DATA_W), .DEPTH(DEPTH)
  ) dut (.*);

  //---------------- Packed buses (same field order as DUT) ----------------
  logic [AX_W-1:0] aw_src, aw_snk, ar_src, ar_snk;
  logic [W_W-1:0]  w_src,  w_snk;
  logic [B_W-1:0]  b_src,  b_snk;
  logic [R_W-1:0]  r_src,  r_snk;

  assign {s_axi_awid, s_axi_awaddr, s_axi_awlen, s_axi_awsize,
          s_axi_awburst, s_axi_awlock, s_axi_awcache, s_axi_awprot} = aw_src;
  assign aw_snk = {m_axi_awid, m_axi_awaddr, m_axi_awlen, m_axi_awsize,
                   m_axi_awburst, m_axi_awlock, m_axi_awcache, m_axi_awprot};

  assign {s_axi_wdata, s_axi_wstrb, s_axi_wlast} = w_src;
  assign w_snk = {m_axi_wdata, m_axi_wstrb, m_axi_wlast};

  assign {m_axi_bid, m_axi_bresp} = b_src;          // B: m -> s
  assign b_snk = {s_axi_bid, s_axi_bresp};

  assign {s_axi_arid, s_axi_araddr, s_axi_arlen, s_axi_arsize,
          s_axi_arburst, s_axi_arlock, s_axi_arcache, s_axi_arprot} = ar_src;
  assign ar_snk = {m_axi_arid, m_axi_araddr, m_axi_arlen, m_axi_arsize,
                   m_axi_arburst, m_axi_arlock, m_axi_arcache, m_axi_arprot};

  assign {m_axi_rid, m_axi_rdata, m_axi_rresp, m_axi_rlast} = r_src;  // R: m -> s
  assign r_snk = {s_axi_rid, s_axi_rdata, s_axi_rresp, s_axi_rlast};

  //---------------- Channel testers ----------------
  logic done_aw, done_w, done_b, done_ar, done_r;
  int   err_aw,  err_w,  err_b,  err_ar,  err_r;
  int   stl_aw,  stl_w,  stl_b,  stl_ar,  stl_r;

  chan_tester #(.W(AX_W), .N(N), .NAME("AW")) t_aw (
    .clk(aclk), .rst_n(aresetn),
    .src_valid(s_axi_awvalid), .src_ready(s_axi_awready), .src_data(aw_src),
    .snk_valid(m_axi_awvalid), .snk_ready(m_axi_awready), .snk_data(aw_snk),
    .done(done_aw), .errors(err_aw), .stall_cycles(stl_aw));

  chan_tester #(.W(W_W), .N(N), .NAME("W")) t_w (
    .clk(aclk), .rst_n(aresetn),
    .src_valid(s_axi_wvalid), .src_ready(s_axi_wready), .src_data(w_src),
    .snk_valid(m_axi_wvalid), .snk_ready(m_axi_wready), .snk_data(w_snk),
    .done(done_w), .errors(err_w), .stall_cycles(stl_w));

  chan_tester #(.W(B_W), .N(N), .NAME("B")) t_b (
    .clk(aclk), .rst_n(aresetn),
    .src_valid(m_axi_bvalid), .src_ready(m_axi_bready), .src_data(b_src),
    .snk_valid(s_axi_bvalid), .snk_ready(s_axi_bready), .snk_data(b_snk),
    .done(done_b), .errors(err_b), .stall_cycles(stl_b));

  chan_tester #(.W(AX_W), .N(N), .NAME("AR")) t_ar (
    .clk(aclk), .rst_n(aresetn),
    .src_valid(s_axi_arvalid), .src_ready(s_axi_arready), .src_data(ar_src),
    .snk_valid(m_axi_arvalid), .snk_ready(m_axi_arready), .snk_data(ar_snk),
    .done(done_ar), .errors(err_ar), .stall_cycles(stl_ar));

  chan_tester #(.W(R_W), .N(N), .NAME("R")) t_r (
    .clk(aclk), .rst_n(aresetn),
    .src_valid(m_axi_rvalid), .src_ready(m_axi_rready), .src_data(r_src),
    .snk_valid(s_axi_rvalid), .snk_ready(s_axi_rready), .snk_data(r_snk),
    .done(done_r), .errors(err_r), .stall_cycles(stl_r));

  //---------------- Reset-value check: no VALID out of DUT during reset -----
  always @(posedge aclk)
    if (!aresetn && (m_axi_awvalid || m_axi_wvalid || m_axi_arvalid ||
                     s_axi_bvalid  || s_axi_rvalid))
      $error("DUT drives VALID during reset");

  //---------------- Test sequence ----------------
  initial begin
    int total_err;
    aresetn = 1'b0;
    repeat (10) @(posedge aclk);
    aresetn <= 1'b1;
    $display("[%0t] Reset released, running %0d beats per channel", $time, N);

    fork
      wait (done_aw && done_w && done_b && done_ar && done_r);
      begin
        repeat (200_000) @(posedge aclk);
        $error("TIMEOUT: not all channels finished");
      end
    join_any
    disable fork;

    repeat (5) @(posedge aclk);
    total_err = err_aw + err_w + err_b + err_ar + err_r;

    $display("==================================================");
    $display(" Channel | done | errors | backpressure cycles");
    $display("   AW    |  %0d   |  %0d     | %0d", done_aw, err_aw, stl_aw);
    $display("   W     |  %0d   |  %0d     | %0d", done_w,  err_w,  stl_w);
    $display("   B     |  %0d   |  %0d     | %0d", done_b,  err_b,  stl_b);
    $display("   AR    |  %0d   |  %0d     | %0d", done_ar, err_ar, stl_ar);
    $display("   R     |  %0d   |  %0d     | %0d", done_r,  err_r,  stl_r);
    $display("==================================================");
    if (total_err == 0 && done_aw && done_w && done_b && done_ar && done_r)
      $display("*** TEST PASSED ***");
    else
      $display("*** TEST FAILED *** (total errors = %0d)", total_err);
    $finish;
  end

endmodule
