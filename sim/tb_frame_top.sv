// Full video pipeline bench: tilemaps + ROZ + sprites + mixer, every memory
// loadable from the C++ driver, one line rendered at a time and scanned out
// through the mixer to RGB. Structure after the Gaiapolis (Pocket) frame bench.
`default_nettype none

module tb_frame_top #(
    parameter int SPR_SB = 2        // sprite line buffer ring: 2**SPR_SB lines
) (
    input  logic        clk,
    input  logic        cen_pix,        // the pixel tick the mixer's phases count from
    input  logic        reset,

    // ---- loads ----
    input  logic        k56_we,  input logic [4:0] k56_addr,  input logic [15:0] k56_data,
    input  logic        k55_we,  input logic [5:0] k55_addr,  input logic  [7:0] k55_data,
    input  logic        k38_we,  input logic [3:0] k38_addr,  input logic [15:0] k38_data,
    input  logic        rozc_we, input logic [3:0] rozc_addr, input logic [15:0] rozc_data,
    input  logic        clip_we, input logic       clip_addr, input logic [15:0] clip_data,
    input  logic        cfg_we,
    input  logic        roz_enable_i,
    input  logic [15:0] opset_i,
    input  logic  [7:0] k46r5_i,
    input  logic [15:0] k46offx_i, k46offy_i,
    input  logic        vram_we, input logic [15:0] vram_waddr, input logic [15:0] vram_wdata,
    input  logic        pal_we,  input logic [10:0] pal_waddr, input logic [23:0] pal_wdata,
    input  logic        sram_we, input logic [10:0] sram_waddr, input logic [15:0] sram_wdata,
    input  logic        li_we,   input logic [10:0] li_waddr,   input logic [15:0] li_wdata,
    input  logic        trom_we, input logic [18:0] trom_waddr, input logic [39:0] trom_wdata,
    input  logic        mrom_we, input logic [18:0] mrom_waddr, input logic [15:0] mrom_wdata,
    input  logic        crom_we, input logic [19:0] crom_waddr, input logic [15:0] crom_wdata,   // {tile[12:0], idx[6:0]}
    input  logic        srom_we, input logic [19:0] srom_waddr, input logic [79:0] srom_wdata,
    input  logic        tab_we,  input logic tab_sel, input logic [10:0] tab_waddr, input logic [23:0] tab_wdata,

    // ---- control ----
    input  logic        build,
    output logic        build_done,
    input  logic        prestart,
    input  logic        line_start,
    input  logic  [8:0] line,           // the tilemap's and the ROZ's line (the sprites schedule their own)
    input  logic  [8:0] vcount,         // the raster line being scanned: the sprite drawer's lead is counted from it
    input  logic  [8:0] hcount_i,       // 0: render lines to completion; 24: a line is dropped as its picture starts
    output logic  [8:0] spr_done_line,
    output logic        busy,
    output logic  [2:0] busy_src,       // {tilemap, ROZ, sprites}
    output logic  [3:0] roz_lead,       // the ROZ plane's lines in hand, after a pulse
    input  logic  [8:0] px,
    input  logic        px_valid,
    output logic [23:0] rgb,
    output logic        unsupported,
    output logic        shadow_overlap,
    output logic  [5:0] dbg_dr_st,      // the sprite drawer's state, for the line-time histogram
    output logic [31:0] cache_hits, cache_misses
);
    // ------------------------------------------------------------ registers
    logic [15:0] k56regs [32];
    logic  [7:0] k55regs [48];
    logic [15:0] k38regs [16];
    logic [15:0] rozctrl [16];
    logic [15:0] rozclip [2];
    logic        roz_enable;
    logic [15:0] opset, k46offx, k46offy;
    logic  [7:0] k46r5;
    always_ff @(posedge clk) begin
        if (k56_we)  k56regs[k56_addr]  <= k56_data;
        if (k55_we)  k55regs[k55_addr]  <= k55_data;
        if (k38_we)  k38regs[k38_addr]  <= k38_data;
        if (rozc_we) rozctrl[rozc_addr] <= rozc_data;
        if (clip_we) rozclip[clip_addr] <= clip_data;
        if (cfg_we) begin
            roz_enable <= roz_enable_i; opset <= opset_i; k46r5 <= k46r5_i;
            k46offx <= k46offx_i; k46offy <= k46offy_i;
        end
    end

    // derived configuration, as mm_core derives it
    logic [7:0] tm_colorbase [4];
    always_comb for (int l = 0; l < 4; l++) tm_colorbase[l] = {k55regs[23 + l][3:0], 4'd0};
    wire [7:0] roz_palbase = k55regs[28];
    wire [7:0] spr_colorbase = {1'b0, k55regs[27][3:0], 3'd0};      // (reg << 3) & 0x7f
    wire [7:0] objset1 = k46r5;
    logic [2:0] shadowon;
    logic [7:0] shdpri [3];
    always_comb begin
        for (int t = 0; t < 3; t++) begin
            shadowon[t] = 1'b0;
            for (int c = 0; c < 3; c++) begin
                logic [8:0] d; d = k38regs[2 + t*3 + c][8:0];
                // |delta| > 7, delta being 9-bit two's complement
                if (d[8] ? (d < 9'h1f9) : (d > 9'd7)) shadowon[t] = 1'b1;
            end
            shdpri[t] = k55regs[37 + t];
        end
    end

    // ------------------------------------------------------------ memories
    logic [15:0] vram [65536];
    logic [15:0] vram_addr, vram_q;
    logic        vram_req, vram_ack;
    logic [39:0] trom [524288];
    logic        trom_req, trom_ack; logic [18:0] trom_addr; logic [39:0] trom_q;
    logic [15:0] mrom [262144];
    logic        mrom_req, mrom_ack; logic [19:0] mrom_addr; logic [15:0] mrom_q;
    logic [15:0] crom [6144 * 128];

    // the character blocks, as the platform streams them: LAT_BLK clocks after
    // the request the tile's 128 words follow, one a clock, in {column, row} order
    logic        blk_req, blk_wr, blk_ack;
    logic [15:0] blk_addr, blk_data;
    logic  [6:0] blk_idx;
    int lat_blk, cnt_blk;
    logic  [7:0] blk_n;                 // 0..127 streaming, 128 done
    logic        blk_run;
    logic [15:0] blk_addr_l;
    initial if (!$value$plusargs("LAT_BLK=%d", lat_blk)) lat_blk = 0;
    always_ff @(posedge clk) begin
        blk_wr <= 1'b0; blk_ack <= 1'b0;
        if (!blk_run) begin
            cnt_blk <= 0; blk_n <= 8'd0;
            if (blk_req && !blk_ack) begin blk_run <= 1'b1; blk_addr_l <= blk_addr; end
        end else if (cnt_blk < lat_blk) cnt_blk <= cnt_blk + 1;
        else if (blk_n != 8'd128) begin
            blk_wr <= 1'b1; blk_idx <= blk_n[6:0];
            blk_data <= crom[{blk_addr_l[12:0], blk_n[6:0]}];
            blk_n <= blk_n + 8'd1;
        end else begin
            blk_run <= 1'b0;
            if (blk_req && blk_addr == blk_addr_l) blk_ack <= 1'b1;
        end
    end

    logic [15:0] sram [2048];
    logic [15:0] lineram [2048];
    logic [10:0] li_addr; logic [15:0] li_q;
    logic [10:0] ol_sram_addr, dr_sram_addr, sram_addr; logic [15:0] sram_q;
    logic [79:0] srom [1048576];
    logic        srom_req, srom_ack; logic [19:0] srom_addr; logic [79:0] srom_q;
    logic [23:0] zoomtab [1024], reciptab [2048];
    logic  [9:0] zoom_addr; logic [10:0] recip_addr; logic [23:0] zoom_q, recip_q;
    logic [23:0] pal [2048];
    logic [10:0] pal_addr; logic [23:0] pal_q;
    logic        ol_busy;
    assign sram_addr = ol_busy ? ol_sram_addr : dr_sram_addr;

    // Each memory answers LAT_* clocks after the request (+LAT_VRAM=n
    // +LAT_TROM=n +LAT_MROM=n +LAT_SROM=n +LAT_BLK=n; 0 = the clock after,
    // the ideal). A request withdrawn before its ack is dropped.
    int lat_vram, lat_trom, lat_mrom, lat_srom;
    int cnt_vram, cnt_trom, cnt_mrom, cnt_srom;
    initial begin
        if (!$value$plusargs("LAT_VRAM=%d", lat_vram)) lat_vram = 0;
        if (!$value$plusargs("LAT_TROM=%d", lat_trom)) lat_trom = 0;
        if (!$value$plusargs("LAT_MROM=%d", lat_mrom)) lat_mrom = 0;
        if (!$value$plusargs("LAT_SROM=%d", lat_srom)) lat_srom = 0;
    end
    `define ROM_PORT(req, ack, cnt, lat) \
        if (!req) begin cnt <= 0; ack <= 1'b0; end \
        else if (ack) begin ack <= 1'b0; cnt <= 0; end \
        else if (cnt >= lat) begin ack <= 1'b1; cnt <= 0; end \
        else begin cnt <= cnt + 1; ack <= 1'b0; end

    always_ff @(posedge clk) begin
        if (vram_we) vram[vram_waddr] <= vram_wdata;
        if (trom_we) trom[trom_waddr] <= trom_wdata;
        if (mrom_we) mrom[mrom_waddr] <= mrom_wdata;
        if (crom_we) crom[crom_waddr] <= crom_wdata;
        if (sram_we) sram[sram_waddr] <= sram_wdata;
        if (li_we)   lineram[li_waddr] <= li_wdata;
        li_q    <= lineram[li_addr];
        if (srom_we) srom[srom_waddr] <= srom_wdata;
        if (pal_we)  pal[pal_waddr]   <= pal_wdata;
        if (tab_we && !tab_sel) zoomtab[tab_waddr[9:0]] <= tab_wdata;
        if (tab_we &&  tab_sel) reciptab[tab_waddr]     <= tab_wdata;
        vram_q  <= vram[vram_addr];      `ROM_PORT(vram_req, vram_ack, cnt_vram, lat_vram)
        trom_q  <= trom[trom_addr];      `ROM_PORT(trom_req, trom_ack, cnt_trom, lat_trom)
        mrom_q  <= mrom[mrom_addr[19:1]]; `ROM_PORT(mrom_req, mrom_ack, cnt_mrom, lat_mrom)
        sram_q  <= sram[sram_addr];
        srom_q  <= srom[srom_addr];      `ROM_PORT(srom_req, srom_ack, cnt_srom, lat_srom)
        zoom_q  <= zoomtab[zoom_addr];
        recip_q <= reciptab[recip_addr];
        pal_q   <= pal[pal_addr];
    end

    // ------------------------------------------------------------ renderers
    logic tm_busy, roz_busy, dr_busy, tm_unsup, roz_unsup;
    logic [10:0] tm_pen [4]; logic [3:0] tm_opq;
    logic [10:0] roz_pen;    logic roz_opq;
    logic spr_opq, spr_shadow; logic [10:0] spr_pen; logic [7:0] spr_pri, spr_shpri; logic [1:0] spr_shtab, spr_mix;
    logic  [9:0] list_idx, list_count; logic [31:0] list_q; logic overflow;
    logic [31:0] dbg0, dbg1, dbg2, dbg3;
    logic  [3:1] mix_zero, mix_full;

    logic spr_late;
    assign busy = tm_busy | roz_busy | spr_late;
    assign busy_src = {tm_busy, roz_busy, spr_late};
    assign unsupported = tm_unsup | roz_unsup | overflow;

    k056832_tilemap u_tm (
        .clk(clk), .reset(reset), .line_start(line_start), .line(line), .busy(tm_busy),
        .regs(k56regs), .colorbase(tm_colorbase),
        .vram_req(vram_req), .vram_addr(vram_addr), .vram_ack(vram_ack), .vram_q(vram_q),
        .rom_req(trom_req), .rom_addr(trom_addr), .rom_ack(trom_ack), .rom_q(trom_q),
        .px(px), .pix(tm_pen), .opaque(tm_opq), .unsupported(tm_unsup)
    );
    k053936_roz u_roz (
        .clk(clk), .reset(reset), .prestart(prestart), .line_start(line_start), .line(line), .busy(roz_busy), .lead(roz_lead),
        .ctrl(rozctrl), .li_addr(li_addr), .li_q(li_q), .clip(rozclip), .roz_enable(roz_enable), .palbase(roz_palbase),
        .map_req(mrom_req), .map_addr(mrom_addr), .map_ack(mrom_ack), .map_q(mrom_q),
        .blk_req(blk_req), .blk_addr(blk_addr), .blk_wr(blk_wr), .blk_idx(blk_idx), .blk_data(blk_data), .blk_ack(blk_ack),
        .px(px), .pix(roz_pen), .opaque(roz_opq), .unsupported(roz_unsup)
    );
    logic  [9:0] ol_zoom_addr, dr_zoom_addr;
    logic  [7:0] yr_addr; logic [21:0] yr_q;
    assign zoom_addr = ol_busy ? ol_zoom_addr : dr_zoom_addr;
    k053247_objlist u_ol (
        .clk(clk), .reset(reset), .start(build), .done(build_done), .busy(ol_busy),
        .opset(opset), .objset1(objset1), .shadowon(shadowon), .shdpri(shdpri),
        .nozcode(1'b1), .mix_zero(mix_zero), .mix_full(mix_full), .k46_offy(k46offy),
        .zoom_addr(ol_zoom_addr), .zoom_q(zoom_q), .yr_addr(yr_addr), .yr_q(yr_q),
        .ram_addr(ol_sram_addr), .ram_q(sram_q),
        .list_idx(list_idx), .list_q(list_q), .count(list_count), .overflow(overflow)
    );
    assign dbg_dr_st = u_dr.st;
    // the sprite row cache between the drawer and the ROM port (+NOCACHE=1 bypasses it)
    logic        dr_rom_req, dr_rom_ack, cc_req, cc_ack; logic [19:0] dr_rom_addr, cc_addr; logic [79:0] dr_rom_q, cc_q;
    int          nocache;
    initial if (!$value$plusargs("NOCACHE=%d", nocache)) nocache = 0;
    logic [31:0] hits, misses;
    spr_rowcache u_rc (
        .clk(clk), .reset(reset),
        .c_req(dr_rom_req), .c_addr(dr_rom_addr), .c_ack(cc_ack), .c_q(cc_q),
        .m_req(cc_req), .m_addr(cc_addr), .m_ack(srom_ack), .m_q(srom_q),
        .dbg_hits(hits), .dbg_misses(misses)
    );
    assign srom_req    = nocache ? dr_rom_req  : cc_req;
    assign srom_addr   = nocache ? dr_rom_addr : cc_addr;
    assign dr_rom_ack  = nocache ? srom_ack    : cc_ack;
    assign dr_rom_q    = nocache ? srom_q      : cc_q;
    assign cache_hits  = hits;
    // +ADDRLOG=<file>: every sprite row the drawer is given, with the line it was fetched for
    integer alog; string alog_name;
    initial begin
        alog = 0;
        if ($value$plusargs("ADDRLOG=%s", alog_name)) alog = $fopen(alog_name, "w");
    end
    always_ff @(posedge clk) if (alog != 0 && dr_rom_ack && dr_rom_req) $fwrite(alog, "%0d %0h\n", u_sched.line, dr_rom_addr);
    assign cache_misses = misses;
    logic        dr_ls, dr_abort, spr_rd_ok, dr_clearing;
    logic  [8:0] dr_line;
    spr_sched #(.SB(SPR_SB)) u_sched (
        .clk(clk), .reset(reset), .vcount(vcount), .hcount(hcount_i), .dr_clearing(dr_clearing), .list_rebuild(build), .list_done(build_done), .dr_busy(dr_busy),
        .line_start(dr_ls), .line(dr_line), .abort(dr_abort), .late(spr_late), .rd_ok(spr_rd_ok), .done_line(spr_done_line)
    );
    k053247_draw #(.SB(SPR_SB)) u_dr (
        .clk(clk), .reset(reset), .line_start(dr_ls), .line(dr_line), .abort(dr_abort), .busy(dr_busy), .clearing(dr_clearing),
        .rd_slot(vcount[SPR_SB-1:0]), .rd_ok(spr_rd_ok),
        .k46r5(objset1), .k46_offx(k46offx), .k46_offy(k46offy), .opset(opset), .colorbase(spr_colorbase),
        .list_idx(list_idx), .list_q(list_q), .list_count(list_count), .yr_addr(yr_addr), .yr_q(yr_q),
        .ram_addr(dr_sram_addr), .ram_q(sram_q),
        .rom_req(dr_rom_req), .rom_addr(dr_rom_addr), .rom_ack(dr_rom_ack), .rom_q(dr_rom_q),
        .zoom_addr(dr_zoom_addr), .zoom_q(zoom_q), .recip_addr(recip_addr), .recip_q(recip_q),
        .px(px), .out_opaque(spr_opq), .out_pen(spr_pen), .out_pri(spr_pri), .out_mix(spr_mix),
        .out_shadow(spr_shadow), .out_shtab(spr_shtab), .out_shpri(spr_shpri),
        .shadow_overlap(shadow_overlap),
        .dbg_objs(dbg0), .dbg_rows(dbg1), .dbg_cols(dbg2), .dbg_pxw(dbg3)
    );
    mm_mixer u_mx (
        .clk(clk), .reset(reset), .cen_pix(cen_pix),
        .tm_pen(tm_pen), .tm_opq(tm_opq & {4{px_valid}}), .roz_pen(roz_pen), .roz_opq(roz_opq & px_valid),
        .spr_opq(spr_opq & px_valid), .spr_pen(spr_pen), .spr_pri(spr_pri), .spr_mix(spr_mix),
        .spr_shadow(spr_shadow & px_valid), .spr_shtab(spr_shtab), .spr_shpri(spr_shpri),
        .k55regs(k55regs), .k38regs(k38regs), .roz_enable(roz_enable),
        .pal_addr(pal_addr), .pal_q(pal_q), .rgb(rgb),
        .mix_zero(mix_zero), .mix_full(mix_full)
    );
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = ^{dbg0, dbg1, dbg2, dbg3, list_idx};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
