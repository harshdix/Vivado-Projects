// tb_vga_controller.v
`timescale 1ns / 1ps

module tb_vga_controller;

    reg  pclk  = 0;
    reg  rst   = 1;
    wire hsync, vsync, active;
    wire [9:0] hcount, vcount;

    // 25 MHz pixel clock (40 ns period)
    always #20 pclk = ~pclk;

    vga_controller dut (
        .pclk   (pclk),
        .rst    (rst),
        .hsync  (hsync),
        .vsync  (vsync),
        .hcount (hcount),
        .vcount (vcount),
        .active (active)
    );

    // Expected timing constants
    localparam H_ACTIVE=640, H_FP=16, H_SYNC=96, H_BP=48, H_TOTAL=800;
    localparam V_ACTIVE=480, V_FP=10, V_SYNC=2,  V_BP=33, V_TOTAL=525;

    integer active_count;
    integer hsync_low_count;
    integer vsync_low_count;
    integer frame_count;
    integer h_max, v_max;
    integer cycle;
    reg prev_vs;

    initial begin
        $dumpfile("tb_vga_controller.vcd");
        $dumpvars(0, tb_vga_controller);

        // ---- Reset ----
        rst = 1;
        repeat(4) @(posedge pclk);
        rst = 0;
        $display("\n=== VGA Controller Testbench ===");

        // ---- Collect statistics over exactly 2 frames ----
        active_count    = 0;
        hsync_low_count = 0;
        vsync_low_count = 0;
        frame_count     = 0;
        h_max = 0; v_max = 0;
        prev_vs = 1;

        repeat(2 * H_TOTAL * V_TOTAL) begin
            @(posedge pclk); #1;
            if (active)        active_count    = active_count    + 1;
            if (!hsync)        hsync_low_count = hsync_low_count + 1;
            if (!vsync)        vsync_low_count = vsync_low_count + 1;
            if (!vsync&&prev_vs) frame_count   = frame_count     + 1;
            if (hcount > h_max) h_max = hcount;
            if (vcount > v_max) v_max = vcount;
            prev_vs = vsync;
        end

        // ---- CHECK 1: Active pixel count ----
        $display("\n--- CHECK 1: Active Pixel Count ---");
        if (active_count === 2 * H_ACTIVE * V_ACTIVE)
            $display("PASS: active_count=%0d", active_count);
        else
            $display("FAIL: active_count=%0d, expected=%0d",
                      active_count, 2*H_ACTIVE*V_ACTIVE);

        // ---- CHECK 2: HSYNC pulse width ----
        $display("\n--- CHECK 2: HSYNC Pulse Width ---");
        begin : hs_check
            integer expected;
            expected = 2 * V_TOTAL * H_SYNC;
            if (hsync_low_count === expected)
                $display("PASS: hsync_low_cycles=%0d", hsync_low_count);
            else
                $display("FAIL: hsync_low=%0d, expected=%0d",
                          hsync_low_count, expected);
        end

        // ---- CHECK 3: VSYNC pulse width ----
        $display("\n--- CHECK 3: VSYNC Pulse Width ---");
        begin : vs_check
            integer expected;
            expected = 2 * H_TOTAL * V_SYNC;
            if (vsync_low_count === expected)
                $display("PASS: vsync_low_cycles=%0d", vsync_low_count);
            else
                $display("FAIL: vsync_low=%0d, expected=%0d",
                          vsync_low_count, expected);
        end

        // ---- CHECK 4: Frame count ----
        $display("\n--- CHECK 4: Frame Count ---");
        if (frame_count === 2)
            $display("PASS: frame_count=%0d", frame_count);
        else
            $display("FAIL: frame_count=%0d, expected 2", frame_count);

        // ---- CHECK 5: Counter max values ----
        $display("\n--- CHECK 5: Counter Max Values ---");
        if (h_max === H_TOTAL-1)
            $display("PASS: hcount_max=%0d", h_max);
        else
            $display("FAIL: hcount_max=%0d, expected=%0d", h_max, H_TOTAL-1);

        if (v_max === V_TOTAL-1)
            $display("PASS: vcount_max=%0d", v_max);
        else
            $display("FAIL: vcount_max=%0d, expected=%0d", v_max, V_TOTAL-1);

        // ---- CHECK 6: active=0 when hcount >= 640 ----
        $display("\n--- CHECK 6: active=0 in Horizontal Blanking ---");
        begin : hblank_check
            integer hblank_errors;
            hblank_errors = 0;
            repeat(H_TOTAL) @(posedge pclk) begin
                #1;
                if (hcount >= H_ACTIVE && active)
                    hblank_errors = hblank_errors + 1;
            end
            if (hblank_errors === 0)
                $display("PASS: active=0 in all horizontal blanking cycles");
            else
                $display("FAIL: active=1 during blanking, %0d times",
                          hblank_errors);
        end

        // ---- CHECK 7: active=0 during sync pulses ----
        $display("\n--- CHECK 7: active=0 During Sync Pulses ---");
        begin : sync_active_check
            integer sync_errors;
            sync_errors = 0;
            repeat(H_TOTAL * V_TOTAL) @(posedge pclk) begin
                #1;
                if ((!hsync || !vsync) && active)
                    sync_errors = sync_errors + 1;
            end
            if (sync_errors === 0)
                $display("PASS: active never high during sync");
            else
                $display("FAIL: active=1 during sync, %0d times", sync_errors);
        end

        #1000;
        $display("\n=== VGA Controller Testbench Complete ===");
        $finish;
    end

endmodule