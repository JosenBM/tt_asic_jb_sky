`default_nettype none

module tt_um_josenbm (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    // ---------------- Pin mapping ----------------
    wire i2c_scl   = ui_in[0];
    wire sda_in    = uio_in[0];

    wire osc0 = ui_in[3];
    wire osc1 = ui_in[4];
    wire osc2 = ui_in[5];
    wire osc3 = ui_in[6];
    wire osc4 = ui_in[7];
    wire osc5 = uio_in[1];
    wire osc6 = uio_in[2];
    wire osc7 = uio_in[3];
    wire osc8 = uio_in[4];

    wire spi_dac_miso = ui_in[1];
    wire spi_adc_miso = ui_in[2];

    // ---------------- Core outputs ----------------
    wire spi_dac_sclk, spi_dac_mosi, spi_dac_cs_n;
    wire spi_adc_sclk, spi_adc_cs_n;

    wire sda_oe;  // open-drain: 1 = pull SDA low

    // Gate reset when not selected (recommended)
    wire rst_n_gated = rst_n & ena;

    // ---------------- Instantiate core ----------------
    asic_top #(
        .I2C_ADDR(7'h2A)
    ) u_core (
        .ref_clk  (clk),
        .rst_n    (rst_n_gated),

        .osc0(osc0), .osc1(osc1), .osc2(osc2), .osc3(osc3), .osc4(osc4),
        .osc5(osc5), .osc6(osc6), .osc7(osc7), .osc8(osc8),

        .scl    (i2c_scl),
        .sda_in (sda_in),
        .sda_oe (sda_oe),

        .spi_sclk (spi_dac_sclk),
        .spi_mosi (spi_dac_mosi),
        .spi_cs_n (spi_dac_cs_n),
        .spi_miso (spi_dac_miso),

        .adc_sclk (spi_adc_sclk),
        .adc_cs_n (spi_adc_cs_n),
        .adc_miso (spi_adc_miso)
    );

    // ---------------- Drive TT outputs ----------------
    // Dedicated outputs
    assign uo_out[0] = spi_dac_sclk;
    assign uo_out[1] = spi_dac_mosi;
    assign uo_out[2] = spi_dac_cs_n;
    assign uo_out[3] = spi_adc_sclk;
    assign uo_out[4] = spi_adc_cs_n;
    assign uo_out[7:5] = 3'b000;

    // Bidirectional outputs
    // I2C SDA: open drain. We only ever drive 0, and enable when we want to pull low.
    assign uio_out[0] = 1'b0;
    assign uio_oe[0]  = sda_oe;

    // Other uio pins are inputs only (OSC5..OSC8 used as inputs)
    assign uio_out[7:1] = 7'b0;
    assign uio_oe[7:1]  = 7'b0;

endmodule
