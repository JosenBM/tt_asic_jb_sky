//`timescale 1ns/1ps
module spi_adc #(
    parameter integer CLKDIV = 8,          // ref_clk divider for SCLK
    parameter integer SAMPLE_PERIOD = 50_000 // how often to sample (cycles of ref_clk)
)(
    input  wire clk,
    input  wire rst_n,

    input  wire enable,           // start periodic sampling when 1

    // SPI to ADC
    output reg  sclk,
    output reg  cs_n,
    input  wire miso,

    // sample output
    output reg [11:0] sample,
    output reg        sample_valid
);
    // Simple periodic trigger
    reg [31:0] per_ctr;

    // SPI engine
    reg        busy;
    reg [15:0] shreg;
    reg [4:0]  bitcnt;
    reg [15:0] divctr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sclk         <= 1'b0;
            cs_n         <= 1'b1;
            sample       <= 12'd0;
            sample_valid <= 1'b0;

            per_ctr      <= 32'd0;

            busy         <= 1'b0;
            shreg        <= 16'd0;
            bitcnt       <= 5'd0;
            divctr       <= 16'd0;
        end else begin
            sample_valid <= 1'b0;

            // Periodic trigger
            if (!busy) begin
                sclk <= 1'b0;
                cs_n <= 1'b1;

                if (enable) begin
                    if (per_ctr >= (SAMPLE_PERIOD-1)) begin
                        per_ctr <= 32'd0;

                        // Start SPI read: pull CS low and clock 16 bits
                        busy   <= 1'b1;
                        cs_n   <= 1'b0;
                        shreg  <= 16'd0;
                        bitcnt <= 5'd16;
                        divctr <= 16'd0;
                    end else begin
                        per_ctr <= per_ctr + 32'd1;
                    end
                end else begin
                    per_ctr <= 32'd0;
                end
            end else begin
                // busy: generate SCLK and shift in on rising edges (Mode 0-ish)
                if (divctr == (CLKDIV-1)) begin
                    divctr <= 16'd0;
                    sclk   <= ~sclk;

                    if (sclk == 1'b0) begin
                        // about to go high: sample MISO on rising edge
                        shreg <= {shreg[14:0], miso};

                        if (bitcnt != 0)
                            bitcnt <= bitcnt - 5'd1;

                        if (bitcnt == 5'd1) begin
                            // done after capturing last bit
                            busy <= 1'b0;
                            cs_n <= 1'b1;
                            sclk <= 1'b0;

                            // ADS7042 outputs a 12-bit result within the stream.
                            // Commonly: top 12 bits are the conversion. We take shreg[11:0] after 16 clocks.
                            sample <= {shreg[10:0], miso}; // last shift already includes miso; be explicit
                            sample_valid <= 1'b1;
                        end
                    end
                end else begin
                    divctr <= divctr + 16'd1;
                end
            end
        end
    end

endmodule