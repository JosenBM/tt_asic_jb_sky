//`timescale 1ns/1ps
module i2c_slave #(
    parameter [6:0] I2C_ADDR = 7'h2A
)(
    input  wire       clk,
    input  wire       rst_n,

    input  wire       scl,
    input  wire       sda_in,
    output wire       sda_oe,

    output reg  [7:0] reg_addr,
    output reg        wr_en,
    output reg  [7:0] wr_data,
    input  wire [7:0] rd_data
);

    // Open-drain SDA: drive LOW when sda_oe is 1. External pull-up provides HIGH.
    reg sda_oe_n;
    assign sda_oe = ~sda_oe_n;

    // 2FF sync
    reg scl_ff1, scl_ff2;
    reg sda_ff1, sda_ff2;
    wire scl_sync = scl_ff2;
    wire sda_sync = sda_ff2;

    // prev for edge detect
    reg scl_prev, sda_prev;
    wire scl_rise = (scl_sync == 1'b1) && (scl_prev == 1'b0);
    wire scl_fall = (scl_sync == 1'b0) && (scl_prev == 1'b1);

    // START/STOP
    wire start_cond = (scl_sync == 1'b1) && (sda_prev == 1'b1) && (sda_sync == 1'b0);
    wire stop_cond  = (scl_sync == 1'b1) && (sda_prev == 1'b0) && (sda_sync == 1'b1);

    // States
    localparam ST_IDLE        = 4'd0;
    localparam ST_RX_ADDR     = 4'd1;
    localparam ST_TX_ACK_ADDR = 4'd2;
    localparam ST_RX_REGPTR   = 4'd3;
    localparam ST_TX_ACK_REG  = 4'd4;
    localparam ST_RX_DATA     = 4'd5;
    localparam ST_TX_ACK_DATA = 4'd6;
    localparam ST_TX_DATA     = 4'd7;
    localparam ST_RX_ACK_RD   = 4'd8;

    reg [3:0] state;

    reg [7:0] shreg;
    reg [2:0] bitcnt;

    reg addr_match;
    reg rw;

    reg [7:0] tx_byte;

    reg ack_hold;
    reg rd_continue;

    // *** LATCHED WRITE PAYLOAD ***
    reg [7:0] wr_addr_lat;
    reg [7:0] wr_data_lat;
    reg       wr_pulse_req; // request a clean 1-clk wr_en pulse

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scl_ff1 <= 1'b1; scl_ff2 <= 1'b1;
            sda_ff1 <= 1'b1; sda_ff2 <= 1'b1;
            scl_prev <= 1'b1;
            sda_prev <= 1'b1;

            state      <= ST_IDLE;
            shreg      <= 8'd0;
            bitcnt     <= 3'd7;
            addr_match <= 1'b0;
            rw         <= 1'b0;

            reg_addr   <= 8'd0;

            wr_en      <= 1'b0;
            wr_data    <= 8'd0;

            sda_oe_n   <= 1'b1;

            tx_byte    <= 8'd0;

            ack_hold   <= 1'b0;
            rd_continue<= 1'b0;

            wr_addr_lat  <= 8'd0;
            wr_data_lat  <= 8'd0;
            wr_pulse_req <= 1'b0;

        end else begin
            // sync
            scl_ff1 <= scl;     scl_ff2 <= scl_ff1;
            sda_ff1 <= sda_in;  sda_ff2 <= sda_ff1;

            // prev
            scl_prev <= scl_sync;
            sda_prev <= sda_sync;

            // defaults
            wr_en <= 1'b0;

            // generate exactly 1 clk pulse for wr_en with stable addr/data
            if (wr_pulse_req) begin
                wr_en   <= 1'b1;
                wr_data <= wr_data_lat;     // stable data
                reg_addr <= wr_addr_lat;    // stable addr for the pulse
                wr_pulse_req <= 1'b0;
            end

            // START
            if (start_cond) begin
                state      <= ST_RX_ADDR;
                bitcnt     <= 3'd7;
                addr_match <= 1'b0;
                rw         <= 1'b0;
                sda_oe_n   <= 1'b1;
                ack_hold   <= 1'b0;
                rd_continue<= 1'b0;
            end

            // STOP
            if (stop_cond) begin
                state    <= ST_IDLE;
                sda_oe_n <= 1'b1;
                ack_hold <= 1'b0;
            end

            // sample on SCL rise
            if (scl_rise) begin
                case (state)
                    ST_RX_ADDR: begin
                        shreg[bitcnt] <= sda_sync;
                        if (bitcnt == 0) begin
                            addr_match <= (shreg[7:1] == I2C_ADDR);
                            rw         <= sda_sync;
                            state      <= ST_TX_ACK_ADDR;
                        end else bitcnt <= bitcnt - 3'd1;
                    end

                    ST_RX_REGPTR: begin
                        shreg[bitcnt] <= sda_sync;
                        if (bitcnt == 0) begin
                            reg_addr <= {shreg[7:1], sda_sync}; // set pointer
                            state    <= ST_TX_ACK_REG;
                        end else bitcnt <= bitcnt - 3'd1;
                    end

                    ST_RX_DATA: begin
                        shreg[bitcnt] <= sda_sync;
                        if (bitcnt == 0) begin
                            // latch final received data byte & current pointer
                            wr_addr_lat <= reg_addr;
                            wr_data_lat <= {shreg[7:1], sda_sync};
                            state       <= ST_TX_ACK_DATA;
                        end else bitcnt <= bitcnt - 3'd1;
                    end

                    ST_RX_ACK_RD: begin
                        rd_continue <= (sda_sync == 1'b0);
                        if (sda_sync == 1'b0) begin
                            reg_addr <= reg_addr + 8'd1;
                        end
                    end

                    default: begin end
                endcase
            end

            // drive on SCL fall
            if (scl_fall) begin
                case (state)

                    ST_TX_ACK_ADDR: begin
                        if (!ack_hold) begin
                            sda_oe_n <= (addr_match) ? 1'b0 : 1'b1;
                            ack_hold <= 1'b1;
                        end else begin
                            ack_hold <= 1'b0;
                            sda_oe_n <= 1'b1;

                            if (addr_match) begin
                                if (rw == 1'b0) begin
                                    state  <= ST_RX_REGPTR;
                                    bitcnt <= 3'd7;
                                end else begin
                                    tx_byte <= rd_data;
                                    state   <= ST_TX_DATA;
                                    bitcnt  <= 3'd7;
                                    // present MSB immediately
                                    sda_oe_n <= (rd_data[7] == 1'b0) ? 1'b0 : 1'b1;
                                end
                            end else begin
                                state <= ST_IDLE;
                            end
                        end
                    end

                    ST_TX_ACK_REG: begin
                        if (!ack_hold) begin
                            sda_oe_n <= 1'b0;
                            ack_hold <= 1'b1;
                        end else begin
                            sda_oe_n <= 1'b1;
                            ack_hold <= 1'b0;
                            state    <= ST_RX_DATA;
                            bitcnt   <= 3'd7;
                        end
                    end

                    ST_TX_ACK_DATA: begin
                        if (!ack_hold) begin
                            // request wr_en pulse (clk domain), ACK low
                            wr_pulse_req <= 1'b1;
                            sda_oe_n      <= 1'b0;
                            ack_hold      <= 1'b1;
                        end else begin
                            // finish ACK clock: release SDA, NOW increment pointer and continue
                            sda_oe_n <= 1'b1;
                            ack_hold <= 1'b0;

                            reg_addr <= reg_addr + 8'd1;   // increment AFTER write request is queued
                            state    <= ST_RX_DATA;
                            bitcnt   <= 3'd7;
                        end
                    end

                    ST_TX_DATA: begin
                        // Change SDA on SCL falling edge so it's stable during SCL high.
                        // When we ENTER ST_TX_DATA we already drove bit7.
                        if (bitcnt == 0) begin
                            // LSB already sent; next clock is master's ACK/NACK
                            state    <= ST_RX_ACK_RD;
                            sda_oe_n <= 1'b1;  // release for ACK bit
                        end else begin
                            // Move to next bit and drive it immediately
                            bitcnt   <= bitcnt - 3'd1;
                            sda_oe_n <= (tx_byte[bitcnt - 3'd1] == 1'b0) ? 1'b0 : 1'b1;
                        end
                    end

                    ST_RX_ACK_RD: begin
                        if (rd_continue) begin
                            tx_byte <= rd_data;
                            state   <= ST_TX_DATA;
                            bitcnt  <= 3'd7;
                            sda_oe_n <= (rd_data[7] == 1'b0) ? 1'b0 : 1'b1;
                        end else begin
                            state    <= ST_IDLE;
                            sda_oe_n <= 1'b1;
                        end
                    end

                    default: begin
                        sda_oe_n <= 1'b1;
                    end
                endcase
            end
        end
    end

endmodule
