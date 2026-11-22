module uart_rx (
    input  wire       clk,        // 100MHz
    input  wire       rst,
    input  wire       rx,         // serial input from FT2232HQ (pin D4)
    output reg  [7:0] data,       // received byte
    output reg        valid        // pulses high 1 cycle when byte ready
);

// ── Baud rate generator ────────────────────────────────────────
// 100MHz / 3Mbaud = 33.33 → use 33
// Actual baud: 100M/33 = 3.030 Mbaud (1% error — fine for UART)
localparam CLKS_PER_BIT = 33;
localparam HALF_BIT     = CLKS_PER_BIT / 2;

// ── 3-stage synchroniser (avoid metastability) ─────────────────
reg [2:0] rx_sync;
always @(posedge clk) rx_sync <= {rx_sync[1:0], rx};
wire rx_s = rx_sync[2];

// ── State machine ──────────────────────────────────────────────
localparam IDLE  = 2'd0,
           START = 2'd1,
           DATA  = 2'd2,
           STOP  = 2'd3;

reg [1:0]  state    = IDLE;
reg [5:0]  clk_cnt  = 0;
reg [2:0]  bit_idx  = 0;
reg [7:0]  rx_shift = 0;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state <= IDLE; valid <= 0; clk_cnt <= 0; bit_idx <= 0;
    end else begin
        valid <= 0;
        case (state)

            // Wait for start bit (falling edge on rx)
            IDLE: begin
                clk_cnt <= 0; bit_idx <= 0;
                if (!rx_s) state <= START;
            end

            // Sample in middle of start bit to confirm
            START: begin
                if (clk_cnt == HALF_BIT) begin
                    clk_cnt <= 0;
                    if (!rx_s) state <= DATA;   // confirmed start
                    else       state <= IDLE;   // glitch — ignore
                end else
                    clk_cnt <= clk_cnt + 1;
            end

            // Shift in 8 data bits, LSB first
            DATA: begin
                if (clk_cnt == CLKS_PER_BIT) begin
                    clk_cnt <= 0;
                    rx_shift <= {rx_s, rx_shift[7:1]};   // LSB first
                    if (bit_idx == 7) begin
                        bit_idx <= 0;
                        state   <= STOP;
                    end else
                        bit_idx <= bit_idx + 1;
                end else
                    clk_cnt <= clk_cnt + 1;
            end

            // Verify stop bit
            STOP: begin
                if (clk_cnt == CLKS_PER_BIT) begin
                    clk_cnt <= 0;
                    if (rx_s) begin           // valid stop bit
                        data  <= rx_shift;
                        valid <= 1;
                    end
                    state <= IDLE;
                end else
                    clk_cnt <= clk_cnt + 1;
            end

        endcase
    end
end
endmodule