`timescale 1ns / 1ps

module vga_controller (
    input  wire        pclk,    // 25 MHz pixel clock
    input  wire        rst,     // synchronous active-high reset
    output reg         hsync,   // horizontal sync (active low)
    output reg         vsync,   // vertical   sync (active low)
    output reg  [9:0]  hcount,  // 0 .. 799
    output reg  [9:0]  vcount,  // 0 .. 524
    output wire        active   // 1 when inside the 640x480 visible area
);

// ---------------------------------------------------------------------------
// Timing constants
// ---------------------------------------------------------------------------
localparam H_ACTIVE = 640,  H_FP = 16,  H_SYNC = 96,  H_BP = 48;
localparam V_ACTIVE = 480,  V_FP = 10,  V_SYNC =  2,  V_BP = 33;
localparam H_TOTAL  = H_ACTIVE + H_FP + H_SYNC + H_BP;   // 800
localparam V_TOTAL  = V_ACTIVE + V_FP + V_SYNC + V_BP;   // 525

// Sync pulse windows (counts where sync is asserted)
localparam HS_START = H_ACTIVE + H_FP;                    // 656
localparam HS_END   = H_ACTIVE + H_FP + H_SYNC;           // 752
localparam VS_START = V_ACTIVE + V_FP;                    // 490
localparam VS_END   = V_ACTIVE + V_FP + V_SYNC;           // 492

// ---------------------------------------------------------------------------
// Counters
// ---------------------------------------------------------------------------
always @(posedge pclk) begin
    if (rst) begin
        hcount <= 0;
        vcount <= 0;
    end else begin
        if (hcount == H_TOTAL - 1) begin
            hcount <= 0;
            vcount <= (vcount == V_TOTAL - 1) ? 10'd0 : vcount + 1;
        end else
            hcount <= hcount + 1;
    end
end

// ---------------------------------------------------------------------------
// Sync signals (registered for clean output timing)
// ---------------------------------------------------------------------------
always @(posedge pclk) begin
    hsync <= ~(hcount >= HS_START && hcount < HS_END);
    vsync <= ~(vcount >= VS_START && vcount < VS_END);
end

// ---------------------------------------------------------------------------
// Active region (combinational — used inside top module for pixel mux)
// ---------------------------------------------------------------------------
assign active = (hcount < H_ACTIVE) && (vcount < V_ACTIVE);

endmodule