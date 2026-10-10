//------------------------------------------------------------------------------
// K055555 priority encoder + K054338 colour stage for Monster Maulers.
//
// The Gaiapolis core's mixer picked the nearest opaque input and darkened it;
// this game also blends (tile layers, the rotating plane and sprites carry K054338
// mix codes), fades with the K054338's brightness registers and mixes shadows
// among them, so the pixel is built the way konamigx_mixer paints a frame: the
// inputs in descending priority, each drawn over what the ones behind it left,
// starting from the K054338 backdrop colour.
//
//   A B C D tile layers, SUB1 the rotating plane, OBJ the sprite pixel the
//   rasterizer left (with its mix code), SHD a sprite shadow flag.
//
//   * Order. Higher K055555 priority value = further back = drawn first. On a tie
//     the sprite is drawn first, then its shadow, then SUB1, D, C, B, A (so A is on
//     top): the rules the Gaiapolis mixer was checked against, with a sprite losing
//     a tie to a layer.
//   * Blend (alpha_blend_r32): d' = (s * a + d * (256 - a)) >> 8 per component, the
//     level from the K054338's registers 13/14 by mix code, inverted (the 5-bit
//     register value 0x1f is invisible) and expanded to 8 bits. Additive sprites:
//     d' = min(255, d + (s * a >> 8)). A tile layer takes its mix code from the
//     K055555's V_INMIX / V_INMIX_ON (a layer's two-bit field), the plane from
//     OSBLEND_ENABLES bits 3:2, a sprite from its attribute. Level 255 is solid.
//   * Brightness (palette contrast): a colour is scaled by bri / 255 (truncated).
//     konamigx_mixer sets it as each tile layer is drawn, from the layer's V_BRI
//     field and K054338 registers 11/12, and the plane and the sprites are drawn
//     with whatever the last tile layer left (for the first of them, the last
//     layer of the frame before).
//   * Shadow: the pixel's colour as RGB15 expanded, plus the K054338's signed
//     delta for the shadow table (-80 for table 3), clamped unless CLIPSL.
//
// One pixel is 16 clocks. `phase` is 0 in the first clock the new pixel's inputs
// are visible; they are latched at the end of phase 1, the seven slots ranked in
// phase 2, then one a clock (phases 3-9) go through palette -> c * brightness ->
// the divide by 255 -> source * level -> painter's step, the last landing at the
// end of phase 14, so `rgb` (the backdrop select in front of it) is stable in
// the clock cen_pix is high.
//------------------------------------------------------------------------------
`default_nettype none

module mm_mixer (
    input  logic        clk,
    input  logic        reset,
    input  logic        cen_pix,        // the pixel tick the phases count from

    // per-pixel inputs, all valid together
    input  logic [10:0] tm_pen [4],     // palette entries
    input  logic  [3:0] tm_opq,
    input  logic [10:0] roz_pen,
    input  logic        roz_opq,
    input  logic        spr_opq,
    input  logic [10:0] spr_pen,
    input  logic  [7:0] spr_pri,
    input  logic  [1:0] spr_mix,
    input  logic        spr_shadow,
    input  logic  [1:0] spr_shtab,
    input  logic  [7:0] spr_shpri,

    // chip registers
    input  logic  [7:0] k55regs [48],
    input  logic [15:0] k38regs [16],
    input  logic        roz_enable,

    // palette: 2048 x xRGB888, registered read
    output logic [10:0] pal_addr,
    input  logic [23:0] pal_q,

    output logic [23:0] rgb,

    // the K054338 alpha levels, for the sprite list builder (mix codes 1-3)
    output logic  [3:1] mix_zero,       // level 0 and not additive: the sprite is not drawn
    output logic  [3:1] mix_full        // level 255: drawn solid
);
    // ------------------------------------------------------- the K054338's levels
    logic [7:0] lvl  [4];               // expanded alpha level by mix code (index 0 unused)
    logic       addm [4];
    wire        mixpri = k38regs[15][1];
    wire  [7:0] mb [4];
    assign mb[0] = 8'd0;
    assign mb[1] = k38regs[13][7:0];
    assign mb[2] = k38regs[14][15:8];
    assign mb[3] = k38regs[14][7:0];
    always_comb begin
        for (int m = 0; m < 4; m++) begin
            lvl[m]  = {~mb[m][4:0], ~mb[m][4:2]};         // (0x1f - v) << 3 | (0x1f - v) >> 2
            addm[m] = mb[m][5];
        end
        mix_zero = '0; mix_full = '0;
        for (int m = 1; m < 4; m++) begin
            mix_zero[m] = (lvl[m] == 8'd0)  && !addm[m] && !mixpri;
            mix_full[m] = (lvl[m] == 8'hff) && !addm[m] && !mixpri;
        end
    end
    wire [3:0] mfull4 = {mix_full, 1'b0};

    // ----------------------------------------------------------- the registers
    wire [7:0] enables = k55regs[45];
    wire [7:0] pri_lyr [5];
    assign pri_lyr[0] = k55regs[7];      // A
    assign pri_lyr[1] = k55regs[10];     // B
    assign pri_lyr[2] = k55regs[13];     // C
    assign pri_lyr[3] = k55regs[14];     // D
    assign pri_lyr[4] = k55regs[16];     // SUB1
    wire [7:0] vinmix = k55regs[33], vmixon = k55regs[34], osinmix = k55regs[35], vbri = k55regs[42];
    wire       backdrop_only = (enables == 8'd0) || !k38regs[15][0];     // no inputs, or K338_CTL_KILL
    wire [23:0] backdrop = {k38regs[0][7:0], k38regs[1]};
    wire        noclip   = k38regs[15][5];

    // tile layers: mix code (V_INMIX & V_INMIX_ON per layer), the blend level it asks for,
    // and the brightness at the moment the layer is drawn
    logic       l_solid [4];            // draw without blending
    logic [7:0] l_alpha [4];
    logic [7:0] l_bri   [4];
    always_comb begin
        logic [1:0] mc, bm;
        logic [7:0] a8;
        for (int l = 0; l < 4; l++) begin
            mc = vinmix[2*l +: 2] & vmixon[2*l +: 2];
            a8 = lvl[mc];
            if (addm[mc]) a8 = (lvl[mc] != 8'd0) ? ~lvl[mc] : 8'd0;      // the additive hack: inverted, blended
            l_solid[l] = (mc == 2'd0) || (a8 == 8'hff);
            l_alpha[l] = a8;
            bm = vbri[2*l +: 2];
            l_bri[l] = (bm == 2'd0) ? 8'hff : (bm == 2'd1) ? k38regs[11][7:0]
                     : (bm == 2'd2) ? k38regs[12][15:8] : k38regs[12][7:0];
        end
    end
    // the plane: OSBLEND_ENABLES bits 3:2 as its mix code, unless the register is 0xff
    wire  [1:0] roz_mc    = osinmix[3:2];
    wire        roz_mix   = (osinmix != 8'hff) && (roz_mc != 2'd0);
    wire  [7:0] roz_a8    = lvl[roz_mc];
    wire        roz_hide  = roz_mix && (roz_a8 == 8'd0);
    wire        roz_solid = !roz_mix || (roz_a8 == 8'hff);

    // ---------------------------------------------------- the pixel's phase
    logic [3:0] phase;
    always_ff @(posedge clk) phase <= cen_pix ? 4'd0 : phase + 4'd1;

    // ------------------------------------------- latched inputs, the seven slots
    // 0..3 A..D, 4 SUB1, 5 OBJ, 6 SHD
    logic        v_q    [7];            // the slot is drawn this pixel
    logic  [7:0] key_q  [7];
    logic [10:0] ent_q  [7];
    logic  [1:0] kind_q [7];            // 0 solid, 1 blend, 2 additive, 3 shadow
    logic  [7:0] alp_q  [7];
    logic  [1:0] stab_q;
    logic  [7:0] bri_q  [4];
    logic  [3:0] ben_q;                 // the tile layers that are enabled (they set the brightness)
    logic        bd_q;
    logic [23:0] bdc_q;
    logic        nc_q;

    always_ff @(posedge clk) if (phase == 4'd1) begin
        for (int l = 0; l < 4; l++) begin
            v_q[l]    <= tm_opq[l] && enables[l];
            key_q[l]  <= pri_lyr[l];
            ent_q[l]  <= tm_pen[l];
            kind_q[l] <= l_solid[l] ? 2'd0 : 2'd1;
            alp_q[l]  <= l_alpha[l];
            bri_q[l]  <= l_bri[l];
        end
        ben_q     <= enables[3:0];
        v_q[4]    <= roz_opq && roz_enable && enables[5] && !roz_hide;
        key_q[4]  <= pri_lyr[4];
        ent_q[4]  <= roz_pen;
        kind_q[4] <= roz_solid ? 2'd0 : 2'd1;
        alp_q[4]  <= roz_a8;
        v_q[5]    <= spr_opq && enables[4];
        key_q[5]  <= spr_pri;
        ent_q[5]  <= spr_pen;
        // a sprite's mix code: 0 or a full level draws solid, an additive level adds
        kind_q[5] <= (spr_mix == 2'd0 || mfull4[spr_mix]) ? 2'd0 : addm[spr_mix] ? 2'd2 : 2'd1;
        alp_q[5]  <= lvl[spr_mix];
        v_q[6]    <= spr_shadow && enables[4];
        key_q[6]  <= spr_shpri;
        ent_q[6]  <= '0;
        kind_q[6] <= 2'd3;
        alp_q[6]  <= '0;
        stab_q    <= spr_shtab;
        bd_q      <= backdrop_only;
        bdc_q     <= backdrop;
        nc_q      <= noclip;
    end

    // ----------------------------------------------------------- the ranking
    // slot j is drawn before slot i when its key is larger, or equal with the tie
    // order (earlier = drawn first): OBJ, SHD, SUB1, D, C, B, A
    localparam int TIE [7] = '{6, 5, 4, 3, 2, 0, 1};      // by slot: A B C D SUB1 OBJ SHD
    logic [2:0] rank [7];
    always_ff @(posedge clk) if (phase == 4'd2) begin
        for (int i = 0; i < 7; i++) begin
            logic [2:0] r;
            r = 3'd0;
            for (int j = 0; j < 7; j++)
                if (j != i && (key_q[j] > key_q[i] || (key_q[j] == key_q[i] && TIE[j] < TIE[i])))
                    r = r + 3'd1;
            rank[i] <= r;
        end
    end

    // the brightness a pixel starts from: the last enabled tile layer in drawing order
    logic [7:0] bri_init;
    always_comb begin
        logic [2:0] best;
        logic       any;
        best = 3'd0; any = 1'b0; bri_init = 8'hff;
        for (int l = 0; l < 4; l++)
            if (ben_q[l] && (!any || rank[l] > best)) begin any = 1'b1; best = rank[l]; bri_init = bri_q[l]; end
    end

    // -------------------------------------------------------- the sequence
    // clock 3+k selects the slot of rank k; palette read, brightness, source * level
    // and the painter's step follow, one stage a clock
    logic  [7:0] cur_bri;
    wire   [7:0] cur_eff = (phase == 4'd3) ? bri_init : cur_bri;
    wire   [2:0] step    = 3'(phase - 4'd3);
    wire         running = (phase >= 4'd3) && (phase <= 4'd9);

    logic        sel_v;
    logic [10:0] sel_e;
    logic  [1:0] sel_kind;
    logic  [7:0] sel_alp, sel_bri;
    always_comb begin
        sel_v = 1'b0; sel_e = '0; sel_kind = 2'd0; sel_alp = '0; sel_bri = cur_eff;
        for (int i = 0; i < 7; i++)
            if (rank[i] == step) begin
                sel_v    = v_q[i];
                sel_e    = ent_q[i];
                sel_kind = kind_q[i];
                sel_alp  = alp_q[i];
            end
        for (int i = 0; i < 4; i++)
            if (rank[i] == step && ben_q[i]) sel_bri = bri_q[i];    // a tile layer sets the brightness
    end

    logic        s1_v, s2_v, s3_v, s4_v;
    logic  [1:0] s1_kind, s2_kind, s3_kind, s4_kind;
    logic  [7:0] s1_alp, s2_alp, s3_alp, s4_alp;
    logic  [7:0] s1_bri, s2_bri;
    logic        s1_first, s2_first, s3_first, s4_first;
    logic  [1:0] s1_stab, s2_stab, s3_stab, s4_stab;

    always_ff @(posedge clk) begin
        s1_v <= 1'b0; s1_first <= 1'b0;
        if (running) begin
            cur_bri  <= sel_bri;
            s1_v     <= sel_v;
            s1_kind  <= sel_kind;
            s1_alp   <= sel_alp;
            s1_bri   <= sel_bri;
            s1_stab  <= stab_q;
            s1_first <= (phase == 4'd3);
            pal_addr <= sel_e;
        end
        // t+1: the palette read; t+2: its data, scaled
        s2_v <= s1_v; s2_kind <= s1_kind; s2_alp <= s1_alp; s2_bri <= s1_bri; s2_first <= s1_first; s2_stab <= s1_stab;
    end

    // t+2: x = c * bri. t+3: c' = floor(c * bri / 255) = (x + (x >> 8) + 1) >> 8
    logic [15:0] x_r, x_g, x_b;
    logic        sx_v, sx_first;
    logic  [1:0] sx_kind, sx_stab;
    logic  [7:0] sx_alp;
    always_ff @(posedge clk) begin
        x_r <= pal_q[23:16] * s2_bri;
        x_g <= pal_q[15:8]  * s2_bri;
        x_b <= pal_q[7:0]   * s2_bri;
        sx_v <= s2_v; sx_kind <= s2_kind; sx_alp <= s2_alp; sx_first <= s2_first; sx_stab <= s2_stab;
    end
    function automatic logic [7:0] fin255(input logic [15:0] x);
        logic [16:0] y;
        y = {1'b0, x} + {9'd0, x[15:8]} + 17'd1;
        return y[15:8];
    endfunction
    logic [7:0] sc_r, sc_g, sc_b;
    always_ff @(posedge clk) begin
        sc_r <= fin255(x_r);
        sc_g <= fin255(x_g);
        sc_b <= fin255(x_b);
        s3_v <= sx_v; s3_kind <= sx_kind; s3_alp <= sx_alp; s3_first <= sx_first; s3_stab <= sx_stab;
    end

    // t+4: source * level, a stage ahead of the painter's step (which then has the
    // one multiply it cannot avoid, d * (256 - a))
    logic [15:0] sa_r, sa_g, sa_b;
    logic  [7:0] cs_r, cs_g, cs_b;
    logic  [8:0] s4_ia;                  // 256 - level
    always_ff @(posedge clk) begin
        sa_r <= sc_r * s3_alp; sa_g <= sc_g * s3_alp; sa_b <= sc_b * s3_alp;
        cs_r <= sc_r; cs_g <= sc_g; cs_b <= sc_b;
        s4_v <= s3_v; s4_kind <= s3_kind; s4_alp <= s3_alp; s4_first <= s3_first; s4_stab <= s3_stab;
        s4_ia <= 9'd256 - {1'b0, s3_alp};
    end

    // t+5: the painter's step. dst starts as the backdrop at the first slot.
    function automatic logic signed [9:0] shd_delta(input logic [15:0] r);
        return r[8] ? $signed({1'b1, r[8:0]}) : $signed({1'b0, r[8:0]});      // 9-bit two's complement
    endfunction
    function automatic logic [7:0] pal5(input logic [4:0] v);
        return {v, v[4:2]};
    endfunction
    function automatic logic [7:0] clampd(input logic signed [9:0] v, input logic nc);
        if (nc) return v[7:0];
        return (v < 0) ? 8'd0 : (v > 10'sd255 ? 8'd255 : v[7:0]);
    endfunction
    logic [23:0] dst;
    logic signed [9:0] dr, dg, db;
    always_comb begin
        case (s4_stab)
            2'd3: begin dr = -10'sd80; dg = -10'sd80; db = -10'sd80; end
            default: begin
                dr = shd_delta(k38regs[2 + {2'd0, s4_stab} * 3]);
                dg = shd_delta(k38regs[3 + {2'd0, s4_stab} * 3]);
                db = shd_delta(k38regs[4 + {2'd0, s4_stab} * 3]);
            end
        endcase
    end
    wire [23:0] base = s4_first ? bdc_q : dst;               // the first slot starts from the backdrop
    wire [8:0]  ia   = s4_ia;
    function automatic logic [7:0] blend(input logic [7:0] d, input logic [15:0] sa, input logic [8:0] ia9);
        logic [16:0] t;
        t = {1'b0, sa} + (d * ia9);
        return t[15:8];                                        // (s * a + d * (256 - a)) >> 8
    endfunction
    function automatic logic [7:0] addsat(input logic [7:0] d, input logic [15:0] sa);
        logic [8:0] t;
        t = {1'b0, d} + {1'b0, sa[15:8]};
        return t[8] ? 8'hff : t[7:0];
    endfunction
    always_ff @(posedge clk) begin
        if (s4_first) dst <= bdc_q;                          // an undrawn first slot leaves the backdrop
        if (s4_v) begin
            case (s4_kind)
                2'd0: dst <= {cs_r, cs_g, cs_b};
                2'd1: dst <= {blend(base[23:16], sa_r, ia), blend(base[15:8], sa_g, ia), blend(base[7:0], sa_b, ia)};
                2'd2: dst <= {addsat(base[23:16], sa_r), addsat(base[15:8], sa_g), addsat(base[7:0], sa_b)};
                default: begin
                    dst <= {clampd($signed({2'd0, pal5(base[23:19])}) + dr, nc_q),
                            clampd($signed({2'd0, pal5(base[15:11])}) + dg, nc_q),
                            clampd($signed({2'd0, pal5(base[7:3])})   + db, nc_q)};
                end
            endcase
        end
    end
    assign rgb = bd_q ? bdc_q : dst;

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = ^{k38regs[0][15:8], reset, s4_alp};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
