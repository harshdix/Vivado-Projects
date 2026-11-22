// tb_frame_buffer_dp.v
`timescale 1ns / 1ps

module tb_frame_buffer_dp;

    localparam DEPTH = 12288;
    localparam ABITS = 14;

    // Write port signals (100 MHz)
    reg [ABITS-1:0] waddr  = 0;
    reg [7:0]       wdata  = 0;
    reg             we     = 0;
    reg             wclk   = 0;

    // Read port signals (25 MHz)
    reg [ABITS-1:0] raddr_a = 0;
    reg [ABITS-1:0] raddr_b = 0;
    reg             rclk    = 0;

    wire [7:0] rdata_a;
    wire [7:0] rdata_b;

    // Background capture (100 MHz)
    reg capture_bg = 0;
    reg sys_clk    = 0;

    // 100 MHz write clock
    always #5  wclk    = ~wclk;
    always #5  sys_clk = ~sys_clk;
    // 25 MHz read clock
    always #20 rclk    = ~rclk;

    frame_buffer_dp #(
        .DEPTH (DEPTH),
        .ABITS (ABITS)
    ) dut (
        .waddr      (waddr),
        .wdata      (wdata),
        .we         (we),
        .wclk       (wclk),
        .raddr_a    (raddr_a),
        .rdata_a    (rdata_a),
        .rclk       (rclk),
        .raddr_b    (raddr_b),
        .rdata_b    (rdata_b),
        .capture_bg (capture_bg),
        .sys_clk    (sys_clk)
    );

    // ------------------------------------------------------------------
    // Task: write one pixel to curr_mem
    // ------------------------------------------------------------------
    task write_pixel;
        input [ABITS-1:0] addr;
        input [7:0]       val;
        begin
            @(negedge wclk);
            waddr = addr; wdata = val; we = 1;
            @(negedge wclk);
            we = 0;
        end
    endtask

    // ------------------------------------------------------------------
    // Task: read current frame pixel (port A) and return value
    // ------------------------------------------------------------------
    task read_curr;
        input  [ABITS-1:0] addr;
        output [7:0]       val;
        begin
            @(negedge rclk);
            raddr_a = addr;
            @(posedge rclk); @(posedge rclk); #1;
            val = rdata_a;
        end
    endtask

    // ------------------------------------------------------------------
    // Task: read background pixel (port B)
    // ------------------------------------------------------------------
    task read_bg;
        input  [ABITS-1:0] addr;
        output [7:0]       val;
        begin
            @(negedge rclk);
            raddr_b = addr;
            @(posedge rclk); @(posedge rclk); #1;
            val = rdata_b;
        end
    endtask

    // ------------------------------------------------------------------
    // Task: trigger background capture and wait for it to finish
    // ------------------------------------------------------------------
    task do_capture;
        begin
            @(negedge sys_clk);
            capture_bg = 1;
            @(negedge sys_clk);
            capture_bg = 0;
            // Wait DEPTH+10 cycles for copy to complete
            repeat(DEPTH + 10) @(posedge sys_clk);
        end
    endtask

    reg [7:0] read_val;
    integer   p, errors;

    initial begin
        $dumpfile("tb_frame_buffer_dp.vcd");
        $dumpvars(0, tb_frame_buffer_dp);
        #100;

        // ---- TEST 1: Write then read back curr_mem ----
        $display("\n=== TEST 1: Write/Read Current Frame ===");
        errors = 0;
        for (p = 0; p < 10; p = p + 1) begin
            write_pixel(p, p * 25);
            read_curr(p, read_val);
            if (read_val !== p * 25) begin
                $display("FAIL: addr=%0d wrote=%0d read=%0d", p, p*25, read_val);
                errors = errors + 1;
            end
        end
        if (errors == 0)
            $display("PASS: First 10 pixels written and read back correctly");

        // ---- TEST 2: Background initially zero ----
        $display("\n=== TEST 2: Background Initially Zero ===");
        errors = 0;
        for (p = 0; p < 5; p = p + 1) begin
            read_bg(p, read_val);
            if (read_val !== 8'h00) begin
                $display("FAIL: bg[%0d]=%0d, expected 0", p, read_val);
                errors = errors + 1;
            end
        end
        if (errors == 0)
            $display("PASS: Background initialised to zero");

        // ---- TEST 3: capture_bg copies curr → bg ----
        $display("\n=== TEST 3: Background Capture ===");
        // Write a known pattern into curr_mem
        for (p = 0; p < 20; p = p + 1)
            write_pixel(p, p * 10);

        // Trigger capture
        do_capture;

        // Verify bg_mem matches what we wrote
        errors = 0;
        for (p = 0; p < 20; p = p + 1) begin
            read_bg(p, read_val);
            if (read_val !== (p * 10) & 8'hFF) begin
                $display("FAIL: bg[%0d]=%0d, expected %0d",
                          p, read_val, (p*10)&8'hFF);
                errors = errors + 1;
            end
        end
        if (errors == 0)
            $display("PASS: Background matches current frame after capture");

        // ---- TEST 4: curr_mem updates don't affect bg_mem ----
        $display("\n=== TEST 4: bg_mem Independent After Capture ===");
        // Overwrite curr_mem with different values
        for (p = 0; p < 20; p = p + 1)
            write_pixel(p, 8'hFF);

        // bg_mem should still have old values
        errors = 0;
        for (p = 0; p < 20; p = p + 1) begin
            read_bg(p, read_val);
            if (read_val !== (p * 10) & 8'hFF) begin
                $display("FAIL: bg[%0d] changed to %0d after curr overwrite",
                          p, read_val);
                errors = errors + 1;
            end
        end
        if (errors == 0)
            $display("PASS: bg_mem unchanged after curr_mem overwrite");

        // ---- TEST 5: Second capture updates bg_mem ----
        $display("\n=== TEST 5: Second Capture Updates bg_mem ===");
        do_capture;
        read_bg(0, read_val);
        if (read_val === 8'hFF)
            $display("PASS: Second capture updated bg[0] to 0xFF");
        else
            $display("FAIL: bg[0]=%0d, expected 0xFF", read_val);

        // ---- TEST 6: Simultaneous read A and B ----
        $display("\n=== TEST 6: Simultaneous Port A and Port B Read ===");
        write_pixel(100, 8'hAA);
        do_capture;
        write_pixel(100, 8'h55);  // change curr only

        @(negedge rclk);
        raddr_a = 100;
        raddr_b = 100;
        @(posedge rclk); @(posedge rclk); #1;
        $display("curr_pixel[100]=%0d (expected 0x55=%0d)", rdata_a, 8'h55);
        $display("bg_pixel[100]  =%0d (expected 0xAA=%0d)", rdata_b, 8'hAA);
        if (rdata_a === 8'h55 && rdata_b === 8'hAA)
            $display("PASS: Port A and B read simultaneously and correctly");
        else
            $display("FAIL: Simultaneous read mismatch");

        #1000;
        $display("\n=== Frame Buffer Testbench Complete ===");
        $finish;
    end

endmodule