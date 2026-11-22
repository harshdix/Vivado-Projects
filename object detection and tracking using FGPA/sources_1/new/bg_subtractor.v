`timescale 1ns / 1ps

module bg_subtractor (
    input  wire       clk,
    input  wire [7:0] curr_pixel,
    input  wire [7:0] bg_pixel,
    input  wire [7:0] threshold,
    output reg        fg_pixel
);

// 9-bit registers to hold the absolute difference without overflow
reg [8:0] diff;

always @(posedge clk) begin
    // Zero-extend both 8-bit inputs to 9 bits using concatenation
    // then subtract — result is always positive and fits in 9 bits
    diff <= (curr_pixel >= bg_pixel)
                ? ({1'b0, curr_pixel} - {1'b0, bg_pixel})
                : ({1'b0, bg_pixel}   - {1'b0, curr_pixel});

    // Compare diff against threshold (threshold zero-extended to 9 bits)
    fg_pixel <= (diff > {1'b0, threshold});
end

endmodule