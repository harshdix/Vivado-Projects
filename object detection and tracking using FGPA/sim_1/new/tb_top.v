// tb_top_uart_final.v
// Full integration testbench with all fixes applied:
//   - Flag-based pulse capture (no missed frame_done/valid)
//   - Proper VGA frame wait times (3 * ONE_VGA_FRAME)
//   - cx/cy checked with integer bounds (no unsigned wrap)
//   - cy=127 bug detection
//   - Green cross sampled on dut.clk_25 (not CLK100MHZ)
//   - All 7 tests from original + coordinate checks from reduced TB
`timescale 1ns / 1ps

module tb_top;

    localparam CAM_W        = 128;
    localparam CAM_H        = 96;
    localparam FRAME_PIXELS = CAM_W * CAM_H;   // 12288

    // One VGA frame = 800 * 525 * 40ns = 16,800,000ns
    // Use 25ms to give pipeline margin
    localparam ONE_VGA_FRAME = 25_000_000;

    reg CLK100MHZ   = 0;
    reg CPU_RESETN  = 0;
    reg UART_TXD_IN = 1;
    reg BTNC        = 0;

    wire [3:0] VGA_R, VGA_G, VGA_B;
    wire       VGA_HS, VGA_VS;
    wire [3:0] LED;

    always #5 CLK100MHZ = ~CLK100MHZ;   // 100 MHz

    top dut (
        .CLK100MHZ   (CLK100MHZ),
        .CPU_RESETN  (CPU_RESETN),
        .UART_TXD_IN (UART_TXD_IN),
        .BTNC        (BTNC),
        .VGA_R       (VGA_R),
        .VGA_G       (VGA_G),
        .VGA_B       (VGA_B),
        .VGA_HS      (VGA_HS),
        .VGA_VS      (VGA_VS),
        .LED         (LED)
    );

    // =========================================================================
    // Flag capture — catches 1-cycle pulses that procedural code would miss
    // =========================================================================
    reg frame_done_flag     = 0;
    reg centroid_valid_flag = 0;

    always @(posedge CLK100MHZ) begin
        if (LED[2]) frame_done_flag     <= 1;
        if (LED[3]) centroid_valid_flag <= 1;
    end

    task clear_flags;
        begin
            @(negedge CLK100MHZ);
            frame_done_flag     = 0;
            centroid_valid_flag = 0;
        end
    endtask

    // =========================================================================
    // Wait for frame_done_flag with timeout
    // =========================================================================
    task wait_frame_done;
        input integer max_cycles;
        integer t;
        begin
            t = 0;
            while (!frame_done_flag && t < max_cycles) begin
                @(posedge CLK100MHZ); #1;
                t = t + 1;
            end
            if (!frame_done_flag)
                $display("  WARNING: frame_done not seen within %0d cycles", t);
            else
                $display("  Frame fully written to BRAM.");
        end
    endtask

    // =========================================================================
    // UART — 3 Mbaud 8N1 (333 ns per bit at 100 MHz)
    // =========================================================================
    localparam BIT_PERIOD = 333;

    task uart_send_byte;
        input [7:0] b;
        integer i;
        begin
            UART_TXD_IN = 0; #BIT_PERIOD;
            for (i = 0; i < 8; i = i + 1) begin
                UART_TXD_IN = b[i]; #BIT_PERIOD;
            end
            UART_TXD_IN = 1; #BIT_PERIOD;
        end
    endtask

    // =========================================================================
    // Frame transmission helpers
    // All pixel values clamped to max 0xFE so no pixel byte is ever
    // mistaken for a sync marker byte (0xFF/0xFE/0xFD) inside the stream
    // =========================================================================
    task send_header;
        begin
            uart_send_byte(8'hFF);
            uart_send_byte(8'hFE);
            uart_send_byte(8'hFD);
        end
    endtask

    task send_dark_frame;
        integer p;
        begin
            clear_flags;
            send_header;
            for (p = 0; p < FRAME_PIXELS; p = p + 1)
                uart_send_byte(8'h10);   // dark but not zero
        end
    endtask

    task send_blob_frame;
        input [6:0] blob_r1, blob_r2;
        input [6:0] blob_c1, blob_c2;
        integer r, c;
        reg in_blob;
        begin
            clear_flags;
            send_header;
            for (r = 0; r < CAM_H; r = r + 1)
                for (c = 0; c < CAM_W; c = c + 1) begin
                    in_blob = (r >= blob_r1 && r <= blob_r2 &&
                               c >= blob_c1 && c <= blob_c2);
                    // bright blob: 0xD0 (208), background: 0x10 (16)
                    // diff = 192, well above threshold of 25
                    uart_send_byte(in_blob ? 8'hD0 : 8'h10);
                end
        end
    endtask

    // =========================================================================
    // Send frame then wait:
    //   1. For BRAM write to complete (wait_frame_done)
    //   2. Three full VGA frames for centroid pipeline to settle
    // The 3-frame wait is needed because:
    //   Frame 1: fg pixels accumulated
    //   Frame 2: divider runs (42 cycles) and cx/cy latched
    //   Frame 3: VGA output reflects new centroid
    // =========================================================================
    task send_dark_and_wait;
        begin
            send_dark_frame;
            wait_frame_done(200_000);
            #(3 * ONE_VGA_FRAME);
        end
    endtask

    task send_blob_and_wait;
        input [6:0] r1, r2, c1, c2;
        begin
            send_blob_frame(r1, r2, c1, c2);
            wait_frame_done(200_000);
            #(3 * ONE_VGA_FRAME);
        end
    endtask

    // =========================================================================
    // Button press — long enough to clear the 2^20 cycle debounce counter
    // 2^20 cycles at 100 MHz = 10.48 ms, press for 15 ms then settle 5 ms
    // =========================================================================
    task press_btnc;
        begin
            $display("  Pressing BTNC...");
            BTNC = 1; #15_000_000;
            BTNC = 0; #5_000_000;
            $display("  BTNC released.");
        end
    endtask

    // =========================================================================
    // Centroid check with integer arithmetic to avoid unsigned underflow
    // e.g. exp_cx=0, tol=1 → 0-1 wraps to large number in Verilog
    // Also explicitly flags cy=127 (the specific bug we fixed)
    // =========================================================================
    task check_centroid;
        input [6:0]    exp_cx, exp_cy;
        input [3:0]    tol;
        input [8*28:1] label;
        integer gx, gy;
        integer lx, hx, ly, hy;
        begin
            // Read as integers to avoid unsigned comparison issues
            gx = dut.cx;
            gy = dut.cy;
            lx = (exp_cx > tol)       ? (exp_cx - tol) : 0;
            hx = (exp_cx + tol < 127) ? (exp_cx + tol) : 127;
            ly = (exp_cy > tol)       ? (exp_cy - tol) : 0;
            hy = (exp_cy + tol < 95)  ? (exp_cy + tol) : 95;

            if (!centroid_valid_flag) begin
                $display("FAIL [%s]: centroid_valid never asserted", label);
                $display("           sum_n may be below MIN_PIX=100");
            end else if (gx >= lx && gx <= hx &&
                         gy >= ly && gy <= hy) begin
                $display("PASS [%s]: cx=%0d cy=%0d (expected ~%0d,~%0d)",
                          label, gx, gy, exp_cx, exp_cy);
            end else begin
                $display("FAIL [%s]: cx=%0d cy=%0d (expected ~%0d,~%0d)",
                          label, gx, gy, exp_cx, exp_cy);
            end

            // Explicit cy=127 trap — catches the lat_y/lat_n bug
            if (gy == 127 && exp_cy !== 127)
                $display("  !! cy=127 detected — lat_y fix not working !!");
        end
    endtask

    // =========================================================================
    // VGA green pixel counter — must sample on clk_25 (VGA pixel clock)
    // Sampling on CLK100MHZ sees the same pixel 4× and misses transitions
    // =========================================================================
    integer green_count;
    integer vga_errors;

    task count_green_pixels;
        begin
            green_count = 0;
            // Wait for start of next active frame (rising edge of vsync)
            @(posedge VGA_VS);
            // Sample exactly 640*480 pixel clocks
            begin : green_scan
                integer p;
                for (p = 0; p < 640 * 480; p = p + 1) begin
                    @(posedge dut.clk_25); #1;
                    // Green cross: R=0, G=F, B=0, inside active area
                    if (VGA_G == 4'hF && VGA_R == 4'h0 &&
                        VGA_B == 4'h0 && VGA_HS && VGA_VS)
                        green_count = green_count + 1;
                end
            end
        end
    endtask

    // =========================================================================
    // Main test sequence
    // =========================================================================
    initial begin
        $dumpfile("tb_top.vcd");
        $dumpvars(0, dut.u_cent);    // centroid internals (cx/cy/divider)
        $dumpvars(0, dut.u_bgsub);   // bg subtractor (fg_pixel)
        $dumpvars(0, dut.u_fb);      // frame buffer (curr/bg pixel)
        $dumpvars(1, dut);           // top-level ports (depth 1 only)

        // ── Power-on reset ────────────────────────────────────────────
        CPU_RESETN = 0;
        #500;
        CPU_RESETN = 1;
        // Wait for PLL (clk_wiz_0) to lock — typically ~100 µs
        #200_000;

        $display("\n========================================");
        $display("   Integration Testbench (Full+Checks)");
        $display("========================================\n");

        // =================================================================
        // TEST 1: UART sync LED state machine
        // Verifies frame_receiver state transitions visible on LEDs
        // Already passed before — kept as a quick sanity check
        // =================================================================
        $display("--- TEST 1: Sync LED State Machine ---");
        clear_flags;

        uart_send_byte(8'hFF);
        repeat(20) @(posedge CLK100MHZ); #1;
        if (LED[1:0] == 2'd1)
            $display("PASS: LED=01 after 0xFF (state WAIT_FE)");
        else
            $display("FAIL: LED=%02b after 0xFF, expected 01", LED[1:0]);

        uart_send_byte(8'hFE);
        repeat(20) @(posedge CLK100MHZ); #1;
        if (LED[1:0] == 2'd2)
            $display("PASS: LED=10 after 0xFE (state WAIT_FD)");
        else
            $display("FAIL: LED=%02b after 0xFE, expected 10", LED[1:0]);

        uart_send_byte(8'hFD);
        repeat(20) @(posedge CLK100MHZ); #1;
        if (LED[1:0] == 2'd3)
            $display("PASS: LED=11 after 0xFD (state RECV)");
        else
            $display("FAIL: LED=%02b after 0xFD, expected 11", LED[1:0]);

        // Flush the partial frame started by the 3 sync bytes above
        begin : flush_test1
            integer p;
            for (p = 0; p < FRAME_PIXELS; p = p + 1)
                uart_send_byte(8'h10);
        end
        wait_frame_done(200_000);
        if (frame_done_flag)
            $display("PASS: LED[2] (frame_done) captured by flag");
        else
            $display("FAIL: frame_done flag never set after flush");

        // =================================================================
        // TEST 2: Background capture
        // Send a dark frame, wait for BRAM write, then capture background.
        // Checks that bg_mem is populated before object detection.
        // =================================================================
        $display("\n--- TEST 2: Background Capture ---");
        $display("  Sending dark frame...");
        send_dark_and_wait;

        press_btnc;
        // Wait for background copy (FRAME_PIXELS cycles at 100MHz = ~123 µs)
        // Use 1ms to be safe
        #1_000_000;
        $display("  Background captured.");

        // Verify bg_pixel is now 0x10 (not 0x00) at a known address
        // Address 0 = pixel (col=0, row=0) which was sent as 0x10
        // We access the BRAM through the DUT's internal signals
        begin : bg_check
            // Drive a read address into the frame buffer
            // (BRAM read is registered so we wait 2 cycles after address)
            // We read through the VGA path by checking dut.bg_pixel
            // when hcount=0, vcount=0 (fb_raddr=0)
            @(posedge dut.clk_25);
            @(posedge dut.clk_25); #1;
            if (dut.bg_pixel === 8'h10)
                $display("PASS: bg_pixel=0x10 at addr 0 (background written)");
            else if (dut.bg_pixel === 8'h00)
                $display("FAIL: bg_pixel=0x00 — background capture did not fire");
            else
                $display("INFO: bg_pixel=0x%02X at addr 0", dut.bg_pixel);
        end

        // =================================================================
        // TEST 3: Object detection — centroid position check
        // Blob rows 40..55 (16 rows), cols 55..72 (18 cols) = 288 fg pixels
        // Expected centroid:
        //   cx = (55+56+...+72)/18 = 63
        //   cy = (40+41+...+55)/16 = 47
        // =================================================================
        $display("\n--- TEST 3: Object Detection ---");
        $display("  Blob rows 40..55, cols 55..72 — expected cx≈63 cy≈47");
        send_blob_and_wait(40, 55, 55, 72);
        check_centroid(63, 47, 3, "DETECT_cx63_cy47            ");

        // =================================================================
        // TEST 4: Green cross visible on VGA
        // Only meaningful if TEST 3 produced a valid centroid on-screen.
        // Cross at cx_vga=63*5=315, cy_vga=47*5=235 — well within 640x480.
        // Expected green pixel count ≈ 2*(2*ARM+1) - 1 = 2*41-1 = 81
        // =================================================================
        $display("\n--- TEST 4: Green Cross on VGA ---");
        $display("  Expected cross position: VGA (%0d,%0d)",
                  dut.cx * 5, dut.cy * 5);

        count_green_pixels;

        // Cross arm = ARM=20 → 2*20+1=41 px per arm, minus 1 overlap = 81
        if (green_count >= 70 && green_count <= 90)
            $display("PASS: %0d green pixels — cross fully visible", green_count);
        else if (green_count > 0)
            $display("PASS: %0d green pixels found (cross visible)", green_count);
        else begin
            $display("FAIL: 0 green pixels");
            $display("      cx_vga=%0d (need <640)   cy_vga=%0d (need <480)",
                      dut.cx * 5, dut.cy * 5);
            $display("      centroid_valid=%0b", dut.centroid_valid);
        end

        // =================================================================
        // TEST 5: VGA outputs zero during sync intervals
        // Samples during vertical blanking where hsync or vsync is low.
        // =================================================================
        $display("\n--- TEST 5: VGA Zero During Blanking ---");
        vga_errors = 0;
        @(negedge VGA_VS);   // wait for vsync pulse to start
        // Sample 800*35 cycles (covers V_SYNC + V_BP periods)
        repeat(800 * 35) @(posedge dut.clk_25) begin
            #1;
            if (!VGA_HS || !VGA_VS)
                if (VGA_R !== 4'h0 || VGA_G !== 4'h0 || VGA_B !== 4'h0)
                    vga_errors = vga_errors + 1;
        end
        if (vga_errors == 0)
            $display("PASS: VGA output is zero during all sync intervals");
        else
            $display("FAIL: %0d non-zero pixels during sync", vga_errors);

        // =================================================================
        // TEST 6: Dark frame → centroid invalid (object leaves scene)
        // After sending a dark frame that matches background,
        // fg_pixel should be 0 everywhere, centroid_valid should go low.
        // =================================================================
        $display("\n--- TEST 6: Dark Frame → Object Lost ---");
        clear_flags;
        send_dark_and_wait;

        // Check LED[3] directly — centroid_valid_flag should NOT be set
        // because no fg pixels accumulated in this frame
        if (!LED[3])
            $display("PASS: centroid_valid=0 — object correctly lost");
        else begin
            // centroid may persist one extra frame — check after another frame
            #ONE_VGA_FRAME;
            if (!LED[3])
                $display("PASS: centroid_valid=0 after extra frame");
            else
                $display("FAIL: centroid_valid still 1 after dark frame");
        end

        // Also confirm centroid_valid_flag was never set during this test
        if (!centroid_valid_flag)
            $display("PASS: centroid_valid_flag never raised in dark frame");
        else
            $display("INFO: centroid_valid briefly asserted during dark frame");

        // =================================================================
        // TEST 7: Object movement tracking
        // Three blob positions — verifies both cx and cy track correctly.
        // cy=127 bug would show here as cy never changing.
        //
        // Frame A: blob left  — cols 10..30, rows 40..55
        //          expected cx≈20, cy≈47
        // Frame B: blob right — cols 90..110, rows 40..55
        //          expected cx≈100, cy≈47 (cy same as A — horizontal move)
        // Frame C: blob up    — cols 55..72, rows 10..25
        //          expected cx≈63, cy≈17 (cy must change — vertical move)
        // =================================================================
        $display("\n--- TEST 7: Movement Tracking ---");

        // Frame A: left
        $display("  Frame A: cols 10..30, rows 40..55 → cx≈20 cy≈47");
        clear_flags;
        send_blob_and_wait(40, 55, 10, 30);
        check_centroid(20, 47, 3, "MOVE_A_cx20_cy47            ");

        // Frame B: right (same row — only cx should change)
        $display("  Frame B: cols 90..110, rows 40..55 → cx≈100 cy≈47");
        clear_flags;
        send_blob_and_wait(40, 55, 90, 110);
        check_centroid(100, 47, 3, "MOVE_B_cx100_cy47           ");

        // Frame C: top-centre (cy must change — this catches cy=127 bug)
        $display("  Frame C: cols 55..72, rows 10..25 → cx≈63 cy≈17");
        clear_flags;
        send_blob_and_wait(10, 25, 55, 72);
        check_centroid(63, 17, 3, "MOVE_C_cx63_cy17            ");

        // Confirm green cross moved to new position in Frame C
        $display("  Checking green cross moved to cy≈17*5=85 on VGA...");
        count_green_pixels;
        if (green_count > 0)
            $display("PASS: %0d green pixels at new position (cx_vga=%0d cy_vga=%0d)",
                      green_count, dut.cx * 5, dut.cy * 5);
        else
            $display("FAIL: 0 green pixels after vertical movement");

        // =================================================================
        // Final summary
        // =================================================================
        #1_000_000;
        $display("\n========================================");
        $display("   Testbench Complete");
        $display("========================================");
        $display("Signals to verify in waveform:");
        $display("  dut.hscaled      — must be nonzero (e.g. 65600 at hcount=320)");
        $display("  dut.fb_x/fb_y    — must count 0..127 / 0..95");
        $display("  dut.fb_raddr     — must be nonzero in active region");
        $display("  dut.curr_pixel   — must show 0xD0 in blob, 0x10 outside");
        $display("  dut.bg_pixel     — must show 0x10 everywhere after capture");
        $display("  dut.fg_pixel     — must be 1 in blob area only");
        $display("  dut.u_cent.cx/cy — must match expected values above");
        $display("  VGA_G            — must pulse 0xF at cross pixels");
        $finish;
    end

endmodule