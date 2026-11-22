// tb_bg_subtractor.v
`timescale 1ns / 1ps

module tb_bg_subtractor;

    reg       clk       = 0;
    reg [7:0] curr      = 0;
    reg [7:0] bg        = 0;
    reg [7:0] threshold = 8'd25;
    wire      fg;

    always #5 clk = ~clk;

    bg_subtractor dut (
        .clk        (clk),
        .curr_pixel (curr),
        .bg_pixel   (bg),
        .threshold  (threshold),
        .fg_pixel   (fg)
    );

    // ------------------------------------------------------------------
    // Task: apply inputs, wait 2 cycles (pipeline), check output
    // ------------------------------------------------------------------
    task check;
        input [7:0]       c, b, th;
        input             expected;
        input [8*16:1]    label;
        reg   [8:0]       abs_diff;
        begin
            curr = c; bg = b; threshold = th;
            @(posedge clk); @(posedge clk); #1;
            abs_diff = (c >= b) ? (c - b) : (b - c);
            if (fg === expected)
                $display("PASS [%s]: curr=%3d bg=%3d th=%3d diff=%3d fg=%0b",
                          label, c, b, th, abs_diff, fg);
            else
                $display("FAIL [%s]: curr=%3d bg=%3d th=%3d diff=%3d " ,
                          label, c, b, th, abs_diff,
                          "got fg=%0b expected=%0b", fg, expected);
        end
    endtask

    integer t;

    initial begin
        $dumpfile("tb_bg_subtractor.vcd");
        $dumpvars(0, tb_bg_subtractor);
        #20;

        $display("\n=== TEST 1: Basic Cases ===");
        check(100, 100, 25,  0, "SAME    ");   // diff=0  → bg
        check(130, 100, 25,  1, "ABOVE_TH");  // diff=30 → fg
        check(125, 100, 25,  0, "AT_TH   ");  // diff=25 → NOT > th
        check(126, 100, 25,  1, "JUST_OVR");  // diff=26 → fg
        check( 70, 100, 25,  1, "NEG_DIFF");  // diff=30 → fg (negative subtraction)
        check(  0,   0, 25,  0, "BOTH_ZERO"); // diff=0  → bg
        check(255,   0, 25,  1, "MAX_DIFF");  // diff=255 → fg
        check(  0, 255, 25,  1, "MAX_NEG ");  // diff=255 → fg

        $display("\n=== TEST 2: Threshold Boundary Sweep ===");
        $display("    (curr=150, bg=100, diff=50)");
        for (t = 45; t <= 55; t = t + 1) begin
            curr = 150; bg = 100; threshold = t;
            @(posedge clk); @(posedge clk); #1;
            $display("  threshold=%2d → fg=%0b (expected %0b)",
                      t, fg, (50 > t) ? 1'b1 : 1'b0);
        end

        $display("\n=== TEST 3: Overflow Safety ===");
        // 9-bit extension means 255-0=255 and 0-255 wraps without issue
        check(255,   1, 25,  1, "255vs1  ");  // diff=254
        check(  1, 255, 25,  1, "1vs255  ");  // diff=254
        check(128, 127, 25,  0, "ONEAPART");  // diff=1 → bg

        $display("\n=== TEST 4: Zero Threshold ===");
        // With threshold=0: any diff>0 is foreground
        check(100, 100, 0,  0, "SAME_TH0");  // diff=0, not >0
        check(101, 100, 0,  1, "DIFF_TH0");  // diff=1, >0

        $display("\n=== TEST 5: Max Threshold ===");
        // With threshold=255: only diff=256 would trigger — impossible with 8-bit
        check(255,   0, 255, 0, "MAX_TH  ");  // diff=255, not >255
        check(  0,   0, 255, 0, "ZERO_MAX");

        #100;
        $display("\n=== BG Subtractor Testbench Complete ===");
        $finish;
    end

endmodule