// freq_counter_gate.v
// Counts rising edges of sig_in over a programmable gate interval in ref_clk cycles.
// Latches count_latched and pulses new_data for 1 ref_clk cycle at end of gate.
//
// gate_cycles is in ref_clk cycles (must be >= 2; module clamps small values).
// NOTE: sig_in may be asynchronous to ref_clk; this module includes a 2-FF synchronizer before edge-detect.

module freq_counter_gate (
    input  wire        ref_clk,
    input  wire        rst_n,
    input  wire        en,
    input  wire        sig_in,
    input  wire [31:0] gate_cycles,

    output reg  [31:0] count_latched,
    output reg         new_data
);

    // Clamp too-small values (avoid gate_cycles 0/1)
    wire [31:0] gate_eff = (gate_cycles < 32'd2) ? 32'd2 : gate_cycles;

    // Synchronize sig_in to ref_clk (2-FF) then edge-detect
    reg sig_meta;
    reg sig_sync;
    reg sig_d;
    wire rise = sig_sync & ~sig_d;

    // Gate counter and edge counter
    reg [31:0] gate_cnt;
    reg [31:0] edge_cnt;

    always @(posedge ref_clk or negedge rst_n) begin
        if (!rst_n) begin
            sig_meta      <= 1'b0;
            sig_sync      <= 1'b0;
            sig_d         <= 1'b0;
            gate_cnt      <= 32'd0;
            edge_cnt      <= 32'd0;
            count_latched <= 32'd0;
            new_data      <= 1'b0;
        end else begin
            sig_meta <= sig_in;
            sig_sync <= sig_meta;
            sig_d    <= sig_sync;
            new_data <= 1'b0;

            if (!en) begin
                gate_cnt <= 32'd0;
                edge_cnt <= 32'd0;
            end else begin
                // count edges during the gate
                if (rise)
                    edge_cnt <= edge_cnt + 32'd1;

                // gate timing
                if (gate_cnt == (gate_eff - 32'd1)) begin
                    gate_cnt      <= 32'd0;
                    count_latched <= edge_cnt;
                    edge_cnt      <= 32'd0;
                    new_data      <= 1'b1;
                end else begin
                    gate_cnt <= gate_cnt + 32'd1;
                end
            end
        end
    end

endmodule
