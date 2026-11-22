`timescale 1ns / 1ps

module frame_buffer_dp #(
    parameter DEPTH = 12288,
    parameter ABITS = 14
)(
    // ── Write port (UART / 100 MHz) ────────────────────────────
    input  wire [ABITS-1:0] waddr,
    input  wire [7:0]       wdata,
    input  wire             we,
    input  wire             wclk,

    // ── Read port A: current frame (VGA / 25 MHz) ──────────────
    input  wire [ABITS-1:0] raddr_a,
    output reg  [7:0]       rdata_a,
    input  wire             rclk,

    // ── Read port B: background frame (VGA / 25 MHz) ───────────
    input  wire [ABITS-1:0] raddr_b,
    output reg  [7:0]       rdata_b,

    // ── Background capture control (100 MHz) ───────────────────
    input  wire             capture_bg, // 1-cycle pulse → start copy
    input  wire             sys_clk
);

// ---------------------------------------------------------------------------
// BRAM inference
// ---------------------------------------------------------------------------
(* ram_style = "block" *) reg [7:0] curr_mem [0:DEPTH-1];
(* ram_style = "block" *) reg [7:0] bg_mem   [0:DEPTH-1];

// Initialise to zero so background subtractor is quiet at power-up
integer i;
initial begin
    for (i = 0; i < DEPTH; i = i + 1) begin
        curr_mem[i] = 8'h00;
        bg_mem[i]   = 8'h00;
    end
end

// ---------------------------------------------------------------------------
// Write current frame (UART side)
// ---------------------------------------------------------------------------
always @(posedge wclk)
    if (we) curr_mem[waddr] <= wdata;

// ---------------------------------------------------------------------------
// Read current frame (VGA side)
// ---------------------------------------------------------------------------
always @(posedge rclk)
    rdata_a <= curr_mem[raddr_a];

// ---------------------------------------------------------------------------
// Read background frame (VGA side)
// ---------------------------------------------------------------------------
always @(posedge rclk)
    rdata_b <= bg_mem[raddr_b];

// ---------------------------------------------------------------------------
// Background capture: walk through every address and copy curr → bg.
// At 100 MHz this takes 12288 cycles = 123 µs — imperceptible to the user.
// ---------------------------------------------------------------------------
reg [ABITS-1:0] copy_addr = 0;
reg             copying   = 0;

always @(posedge sys_clk) begin
    if (capture_bg && !copying) begin
        copying   <= 1;
        copy_addr <= 0;
    end

    if (copying) begin
        bg_mem[copy_addr] <= curr_mem[copy_addr];
        if (copy_addr == DEPTH - 1) begin
            copy_addr <= 0;
            copying   <= 0;
        end else
            copy_addr <= copy_addr + 1;
    end
end

endmodule