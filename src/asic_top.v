// tt_iface_top_2ch_stream.v
// Adds runtime-programmable gate_cycles via I2C:
//
// Gate config regs (RW):
//   0x20: gate_cycles_cfg[7:0]
//   0x21: gate_cycles_cfg[15:8]
//   0x22: gate_cycles_cfg[23:16]
//   0x23: gate_cycles_cfg[31:24]
//
// Apply command (WO semantics via write):
//   0x27 bit0 = APPLY_GATE
//     - If counters disabled: gate_cycles_active <= gate_cycles_cfg immediately
//     - If counters enabled: sets pending_apply, which applies on next clean enable edge
//
// Notes:
// - Counters use gate_cycles_active, not the raw cfg.
// - gate_cycles_active is also latched on rising edge of (global_en & cnt_en).
//
// Existing features retained: 9 counters, ADS7042 spi_adc, DAC SPI commit,
// frame-complete snapshot option, STATUS regs 0x44..0x46.

//`include "spi_adc.v"
//`include "freq_counter_gate.v"
//`include "i2c_slave.v"
//`include "spi_dac.v"

module asic_top #(
    parameter [6:0] I2C_ADDR = 7'h2A,

    // ADC sampling defaults
    parameter integer ADC_SAMPLE_PERIOD = 50_000,
    parameter integer ADC_CLKDIV        = 8
)(
    input  wire ref_clk,
    input  wire rst_n,

    input  wire osc0,
    input  wire osc1,
    input  wire osc2,
    input  wire osc3,
    input  wire osc4,
    input  wire osc5,
    input  wire osc6,
    input  wire osc7,
    input  wire osc8,

    input  wire scl,
    input  wire sda_in,      // PATCH: was inout sda
    output wire sda_oe,      // PATCH: open-drain drive-low enable

    // DAC SPI
    output wire spi_sclk,
    output wire spi_mosi,
    output wire spi_cs_n,
    input  wire spi_miso,

    // ADC SPI (ADS7042)
    output wire adc_sclk,
    output wire adc_cs_n,
    input  wire adc_miso
);

    // ---------------- Register file storage (RW registers) ----------------
    // EDIT: shrink regfile for area/routing. You use <= 0x6D, so 0x00..0x7F is safe.
    reg [7:0] regs [0:127];

    // ---------------- I2C interface wires ----------------
    wire [7:0] i2c_reg_addr;
    wire       i2c_wr_en;
    wire [7:0] i2c_wr_data;
    reg  [7:0] i2c_rd_data;

    // ---------------- Counter outputs ----------------
    wire [31:0] c0_latched, c1_latched, c2_latched, c3_latched, c4_latched, c5_latched, c6_latched, c7_latched, c8_latched;
    wire        c0_new,     c1_new,     c2_new,     c3_new,     c4_new,     c5_new,     c6_new,     c7_new,     c8_new;

    wire any_c_new = c0_new | c1_new | c2_new | c3_new | c4_new | c5_new | c6_new | c7_new | c8_new;

    // ---------------- Global control bits ----------------
    wire global_en     = regs[8'h04][0];
    wire cnt_en        = regs[8'h04][4];
    wire frame_mode_en = regs[8'h04][5];

    wire cnt_running = global_en & cnt_en;

    // ---------------- Gate cycles config ----------------
    wire [31:0] gate_cycles_cfg = {regs[8'h23], regs[8'h22], regs[8'h21], regs[8'h20]};
    reg  [31:0] gate_cycles_active;
    reg         pending_apply;

    // Rising edge detect for cnt_running
    reg cnt_running_d;
    wire cnt_running_rise = cnt_running & ~cnt_running_d;

    // ---------------- DAC codes (example mapping) ----------------
    wire [15:0] dac0_code = {regs[8'h13], regs[8'h12]};
    wire [15:0] dac1_code = {regs[8'h15], regs[8'h14]};

    // ---------------- Temperature register value (ADC-owned when enabled) ----------------
    wire [15:0] temp_reg = {regs[8'h35], regs[8'h34]}; // 0x34 LSB, 0x35 MSB

    // Snapshot bank (stream block)
    reg [31:0] snap_c0, snap_c1, snap_c2, snap_c3, snap_c4, snap_c5, snap_c6, snap_c7, snap_c8;
    reg [15:0] snap_temp;

    // Latest samples for frame-complete mode
    reg [31:0] latest_c0, latest_c1, latest_c2, latest_c3, latest_c4, latest_c5, latest_c6, latest_c7, latest_c8;
    reg [15:0] latest_temp;

    reg [8:0]  seen_mask;
    reg        snap_valid;
    reg [15:0] frame_id;

    // ---------------- I2C slave ----------------
    i2c_slave #(
        .I2C_ADDR(I2C_ADDR)
    ) u_i2c (
        .clk     (ref_clk),
        .rst_n   (rst_n),
        .scl     (scl),
        .sda_in  (sda_in),   // PATCH: was .sda(sda)
        .sda_oe  (sda_oe),   // PATCH: new
        .reg_addr(i2c_reg_addr),
        .wr_en   (i2c_wr_en),
        .wr_data (i2c_wr_data),
        .rd_data (i2c_rd_data)
    );

    // ---------------- Counters (now use gate_cycles_active) ----------------
    freq_counter_gate u_cnt0 (
        .ref_clk(ref_clk), .rst_n(rst_n),
        .en(cnt_running),
        .sig_in(osc0),
        .gate_cycles(gate_cycles_active),
        .count_latched(c0_latched),
        .new_data(c0_new)
    );

    freq_counter_gate u_cnt1 (
        .ref_clk(ref_clk), .rst_n(rst_n),
        .en(cnt_running),
        .sig_in(osc1),
        .gate_cycles(gate_cycles_active),
        .count_latched(c1_latched),
        .new_data(c1_new)
    );

    freq_counter_gate u_cnt2 (
        .ref_clk(ref_clk), .rst_n(rst_n),
        .en(cnt_running),
        .sig_in(osc2),
        .gate_cycles(gate_cycles_active),
        .count_latched(c2_latched),
        .new_data(c2_new)
    );

    freq_counter_gate u_cnt3 (
        .ref_clk(ref_clk), .rst_n(rst_n),
        .en(cnt_running),
        .sig_in(osc3),
        .gate_cycles(gate_cycles_active),
        .count_latched(c3_latched),
        .new_data(c3_new)
    );

    freq_counter_gate u_cnt4 (
        .ref_clk(ref_clk), .rst_n(rst_n),
        .en(cnt_running),
        .sig_in(osc4),
        .gate_cycles(gate_cycles_active),
        .count_latched(c4_latched),
        .new_data(c4_new)
    );

    freq_counter_gate u_cnt5 (
        .ref_clk(ref_clk), .rst_n(rst_n),
        .en(cnt_running),
        .sig_in(osc5),
        .gate_cycles(gate_cycles_active),
        .count_latched(c5_latched),
        .new_data(c5_new)
    );

    freq_counter_gate u_cnt6 (
        .ref_clk(ref_clk), .rst_n(rst_n),
        .en(cnt_running),
        .sig_in(osc6),
        .gate_cycles(gate_cycles_active),
        .count_latched(c6_latched),
        .new_data(c6_new)
    );

    freq_counter_gate u_cnt7 (
        .ref_clk(ref_clk), .rst_n(rst_n),
        .en(cnt_running),
        .sig_in(osc7),
        .gate_cycles(gate_cycles_active),
        .count_latched(c7_latched),
        .new_data(c7_new)
    );

    freq_counter_gate u_cnt8 (
        .ref_clk(ref_clk), .rst_n(rst_n),
        .en(cnt_running),
        .sig_in(osc8),
        .gate_cycles(gate_cycles_active),
        .count_latched(c8_latched),
        .new_data(c8_new)
    );

    // ---------------- ADS7042 ADC reader ----------------
    wire [11:0] adc_code;
    wire        adc_valid;

    spi_adc #(
        .CLKDIV(ADC_CLKDIV),
        .SAMPLE_PERIOD(ADC_SAMPLE_PERIOD)
    ) u_adc (
        .clk         (ref_clk),
        .rst_n       (rst_n),
        .enable      (global_en),
        .sclk        (adc_sclk),
        .cs_n        (adc_cs_n),
        .miso        (adc_miso),
        .sample      (adc_code),
        .sample_valid(adc_valid)
    );

    // ---------------- SPI engine (DAC) ----------------
    reg        commit_req;

    reg [1:0]  spi_state;
    reg        spi_start;
    reg [3:0]  spi_reg_addr;
    reg [15:0] spi_data;
    wire       spi_busy;

    spi_dac #(.CLKDIV(4)) u_spi (
        .clk     (ref_clk),
        .rst_n   (rst_n),
        .start   (spi_start),
        .reg_addr(spi_reg_addr),
        .data    (spi_data),
        .busy    (spi_busy),
        .sclk    (spi_sclk),
        .mosi    (spi_mosi),
        .miso    (spi_miso),
        .cs_n    (spi_cs_n)
    );

    reg  spi_busy_d;
    wire spi_done = spi_busy_d & ~spi_busy;

    always @(posedge ref_clk or negedge rst_n) begin
        if (!rst_n) spi_busy_d <= 1'b0;
        else        spi_busy_d <= spi_busy;
    end

    reg commit_consume;

    always @(posedge ref_clk or negedge rst_n) begin
        if (!rst_n) begin
            spi_state      <= 2'd0;
            spi_start      <= 1'b0;
            spi_reg_addr   <= 4'h0;
            spi_data       <= 16'h0000;
            commit_consume <= 1'b0;
        end else begin
            spi_start      <= 1'b0;
            commit_consume <= 1'b0;

            case (spi_state)
                2'd0: begin
                    if (commit_req && !spi_busy) begin
                        spi_reg_addr <= 4'h8;
                        spi_data     <= dac0_code;
                        spi_start    <= 1'b1;

                        commit_consume <= 1'b1;
                        spi_state <= 2'd1;
                    end
                end

                2'd1: begin
                    if (spi_done) begin
                        spi_reg_addr <= 4'h9;
                        spi_data     <= dac1_code;
                        spi_start    <= 1'b1;
                        spi_state    <= 2'd2;
                    end
                end

                2'd2: begin
                    if (spi_done) begin
                        spi_state <= 2'd0;
                    end
                end

                default: spi_state <= 2'd0;
            endcase
        end
    end

    // ---------------- Main register write handling + snapshot + gate apply ----------------
    reg        i2c_wr_en_d;
    reg [7:0]  i2c_addr_d;
    reg [7:0]  i2c_data_d;

    integer k;
    always @(posedge ref_clk or negedge rst_n) begin
        if (!rst_n) begin
            // EDIT: loop bound matches new regfile size
            for (k=0; k<128; k=k+1) regs[k] <= 8'h00;

            regs[8'h00] <= 8'hC3; // DEVICE_ID
            regs[8'h04] <= 8'h00; // GLOBAL_CTRL

            // Default ADC temp regs
            regs[8'h34] <= 8'h34;
            regs[8'h35] <= 8'h12;

            // Default gate_cycles_cfg = 50_000 (1ms @ 50MHz): 0x0000C350
            regs[8'h20] <= 8'h50;
            regs[8'h21] <= 8'hC3;
            regs[8'h22] <= 8'h00;
            regs[8'h23] <= 8'h00;

            // Active gate defaults to cfg
            gate_cycles_active <= 32'd50_000;
            pending_apply      <= 1'b0;

            snap_c0   <= 32'd0; snap_c1 <= 32'd0; snap_c2 <= 32'd0;
            snap_c3   <= 32'd0; snap_c4 <= 32'd0; snap_c5 <= 32'd0;
            snap_c6   <= 32'd0; snap_c7 <= 32'd0; snap_c8 <= 32'd0;
            snap_temp <= 16'd0;

            latest_c0 <= 32'd0; latest_c1 <= 32'd0; latest_c2 <= 32'd0;
            latest_c3 <= 32'd0; latest_c4 <= 32'd0; latest_c5 <= 32'd0;
            latest_c6 <= 32'd0; latest_c7 <= 32'd0; latest_c8 <= 32'd0;
            latest_temp <= 16'd0;

            seen_mask  <= 9'd0;
            snap_valid <= 1'b0;
            frame_id   <= 16'd0;

            i2c_wr_en_d <= 1'b0;
            i2c_addr_d  <= 8'h00;
            i2c_data_d  <= 8'h00;

            commit_req <= 1'b0;

            cnt_running_d <= 1'b0;
        end else begin
            // track cnt_running for edge detect
            cnt_running_d <= cnt_running;

            // capture I2C write bus
            i2c_wr_en_d <= i2c_wr_en;
            i2c_addr_d  <= i2c_reg_addr;
            i2c_data_d  <= i2c_wr_data;

            // clear commit_req when SPI FSM consumes it
            if (commit_consume)
                commit_req <= 1'b0;

            // if counters disabled, clear partial-frame mask
            if (!cnt_running)
                seen_mask <= 9'd0;

            // Apply pending gate update on next clean enable edge
            if (cnt_running_rise && pending_apply) begin
                gate_cycles_active <= gate_cycles_cfg;
                pending_apply      <= 1'b0;
            end

            // -------- I2C writes --------
            if (i2c_wr_en_d) begin
                // Clear snap_valid if host writes 1 to STATUS bit0
                if (i2c_addr_d == 8'h44 && i2c_data_d[0]) begin
                    snap_valid <= 1'b0;
                end

                // APPLY_GATE command at 0x27 bit0
                if (i2c_addr_d == 8'h27 && i2c_data_d[0]) begin
                    if (!cnt_running) begin
                        gate_cycles_active <= gate_cycles_cfg;  // apply immediately if safe
                        pending_apply      <= 1'b0;
                    end else begin
                        pending_apply      <= 1'b1;             // defer to next enable edge
                    end
                end

                // EDIT: prevent out-of-range reg indexing (<=0x7F only)
                // Prevent I2C from overriding ADC temp regs when ADC enabled
                if (!(global_en && (i2c_addr_d == 8'h34 || i2c_addr_d == 8'h35))) begin
                    if (i2c_addr_d <= 8'h7F) begin
                        regs[i2c_addr_d] <= i2c_data_d;
                    end
                end

                // DAC commit request
                if (i2c_addr_d == 8'h26 && i2c_data_d[1]) begin
                    commit_req <= 1'b1;
                end
            end

            // -------- ADC update into temp regs + latest_temp --------
            if (adc_valid) begin
                regs[8'h34] <= adc_code[7:0];
                regs[8'h35] <= {4'b0, adc_code[11:8]};
                latest_temp <= {4'b0, adc_code[11:8], adc_code[7:0]};
            end

            // -------- Update latest counts + seen mask --------
            if (c0_new) begin latest_c0 <= c0_latched; seen_mask[0] <= 1'b1; end
            if (c1_new) begin latest_c1 <= c1_latched; seen_mask[1] <= 1'b1; end
            if (c2_new) begin latest_c2 <= c2_latched; seen_mask[2] <= 1'b1; end
            if (c3_new) begin latest_c3 <= c3_latched; seen_mask[3] <= 1'b1; end
            if (c4_new) begin latest_c4 <= c4_latched; seen_mask[4] <= 1'b1; end
            if (c5_new) begin latest_c5 <= c5_latched; seen_mask[5] <= 1'b1; end
            if (c6_new) begin latest_c6 <= c6_latched; seen_mask[6] <= 1'b1; end
            if (c7_new) begin latest_c7 <= c7_latched; seen_mask[7] <= 1'b1; end
            if (c8_new) begin latest_c8 <= c8_latched; seen_mask[8] <= 1'b1; end

            // -------- Snapshot update --------
            if (!frame_mode_en) begin
                // legacy per-channel snapshot
                if (c0_new) snap_c0 <= c0_latched;
                if (c1_new) snap_c1 <= c1_latched;
                if (c2_new) snap_c2 <= c2_latched;
                if (c3_new) snap_c3 <= c3_latched;
                if (c4_new) snap_c4 <= c4_latched;
                if (c5_new) snap_c5 <= c5_latched;
                if (c6_new) snap_c6 <= c6_latched;
                if (c7_new) snap_c7 <= c7_latched;
                if (c8_new) snap_c8 <= c8_latched;

                if (adc_valid)
                    snap_temp <= {4'b0, adc_code[11:8], adc_code[7:0]};
                else
                    snap_temp <= temp_reg;

            end else begin
                // frame-complete snapshot
                if (seen_mask == 9'h1FF) begin
                    snap_c0   <= latest_c0;
                    snap_c1   <= latest_c1;
                    snap_c2   <= latest_c2;
                    snap_c3   <= latest_c3;
                    snap_c4   <= latest_c4;
                    snap_c5   <= latest_c5;
                    snap_c6   <= latest_c6;
                    snap_c7   <= latest_c7;
                    snap_c8   <= latest_c8;
                    snap_temp <= latest_temp;

                    snap_valid <= 1'b1;
                    frame_id   <= frame_id + 16'd1;
                    seen_mask  <= 9'd0;
                end
            end
        end
    end

    // ---------------- Read mux ----------------
    always @(*) begin
        case (i2c_reg_addr)
            // STATUS / frame id
            8'h44: i2c_rd_data = {7'b0, snap_valid};
            8'h45: i2c_rd_data = frame_id[7:0];
            8'h46: i2c_rd_data = frame_id[15:8];

            // Optional debug: expose pending_apply (bit0) and cnt_running (bit1)
            8'h47: i2c_rd_data = {6'b0, cnt_running, pending_apply};

            // CH0..CH8 + TEMP
            8'h48: i2c_rd_data = snap_c0[7:0];
            8'h49: i2c_rd_data = snap_c0[15:8];
            8'h4A: i2c_rd_data = snap_c0[23:16];
            8'h4B: i2c_rd_data = snap_c0[31:24];

            8'h4C: i2c_rd_data = snap_c1[7:0];
            8'h4D: i2c_rd_data = snap_c1[15:8];
            8'h4E: i2c_rd_data = snap_c1[23:16];
            8'h4F: i2c_rd_data = snap_c1[31:24];

            8'h50: i2c_rd_data = snap_c2[7:0];
            8'h51: i2c_rd_data = snap_c2[15:8];
            8'h52: i2c_rd_data = snap_c2[23:16];
            8'h53: i2c_rd_data = snap_c2[31:24];

            8'h54: i2c_rd_data = snap_c3[7:0];
            8'h55: i2c_rd_data = snap_c3[15:8];
            8'h56: i2c_rd_data = snap_c3[23:16];
            8'h57: i2c_rd_data = snap_c3[31:24];

            8'h58: i2c_rd_data = snap_c4[7:0];
            8'h59: i2c_rd_data = snap_c4[15:8];
            8'h5A: i2c_rd_data = snap_c4[23:16];
            8'h5B: i2c_rd_data = snap_c4[31:24];

            8'h5C: i2c_rd_data = snap_c5[7:0];
            8'h5D: i2c_rd_data = snap_c5[15:8];
            8'h5E: i2c_rd_data = snap_c5[23:16];
            8'h5F: i2c_rd_data = snap_c5[31:24];

            8'h60: i2c_rd_data = snap_c6[7:0];
            8'h61: i2c_rd_data = snap_c6[15:8];
            8'h62: i2c_rd_data = snap_c6[23:16];
            8'h63: i2c_rd_data = snap_c6[31:24];

            8'h64: i2c_rd_data = snap_c7[7:0];
            8'h65: i2c_rd_data = snap_c7[15:8];
            8'h66: i2c_rd_data = snap_c7[23:16];
            8'h67: i2c_rd_data = snap_c7[31:24];

            8'h68: i2c_rd_data = snap_c8[7:0];
            8'h69: i2c_rd_data = snap_c8[15:8];
            8'h6A: i2c_rd_data = snap_c8[23:16];
            8'h6B: i2c_rd_data = snap_c8[31:24];

            8'h6C: i2c_rd_data = snap_temp[7:0];
            8'h6D: i2c_rd_data = snap_temp[15:8];

            // EDIT: default reg read is guarded
            default: i2c_rd_data = (i2c_reg_addr <= 8'h7F) ? regs[i2c_reg_addr] : 8'h00;
        endcase
    end

endmodule
