//------------------------------------------------------------------------------
// axi4_queue.sv
// AXI4 queue (buffer) component, as used as the DUT in the paper.
//  - One AXI4 subordinate port (s_axi_*)  <- connected to an upstream manager
//  - One AXI4 manager port     (m_axi_*)  -> connected to a downstream subordinate
//  - Five independent FIFOs, one per channel:
//      AW, W, AR : s_axi -> m_axi
//      B,  R     : m_axi -> s_axi
//  - Per the paper's use case: no REGION / QoS signals, no out-of-order,
//    no read interleaving (the queue is in-order by construction).
//------------------------------------------------------------------------------
module axi4_queue #(
  parameter int ID_W   = 4,
  parameter int ADDR_W = 32,
  parameter int DATA_W = 128,
  parameter int DEPTH  = 4
)(
  input  logic                aclk,
  input  logic                aresetn,

  //==================== Subordinate port (from upstream manager) =============
  // Write address
  input  logic [ID_W-1:0]     s_axi_awid,
  input  logic [ADDR_W-1:0]   s_axi_awaddr,
  input  logic [7:0]          s_axi_awlen,
  input  logic [2:0]          s_axi_awsize,
  input  logic [1:0]          s_axi_awburst,
  input  logic                s_axi_awlock,
  input  logic [3:0]          s_axi_awcache,
  input  logic [2:0]          s_axi_awprot,
  input  logic                s_axi_awvalid,
  output logic                s_axi_awready,
  // Write data
  input  logic [DATA_W-1:0]   s_axi_wdata,
  input  logic [DATA_W/8-1:0] s_axi_wstrb,
  input  logic                s_axi_wlast,
  input  logic                s_axi_wvalid,
  output logic                s_axi_wready,
  // Write response
  output logic [ID_W-1:0]     s_axi_bid,
  output logic [1:0]          s_axi_bresp,
  output logic                s_axi_bvalid,
  input  logic                s_axi_bready,
  // Read address
  input  logic [ID_W-1:0]     s_axi_arid,
  input  logic [ADDR_W-1:0]   s_axi_araddr,
  input  logic [7:0]          s_axi_arlen,
  input  logic [2:0]          s_axi_arsize,
  input  logic [1:0]          s_axi_arburst,
  input  logic                s_axi_arlock,
  input  logic [3:0]          s_axi_arcache,
  input  logic [2:0]          s_axi_arprot,
  input  logic                s_axi_arvalid,
  output logic                s_axi_arready,
  // Read data
  output logic [ID_W-1:0]     s_axi_rid,
  output logic [DATA_W-1:0]   s_axi_rdata,
  output logic [1:0]          s_axi_rresp,
  output logic                s_axi_rlast,
  output logic                s_axi_rvalid,
  input  logic                s_axi_rready,

  //==================== Manager port (to downstream subordinate) =============
  // Write address
  output logic [ID_W-1:0]     m_axi_awid,
  output logic [ADDR_W-1:0]   m_axi_awaddr,
  output logic [7:0]          m_axi_awlen,
  output logic [2:0]          m_axi_awsize,
  output logic [1:0]          m_axi_awburst,
  output logic                m_axi_awlock,
  output logic [3:0]          m_axi_awcache,
  output logic [2:0]          m_axi_awprot,
  output logic                m_axi_awvalid,
  input  logic                m_axi_awready,
  // Write data
  output logic [DATA_W-1:0]   m_axi_wdata,
  output logic [DATA_W/8-1:0] m_axi_wstrb,
  output logic                m_axi_wlast,
  output logic                m_axi_wvalid,
  input  logic                m_axi_wready,
  // Write response
  input  logic [ID_W-1:0]     m_axi_bid,
  input  logic [1:0]          m_axi_bresp,
  input  logic                m_axi_bvalid,
  output logic                m_axi_bready,
  // Read address
  output logic [ID_W-1:0]     m_axi_arid,
  output logic [ADDR_W-1:0]   m_axi_araddr,
  output logic [7:0]          m_axi_arlen,
  output logic [2:0]          m_axi_arsize,
  output logic [1:0]          m_axi_arburst,
  output logic                m_axi_arlock,
  output logic [3:0]          m_axi_arcache,
  output logic [2:0]          m_axi_arprot,
  output logic                m_axi_arvalid,
  input  logic                m_axi_arready,
  // Read data
  input  logic [ID_W-1:0]     m_axi_rid,
  input  logic [DATA_W-1:0]   m_axi_rdata,
  input  logic [1:0]          m_axi_rresp,
  input  logic                m_axi_rlast,
  input  logic                m_axi_rvalid,
  output logic                m_axi_rready
);

  //--------------------------------------------------------------------------
  // Packed channel widths
  //--------------------------------------------------------------------------
  localparam int STRB_W = DATA_W/8;
  localparam int AX_W   = ID_W + ADDR_W + 8 + 3 + 2 + 1 + 4 + 3; // id,addr,len,size,burst,lock,cache,prot
  localparam int W_W    = DATA_W + STRB_W + 1;                   // data,strb,last
  localparam int B_W    = ID_W + 2;                              // id,resp
  localparam int R_W    = ID_W + DATA_W + 2 + 1;                 // id,data,resp,last

  //--------------------------------------------------------------------------
  // AW channel : s -> m
  //--------------------------------------------------------------------------
  logic [AX_W-1:0] aw_in, aw_out;
  assign aw_in = {s_axi_awid, s_axi_awaddr, s_axi_awlen, s_axi_awsize,
                  s_axi_awburst, s_axi_awlock, s_axi_awcache, s_axi_awprot};
  assign {m_axi_awid, m_axi_awaddr, m_axi_awlen, m_axi_awsize,
          m_axi_awburst, m_axi_awlock, m_axi_awcache, m_axi_awprot} = aw_out;

  axi_fifo #(.WIDTH(AX_W), .DEPTH(DEPTH)) u_aw_fifo (
    .clk(aclk), .rst_n(aresetn),
    .in_valid (s_axi_awvalid), .in_ready (s_axi_awready), .in_data (aw_in),
    .out_valid(m_axi_awvalid), .out_ready(m_axi_awready), .out_data(aw_out)
  );

  //--------------------------------------------------------------------------
  // W channel : s -> m
  //--------------------------------------------------------------------------
  logic [W_W-1:0] w_in, w_out;
  assign w_in = {s_axi_wdata, s_axi_wstrb, s_axi_wlast};
  assign {m_axi_wdata, m_axi_wstrb, m_axi_wlast} = w_out;

  axi_fifo #(.WIDTH(W_W), .DEPTH(DEPTH)) u_w_fifo (
    .clk(aclk), .rst_n(aresetn),
    .in_valid (s_axi_wvalid), .in_ready (s_axi_wready), .in_data (w_in),
    .out_valid(m_axi_wvalid), .out_ready(m_axi_wready), .out_data(w_out)
  );

  //--------------------------------------------------------------------------
  // B channel : m -> s
  //--------------------------------------------------------------------------
  logic [B_W-1:0] b_in, b_out;
  assign b_in = {m_axi_bid, m_axi_bresp};
  assign {s_axi_bid, s_axi_bresp} = b_out;

  axi_fifo #(.WIDTH(B_W), .DEPTH(DEPTH)) u_b_fifo (
    .clk(aclk), .rst_n(aresetn),
    .in_valid (m_axi_bvalid), .in_ready (m_axi_bready), .in_data (b_in),
    .out_valid(s_axi_bvalid), .out_ready(s_axi_bready), .out_data(b_out)
  );

  //--------------------------------------------------------------------------
  // AR channel : s -> m
  //--------------------------------------------------------------------------
  logic [AX_W-1:0] ar_in, ar_out;
  assign ar_in = {s_axi_arid, s_axi_araddr, s_axi_arlen, s_axi_arsize,
                  s_axi_arburst, s_axi_arlock, s_axi_arcache, s_axi_arprot};
  assign {m_axi_arid, m_axi_araddr, m_axi_arlen, m_axi_arsize,
          m_axi_arburst, m_axi_arlock, m_axi_arcache, m_axi_arprot} = ar_out;

  axi_fifo #(.WIDTH(AX_W), .DEPTH(DEPTH)) u_ar_fifo (
    .clk(aclk), .rst_n(aresetn),
    .in_valid (s_axi_arvalid), .in_ready (s_axi_arready), .in_data (ar_in),
    .out_valid(m_axi_arvalid), .out_ready(m_axi_arready), .out_data(ar_out)
  );

  //--------------------------------------------------------------------------
  // R channel : m -> s
  //--------------------------------------------------------------------------
  logic [R_W-1:0] r_in, r_out;
  assign r_in = {m_axi_rid, m_axi_rdata, m_axi_rresp, m_axi_rlast};
  assign {s_axi_rid, s_axi_rdata, s_axi_rresp, s_axi_rlast} = r_out;

  axi_fifo #(.WIDTH(R_W), .DEPTH(DEPTH)) u_r_fifo (
    .clk(aclk), .rst_n(aresetn),
    .in_valid (m_axi_rvalid), .in_ready (m_axi_rready), .in_data (r_in),
    .out_valid(s_axi_rvalid), .out_ready(s_axi_rready), .out_data(r_out)
  );

endmodule
