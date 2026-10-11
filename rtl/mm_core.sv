//------------------------------------------------------------------------------
// Monster Maulers: the platform-agnostic machine.
//
// Everything the board does, with the ROMs behind request/ack ports so the
// same module runs under Verilator with ideal memories and on the MiSTer behind
// the SDRAM/DDR3 controllers. docs/hardware.md is the map.
//
// Derived from the Gaiapolis machine (plasticbugs' Pocket core, via
// gaiapolis-mister): the same 68000 / Z80 / K056832 / K055673 / K053936 /
// K055555 / K054338 / K054539 board family, with this game's 5-bit tiles and
// sprites, 8bpp rotating plane, K055550 and a mixer that blends.
//
// The sound board (mm_sound.sv) mixes the two K054539s; the K054321's
// master volume and channel enables are applied here.
//------------------------------------------------------------------------------
`default_nettype none

module mm_core #(
    parameter string HEXDIR = "rtl/data",
    parameter int    OBJ_BUILD_LINE = 241, // raster line at which the sprite list is built: the first of vblank
    parameter int    STEP_COST_BUS = 16,   // 68000 pacing (mm_main)
    parameter int    STEP_COST_INT = 8
) (
    input  logic        clk,                // 96 MHz
    input  logic        reset,              // the machine
    input  logic        vid_reset,          // the raster and clock enables only: the platform
                                            // keeps video running while the machine is held

    // program ROM, 2 MB as 1M x 16
    output logic        prog_req,
    output logic [22:1] prog_addr,
    input  logic        prog_ack,
    input  logic [15:0] prog_q,
    // tile ROM, 512K rows of 8 pixels: {4 chunky bytes, the fifth plane's byte}
    output logic        tile_req,
    output logic [18:0] tile_addr,
    input  logic        tile_ack,
    input  logic [39:0] tile_q,
    // ROZ map ROM (gfx4, 512 KB) and character ROM (gfx3, 1.5 MB): byte address, 16-bit word back
    output logic        map_req,
    output logic [19:0] map_addr,
    input  logic        map_ack,
    input  logic [15:0] map_q,
    // the ROZ characters come in 128-word blocks (a tile, column-major),
    // streamed: see k053936_roz.sv
    output logic        blk_req,
    output logic [15:0] blk_addr,
    input  logic        blk_wr,
    input  logic  [6:0] blk_idx,
    input  logic [15:0] blk_data,
    input  logic        blk_ack,
    output logic  [3:0] roz_lead,       // lines the ROZ plane has in hand: the platform's arbiter may yield the port by it
    // sprite ROM, 1M rows: {the four low planes as 64 bits, the fifth plane's 16}
    output logic        spr_req,
    output logic [19:0] spr_addr,
    input  logic        spr_ack,
    input  logic [79:0] spr_q,
    // tile RAM (K056832 VRAM, 64K x 16), outside the core: request/ack,
    // byte-enabled writes
    output logic        vram_req,
    output logic        vram_we,
    output logic [15:0] vram_addr,
    output logic  [1:0] vram_be,
    output logic [15:0] vram_wdata,
    input  logic        vram_ack,
    input  logic [15:0] vram_q,
    // sound program ROM, 256 KB, and PCM ROM, 4 MB: byte ports
    output logic        snd_rom_req,
    output logic [17:0] snd_rom_addr,
    input  logic        snd_rom_ack,
    input  logic  [7:0] snd_rom_q,
    output logic        pcm_req,
    output logic [21:0] pcm_addr,
    input  logic        pcm_ack,
    input  logic  [7:0] pcm_q,

    // EEPROM array: load at start, read back to save
    input  logic        eep_ld_we,
    input  logic  [6:0] eep_ld_addr,
    input  logic  [7:0] eep_ld_wdata,
    output logic  [7:0] eep_ld_q,
    output logic        eep_dirty,

    // controls, active low as the board sees them (docs/hardware.md section 8)
    input  logic [15:0] in0_p1,
    input  logic  [7:0] in1,
    input  logic  [7:0] p2,

    // video, 6 MHz pixel rate on cen_pix
    output logic        cen_pix,
    output logic [23:0] rgb,
    output logic        hsync,
    output logic        vsync,
    output logic        de,
    output logic        vblank,

    // audio: a stereo sample on every snd_valid (48 kHz, clk/2000)
    output logic [15:0] snd_l,
    output logic [15:0] snd_r,
    output logic        snd_valid,

    // diagnostics
    output logic [23:0] dbg_addr,
    output logic [15:0] dbg_data,
    output logic  [1:0] dbg_busstate,
    output logic        dbg_step,
    output logic        dbg_irq5,
    output logic        dbg_overrun,
    output logic        dbg_overrun_line,   // one clock per overrunning line
    output logic  [2:0] dbg_overrun_src,    // {tilemap, ROZ, sprites} still busy at that line start
    output logic [31:0] dbg_draw_objs, dbg_draw_rows, dbg_draw_cols, dbg_draw_pxw,   // the sprite renderer's running work counts
    output logic        dbg_spr_we,             // a CPU write into the sprite RAM
    output logic          dbg_roz_en,           // the ROZ plane's registers as the CPU left them (benches)
    output logic [127:0]  dbg_rozctrl,
    output logic  [31:0]  dbg_rozclip,
    output logic [383:0]  dbg_k55,
    output logic        dbg_unsupported,
    output logic        dbg_shadow_overlap,
    output logic  [9:0] dbg_objcount,
    output logic  [8:0] dbg_vcount,
    output logic [15:0] dbg_zpc,
    output logic        dbg_zstep,      // one pulse per Z80 opcode fetch
    output logic        dbg_zwait,      // the Z80 is being held by wait_n
    output logic        dbg_zwr,        // Z80 bus strobes with dbg_zpc as the address
    output logic        dbg_zrd,
    output logic  [7:0] dbg_zwdata,
    output logic        dbg_dma         // the K055550 memset is running
);
    // ------------------------------------------------------------ clocks
    logic cen_16m, cen_8m, cen_48k;
    clk_enables u_cen (.clk(clk), .reset(vid_reset), .cen_16m(cen_16m), .cen_8m(cen_8m), .cen_pix(cen_pix), .cen_48k(cen_48k));

    // ------------------------------------------------------------ timing
    logic        line_start, prestart, px_valid, vblank_rise;
    logic  [2:0] renderers_busy;
    logic  [8:0] render_line, px, hcount, vcount;
    mm_video u_vid (
        .clk(clk), .reset(vid_reset), .cen_pix(cen_pix),
        .line_start(line_start), .render_line(render_line), .prestart(prestart),
        .renderers_busy(renderers_busy), .overrun(dbg_overrun), .overrun_line(dbg_overrun_line), .overrun_src(dbg_overrun_src),
        .px(px), .px_valid(px_valid), .hcount(hcount), .vcount(vcount),
        .hsync(hsync), .vsync(vsync), .de(de), .vblank(vblank), .vblank_rise(vblank_rise)
    );
    assign dbg_vcount = vcount;

    // ------------------------------------------------------- main board
    logic [15:0] k56regs [32] /*verilator public_flat_rd*/, k56regsb [4] /*verilator public_flat_rd*/, k38regs [16] /*verilator public_flat_rd*/,
                 rozctrl [16] /*verilator public_flat_rd*/, rozclip [2] /*verilator public_flat_rd*/, k47regs [8] /*verilator public_flat_rd*/;
    logic  [7:0] k55regs [48] /*verilator public_flat_rd*/, k46regs [8] /*verilator public_flat_rd*/;
    logic        roz_enable;
    logic  [1:0] roz_rombank;
    logic [15:0] sram_q, vram_raddr;
    logic        tvr_req, tvr_ack, vc_req, vc_we, vc_ack;
    logic [15:0] vc_addr, vc_wdata;
    logic  [1:0] vc_be;
    logic [10:0] sram_raddr, pal_raddr, roz_li_addr;
    logic [15:0] roz_li_q;
    logic [23:0] pal_q;
    logic        eep_di, eep_cs, eep_clk, eep_do, eep_ready;
    logic        snd_wr, snd_rd, snd_irq;
    logic  [3:0] snd_off;
    logic  [7:0] snd_wdata, snd_rdata;
    logic        cmap_req, cmap_ack, cchr_req, cchr_ack, ctrom_req, ctrom_ack, csrom_req, csrom_ack;
    logic [19:0] cmap_addr;
    logic [21:0] cchr_addr;
    logic [18:0] ctrom_addr;
    logic [19:0] csrom_addr;

    mm_main #(.STEP_COST_BUS(STEP_COST_BUS), .STEP_COST_INT(STEP_COST_INT)) u_main (
        .clk(clk), .reset(reset), .cen_16m(cen_16m),
        .rom_req(prog_req), .rom_addr(prog_addr), .rom_ack(prog_ack), .rom_q(prog_q),
        .map_req(cmap_req), .map_addr(cmap_addr), .map_ack(cmap_ack), .map_q(map_q),
        .chr_req(cchr_req), .chr_addr(cchr_addr), .chr_ack(cchr_ack), .chr_q(chr_q),
        .trom_req(ctrom_req), .trom_addr(ctrom_addr), .trom_ack(ctrom_ack), .trom_q(tile_q),
        .srom_req(csrom_req), .srom_addr(csrom_addr), .srom_ack(csrom_ack), .srom_q(spr_q),
        .vblank_rise(ol_done),          // the vblank interrupt, once the sprite list is built (~1 line in)
        .in0_p1(in0_p1), .in1(in1), .p2(p2),
        .eep_di(eep_di), .eep_cs(eep_cs), .eep_clk(eep_clk), .eep_do(eep_do), .eep_ready(eep_ready),
        .snd_wr(snd_wr), .snd_rd(snd_rd), .snd_off(snd_off), .snd_wdata(snd_wdata), .snd_rdata(snd_rdata),
        .snd_irq(snd_irq),
        .k56regs(k56regs), .k56regsb(k56regsb), .k55regs(k55regs), .k38regs(k38regs),
        .rozctrl(rozctrl), .rozclip(rozclip), .roz_enable(roz_enable), .roz_rombank(roz_rombank),
        .k46regs(k46regs), .k47regs(k47regs),
        .vc_req(vc_req), .vc_we(vc_we), .vc_addr(vc_addr), .vc_be(vc_be), .vc_wdata(vc_wdata), .vc_ack(vc_ack), .vc_q(vram_q),
        .sram_raddr(sram_raddr), .sram_q(sram_q),
        .pal_raddr(pal_raddr), .pal_q(pal_q), .rozli_raddr(roz_li_addr), .rozli_rq(roz_li_q),
        .dbg_addr(dbg_addr), .dbg_data(dbg_data), .dbg_busstate(dbg_busstate), .dbg_step(dbg_step), .dbg_irq5(dbg_irq5),
        .dbg_spr_we(dbg_spr_we), .dbg_dma(dbg_dma)
    );

    er5911 u_eep (
        .clk(clk), .reset(reset),
        .cs(eep_cs), .sclk(eep_clk), .di(eep_di), .dout(eep_do), .ready(eep_ready),
        .ld_we(eep_ld_we), .ld_addr(eep_ld_addr), .ld_wdata(eep_ld_wdata), .ld_q(eep_ld_q),
        .dirty(eep_dirty)
    );

    logic [6:0] snd_volume;
    logic [1:0] snd_active;
    logic       lat_wr;
    logic [1:0] lat_off;
    logic [7:0] lat_wdata, lat_rdata;
    k054321 u_latch (
        .clk(clk), .reset(reset),
        .m_wr(snd_wr), .m_rd(snd_rd), .m_off(snd_off), .m_wdata(snd_wdata), .m_rdata(snd_rdata),
        .s_wr(lat_wr), .s_off(lat_off), .s_wdata(lat_wdata), .s_rdata(lat_rdata),
        .volume(snd_volume), .active(snd_active)
    );

    logic [15:0] mix_l, mix_r;
    mm_sound #(.HEXDIR(HEXDIR)) u_snd (
        .clk(clk), .reset(reset), .cen_8m(cen_8m), .cen_48k(cen_48k),
        .rom_req(snd_rom_req), .rom_addr(snd_rom_addr), .rom_ack(snd_rom_ack), .rom_q(snd_rom_q),
        .pcm_req(pcm_req), .pcm_addr(pcm_addr), .pcm_ack(pcm_ack), .pcm_q(pcm_q),
        .lat_wr(lat_wr), .lat_off(lat_off), .lat_wdata(lat_wdata), .lat_rdata(lat_rdata),
        .irq_pulse(snd_irq),
        .snd_l(mix_l), .snd_r(mix_r), .dbg_pc(dbg_zpc), .dbg_step(dbg_zstep), .dbg_wait(dbg_zwait),
        .dbg_wr(dbg_zwr), .dbg_rd(dbg_zrd), .dbg_wdata(dbg_zwdata)
    );

    // ------------------------------------------------- derived config
    logic [7:0] tm_colorbase [4];
    always_comb for (int l = 0; l < 4; l++) tm_colorbase[l] = {k55regs[23 + l][3:0], 4'd0};
    wire [7:0] roz_palbase   = k55regs[28];
    // mystwarr_state::screen_update_dadandrn, game type 1: (palette index << 3) & 0x7f
    wire [7:0] spr_colorbase = {1'b0, k55regs[27][3:0], 3'd0};
    wire [7:0] objset1       = k46regs[5];
    wire [15:0] opset        = k47regs[6];
    wire [15:0] k46offx      = {k46regs[0], k46regs[1]};
    wire [15:0] k46offy      = {k46regs[2], k46regs[3]};
    logic [2:0] shadowon;
    logic [7:0] shdpri [3];
    always_comb begin
        for (int t = 0; t < 3; t++) begin
            shadowon[t] = 1'b0;
            for (int c = 0; c < 3; c++) begin
                logic [8:0] d; d = k38regs[2 + t*3 + c][8:0];
                if (d[8] ? (d < 9'h1f9) : (d > 9'd7)) shadowon[t] = 1'b1;
            end
            shdpri[t] = k55regs[37 + t];
        end
    end

    // ------------------------------------------------------- renderers
    logic tm_busy, roz_busy, dr_busy, ol_busy, ol_done, tm_unsup, roz_unsup, ol_overflow;
    logic [10:0] tm_pen [4]; logic [3:0] tm_opq;
    logic [10:0] roz_pen;    logic roz_opq;
    logic spr_opq, spr_shadow; logic [10:0] spr_pen; logic [7:0] spr_pri, spr_shpri; logic [1:0] spr_shtab, spr_mix;
    logic  [9:0] list_idx, list_count; logic [31:0] list_q;
    logic [10:0] ol_sram_addr, dr_sram_addr;
    logic  [9:0] zoom_addr; logic [10:0] recip_addr; logic [23:0] zoom_q, recip_q;
    logic        rmap_req, rmap_ack, rtile_req, rtile_ack, rspr_req, rspr_ack;
    logic [15:0] chr_q;                 // the CPU's read-back word
    logic [19:0] rmap_addr;
    logic [18:0] rtile_addr;
    logic [19:0] rspr_addr;
    logic  [3:1] mix_zero, mix_full;

    logic spr_late;     // the sprite line about to be shown is not finished (spr_sched)
    assign renderers_busy  = {tm_busy, roz_busy, spr_late};
    assign dbg_roz_en = roz_enable;
    always_comb begin
        for (int i = 0; i < 8; i++)  dbg_rozctrl[i*16 +: 16] = rozctrl[i];
        for (int i = 0; i < 2; i++)  dbg_rozclip[i*16 +: 16] = rozclip[i];
        for (int i = 0; i < 48; i++) dbg_k55[i*8 +: 8] = k55regs[i];
    end
    assign dbg_unsupported = tm_unsup | roz_unsup | ol_overflow;

    // The sprite table the renderers work from is a copy of the sprite RAM
    // taken at the first blanking line, as the K053246's DMA into the
    // K053247 does and as MAME's list is taken: the game writes its table
    // during the visible frame as well, and a renderer reading the live RAM
    // line by line saw entries half updated. The copy takes 2,048 clocks; the
    // list is built from it after that, and the vblank interrupt follows the
    // build (below).
    logic [15:0] sram_copy [2048];
    logic [15:0] scopy_q;
    logic [11:0] copy_i;
    logic        copying, copy_start;
    assign sram_raddr = copying ? copy_i[10:0] : 11'd0;      // the live RAM is read only by the copy
    wire [10:0] scopy_raddr = ol_busy ? ol_sram_addr : dr_sram_addr;
    always_ff @(posedge clk) begin
        scopy_q <= sram_copy[scopy_raddr];
        if (copying && copy_i != 12'd0) sram_copy[copy_i[10:0] - 11'd1] <= sram_q;   // sram_q lags the address a clock
    end
    logic obj_build, build_armed;
    always_ff @(posedge clk) begin
        obj_build <= 1'b0; copy_start <= 1'b0;
        if (reset) begin build_armed <= 1'b1; copying <= 1'b0; copy_i <= '0; end
        else begin
            if (copy_start) begin copying <= 1'b1; copy_i <= '0; end
            else if (copying) begin
                if (copy_i == 12'd2048) begin copying <= 1'b0; obj_build <= 1'b1; end
                else copy_i <= copy_i + 12'd1;
            end
        end
        if (!reset && cen_pix) begin
            if (vcount == 9'(OBJ_BUILD_LINE) && hcount == 9'd0 && build_armed) begin
                copy_start <= 1'b1; build_armed <= 1'b0;
            end
            if (vcount != 9'(OBJ_BUILD_LINE)) build_armed <= 1'b1;
        end
    end

    k056832_tilemap u_tm (
        .clk(clk), .reset(reset), .line_start(line_start), .line(render_line), .busy(tm_busy),
        .regs(k56regs), .colorbase(tm_colorbase),
        .vram_req(tvr_req), .vram_addr(vram_raddr), .vram_ack(tvr_ack), .vram_q(vram_q),
        .rom_req(rtile_req), .rom_addr(rtile_addr), .rom_ack(rtile_ack), .rom_q(tile_q),
        .px(px), .pix(tm_pen), .opaque(tm_opq), .unsupported(tm_unsup)
    );
    ram_arb2 #(.AW(16), .DW(16)) u_vram_arb (
        .clk(clk), .reset(reset),
        .c0_req(tvr_req), .c0_we(1'b0), .c0_addr(vram_raddr), .c0_be(2'b11), .c0_wdata(16'd0), .c0_ack(tvr_ack),
        .c1_req(vc_req), .c1_we(vc_we), .c1_addr(vc_addr), .c1_be(vc_be), .c1_wdata(vc_wdata), .c1_ack(vc_ack),
        .m_req(vram_req), .m_we(vram_we), .m_addr(vram_addr), .m_be(vram_be), .m_wdata(vram_wdata), .m_ack(vram_ack)
    );
    rom_arb2 #(.AW(19), .DW(40)) u_tile_arb (
        .clk(clk), .reset(reset),
        .c0_req(rtile_req), .c0_addr(rtile_addr), .c0_ack(rtile_ack),
        .c1_req(ctrom_req), .c1_addr(ctrom_addr), .c1_ack(ctrom_ack),
        .m_req(tile_req), .m_addr(tile_addr), .m_ack(tile_ack), .m_q(tile_q), .q()
    );
    k053936_roz u_roz (
        .clk(clk), .reset(reset), .prestart(prestart), .line_start(line_start), .line(render_line), .busy(roz_busy), .lead(roz_lead),
        .ctrl(rozctrl), .li_addr(roz_li_addr), .li_q(roz_li_q), .clip(rozclip), .roz_enable(roz_enable), .palbase(roz_palbase),
        .map_req(rmap_req), .map_addr(rmap_addr), .map_ack(rmap_ack), .map_q(map_q),
        .blk_req(rblk_req), .blk_addr(rblk_addr), .blk_wr(rblk_wr), .blk_idx(blk_idx), .blk_data(blk_data), .blk_ack(rblk_ack),
        .px(px), .pix(roz_pen), .opaque(roz_opq), .unsupported(roz_unsup)
    );
    rom_arb2 #(.AW(20), .DW(16)) u_map_arb (
        .clk(clk), .reset(reset),
        .c0_req(rmap_req), .c0_addr(rmap_addr), .c0_ack(rmap_ack),
        .c1_req(cmap_req), .c1_addr(cmap_addr), .c1_ack(cmap_ack),
        .m_req(map_req), .m_addr(map_addr), .m_ack(map_ack), .m_q(map_q), .q()
    );
    // The block port is shared by the renderer (client 0) and the CPU's
    // character read-back window (client 1), which reads one byte: its
    // adapter fetches the byte's tile and keeps the word it wants. The
    // stream reaches only the client that owns the port.
    logic        rblk_req, rblk_wr, rblk_ack, cblk_req, cblk_wr, cblk_ack;
    logic [15:0] rblk_addr, cblk_addr;
    logic        blk_busy, blk_sel;
    always_ff @(posedge clk) begin
        if (reset) begin blk_busy <= 1'b0; blk_sel <= 1'b0; end
        else if (!blk_busy) begin
            if (rblk_req)      begin blk_busy <= 1'b1; blk_sel <= 1'b0; end
            else if (cblk_req) begin blk_busy <= 1'b1; blk_sel <= 1'b1; end
        end else if (blk_ack || !(blk_sel ? cblk_req : rblk_req)) blk_busy <= 1'b0;
    end
    assign blk_req  = blk_busy && (blk_sel ? cblk_req : rblk_req);
    assign blk_addr = blk_sel ? cblk_addr : rblk_addr;
    assign rblk_ack = blk_busy && !blk_sel && blk_ack;
    assign cblk_ack = blk_busy &&  blk_sel && blk_ack;
    assign rblk_wr  = blk_busy && !blk_sel && blk_wr;
    assign cblk_wr  = blk_busy &&  blk_sel && blk_wr;
    // the CPU's byte: gfx3 byte b = tile * 256 + row * 16 + x; the word holding it is
    // word row*8 + (x >> 1) of the tile, streamed at index {x >> 1, row}
    logic [6:0]  cblk_row;
    logic [15:0] cblk_word;
    logic        cblk_run;
    assign cblk_addr = {2'b00, cchr_addr[21:8]};
    wire         cchr_oor = (cchr_addr[21:8] >= 14'd6144);            // beyond gfx3's 1.5 MB
    always_ff @(posedge clk) begin
        cchr_ack <= 1'b0;
        if (reset) begin cblk_req <= 1'b0; cblk_run <= 1'b0; end
        else if (!cblk_run) begin
            if (cchr_req && !cchr_ack) begin
                if (cchr_oor) begin cblk_word <= 16'h0000; cchr_ack <= 1'b1; end
                else begin cblk_req <= 1'b1; cblk_row <= {cchr_addr[3:1], cchr_addr[7:4]}; cblk_run <= 1'b1; end
            end
        end else begin
            if (cblk_wr && blk_idx == cblk_row) cblk_word <= blk_data;
            if (cblk_ack) begin cblk_req <= 1'b0; cblk_run <= 1'b0; cchr_ack <= 1'b1; end
            else if (!cchr_req) begin cblk_req <= 1'b0; cblk_run <= 1'b0; end
        end
    end
    assign chr_q = cblk_word;
    logic  [9:0] ol_zoom_addr, dr_zoom_addr;
    logic  [7:0] yr_addr; logic [21:0] yr_q;
    assign zoom_addr = ol_busy ? ol_zoom_addr : dr_zoom_addr;
    k053247_objlist u_ol (
        .clk(clk), .reset(reset), .start(obj_build), .done(ol_done), .busy(ol_busy),
        .opset(opset), .objset1(objset1), .shadowon(shadowon), .shdpri(shdpri),
        .nozcode(1'b1), .mix_zero(mix_zero), .mix_full(mix_full), .k46_offy(k46offy),
        .zoom_addr(ol_zoom_addr), .zoom_q(zoom_q), .yr_addr(yr_addr), .yr_q(yr_q),
        .ram_addr(ol_sram_addr), .ram_q(scopy_q),
        .list_idx(list_idx), .list_q(list_q), .count(list_count), .overflow(ol_overflow)
    );
    assign dbg_objcount = list_count;
    sprite_tables #(.HEXDIR(HEXDIR)) u_tab (
        .clk(clk), .zoom_addr(zoom_addr), .zoom_q(zoom_q), .recip_addr(recip_addr), .recip_q(recip_q)
    );
    // the drawer runs ahead of the scan-out through a ring of line buffers (spr_sched), and its ROM rows come
    // through a row cache (spr_rowcache) in front of the arbiter
    localparam int SPR_SB = 3;
    logic        dr_ls, dr_abort, spr_rd_ok, dr_clearing;
    logic  [8:0] dr_line, dr_done_line;
    logic        drw_req, drw_ack; logic [19:0] drw_addr; logic [79:0] drw_q;
    logic [31:0] rc_hits, rc_misses;
    spr_sched #(.SB(SPR_SB)) u_sched (
        .clk(clk), .reset(reset), .vcount(vcount), .hcount(hcount), .dr_clearing(dr_clearing), .list_rebuild(copy_start), .list_done(ol_done), .dr_busy(dr_busy),
        .line_start(dr_ls), .line(dr_line), .abort(dr_abort), .late(spr_late), .rd_ok(spr_rd_ok), .done_line(dr_done_line)
    );
    k053247_draw #(.SB(SPR_SB)) u_dr (
        .clk(clk), .reset(reset), .line_start(dr_ls), .line(dr_line), .abort(dr_abort), .busy(dr_busy), .clearing(dr_clearing),
        .rd_slot(vcount[SPR_SB-1:0]), .rd_ok(spr_rd_ok),
        .k46r5(objset1), .k46_offx(k46offx), .k46_offy(k46offy), .opset(opset), .colorbase(spr_colorbase),
        .list_idx(list_idx), .list_q(list_q), .list_count(list_count), .yr_addr(yr_addr), .yr_q(yr_q),
        .ram_addr(dr_sram_addr), .ram_q(scopy_q),
        .rom_req(drw_req), .rom_addr(drw_addr), .rom_ack(drw_ack), .rom_q(drw_q),
        .zoom_addr(dr_zoom_addr), .zoom_q(zoom_q), .recip_addr(recip_addr), .recip_q(recip_q),
        .px(px), .out_opaque(spr_opq), .out_pen(spr_pen), .out_pri(spr_pri), .out_mix(spr_mix),
        .out_shadow(spr_shadow), .out_shtab(spr_shtab), .out_shpri(spr_shpri),
        .shadow_overlap(dbg_shadow_overlap),
        .dbg_objs(dbg_draw_objs), .dbg_rows(dbg_draw_rows), .dbg_cols(dbg_draw_cols), .dbg_pxw(dbg_draw_pxw)
    );
    spr_rowcache u_rowcache (
        .clk(clk), .reset(reset),
        .c_req(drw_req), .c_addr(drw_addr), .c_ack(drw_ack), .c_q(drw_q),
        .m_req(rspr_req), .m_addr(rspr_addr), .m_ack(rspr_ack), .m_q(spr_q),
        .dbg_hits(rc_hits), .dbg_misses(rc_misses)
    );
    rom_arb2 #(.AW(20), .DW(80)) u_spr_arb (
        .clk(clk), .reset(reset),
        .c0_req(rspr_req), .c0_addr(rspr_addr), .c0_ack(rspr_ack),
        .c1_req(csrom_req), .c1_addr(csrom_addr), .c1_ack(csrom_ack),
        .m_req(spr_req), .m_addr(spr_addr), .m_ack(spr_ack), .m_q(spr_q), .q()
    );
    mm_mixer u_mx (
        .clk(clk), .reset(reset), .cen_pix(cen_pix),
        .tm_pen(tm_pen), .tm_opq(tm_opq & {4{px_valid}}), .roz_pen(roz_pen), .roz_opq(roz_opq & px_valid),
        .spr_opq(spr_opq & px_valid), .spr_pen(spr_pen), .spr_pri(spr_pri), .spr_mix(spr_mix),
        .spr_shadow(spr_shadow & px_valid), .spr_shtab(spr_shtab), .spr_shpri(spr_shpri),
        .k55regs(k55regs), .k38regs(k38regs), .roz_enable(roz_enable),
        .pal_addr(pal_raddr), .pal_q(pal_q), .rgb(rgb),
        .mix_zero(mix_zero), .mix_full(mix_full)
    );

    // K054321 master volume, 2^((v - 40) / 10) as Q4.12 from the table, and
    // the active bits gating the channels; saturated to 16 bits
    logic [15:0] k321_vol [128];
    initial $readmemh({HEXDIR, "/k321_vol.hex"}, k321_vol);
    wire [15:0] snd_gain = k321_vol[snd_volume];
    function automatic logic [15:0] sat16(input logic signed [32:0] v);
        if (v > 33'sd32767)  return 16'h7fff;
        if (v < -33'sd32768) return 16'h8000;
        return v[15:0];
    endfunction
    // three steps a sample -- the chips' sum, the gain product, the cap --
    // since the sum, multiply and saturate in one cycle were a -0.8 ns path
    logic signed [15:0] mix_l_r, mix_r_r;
    logic signed [32:0] prod_l, prod_r;
    logic         [2:0] snd_stage;
    always_ff @(posedge clk) begin
        snd_stage <= {snd_stage[1:0], cen_48k};
        if (cen_48k) begin mix_l_r <= mix_l; mix_r_r <= mix_r; end
        if (snd_stage[0]) begin
            prod_l <= $signed(mix_l_r) * $signed({1'b0, snd_gain});
            prod_r <= $signed(mix_r_r) * $signed({1'b0, snd_gain});
        end
        if (snd_stage[1]) begin
            snd_l <= snd_active[1] ? sat16(prod_l >>> 12) : '0;
            snd_r <= snd_active[0] ? sat16(prod_r >>> 12) : '0;
        end
        snd_valid <= snd_stage[2];
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = ^{k56regsb[0], k56regsb[1], k56regsb[2], k56regsb[3], roz_rombank,
                    px_valid, vblank_rise, cchr_addr[0], dr_done_line, rc_hits, rc_misses};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
