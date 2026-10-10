// Full-system bench wrapper: mm_core behind the real MiSTer memory subsystem
// (target/mister/mm_mem.sv: the loader, the caches, the SDRAM controller and the
// DDR3 arbiter), a behavioural SDRAM chip and a behavioural Avalon DDR3. The ROM
// image goes in through the loader's byte port exactly as the HPS delivers it,
// so the loader's interleaving of the planes is part of what is tested.
`default_nettype none

module tb_mm_top #(
    parameter int STEP_COST_BUS = 16,
    parameter int STEP_COST_INT = 8,
    parameter int DDR_LAT       = 24,
    parameter int DDR_BUSY_PCT  = 20
) (
    input  logic        clk,
    input  logic        reset,          // the platform's reset: SDRAM init and the machine
    input  logic        dl_hold,        // an image is loading: the machine stays in reset
    input  logic        dl_start,
    input  logic        dl_we, input logic [24:0] dl_addr, input logic [7:0] dl_data,
    output logic        dl_wait,
    output logic        mem_ready,

    input  logic        eep_we, input logic [6:0] eep_waddr, input logic [7:0] eep_wdata,
    input  logic [15:0] in0_p1,
    input  logic  [7:0] in1,
    input  logic  [7:0] p2,

    output logic        cen_pix,
    output logic [23:0] rgb,
    output logic        hsync, vsync, de, vblank,
    output logic [23:0] dbg_addr,
    output logic [15:0] dbg_data,
    output logic  [1:0] dbg_busstate,
    output logic        dbg_step, dbg_irq5, dbg_overrun, dbg_unsupported, dbg_shadow_overlap, dbg_dma,
    output logic  [2:0] dbg_overrun_src,
    output logic        dbg_spr_we,
    output logic  [9:0] dbg_objcount,
    output logic  [8:0] dbg_vcount,
    output logic [15:0] dbg_zpc,
    output logic        dbg_zstep, dbg_zwait, dbg_zwr, dbg_zrd,
    output logic  [7:0] dbg_zwdata,
    output logic [15:0] snd_l, snd_r,
    output logic        snd_valid,
    output logic  [7:0] eep_q,
    output logic        eep_dirty,
    output logic        ddr_overflow
);
    logic        prog_req, prog_ack, tile_req, tile_ack, map_req, map_ack, spr_req, spr_ack;
    logic [22:1] prog_addr; logic [18:0] tile_addr; logic [19:0] map_addr; logic [19:0] spr_addr;
    logic [15:0] prog_q, map_q; logic [39:0] tile_q; logic [79:0] spr_q;
    // read by the C++ bench's ROM check (ROMCHK=1)
    logic        chk_tile_ack /*verilator public_flat_rd*/, chk_spr_ack /*verilator public_flat_rd*/, chk_map_ack /*verilator public_flat_rd*/;
    logic [18:0] chk_tile_addr /*verilator public_flat_rd*/;
    logic [39:0] chk_tile_q /*verilator public_flat_rd*/;
    logic [19:0] chk_spr_addr /*verilator public_flat_rd*/;
    logic [79:0] chk_spr_q /*verilator public_flat_rd*/;
    logic [19:0] chk_map_addr /*verilator public_flat_rd*/;
    logic [15:0] chk_map_q /*verilator public_flat_rd*/;
    assign chk_tile_ack = tile_ack; assign chk_tile_addr = tile_addr; assign chk_tile_q = tile_q;
    assign chk_spr_ack  = spr_ack;  assign chk_spr_addr  = spr_addr;  assign chk_spr_q  = spr_q;
    assign chk_map_ack  = map_ack;  assign chk_map_addr  = map_addr;  assign chk_map_q  = map_q;
    logic        blk_req, blk_wr, blk_ack; logic [15:0] blk_addr, blk_data; logic [6:0] blk_idx; logic [3:0] roz_lead;
    logic        srom_req, srom_ack, pcmr_req, pcmr_ack;
    logic [17:0] srom_addr; logic [21:0] pcmr_addr;
    logic  [7:0] srom_q, pcmr_q;
    logic        vram_req, vram_we, vram_ack;
    logic [15:0] vram_addr, vram_wdata, vram_q;
    logic  [1:0] vram_be;

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
        .prog_req(prog_req), .prog_addr(prog_addr), .prog_ack(prog_ack), .prog_q(prog_q),
        .tile_req(tile_req), .tile_addr(tile_addr), .tile_ack(tile_ack), .tile_q(tile_q),
        .map_req(map_req), .map_addr(map_addr), .map_ack(map_ack), .map_q(map_q),
        .blk_req(blk_req), .blk_addr(blk_addr), .blk_wr(blk_wr), .blk_idx(blk_idx), .blk_data(blk_data), .blk_ack(blk_ack), .roz_lead(roz_lead),
        .spr_req(spr_req), .spr_addr(spr_addr), .spr_ack(spr_ack), .spr_q(spr_q),
        .snd_req(srom_req), .snd_addr(srom_addr), .snd_ack(srom_ack), .snd_q(srom_q),
        .pcm_req(pcmr_req), .pcm_addr(pcmr_addr), .pcm_ack(pcmr_ack), .pcm_q(pcmr_q),
        .vram_req(vram_req), .vram_we(vram_we), .vram_addr(vram_addr), .vram_be(vram_be), .vram_wdata(vram_wdata),
        .vram_ack(vram_ack), .vram_q(vram_q),
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
    ddr_model #(.AW(20), .LAT(DDR_LAT), .BUSY_PCT(DDR_BUSY_PCT)) ddr (
        .clk(clk), .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
        .DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY),
        .DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE)
    );

    // the machine waits for the memories and for the image, as MonsterMaulers.sv does
    wire core_reset = reset | ~mem_ready | dl_hold;
    mm_core #(.HEXDIR("../rtl/data"), .STEP_COST_BUS(STEP_COST_BUS), .STEP_COST_INT(STEP_COST_INT)) u_core (
        .clk(clk), .reset(core_reset), .vid_reset(reset),
        .prog_req(prog_req), .prog_addr(prog_addr), .prog_ack(prog_ack), .prog_q(prog_q),
        .tile_req(tile_req), .tile_addr(tile_addr), .tile_ack(tile_ack), .tile_q(tile_q),
        .map_req(map_req), .map_addr(map_addr), .map_ack(map_ack), .map_q(map_q),
        .blk_req(blk_req), .blk_addr(blk_addr), .blk_wr(blk_wr), .blk_idx(blk_idx), .blk_data(blk_data), .blk_ack(blk_ack), .roz_lead(roz_lead),
        .spr_req(spr_req), .spr_addr(spr_addr), .spr_ack(spr_ack), .spr_q(spr_q),
        .vram_req(vram_req), .vram_we(vram_we), .vram_addr(vram_addr), .vram_be(vram_be), .vram_wdata(vram_wdata),
        .vram_ack(vram_ack), .vram_q(vram_q),
        .snd_rom_req(srom_req), .snd_rom_addr(srom_addr), .snd_rom_ack(srom_ack), .snd_rom_q(srom_q),
        .pcm_req(pcmr_req), .pcm_addr(pcmr_addr), .pcm_ack(pcmr_ack), .pcm_q(pcmr_q),
        .eep_ld_we(eep_we), .eep_ld_addr(eep_waddr), .eep_ld_wdata(eep_wdata), .eep_ld_q(eep_q), .eep_dirty(eep_dirty),
        .in0_p1(in0_p1), .in1(in1), .p2(p2),
        .cen_pix(cen_pix), .rgb(rgb), .hsync(hsync), .vsync(vsync), .de(de), .vblank(vblank),
        .snd_l(snd_l), .snd_r(snd_r), .snd_valid(snd_valid),
        .dbg_addr(dbg_addr), .dbg_data(dbg_data), .dbg_busstate(dbg_busstate), .dbg_step(dbg_step), .dbg_irq5(dbg_irq5),
        .dbg_overrun(dbg_overrun), .dbg_overrun_src(dbg_overrun_src), .dbg_draw_objs(), .dbg_draw_rows(), .dbg_draw_cols(), .dbg_draw_pxw(),
        .dbg_spr_we(dbg_spr_we), .dbg_roz_en(), .dbg_rozctrl(), .dbg_rozclip(), .dbg_k55(),
        .dbg_unsupported(dbg_unsupported), .dbg_shadow_overlap(dbg_shadow_overlap),
        .dbg_objcount(dbg_objcount), .dbg_vcount(dbg_vcount), .dbg_zpc(dbg_zpc), .dbg_zstep(dbg_zstep), .dbg_zwait(dbg_zwait),
        .dbg_zwr(dbg_zwr), .dbg_zrd(dbg_zrd), .dbg_zwdata(dbg_zwdata), .dbg_dma(dbg_dma)
    );
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = ^{dram_clk};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
