//------------------------------------------------------------------------------
// K053936-class PSAC2 rotate/zoom plane for Monster Maulers.
//
// Derived from the Gaiapolis core's plane. A 512x512 grid of 16x16 tiles -- an
// 8192x8192 virtual plane -- sampled through an affine transform. The tile map
// lives in ROM (gfx4) rather than RAM, two bytes per tile (get_ult_936_tile_info:
// tile number = dat2 | (dat1 & 0x1f) << 8, flip x = dat1 bit 6); the characters
// are 8bpp, one byte a pixel, in gfx3, and the whole plane takes one palette
// group of 256, the K055555's SUB1 base. See docs/hardware.md section 5.
//
// Both modes of K053936GP_zoom_draw are implemented: "simple" (ctrl[7] bit 6
// clear: one affine transform for the frame) and "super" (bit 6 set: a start and
// an x step per line from the 4 KB line RAM, as the stage backgrounds that
// wobble use). MAME draws the transform of raster row N-1 at row N and never
// writes the first row (its blitter advances its destination row before the
// loop body); MAME_SHIFT=1 does the same, which is what the frame bench's
// pixel-for-pixel comparison against MAME's snapshots needs.
//
// Memory strategy. A raster line walks a straight path across the plane; at
// this game's transforms (zoom 0.5-2.7, any angle: the character-select water
// rotates) it crosses 25-90 tiles, and the next line, one source pixel over,
// crosses nearly the same ones. So the unit of fetch is a whole tile -- its
// 64 words in one burst from the platform's memory, stored column-major at
// load time -- into a 128-entry fully associative cache with round-robin
// replacement. Hits need no map read either: the entry keeps the tile's
// colour bits. What remains bursty is the line on which the walk moves to a
// new tile row and every tile changes at once (9,000+ clocks at zoom 1.9);
// the renderer therefore keeps 8 line buffers and runs up to 7 lines ahead
// of the display, so such a line borrows from its cheap neighbours (the
// average is 1,400-3,200 clocks a line). the Pocket repository's tools/roz_fetches.py models the
// walk; the frame bench measures the lead actually used.
//
// Deliberate divergence from MAME: K053936GP_copyroz32clip advances its
// destination row before the loop body, so MAME paints raster row N with the
// transform for row N-1 and never writes the first visible row. That reads as
// a porting artefact rather than silicon behaviour, so this module does not
// copy it; the Pocket repository's sim/run_roz.sh compares against the model with the resulting
// one-line offset applied. docs/hardware.md section 10.
//------------------------------------------------------------------------------
`default_nettype none

module k053936_roz #(
    parameter int VIS_W  = 288,
    parameter int VIS_H  = 224,
    parameter int VIS_X0 = 24,
    parameter int VIS_Y0 = 17,
    parameter int LB_AW  = 9,
    // K053936GP_set_offset(0, -8, 0) for dadandrn (a laser attack's offset)
    parameter int OFFS_X = -8,
    parameter int OFFS_Y = 0,
    parameter int NENT   = 64,          // cached tiles (a tile is 128 words)
    parameter bit MAME_SHIFT = 1'b1     // draw row N with the transform of row N-1, row 0 blank (as MAME does)
) (
    input  logic        clk,
    input  logic        reset,

    // Pacing from mm_video. prestart pulses a few raster lines before the
    // visible area and begins the frame's rendering; line_start pulses at the
    // start of raster line r with line = r+1, the line the display shows
    // next. busy: that line is not rendered yet (sampled at the next pulse
    // for the overrun count). The renderer runs ahead of the display by up
    // to NBANK-1 lines and never writes the buffer being displayed; if it is
    // ever behind at a pulse, the line in progress is abandoned, as before.
    input  logic        prestart,
    input  logic        line_start,
    input  logic  [8:0] line,
    output logic        busy,
    output logic  [3:0] lead,           // lines rendered beyond the one due, saturating (benches)

    input  logic [15:0] ctrl [16],      // 0x460000 control block (only 0-7 used)
    // line RAM (0x470000, 2048 words: 4 per raster line), registered read
    output logic [10:0] li_addr,
    input  logic [15:0] li_q,
    input  logic [15:0] clip [2],       // 0x484000 clip window
    input  logic        roz_enable,     // 0x6c0000 bit 8
    // K055555 SUB1 palette base: the 8bpp group, colour % 8
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic  [7:0] palbase,
    /* verilator lint_on UNUSEDSIGNAL */

    // tile map ROM (gfx4). Byte address; map_q is the containing 16-bit word.
    output logic        map_req,
    output logic [19:0] map_addr,
    input  logic        map_ack,
    input  logic [15:0] map_q,

    // character ROM (gfx3): a level request for tile blk_addr, its 128 words
    // streamed back with blk_wr/blk_idx/blk_data (idx = {word column, row},
    // the load-time layout: a word is two pixels), then blk_ack for a request
    // still standing with the same address
    output logic        blk_req,
    output logic [15:0] blk_addr,
    input  logic        blk_wr,
    input  logic  [6:0] blk_idx,
    input  logic [15:0] blk_data,
    input  logic        blk_ack,

    input  logic [LB_AW-1:0] px,
    output logic [10:0] pix,            // palette entry
    output logic        opaque,

    output logic        unsupported
);
    // ------------------------------------------------------------- transform
    function automatic logic signed [31:0] sx16(input logic [15:0] v);
        return {{16{v[15]}}, v};
    endfunction

    logic signed [31:0] incxx, incxy, incyx, incyy;
    logic        [31:0] sinc_x, sinc_y;         // this line's per-pixel steps (global in simple mode, from the line RAM in super mode)
    logic        [31:0] startx, starty;      // 16.16, wraps as uint32 like MAME

    // --------------------------------------------------------- line buffers
    // 8 banks of 384 (a bank's base is bank*384: two shifted adds); a pixel
    // is {colour[2:0], pen[7:0]}, and pen 0 is transparent, so no opaque bit is kept
    localparam int NBANK = 8, LB_STRIDE = 384;
    function automatic logic [11:0] bank_base(input logic [2:0] b);
        return {1'b0, b, 8'd0} + {2'b0, b, 7'd0};
    endfunction
    logic [10:0] lbuf [NBANK*LB_STRIDE];
    logic [10:0] rd;
    logic [11:0] rd_base, wa;
    always_ff @(posedge clk) rd <= lbuf[rd_base + 12'(px)];
    assign pix    = rd;
    assign opaque = |rd[7:0];

    // ------------------------------------------------------- frame pacing
    logic signed [9:0] disp;            // the line the display shows now (-1 before the first)
    logic        [8:0] need, rline;     // the line due at the next pulse; the next line to render
    logic              need_v;
    wire signed  [9:0] disp_new = $signed({1'b0, line}) - $signed(10'(VIS_Y0 + 1));
    wire               behind   = line_start && ($signed({1'b0, rline}) <= disp_new);
    wire               abandon  = prestart || behind;
    assign busy = need_v && (need < 9'(VIS_H)) && (rline <= need);
    wire [9:0] lead_w = {1'b0, rline} - {1'b0, need};
    assign lead = lead_w[9] ? 4'd0 : (lead_w > 10'd15) ? 4'd15 : lead_w[3:0];

    // ------------------------------------------------------------- clipping
    wire        clip_en = clip[1][8];
    wire        roz_on  = roz_enable && !blank_line;
    wire [ 5:0] clip_x  = clip[0][5:0];
    wire [ 5:0] clip_y  = clip[0][11:6];
    wire [ 1:0] csx     = clip[0][13:12];
    wire [ 1:0] csy     = clip[0][15:14];
    function automatic logic [2:0] clipsize(input logic [1:0] v);
        case (v) 2'd3: return 3'd1; 2'd2: return 3'd2; default: return 3'd4; endcase
    endfunction
    wire [12:0] minx = {clip_x, 7'd0};
    wire  [5:0] clip_ex = clip_x + {3'd0, clipsize(csx)};
    wire [12:0] maxx = {clip_ex, 7'd0} - 13'd1;
    wire [12:0] miny = {clip_y, 7'd0};
    wire  [5:0] clip_ey = clip_y + {3'd0, clipsize(csy)};
    wire [12:0] maxy = {clip_ey, 7'd0} - 13'd1;

    // ------------------------------------------------------------ tile cache
    // tags, valid and flip bits are registers (every entry is compared each
    // clock); the tile data is a RAM addressed by the hit entry
    localparam int EW = $clog2(NENT);
    logic [31:0] cx, cy;
    logic [12:0] srcx, srcy;
    wire  [17:0] ti_now = {cy[28:20], cx[28:20]};     // {row, column} of the tile on the plane

    logic [17:0]     tag   [NENT];
    logic [NENT-1:0] valid, match, flip;
    logic [15:0]     tmem  [NENT*128];
    logic [EW-1:0]   fifo_ptr, fill_ent;
    logic [15:0]     tmem_rd;
    logic  [7:0]     d1, d2;
    logic [17:0]     ti;

    function automatic logic [EW-1:0] enc(input logic [NENT-1:0] m);
        logic [EW-1:0] r;
        r = '0;
        for (int i = 0; i < NENT; i++) if (m[i]) r = r | EW'(i);
        return r;
    endfunction
    wire [EW-1:0] ent_now  = enc(match);
    wire          flip_now = |(match & flip);
    wire    [3:0] xs       = srcx[3:0] ^ {4{flip_now}};      // the pixel's column in the (flipped) tile

    always_ff @(posedge clk)
        for (int i = 0; i < NENT; i++) match[i] <= valid[i] && (tag[i] == ti_now);

    typedef enum logic [4:0] {
        R_IDLE, R_SETUP, R_SETUP2, R_PIX0, R_PIX, R_LOOK, R_CHK,
        R_M1W, R_M2, R_M2W, R_FILL, R_FILLW,
        R_LIA, R_LIB, R_LIC, R_LID, R_LIE
    } state_t;
    state_t st;

    always_ff @(posedge clk) begin
        if (blk_wr) tmem[{fill_ent, blk_idx}] <= blk_data;
        tmem_rd <= tmem[{ent_now, xs[3:1], srcy[3:0]}];
    end

    // ------------------------------------------------------------------ FSM
    logic [LB_AW-1:0] cur_x;
    logic        hit, clipped;
    // the line being drawn and, in super mode, its line RAM entry
    logic        blank_line, super_l;
    logic  [8:0] lrow;                  // the visible row whose transform this line uses
    logic  [1:0] lk;
    logic [15:0] lw [4];
    logic signed [31:0] lsx, lsy, lix, liy;
    wire signed [15:0] lw0s = $signed(lw[0] + ctrl[0]);
    wire signed [15:0] lw1s = $signed(lw[1] + ctrl[1]);
    logic        pix_sel;
    logic [31:0] pyx, pyy;

    // a word holds two pixels, the even column's byte first (the high byte)
    wire [7:0] pen = pix_sel ? tmem_rd[7:0] : tmem_rd[15:8];

    always_ff @(posedge clk) begin
        if (reset) begin
            st <= R_IDLE; map_req <= 1'b0; blk_req <= 1'b0; unsupported <= 1'b0; blank_line <= 1'b0; super_l <= 1'b0;
            valid <= '0; flip <= '0; fifo_ptr <= '0;
            rline <= 9'(VIS_H); need <= '0; need_v <= 1'b0; disp <= -10'sd1; rd_base <= '0;
        end else begin
            if (prestart) begin
                rline <= '0; disp <= -10'sd1; need_v <= 1'b0;
            end else if (line_start) begin
                need <= line - 9'(VIS_Y0); need_v <= 1'b1;
                disp <= disp_new; rd_base <= bank_base(disp_new[2:0]);
                if (behind) rline <= line - 9'(VIS_Y0);
            end

            if (abandon) begin
                st <= R_IDLE; map_req <= 1'b0; blk_req <= 1'b0;
            end else case (st)
                R_IDLE: begin
                    if (rline < 9'(VIS_H) && $signed({1'b0, rline}) <= disp + 10'(NBANK - 1)) begin
                        st <= R_SETUP;
                    end
                end

                R_SETUP: begin
                    cur_x <= '0;
                    wa    <= bank_base(rline[2:0]);
                    // MAME draws the transform of row N-1 at row N, and nothing at row 0
                    lrow       <= MAME_SHIFT ? rline - 9'd1 : rline;
                    blank_line <= MAME_SHIFT && (rline == 9'd0);
                    super_l    <= ctrl[7][6];
                    st <= R_SETUP2;
                end
                R_SETUP2: begin
                    if (super_l) begin
                        // line RAM entry (y - offset) & 0x1ff: 4 words from {entry, 2'b00}
                        li_addr <= {9'(VIS_Y0 + lrow - OFFS_Y), 2'b00};
                        lk <= 2'd0;
                        st <= R_LIA;
                    end else begin
                        // startx/starty already fold in the visible-area origin, so
                        // the per-line advance counts visible lines, not raster ones;
                        // the multiply and the add are two cycles (one path was -6.6 ns)
                        pyx <= $unsigned(incyx) * {23'd0, lrow};
                        pyy <= $unsigned(incyy) * {23'd0, lrow};
                        sinc_x <= $unsigned(incxx); sinc_y <= $unsigned(incxy);
                        st <= R_PIX0;
                    end
                end
                // simple mode: the registered sum a clock later
                R_PIX0: begin
                    cx <= startx + pyx;
                    cy <= starty + pyy;
                    st <= R_PIX;
                end

                // super mode: the four words of the line's entry (the RAM is registered)
                R_LIA: st <= R_LIB;
                R_LIB: st <= R_LIC;
                R_LIC: begin
                    lw[lk] <= li_q;
                    if (lk == 2'd3) st <= R_LID;
                    else begin lk <= lk + 2'd1; li_addr <= {li_addr[10:2], lk + 2'd1}; st <= R_LIA; end
                end
                R_LID: begin
                    // startx = (int16)(w0 + ctrl[0]) << 8, incxx = (int16)w2 (<< 8 if ctrl[6] bit 15), likewise y
                    lix <= ctrl[6][15] ? ($signed({{16{lw[2][15]}}, lw[2]}) <<< 8) : $signed({{16{lw[2][15]}}, lw[2]});
                    liy <= ctrl[6][7]  ? ($signed({{16{lw[3][15]}}, lw[3]}) <<< 8) : $signed({{16{lw[3][15]}}, lw[3]});
                    lsx <= {{8{lw0s[15]}}, lw0s, 8'd0};
                    lsy <= {{8{lw1s[15]}}, lw1s, 8'd0};
                    st <= R_LIE;
                end
                R_LIE: begin
                    // start -= OFFS_X * inc; <<5; plus the visible origin's VIS_X0 steps
                    cx <= $unsigned((lsx - OFFS_X * lix) <<< 5) + $unsigned(lix <<< 5) * VIS_X0;
                    cy <= $unsigned((lsy - OFFS_X * liy) <<< 5) + $unsigned(liy <<< 5) * VIS_X0;
                    sinc_x <= $unsigned(lix <<< 5); sinc_y <= $unsigned(liy <<< 5);
                    st <= R_PIX;
                end

                // three clocks a pixel on a hit: the source position, then the
                // tag compare (registered above from cx/cy), then the data
                R_PIX: begin
                    srcx <= cx[28:16];
                    srcy <= cy[28:16];
                    ti   <= ti_now;
                    st   <= R_LOOK;
                end
                R_LOOK: begin
                    hit     <= |match;
                    clipped <= clip_en & ((srcx < minx) | (srcx > maxx)
                                        | (srcy < miny) | (srcy > maxy));
                    pix_sel <= xs[0];
                    st <= R_CHK;
                end
                R_CHK: begin
                    if (roz_on && !hit) begin
                        // dat1 (flip, tile bits 12:8), then dat2 (tile bits 7:0)
                        map_addr <= {2'd0, ti};
                        map_req  <= 1'b1;
                        st <= R_M1W;
                    end else begin
                        lbuf[wa] <= (roz_on && |pen && !clipped) ? {palbase[2:0], pen} : 11'd0;
                        wa <= wa + 12'd1;
                        cx <= cx + sinc_x;
                        cy <= cy + sinc_y;
                        if (cur_x == VIS_W[LB_AW-1:0] - 1) begin
                            st <= R_IDLE; rline <= rline + 9'd1;
                        end else begin
                            cur_x <= cur_x + 1'd1;
                            st <= R_PIX;
                        end
                    end
                end

                // a miss: the tile's two map bytes, then its 128 words into
                // the round-robin victim
                R_M1W: if (map_ack) begin
                    d1 <= map_addr[0] ? map_q[7:0] : map_q[15:8];
                    map_req <= 1'b0;
                    st <= R_M2;
                end
                R_M2: begin
                    map_addr <= 20'h40000 + {2'd0, ti};
                    map_req  <= 1'b1;
                    st <= R_M2W;
                end
                R_M2W: if (map_ack) begin
                    d2 <= map_addr[0] ? map_q[7:0] : map_q[15:8];
                    map_req <= 1'b0;
                    st <= R_FILL;
                end
                R_FILL: begin
                    fill_ent <= fifo_ptr;
                    valid[fifo_ptr] <= 1'b0;
                    blk_addr <= {3'd0, d1[4:0], d2};
                    blk_req  <= 1'b1;
                    st <= R_FILLW;
                end
                R_FILLW: if (blk_ack) begin
                    blk_req <= 1'b0;
                    tag[fill_ent]   <= ti;
                    valid[fill_ent] <= 1'b1;
                    flip[fill_ent]  <= d1[6];
                    fifo_ptr <= (fifo_ptr == EW'(NENT - 1)) ? '0 : fifo_ptr + 1'd1;
                    st <= R_PIX;                       // now a hit
                end
                default: st <= R_IDLE;
            endcase
        end
    end

    // control-register decode, registered in three short stages every cycle
    // so a mid-frame write still takes effect on the next line rendered (up
    // to NBANK-1 lines before it shows), without the shifts, constant
    // multiplies and adds forming one long path
    logic signed [31:0] ixx, ixy, iyx, iyy, sx0, sy0, sx, sy;
    logic        [31:0] pxx, pxy;
    always_ff @(posedge clk) begin
        // stage 1: sign extension and the x256 modes
        ixx <= ctrl[6][6]  ? (sx16(ctrl[4]) <<< 8) : sx16(ctrl[4]);
        ixy <= ctrl[6][6]  ? (sx16(ctrl[5]) <<< 8) : sx16(ctrl[5]);
        iyx <= ctrl[6][14] ? (sx16(ctrl[2]) <<< 8) : sx16(ctrl[2]);
        iyy <= ctrl[6][14] ? (sx16(ctrl[3]) <<< 8) : sx16(ctrl[3]);
        sx0 <= sx16(ctrl[0]) <<< 8;
        sy0 <= sx16(ctrl[1]) <<< 8;
        // stage 2: the layer offsets and the 16.16 increments
        sx <= sx0 - OFFS_Y * iyx - OFFS_X * ixx;
        sy <= sy0 - OFFS_Y * iyy - OFFS_X * ixy;
        incxx <= ixx <<< 5; incxy <= ixy <<< 5;
        incyx <= iyx <<< 5; incyy <= iyy <<< 5;
        pxx <= $unsigned(ixx <<< 5) * VIS_X0; pxy <= $unsigned(ixy <<< 5) * VIS_X0;
        // stage 3: the visible-area origin folded in
        startx <= $unsigned(sx <<< 5) + pxx + $unsigned(incyx) * VIS_Y0;
        starty <= $unsigned(sy <<< 5) + pxy + $unsigned(incyy) * VIS_Y0;
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = ^{d1[7], d1[5], ctrl[8], ctrl[9], ctrl[10], ctrl[11], ctrl[12], ctrl[13], ctrl[14], ctrl[15],
                    palbase[7:3], clip[1][15:9], clip[1][7:0], cx[31:29], cx[15:0], cy[31:29], cy[15:0]};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
