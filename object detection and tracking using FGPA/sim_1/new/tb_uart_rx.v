// tb_uart_rx.v  — FIXED
`timescale 1ns / 1ps

module tb_uart_rx;

    reg        clk = 0;
    reg        rst = 1;
    reg        rx  = 1;

    wire [7:0] data;
    wire       valid;

    always #5 clk = ~clk;   // 100 MHz

    uart_rx dut (
        .clk   (clk),
        .rst   (rst),
        .rx    (rx),
        .data  (data),
        .valid (valid)
    );

    // ------------------------------------------------------------------
    // FIX: capture valid in a flag so we never miss a 1-cycle pulse
    // ------------------------------------------------------------------
    reg       valid_flag = 0;
    reg [7:0] valid_data = 0;

    always @(posedge clk) begin
        if (valid) begin
            valid_flag <= 1;
            valid_data <= data;
        end
    end

    task clear_flag;
        begin
            @(negedge clk);
            valid_flag = 0;
            valid_data = 0;
        end
    endtask

    // ------------------------------------------------------------------
    // 3 Mbaud: bit period = 333 ns
    // Stop bit: we only hold for 200 ns (not full 333 ns) so
    // the receiver samples at the midpoint and fires valid while
    // we are still in send_byte — the flag catches it.
    // ------------------------------------------------------------------
    localparam BIT_PERIOD = 333;

    task send_byte;
        input [7:0] byte_in;
        integer i;
        begin
            rx = 0;
            #BIT_PERIOD;                          // start bit
            for (i = 0; i < 8; i = i + 1) begin
                rx = byte_in[i];
                #BIT_PERIOD;                      // data bits
            end
            rx = 1;
            #BIT_PERIOD;                          // stop bit (full period)
            #50;                                  // small guard
        end
    endtask

    // ------------------------------------------------------------------
    // Send byte, then wait up to 10 us for the flag to be set
    // ------------------------------------------------------------------
    task send_and_check;
        input [7:0]    byte_in;
        input [8*16:1] label;
        integer        timeout;
        begin
            clear_flag;
            send_byte(byte_in);

            // Wait for flag (flag set by always block during send_byte)
            timeout = 0;
            while (!valid_flag && timeout < 10000) begin
                @(posedge clk); #1;
                timeout = timeout + 1;
            end

            if (!valid_flag)
                $display("FAIL [%s]: timeout — valid never fired", label);
            else if (valid_data === byte_in)
                $display("PASS [%s]: sent=0x%02X received=0x%02X",
                          label, byte_in, valid_data);
            else
                $display("FAIL [%s]: sent=0x%02X received=0x%02X",
                          label, byte_in, valid_data);
        end
    endtask

    initial begin
        $dumpfile("tb_uart_rx.vcd");
        $dumpvars(0, tb_uart_rx);

        repeat(5) @(posedge clk);
        rst = 0;
        #200;

        // ---- TEST 1: Basic byte values ----
        $display("\n=== TEST 1: Basic Byte Values ===");
        send_and_check(8'h00, "ZERO    ");
        send_and_check(8'hFF, "ALL_ONES");
        send_and_check(8'hAA, "ALT_10  ");
        send_and_check(8'h55, "ALT_01  ");

        // ---- TEST 2: Sync marker bytes ----
        $display("\n=== TEST 2: Sync Marker Bytes ===");
        send_and_check(8'hFF, "SYNC_FF ");
        send_and_check(8'hFE, "SYNC_FE ");
        send_and_check(8'hFD, "SYNC_FD ");

        // ---- TEST 3: Back-to-back bytes ----
        $display("\n=== TEST 3: Back-to-Back Bytes ===");
        send_and_check(8'h12, "BTB_1   ");
        send_and_check(8'h34, "BTB_2   ");
        send_and_check(8'h56, "BTB_3   ");

        // ---- TEST 4: Glitch ignored ----
        $display("\n=== TEST 4: Short Glitch Ignored ===");
        rx = 0; #80; rx = 1;   // glitch shorter than half-bit (166 ns)
        #500;
        send_and_check(8'hAB, "AFTER_GL");

        // ---- TEST 5: All 256 values ----
        $display("\n=== TEST 5: All 256 Values ===");
        begin : all256
            integer v, errors;
            errors = 0;
            for (v = 0; v < 256; v = v + 1) begin
                clear_flag;
                send_byte(v[7:0]);
                begin : wait256
                    integer t;
                    t = 0;
                    while (!valid_flag && t < 10000) begin
                        @(posedge clk); #1; t = t + 1;
                    end
                end
                if (valid_data !== v[7:0]) errors = errors + 1;
            end
            if (errors == 0)
                $display("PASS: All 256 values received correctly");
            else
                $display("FAIL: %0d errors in 256-value sweep", errors);
        end

        #1000;
        $display("\n=== UART RX Testbench Complete ===");
        $finish;
    end

endmodule