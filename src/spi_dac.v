// ============================================================
// spi_dac.v 
// - 24-bit frame: RW(0) + 3'b000 + reg_addr[3:0] + data[15:0]
// - CPOL=0
// - MOSI is valid while SCLK is LOW
// - Shift/advance on the falling edge (1->0) so next bit is ready for next rising edge
// ============================================================
module spi_dac #(
    parameter integer CLKDIV = 4
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [3:0]  reg_addr,
    input  wire [15:0] data,
    output reg         busy,

    output reg         sclk,
    output reg         mosi,
    input  wire        miso,
    output reg         cs_n
);
    reg [23:0] shreg;
    reg [7:0]  bitcnt;
    reg [15:0] divctr;

    // 24-bit: RW=0, reserved=000, A[3:0], DATA[15:0]
    wire [23:0] frame = {1'b0, 3'b000, reg_addr, data};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy   <= 1'b0;
            sclk   <= 1'b0;   // CPOL=0
            mosi   <= 1'b0;
            cs_n   <= 1'b1;
            shreg  <= 24'd0;
            bitcnt <= 8'd0;
            divctr <= 16'd0;
        end else begin
            if (!busy) begin
                sclk <= 1'b0;
                cs_n <= 1'b1;

                if (start) begin
                    busy   <= 1'b1;
                    cs_n   <= 1'b0;
                    shreg  <= frame;
                    bitcnt <= 8'd24;
                    divctr <= 16'd0;

                    // Present MSB immediately while SCLK is low
                    mosi <= frame[23];
                end
            end else begin
                if (divctr == (CLKDIV-1)) begin
                    divctr <= 16'd0;
                    sclk   <= ~sclk;

                    // We want to advance on the falling edge (1->0).
                    // In this always block, sclk is the *old* value.
                    // If old sclk==1, the toggle is 1->0 (falling edge).
                    if (sclk == 1'b1) begin
                        // advance to next bit during low time
                        if (bitcnt != 0) begin
                            shreg  <= {shreg[22:0], 1'b0};
                            bitcnt <= bitcnt - 8'd1;
                            mosi   <= shreg[22];
                        end

                        // after last bit shifted out (bitcnt==1), finish
                        if (bitcnt == 8'd1) begin
                            busy <= 1'b0;
                            cs_n <= 1'b1;  // DAC latches on CS rising edge
                            sclk <= 1'b0;
                        end
                    end
                end else begin
                    divctr <= divctr + 16'd1;
                end
            end
        end
    end
endmodule