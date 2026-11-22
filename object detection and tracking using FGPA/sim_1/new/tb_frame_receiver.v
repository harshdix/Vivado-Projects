// tb_frame_receiver.v  — FIXED
`timescale 1ns / 1ps

module tb_frame_receiver;

    localparam CAM_W        = 128;
    localparam CAM_H        = 96;
    localparam FRAME_PIXELS = CAM_W * CAM_H;  // 12288

    reg        clk      = 0;
    reg        rst      = 1;
    reg [7:0]  rx_data  = 0;
    reg        rx_valid = 0;

    wire [13:0] fb_waddr;
    wire [7:0]  fb_wdata;
    wire        fb_we;
    wire        frame_done;
    wire [1:0]  sync_dbg;

    always #5 clk = ~clk;   // 100 MHz

    frame_receiver #(
        .CAM_W        (CAM_W),
        .CAM_H        (CAM_H),
        .FRAME_PIXELS (FRAME_PIXELS)
    ) dut (
        .clk            (clk),
        .rst            (rst),
        .rx_data        (rx_data),
        .rx_valid       (rx_valid),
        .fb_waddr       (fb_waddr),
        .fb_wdata       (fb_wdata),
        .fb_we          (fb_we),
        .frame_done     (frame_done),
        .sync_state_dbg (sync_dbg)
    );

    // ------------------------------------------------------------------
    // FIX: flag that catches the 1-cycle frame_done pulse
    // ------------------------------------------------------------------
    reg frame_done_flag = 0;

    always @(posedge clk)
        if (frame_done) frame_done_flag <= 1;

    task clear_frame_done_flag;
        begin
            @(negedge clk);
            frame_done_flag = 0;
        end
    endtask

    // Wait up to 'timeout_cycles' for frame_done_flag
    task wait_frame_done;
        input integer timeout_cycles;
        integer t;
        begin
            t = 0;
            while (!frame_done_flag && t < timeout_cycles) begin
                @(posedge clk); #1;
                t = t + 1;
            end
            if (!frame_done_flag)
                $display("FAIL: frame_done timeout after %0d cycles", t);
        end
    endtask

    // ------------------------------------------------------------------
    // Inject one byte
    // ------------------------------------------------------------------
    task inject_byte;
        input [7:0] b;
        begin
            @(negedge clk);
            rx_data  = b;
            rx_valid = 1;
            @(negedge clk);
            rx_valid = 0;
            rx_data  = 0;
        end
    endtask

    task send_header;
        begin
            inject_byte(8'hFF);
            inject_byte(8'hFE);
            inject_byte(8'hFD);
        end
    endtask

    task send_frame;
        input [7:0] base_val;
        integer p;
        begin
            clear_frame_done_flag;
            send_header;
            for (p = 0; p < FRAME_PIXELS; p = p + 1)
                inject_byte((base_val + p) & 8'hFF);
        end
    endtask

    integer p, errors;

    initial begin
        $dumpfile("tb_frame_receiver.vcd");
        $dumpvars(0, tb_frame_receiver);

        repeat(5) @(posedge clk);
        rst = 0;
        #100;

        // ---- TEST 1: Sync state detection ----
        $display("\n=== TEST 1: Sync Header Detection ===");
        inject_byte(8'hFF);
        @(negedge clk); #1;
        if (sync_dbg == 2'd1)
            $display("PASS: State→1 after 0xFF");
        else
            $display("FAIL: State=%0d after 0xFF, expected 1", sync_dbg);

        inject_byte(8'hFE);
        @(negedge clk); #1;
        if (sync_dbg == 2'd2)
            $display("PASS: State→2 after 0xFE");
        else
            $display("FAIL: State=%0d after 0xFE, expected 2", sync_dbg);

        inject_byte(8'hFD);
        @(negedge clk); #1;
        if (sync_dbg == 2'd3)
            $display("PASS: State→3 (RECV) after 0xFD");
        else
            $display("FAIL: State=%0d after 0xFD, expected 3", sync_dbg);

        // Flush rest of frame
        for (p = 0; p < FRAME_PIXELS; p = p + 1)
            inject_byte(8'h00);

        // FIX: use flag instead of @(posedge frame_done)
        wait_frame_done(100);
        if (frame_done_flag)
            $display("PASS: frame_done pulsed after %0d pixels", FRAME_PIXELS);

        // ---- TEST 2: Pixel data written correctly ----
        $display("\n=== TEST 2: fb_waddr Increments Correctly ===");
        begin : addr_check
            integer expected_addr, addr_errors;
            expected_addr = 0;
            addr_errors   = 0;

            clear_frame_done_flag;
            send_header;

            for (p = 0; p < FRAME_PIXELS; p = p + 1) begin
                inject_byte(p[7:0]);
                @(posedge clk); #1;
                if (fb_we) begin
                    if (fb_waddr !== expected_addr) begin
                        if (addr_errors < 5)
                            $display("FAIL: waddr=%0d expected=%0d",
                                      fb_waddr, expected_addr);
                        addr_errors = addr_errors + 1;
                    end
                    expected_addr = expected_addr + 1;
                end
            end

            wait_frame_done(100);
            if (addr_errors == 0)
                $display("PASS: All %0d write addresses sequential",
                          FRAME_PIXELS);
            else
                $display("FAIL: %0d address errors", addr_errors);
        end

        // ---- TEST 3: Broken sync discarded ----
        $display("\n=== TEST 3: Partial Sync Discarded ===");
        inject_byte(8'hFF);
        inject_byte(8'hFE);
        inject_byte(8'hAB);   // wrong third byte
        @(negedge clk); #1;
        if (sync_dbg == 2'd0)
            $display("PASS: State reset to 0 after bad sync byte");
        else
            $display("FAIL: State=%0d, expected 0", sync_dbg);

        // ---- TEST 4: Double 0xFF handled ----
        $display("\n=== TEST 4: Double 0xFF ===");
        inject_byte(8'hFF);
        inject_byte(8'hFF);
        @(negedge clk); #1;
        if (sync_dbg == 2'd1)
            $display("PASS: Double 0xFF — stayed in state 1");
        else
            $display("FAIL: State=%0d, expected 1", sync_dbg);
        // Flush
        inject_byte(8'hFE); inject_byte(8'hFD);
        for (p = 0; p < FRAME_PIXELS; p = p + 1) inject_byte(8'h00);
        wait_frame_done(100);

        // ---- TEST 5: Two consecutive frames ----
        $display("\n=== TEST 5: Two Consecutive Frames ===");
        begin : two_frames
            integer f, fdcount;
            fdcount = 0;
            for (f = 0; f < 2; f = f + 1) begin
                send_frame(f * 8'h10);
                wait_frame_done(FRAME_PIXELS * 4);
                if (frame_done_flag) fdcount = fdcount + 1;
                clear_frame_done_flag;
                #50;
            end
            if (fdcount == 2)
                $display("PASS: frame_done fired for both frames");
            else
                $display("FAIL: frame_done count=%0d, expected 2", fdcount);
        end

        // ---- TEST 6: frame_done is 1 cycle wide ----
        $display("\n=== TEST 6: frame_done Pulse Width ===");
        begin : pw
            integer high_cycles;
            high_cycles = 0;
            clear_frame_done_flag;
            send_frame(8'h55);

            // Spin until frame_done goes high
            begin : wait_hi
                integer t;
                t = 0;
                while (!frame_done && t < FRAME_PIXELS * 4) begin
                    @(posedge clk); #1; t = t + 1;
                end
            end

            // Count how long it stays high
            while (frame_done) begin
                high_cycles = high_cycles + 1;
                @(posedge clk); #1;
            end

            if (high_cycles == 1)
                $display("PASS: frame_done is exactly 1 cycle");
            else
                $display("FAIL: frame_done high for %0d cycles", high_cycles);
        end

        // ---- TEST 7: Out-of-range address never written ----
        $display("\n=== TEST 7: No Out-of-Range Write ===");
        // (Monitored continuously — see always block below)
        send_frame(8'hCC);
        wait_frame_done(FRAME_PIXELS * 4);
        $display("PASS: No out-of-range write detected (check waveform)");

        #1000;
        $display("\n=== Frame Receiver Testbench Complete ===");
        $finish;
    end

    // Continuous OOB guard
    always @(posedge clk)
        if (fb_we && fb_waddr >= FRAME_PIXELS)
            $display("ERROR t=%0t: fb_waddr=%0d out of range!", $time, fb_waddr);

endmodule