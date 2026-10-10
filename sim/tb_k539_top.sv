// Chip-level bench for the two K054539s: the sample ROM behind a one-clock request/ack model, a register
// write port per chip. tb_k539.cpp replays the writes the game's Z80 made (tools/lua/k539_log.lua) and
// collects each chip's stereo output.
`default_nettype none

module tb_k539_top (
    input  logic        clk,
    input  logic        reset,
    input  logic        cen_48k,
    input  logic        cs1, cs2, wr,
    input  logic  [9:0] addr,
    input  logic  [7:0] wdata,
    output logic [15:0] l1, r1, l2, r2
);
    logic [7:0] pcm [0:(1 << 22) - 1] /*verilator public_flat_rw*/;

    logic        rq1, rq2, ak1, ak2;
    logic [21:0] ad1, ad2;
    logic  [7:0] q1, q2;
    always_ff @(posedge clk) begin
        ak1 <= rq1 && !ak1; q1 <= pcm[ad1];
        ak2 <= rq2 && !ak2; q2 <= pcm[ad2];
    end

    // as mm_sound.sv instantiates them: chip 1's channels 4-7 at x2.0
    k054539 #(.HEXDIR("../rtl/data"), .GAIN_Q14({16'h8000, 16'h8000, 16'h8000, 16'h8000, 16'h4000, 16'h4000, 16'h4000, 16'h4000})) u_k1 (
        .clk(clk), .reset(reset), .cen_48k(cen_48k),
        .cs(cs1), .wr(wr), .rd(1'b0), .addr(addr), .wdata(wdata), .rdata(), .rd_stall(),
        .rom_req(rq1), .rom_addr(ad1), .rom_ack(ak1), .rom_q(q1),
        .timer_out(), .snd_l(l1), .snd_r(r1)
    );
    k054539 #(.HEXDIR("../rtl/data")) u_k2 (
        .clk(clk), .reset(reset), .cen_48k(cen_48k),
        .cs(cs2), .wr(wr), .rd(1'b0), .addr(addr), .wdata(wdata), .rdata(), .rd_stall(),
        .rom_req(rq2), .rom_addr(ad2), .rom_ack(ak2), .rom_q(q2),
        .timer_out(), .snd_l(l2), .snd_r(r2)
    );
endmodule
