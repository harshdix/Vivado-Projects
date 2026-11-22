//------------------------------------------------------------------------------
// axi_fifo.sv
// Generic synchronous FIFO with VALID/READY handshakes on both sides.
// - First-word fall-through: out_data is valid in the same cycle out_valid=1
// - in_ready depends only on internal state (no combinational READY->READY path)
// - out_valid depends only on internal state (AXI rule: VALID must not wait on READY)
// - Synchronous active-low reset (Xilinx-friendly)
//------------------------------------------------------------------------------
module axi_fifo #(
  parameter int WIDTH = 8,
  parameter int DEPTH = 4          // use >= 2 for full throughput
)(
  input  logic             clk,
  input  logic             rst_n,

  // write (input) side
  input  logic             in_valid,
  output logic             in_ready,
  input  logic [WIDTH-1:0] in_data,

  // read (output) side
  output logic             out_valid,
  input  logic             out_ready,
  output logic [WIDTH-1:0] out_data
);

  localparam int PTR_W = (DEPTH > 1) ? $clog2(DEPTH) : 1;
  localparam int CNT_W = $clog2(DEPTH + 1);

  logic [WIDTH-1:0] mem [DEPTH];
  logic [PTR_W-1:0] wr_ptr, rd_ptr;
  logic [CNT_W-1:0] count;

  logic push, pop;

  assign in_ready  = (count != CNT_W'(DEPTH));
  assign out_valid = (count != '0);
  assign out_data  = mem[rd_ptr];

  assign push = in_valid  && in_ready;
  assign pop  = out_valid && out_ready;

  // storage (no reset needed on data)
  always_ff @(posedge clk) begin
    if (push)
      mem[wr_ptr] <= in_data;
  end

  // pointers and occupancy
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wr_ptr <= '0;
      rd_ptr <= '0;
      count  <= '0;
    end else begin
      if (push)
        wr_ptr <= (wr_ptr == PTR_W'(DEPTH-1)) ? '0 : wr_ptr + 1'b1;
      if (pop)
        rd_ptr <= (rd_ptr == PTR_W'(DEPTH-1)) ? '0 : rd_ptr + 1'b1;

      case ({push, pop})
        2'b10:   count <= count + 1'b1;
        2'b01:   count <= count - 1'b1;
        default: count <= count;     // 00 or 11: no change
      endcase
    end
  end

endmodule
