`timescale 1ps/1ps
`define SIM 1
`default_nettype none

module tb;

    // ============================================================
    // TT Interface Signals
    // ============================================================
    wire [7:0] ui_in;
    wire [7:0] uio_in;
    wire [7:0] uo_out;
    wire [7:0] uio_out;
    wire [7:0] uio_oe;

    reg ena   = 1'b1;
    reg clk   = 1'b0;
    reg rst_n = 1'b0;

    // 50 MHz clock: period 20ns = 20000ps, half=10000ps
    always #10000 clk = ~clk;

    // ============================================================
    // PASS / FAIL flags (checked by cocotb)
    // ============================================================
    reg tb_done = 1'b0;
    reg tb_fail = 1'b0;

    // ============================================================
    // I2C Open Drain Modeling
    //   Mapping assumed:
    //     ui[0]  = SCL
    //     uio[0] = SDA (open-drain)
    // ============================================================
    reg scl_drv = 1'b1;
    reg sda_drv = 1'b1; // 0 = pull low, 1 = release

    // DUT pulls SDA low when output-enable and output=0
    wire dut_sda_low = (uio_oe[0] && (uio_out[0] == 1'b0));

    // Resolved SDA line (pull-up by default)
    wire sda_line = ~(dut_sda_low | (sda_drv == 1'b0));

    // ============================================================
    // Oscillators (9)
    // ============================================================
    reg osc0=0, osc1=0, osc2=0, osc3=0, osc4=0;
    reg osc5=0, osc6=0, osc7=0, osc8=0;

    // Base around 11MHz with slight offsets
    localparam integer HP0_PS = 45455; // ~11.000 MHz half-period
    localparam integer HP1_PS = 45450;
    localparam integer HP2_PS = 45445;
    localparam integer HP3_PS = 45440;
    localparam integer HP4_PS = 45435;
    localparam integer HP5_PS = 45430;
    localparam integer HP6_PS = 45425;
    localparam integer HP7_PS = 45420;
    localparam integer HP8_PS = 45415;

    initial forever #(HP0_PS) osc0 = ~osc0;
    initial forever #(HP1_PS) osc1 = ~osc1;
    initial forever #(HP2_PS) osc2 = ~osc2;
    initial forever #(HP3_PS) osc3 = ~osc3;
    initial forever #(HP4_PS) osc4 = ~osc4;
    initial forever #(HP5_PS) osc5 = ~osc5;
    initial forever #(HP6_PS) osc6 = ~osc6;
    initial forever #(HP7_PS) osc7 = ~osc7;
    initial forever #(HP8_PS) osc8 = ~osc8;

    // ============================================================
    // SPI Signals (from uo_out) + MISOs (into ui_in)
    //   Mapping assumed (matches your info.yaml earlier):
    //     uo[0]=SPI_DAC_SCLK, uo[1]=SPI_DAC_MOSI, uo[2]=SPI_DAC_CS_N
    //     uo[3]=SPI_ADC_SCLK, uo[4]=SPI_ADC_CS_N
    //     ui[1]=SPI_DAC_MISO, ui[2]=SPI_ADC_MISO
    // ============================================================
    wire spi_sclk = uo_out[0];
    wire spi_mosi = uo_out[1];
    wire spi_cs_n = uo_out[2];

    wire adc_sclk = uo_out[3];
    wire adc_cs_n = uo_out[4];

    wire spi_miso = 1'b0; // tie low
    wire adc_miso;

    // ============================================================
    // Single-driver input bus (CRITICAL CI FIX)
    // ============================================================
    reg [7:0] ui_bus;
    reg [7:0] uio_bus;

    assign ui_in  = ui_bus;
    assign uio_in = uio_bus;

    always @(*) begin
        ui_bus  = 8'h00;
        uio_bus = 8'h00;

        // I2C
        ui_bus[0]  = scl_drv;
        uio_bus[0] = sda_line;

        // SPI MISOs into DUT
        ui_bus[1] = spi_miso;
        ui_bus[2] = adc_miso;

        // Osc inputs (as mapped in wrapper)
        ui_bus[3] = osc0;
        ui_bus[4] = osc1;
        ui_bus[5] = osc2;
        ui_bus[6] = osc3;
        ui_bus[7] = osc4;

        uio_bus[1] = osc5;
        uio_bus[2] = osc6;
        uio_bus[3] = osc7;
        uio_bus[4] = osc8;

        // uio_bus[7:5] remain 0
    end

    // ============================================================
    // DUT
    // ============================================================
    tt_um_josenbm dut (
        .ui_in  (ui_in),
        .uo_out (uo_out),
        .uio_in (uio_in),
        .uio_out(uio_out),
        .uio_oe (uio_oe),
        .ena    (ena),
        .clk    (clk),
        .rst_n  (rst_n)
    );

    // ============================================================
    // I2C bit-bang helpers (Icarus-friendly)
    // ============================================================
    task i2c_t; begin #200000; end endtask // 200ns = 200000ps

    task i2c_scl_lo; begin scl_drv = 1'b0; i2c_t(); end endtask
    task i2c_scl_hi; begin scl_drv = 1'b1; i2c_t(); end endtask

    task i2c_sda_lo; begin sda_drv = 1'b0; i2c_t(); end endtask
    task i2c_sda_rel; begin sda_drv = 1'b1; i2c_t(); end endtask

    task i2c_start;
    begin
        i2c_sda_rel();
        i2c_scl_hi();
        i2c_sda_lo();
        i2c_scl_lo();
    end
    endtask

    task i2c_stop;
    begin
        i2c_sda_lo();
        i2c_scl_hi();
        i2c_sda_rel();
    end
    endtask

    task i2c_write_bit(input b);
    begin
        i2c_scl_lo();
        if (b) i2c_sda_rel(); else i2c_sda_lo();
        i2c_scl_hi();
        i2c_scl_lo();
    end
    endtask

    task i2c_read_bit(output b);
    begin
        i2c_scl_lo();
        i2c_sda_rel();
        i2c_scl_hi();
        b = sda_line;
        i2c_scl_lo();
    end
    endtask

    task i2c_write_byte(input [7:0] data_byte, output ok);
        integer i;
        reg ack;
    begin
        for (i = 7; i >= 0; i = i - 1)
            i2c_write_bit(data_byte[i]);
        i2c_read_bit(ack);
        ok = (ack == 1'b0);
    end
    endtask

    task i2c_read_byte(input ack_more, output [7:0] v);
        integer i;
        reg b;
    begin
        v = 8'h00;
        for (i = 7; i >= 0; i = i - 1) begin
            i2c_read_bit(b);
            v[i] = b;
        end
        i2c_write_bit(ack_more ? 1'b0 : 1'b1); // ACK=0 continue, NACK=1 end
    end
    endtask

    task i2c_write_reg8(input [6:0] addr, input [7:0] regaddr, input [7:0] data);
        reg ok;
    begin
        i2c_start();
        i2c_write_byte({addr,1'b0}, ok);
        if (!ok) begin $display("FATAL: No ACK on address(W)"); tb_fail=1; tb_done=1; $finish; end

        i2c_write_byte(regaddr, ok);
        if (!ok) begin $display("FATAL: No ACK on regaddr"); tb_fail=1; tb_done=1; $finish; end

        i2c_write_byte(data, ok);
        if (!ok) begin $display("FATAL: No ACK on data"); tb_fail=1; tb_done=1; $finish; end

        i2c_stop();
    end
    endtask

    task i2c_write_reg32(input [6:0] addr, input [7:0] base_reg, input [31:0] value);
    begin
        i2c_write_reg8(addr, base_reg + 8'd0, value[7:0]);
        i2c_write_reg8(addr, base_reg + 8'd1, value[15:8]);
        i2c_write_reg8(addr, base_reg + 8'd2, value[23:16]);
        i2c_write_reg8(addr, base_reg + 8'd3, value[31:24]);
    end
    endtask

    // Read N bytes starting at regaddr into rb[]
    reg [7:0] rb [0:63];
    task i2c_read_regs(input [6:0] addr, input [7:0] regaddr, input integer n);
        integer i;
        reg ok;
        reg [7:0] tmp;
    begin
        i2c_start();
        i2c_write_byte({addr,1'b0}, ok);
        if (!ok) begin $display("FATAL: No ACK on address(W)"); tb_fail=1; tb_done=1; $finish; end

        i2c_write_byte(regaddr, ok);
        if (!ok) begin $display("FATAL: No ACK on regaddr"); tb_fail=1; tb_done=1; $finish; end

        i2c_start();
        i2c_write_byte({addr,1'b1}, ok);
        if (!ok) begin $display("FATAL: No ACK on address(R)"); tb_fail=1; tb_done=1; $finish; end

        for (i = 0; i < n; i = i + 1) begin
            i2c_read_byte(i != (n-1), tmp);
            rb[i] = tmp;
        end
        i2c_stop();
    end
    endtask

    // ============================================================
    // DAC SPI monitor
    // ============================================================
    reg [23:0] spi_cap;
    integer    spi_bits;

    always @(negedge spi_cs_n) begin
        spi_cap  = 24'h0;
        spi_bits = 0;
        spi_cap  = {spi_cap[22:0], spi_mosi};
        spi_bits = 1;
    end

    always @(negedge spi_sclk) begin
        if (!spi_cs_n) begin
            spi_cap  = {spi_cap[22:0], spi_mosi};
            spi_bits = spi_bits + 1;
        end
    end

    always @(posedge spi_cs_n) begin
        if (spi_bits != 0) begin
            $display("SPI(DAC) bits=%0d frame=0x%06h RW=%b reg=0x%0h data=0x%04h (t=%0t)",
                     spi_bits, spi_cap, spi_cap[23], spi_cap[19:16], spi_cap[15:0], $time);
        end
    end

    // ============================================================
    // ADC model (ADS7042-style shift)
    // ============================================================
    reg [11:0] adc_code_model = 12'h123;
    reg [15:0] adc_shift;
    integer    adc_bit;
    reg        adc_miso_r;
    assign adc_miso = adc_miso_r;

    always begin
        #5000000000; // 5ms
        adc_code_model = adc_code_model + 12'h031;
        $display("ADC(model) new code=0x%03h (t=%0t)", adc_code_model, $time);
    end

    always @(negedge adc_cs_n) begin
        adc_shift  = {adc_code_model, 4'h0};
        adc_bit    = 15;
        adc_miso_r = adc_shift[15];
    end

    always @(negedge adc_sclk) begin
        if (!adc_cs_n) begin
            if (adc_bit > 0) begin
                adc_bit    = adc_bit - 1;
                adc_miso_r = adc_shift[adc_bit];
            end
        end
    end

    // ============================================================
    // Test sequence
    // ============================================================
    localparam [6:0] I2C7 = 7'h2A;

    localparam [15:0] CODE_0P9V = 16'hB851;

    localparam [7:0] REG_GATE0  = 8'h20;
    localparam [7:0] REG_APPLY  = 8'h27;

    localparam integer REF_CLK_HZ = 50_000_000;

    // CI-safe default. Use 0 or 1. (3 = 1s may be too slow for CI)
    integer GATE_SEL = 0;

    integer gate_cycles_cfg;
    time    wait_time_ps;

    task set_gate_profile(input integer sel);
        integer gate_ms;
    begin
        case (sel)
            0: gate_ms = 1;
            1: gate_ms = 10;
            2: gate_ms = 100;
            3: gate_ms = 1000;
            default: gate_ms = 1;
        endcase

        gate_cycles_cfg = (REF_CLK_HZ / 1000) * gate_ms; // cycles for gate

        // wait = 3x gate (ms->ps)
        wait_time_ps = gate_ms;
        wait_time_ps = wait_time_ps * 3;
        wait_time_ps = wait_time_ps * 1000000000;

        $display("TB gate profile: sel=%0d gate_ms=%0d gate_cycles=%0d wait=%0t ps",
                 sel, gate_ms, gate_cycles_cfg, wait_time_ps);
    end
    endtask

    initial begin
        reg ok;
        integer i;

        integer c[0:8];
        integer temp;

        $dumpfile("tb.fst");
        $dumpvars(0, tb);

        $display("TB start");

        // idle I2C lines
        scl_drv = 1'b1;
        sda_drv = 1'b1;

        // reset
        rst_n = 1'b0;
        #1000000;   // 1us
        rst_n = 1'b1;
        #2000000;   // 2us settle

        // Address ACK check
        i2c_start();
        i2c_write_byte({I2C7,1'b0}, ok);
        $display("ADDR ACK? ok=%b (expect 1)", ok);
        i2c_stop();

        if (!ok) begin
            tb_fail = 1'b1;
            $display("FAIL: no ACK");
            tb_done = 1'b1;
            #100000;
            $finish;
        end

        // Enable global + counters (also enables ADC sampling)
        // REG04: bit0=global_en, bit4=cnt_en
        i2c_write_reg8(I2C7, 8'h04, 8'h11);

        // Program DAC codes CH0/CH1 then commit
        i2c_write_reg8(I2C7, 8'h12, CODE_0P9V[7:0]);
        i2c_write_reg8(I2C7, 8'h13, CODE_0P9V[15:8]);
        i2c_write_reg8(I2C7, 8'h14, CODE_0P9V[7:0]);
        i2c_write_reg8(I2C7, 8'h15, CODE_0P9V[15:8]);
        i2c_write_reg8(I2C7, 8'h26, 8'h02); // commit

        // Program gate based on selector
        set_gate_profile(GATE_SEL);

        // Disable counters, program gate cycles, apply, re-enable
        i2c_write_reg8(I2C7, 8'h04, 8'h01); // global_en=1, cnt_en=0
        i2c_write_reg32(I2C7, REG_GATE0, gate_cycles_cfg[31:0]);
        i2c_write_reg8(I2C7, REG_APPLY, 8'h01);
        i2c_write_reg8(I2C7, 8'h04, 8'h11); // global_en=1, cnt_en=1

        // Wait for ADC + counters
        #(wait_time_ps);

        // Read full stream: 9 channels * 4 bytes + 2 temp bytes = 38 bytes
        i2c_read_regs(I2C7, 8'h48, 38);

        // Decode counts (little-endian u32)
        for (i = 0; i < 9; i = i + 1) begin
            c[i] = (rb[i*4 + 0]) |
                   (rb[i*4 + 1] << 8) |
                   (rb[i*4 + 2] << 16) |
                   (rb[i*4 + 3] << 24);
        end

        temp = rb[36] | (rb[37] << 8);

        $display("STREAM (gate_cycles=%0d):", gate_cycles_cfg);
        for (i = 0; i < 9; i = i + 1) begin
            $display("  CH%0d count = %0d", i, c[i]);
            if (c[i] <= 0) begin
                $display("FAIL: CH%0d count not > 0", i);
                tb_fail = 1'b1;
            end
        end
        $display("  TEMP (raw 16b) = 0x%04h", temp[15:0]);

        if (tb_fail)
            $display("TB FAIL");
        else
            $display("TB PASS");

        tb_done = 1'b1;
        #1000000;
        $finish;
    end

endmodule

`default_nettype wire
