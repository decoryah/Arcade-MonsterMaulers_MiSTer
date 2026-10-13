// The MiSTer memory subsystem (target/mister/mm_mem.sv: loader, caches, SDRAM controller, DDR3
// arbiter) behind a behavioural SDRAM chip and Avalon DDR3, with every read port exposed to the C++
// bench (sim/tb_memrd.cpp), which loads the ROM image (through the loader's byte port or straight into the
// chips) and reads every region back through the ports the machine uses, comparing with the image.
`default_nettype none

module tb_memrd_top #(
    parameter int DDR_LAT      = 24,
    parameter int DDR_BUSY_PCT = 20
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        dl_start,
    input  logic        dl_we, input logic [24:0] dl_addr, input logic [7:0] dl_data,
    output logic        dl_wait,
    input  logic        fl_go, input logic [24:0] fl_len, output logic fl_done,     // fast load: the image is in the DDR3
    output logic        mem_ready,

    input  logic        prog_req, input logic [22:1] prog_addr, output logic prog_ack, output logic [15:0] prog_q,
    input  logic        snd_req,  input logic [17:0] snd_addr,  output logic snd_ack,  output logic  [7:0] snd_q,
    input  logic        pcm_req,  input logic [21:0] pcm_addr,  output logic pcm_ack,  output logic  [7:0] pcm_q,
    input  logic        tile_req, input logic [18:0] tile_addr, output logic tile_ack, output logic [39:0] tile_q,
    input  logic        map_req,  input logic [19:0] map_addr,  output logic map_ack,  output logic [15:0] map_q,
    input  logic        spr_req,  input logic [19:0] spr_addr,  output logic spr_ack,  output logic [79:0] spr_q,
    input  logic        blk_req,  input logic [15:0] blk_addr,  output logic blk_ack,
    output logic        blk_wr,   output logic [6:0] blk_idx,   output logic [15:0] blk_data,
    output logic        ddr_overflow
);
    wire  [15:0] dram_dq; wire [12:0] dram_a; wire [1:0] dram_ba, dram_dqm;
    wire         dram_clk, dram_cke, dram_ras_n, dram_cas_n, dram_we_n;
    wire         ddr_rd, ddr_we, ddr_busy, ddr_dready;
    wire  [24:0] ddr_addr; wire [7:0] ddr_burst, ddr_be; wire [63:0] ddr_din, ddr_dout;
    wire         DDRAM_BUSY, DDRAM_DOUT_READY, DDRAM_RD, DDRAM_WE;
    wire  [7:0]  DDRAM_BURSTCNT, DDRAM_BE;
    wire  [28:0] DDRAM_ADDR;
    wire  [63:0] DDRAM_DIN, DDRAM_DOUT;

    mm_mem u_mem (
        .clk(clk), .clk_sdram(clk), .init(reset), .dl_start(dl_start), .ready(mem_ready), .rd_late(1'b0), .burst_slow(1'b0),
        .test_start(1'b0), .test_run(), .test_done(), .test_ok(), .test_stable(), .vram_ok(), .vram_bad(),
        .dl_we(dl_we), .dl_addr(dl_addr), .dl_data(dl_data), .dl_wait(dl_wait),
        .fl_go(fl_go), .fl_len(fl_len), .fl_done(fl_done),
        .prog_req(prog_req), .prog_addr(prog_addr), .prog_ack(prog_ack), .prog_q(prog_q),
        .tile_req(tile_req), .tile_addr(tile_addr), .tile_ack(tile_ack), .tile_q(tile_q),
        .map_req(map_req), .map_addr(map_addr), .map_ack(map_ack), .map_q(map_q),
        .blk_req(blk_req), .blk_addr(blk_addr), .blk_wr(blk_wr), .blk_idx(blk_idx), .blk_data(blk_data), .blk_ack(blk_ack), .roz_lead(),
        .spr_req(spr_req), .spr_addr(spr_addr), .spr_ack(spr_ack), .spr_q(spr_q),
        .snd_req(snd_req), .snd_addr(snd_addr), .snd_ack(snd_ack), .snd_q(snd_q),
        .pcm_req(pcm_req), .pcm_addr(pcm_addr), .pcm_ack(pcm_ack), .pcm_q(pcm_q),
        .vram_req(1'b0), .vram_we(1'b0), .vram_addr(16'd0), .vram_be(2'd0), .vram_wdata(16'd0), .vram_ack(), .vram_q(),
        .dram_dq(dram_dq), .dram_a(dram_a), .dram_ba(dram_ba), .dram_dqm(dram_dqm),
        .dram_clk(dram_clk), .dram_cke(dram_cke), .dram_ras_n(dram_ras_n), .dram_cas_n(dram_cas_n), .dram_we_n(dram_we_n),
        .ddr_rd(ddr_rd), .ddr_we(ddr_we), .ddr_addr(ddr_addr), .ddr_burst(ddr_burst), .ddr_din(ddr_din), .ddr_be(ddr_be),
        .ddr_busy(ddr_busy), .ddr_dout(ddr_dout), .ddr_dready(ddr_dready)
    );
    sdram_model #(.PHASE_LAG(0), .AW(24)) chip (
        .clk(clk), .dq(dram_dq), .a(dram_a), .ba(dram_ba), .dqml(dram_dqm[0]), .dqmh(dram_dqm[1]),
        .cs_n(1'b0), .ras_n(dram_ras_n), .cas_n(dram_cas_n), .we_n(dram_we_n), .cke(dram_cke)
    );
    ddr_arb u_arb (
        .clk(clk), .reset(reset),
        .c_rd(ddr_rd), .c_we(ddr_we), .c_addr(ddr_addr), .c_burst(ddr_burst), .c_din(ddr_din), .c_be(ddr_be),
        .c_busy(ddr_busy), .c_dout(ddr_dout), .c_dready(ddr_dready),
        .r_we(1'b0), .r_addr(29'd0), .r_din(64'd0), .r_be(8'd0),
        .f_rd(1'b0), .f_addr(25'd0), .f_burst(8'd0), .f_busy(), .f_dready(),
        .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
        .DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY),
        .DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
        .overflow(ddr_overflow)
    );
    ddr_model #(.AW(23), .LAT(DDR_LAT), .BUSY_PCT(DDR_BUSY_PCT)) ddr (
        .clk(clk), .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
        .DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY),
        .DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE)
    );
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = ^{dram_clk};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
