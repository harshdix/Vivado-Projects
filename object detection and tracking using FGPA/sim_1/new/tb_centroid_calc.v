// tb_centroid_fix.v
// Only tests the lat_y/lat_n fix — confirms cy is no longer 127.
// Skips all cases already verified in the full testbench.
`timescale 1ns / 1ps

module tb_centroid_calc;

    reg        clk         = 0;
    reg        rst         = 1;
    reg        frame_start = 0;
    reg        frame_end   = 0;
    reg        pixel_valid = 0;
    reg        fg          = 0;
    reg [6:0]  px          = 0;
    reg [6:0]  py          = 0;

    wire [6:0] cx, cy;
    wire       valid;

    always #20 clk = ~clk;   // 25 MHz

    centroid_calc #(
        .SUM_BITS (21),
        .CNT_BITS (14),
        .X_BITS   (7),
        .Y_BITS   (7),
        .MIN_PIX  (100)
    ) dut (
        .clk         (clk),
        .rst         (rst),
        .frame_start (frame_start),
        .frame_end   (frame_end),
        .pixel_valid (pixel_valid),
        .fg          (fg),
        .px          (px),
        .py          (py),
        .cx          (cx),
        .cy          (cy),
        .valid       (valid)
    );

    // ------------------------------------------------------------------
    // Send N identical fg pixels then trigger frame_end+frame_start
    // together (exactly as top_uart does — same signal for both)
    // ------------------------------------------------------------------
    task run_frame;
        input [6:0]  blob_cx, blob_cy;
        input [13:0] count;
        integer i;
        begin
            // Accumulate pixels
            for (i = 0; i < count; i = i + 1) begin
                @(negedge clk);
                px = blob_cx; py = blob_cy;
                pixel_valid = 1; fg = 1;
                @(negedge clk);
                pixel_valid = 0; fg = 0;
            end

            // Fire frame_end AND frame_start on the same cycle
            // This is exactly what top_uart does (same signal)
            @(negedge clk);
            frame_end   = 1;
            frame_start = 1;
            @(negedge clk);
            frame_end   = 0;
            frame_start = 0;

            // Wait for divider: 2 * SUM_BITS + margin = 2*21+10 = 52 cycles
            repeat(55) @(posedge clk);
            #1;
        end
    endtask

    // ------------------------------------------------------------------
    // Check with integer comparison to avoid boundary wrap bugs
    // ------------------------------------------------------------------
    task check;
        input [6:0]    exp_cx, exp_cy;
        input [3:0]    tol;
        input [8*24:1] label;
        integer gx, gy, lx, hx, ly, hy;
        begin
            gx = cx; gy = cy;
            lx = (exp_cx > tol) ? exp_cx - tol : 0;
            hx = (exp_cx + tol < 127) ? exp_cx + tol : 127;
            ly = (exp_cy > tol) ? exp_cy - tol : 0;
            hy = (exp_cy + tol < 95)  ? exp_cy + tol : 95;

            if (!valid)
                $display("FAIL [%s]: valid=0", label);
            else if (gx >= lx && gx <= hx && gy >= ly && gy <= hy)
                $display("PASS [%s]: cx=%0d cy=%0d (exp ~%0d,~%0d)",
                          label, cx, cy, exp_cx, exp_cy);
            else
                $display("FAIL [%s]: cx=%0d cy=%0d (exp ~%0d,~%0d)",
                          label, cx, cy, exp_cx, exp_cy);

            // Explicit cy≠127 check — the specific bug we fixed
            if (cy === 7'd127 && exp_cy !== 7'd127)
                $display("  !! cy=127 detected — lat_y fix not working !!");
        end
    endtask

    initial begin
        $dumpfile("tb_centroid_calc.vcd");
        $dumpvars(0, tb_centroid_calc);

        repeat(3) @(posedge clk);
        rst = 0; #1;

        $display("\n=== Centroid cy Fix Verification ===");
        $display("(All tests use same frame_end+frame_start signal");
        $display(" — identical to top_uart behaviour)\n");

        // ---- TEST 1: cy must NOT be 127 ----
        // This was the exact failing case — blob at (63,47)
        $display("--- TEST 1: Blob at (63,47) — cy must be ~47 not 127 ---");
        run_frame(63, 47, 200);
        check(63, 47, 2, "CENTRE_63_47            ");

        // ---- TEST 2: cy at top of frame ----
        $display("--- TEST 2: Blob at (64,5) — cy must be ~5 not 127 ---");
        run_frame(64, 5, 200);
        check(64, 5, 2, "TOP_ROW_5               ");

        // ---- TEST 3: cy at bottom of frame ----
        $display("--- TEST 3: Blob at (64,90) — cy must be ~90 not 127 ---");
        run_frame(64, 90, 200);
        check(64, 90, 2, "BOT_ROW_90              ");

        // ---- TEST 4: Replicate integration test 3 exactly ----
        // Blob rows 40..55 cols 55..72 → cx≈63 cy≈47
        // send_frame_with_blob sends each pixel once so:
        // sum_x = sum of all col values from 55 to 72 per row (16 rows)
        // Exact: cx = (55+56+...+72)/18 = 63, cy = (40+41+...+55)/16 = 47
        $display("--- TEST 4: Integration blob (rows 40-55, cols 55-72) ---");
        begin : int_blob
            integer r, c;
            // frame_start to clear
            @(negedge clk);
            frame_start = 1;
            @(negedge clk);
            frame_start = 0;

            // Submit blob pixels
            for (r = 40; r <= 55; r = r + 1) begin
                for (c = 55; c <= 72; c = c + 1) begin
                    @(negedge clk);
                    px = c[6:0]; py = r[6:0];
                    pixel_valid = 1; fg = 1;
                    @(negedge clk);
                    pixel_valid = 0; fg = 0;
                end
            end

            // Trigger frame_end + frame_start together
            @(negedge clk);
            frame_end = 1; frame_start = 1;
            @(negedge clk);
            frame_end = 0; frame_start = 0;

            repeat(55) @(posedge clk); #1;
        end
        check(63, 47, 2, "INT_BLOB_63_47          ");

        // ---- TEST 5: Movement — cx changes, cy stays same ----
        $display("--- TEST 5: Movement cx 20→100, cy stays at 48 ---");
        run_frame(20, 48, 200);
        check(20, 48, 2, "MOVE_LEFT_20_48         ");
        run_frame(100, 48, 200);
        check(100, 48, 2, "MOVE_RIGHT_100_48       ");

        #500;
        $display("\n=== Centroid Fix Testbench Complete ===");
        $finish;
    end

endmodule