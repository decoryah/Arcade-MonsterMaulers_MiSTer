//------------------------------------------------------------------------------
// Monster Maulers main board: 68000 @ 16 MHz and everything on its bus.
//
// Address decode follows docs/hardware.md section 3 (MAME's dadandrn_map in
// mystwarr.cpp). The CPU is TG68K.C, paced by a token bucket the way the
// S.T.U.N. Runner core paces its 68010 -- STEP_COST_BUS/STEP_COST_INT/STEP_GAIN
// set the step rate; the values are calibrated against MAME's frame timing.
//
// Derived from the Gaiapolis core's main board (plasticbugs' Pocket core, via
// gaiapolis-mister): the same chip set sits on this board. What differs is the
// map (2 MB program, a 16 KB tile ROM window, the K055550 instead of the K054000),
// the ROZ plane's ROM layout (8bpp characters, a two-byte map) and the 5-bit
// graphics: the tile ROM readback has the fifth plane and the K055673's ROM
// window reads the 5bpp layout.
//
// What lives here: work RAM, K056832 tile RAM (all 16 pages, one visible
// through the banked window), palette, sprite RAM through the K053247's
// scattered window, the ROZ control block and line RAM, the K055550's memset
// engine (it masters the 68000's bus, so the CPU is held while it runs), and
// the register files of every video chip, exported to the renderers. Renderers
// read the memories through their own ports.
//
// All five ROM-readback windows are real. The self-test checksums every
// graphics ROM through them. They share the renderers' ROM ports through
// arbiters that give the renderer priority.
//   440000  K056832 mw_rom_word_r: bank regs[0x1a]|regs[0x1b]<<16 (mod 256)
//           selects 2048 five-byte groups; a word is one half of a group, or
//           with regsb[2] bit 3 a spread of the fifth plane's bits.
//   450000  K055673 k055673_5bpp_rom_word_r: u16 view of the sprite ROM at the
//           offset in k053246 regs 6/7/4, and bytes of the fifth plane area.
//------------------------------------------------------------------------------
`default_nettype none

module mm_main #(
    parameter int STEP_COST_BUS = 16, // tokens per kernel step that runs a bus cycle: 4 clocks, as the 68000's
    parameter int STEP_COST_INT = 8,  // tokens per internal step: 2 clocks
    parameter int STEP_GAIN = 4       // tokens per cen_16m: 4 tokens = one 16 MHz clock
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        cen_16m,

    // program ROM, 2 MB
    output logic        rom_req,
    output logic [22:1] rom_addr,
    input  logic        rom_ack,
    input  logic [15:0] rom_q,

    // ROZ ROMs for the readback windows (shared with the renderer's ports)
    output logic        map_req,
    output logic [19:0] map_addr,       // byte address in gfx4; map_q is the containing word
    input  logic        map_ack,
    input  logic [15:0] map_q,
    output logic        chr_req,
    output logic [21:0] chr_addr,       // byte address in gfx3 (bank * 0x100000 + offset)
    input  logic        chr_ack,
    input  logic [15:0] chr_q,          // the word containing it
    // tile ROM (K056832 readback) and sprite ROM (K055673 readback)
    output logic        trom_req,
    output logic [18:0] trom_addr,      // 5-byte group (an 8-pixel row)
    input  logic        trom_ack,
    input  logic [39:0] trom_q,         // {4 chunky bytes, the fifth plane's byte}
    output logic        srom_req,
    output logic [19:0] srom_addr,      // 16-pixel row
    input  logic        srom_ack,
    input  logic [79:0] srom_q,         // {the four low planes' 64 bits, the fifth plane's 16}

    // vblank interrupt (IRQ5, held until acknowledged)
    input  logic        vblank_rise,

    // inputs, active low as the board sees them. in1[1:0] are replaced by the
    // EEPROM's DO and READY lines on the way in (dddeeprom_r).
    input  logic [15:0] in0_p1,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic  [7:0] in1,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic  [7:0] p2,

    // ER5911 serial EEPROM
    output logic        eep_di,
    output logic        eep_cs,
    output logic        eep_clk,
    input  logic        eep_do,
    input  logic        eep_ready,

    // K054321 main side: byte registers at word offsets 0..15
    output logic        snd_wr,
    output logic        snd_rd,
    output logic  [3:0] snd_off,
    output logic  [7:0] snd_wdata,
    input  logic  [7:0] snd_rdata,
    output logic        snd_irq,        // 6E0000 write: Z80 IRQ0

    // video chip register files
    output logic [15:0] k56regs  [32],
    output logic [15:0] k56regsb [4],
    output logic  [7:0] k55regs  [48],
    output logic [15:0] k38regs  [16],
    output logic [15:0] rozctrl  [16],
    output logic [15:0] rozclip  [2],
    output logic        roz_enable,
    output logic  [1:0] roz_rombank,
    output logic  [7:0] k46regs  [8],
    output logic [15:0] k47regs  [8],

    // memories the renderers read
    // tile RAM lives outside; the CPU window's accesses go out as
    // request/ack, writes byte-enabled, and the kernel waits for them
    output logic        vc_req,
    output logic        vc_we,
    output logic [15:0] vc_addr,
    output logic  [1:0] vc_be,
    output logic [15:0] vc_wdata,
    input  logic        vc_ack,
    input  logic [15:0] vc_q,
    input  logic [10:0] sram_raddr,
    output logic [15:0] sram_q,
    input  logic [10:0] pal_raddr,
    output logic [23:0] pal_q,
    input  logic [10:0] rozli_raddr,    // the ROZ line RAM, for the plane's per-line mode
    output logic [15:0] rozli_rq,

    // diagnostics
    output logic [23:0] dbg_addr,
    output logic [15:0] dbg_data,       // data_in of the last completed read
    output logic  [1:0] dbg_busstate,
    output logic        dbg_step,
    output logic        dbg_irq5,
    output logic        dbg_spr_we,          // a CPU write into the sprite RAM (benches)
    output logic        dbg_dma              // the K055550 is running (benches)
);
    // ------------------------------------------------------------ TG68K
    logic        clkena;
    logic [15:0] data_in;
    logic  [2:0] ipl_n;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0] addr_out;   // a 68000 has 24 address lines and no A0
    /* verilator lint_on UNUSEDSIGNAL */
    logic [15:0] data_write;
    logic        nWr, nUDS, nLDS;
    logic  [1:0] busstate;
    logic        nResetOut;
    logic [31:0] regin_out, vbr_out;
    logic  [3:0] cacr_out;
    logic  [2:0] fc;
    logic        longword, clr_berr, skipFetch;
    logic  [2:0] step_gap;

    TG68KdotC_Kernel cpu (
        .clk            ( clk ),
        .nReset         ( ~reset ),
        .clkena_in      ( clkena ),
        .data_in        ( data_in ),
        .IPL            ( ipl_n ),
        .IPL_autovector ( 1'b1 ),
        .berr           ( 1'b0 ),
        .CPU            ( 2'b00 ),          // 68000
        .addr_out       ( addr_out ),
        .data_write     ( data_write ),
        .nWr            ( nWr ),
        .nUDS           ( nUDS ),
        .nLDS           ( nLDS ),
        .busstate       ( busstate ),
        .longword       ( longword ),
        .nResetOut      ( nResetOut ),
        .FC             ( fc ),
        .clr_berr       ( clr_berr ),
        .skipFetch      ( skipFetch ),
        .regin_out      ( regin_out ),
        .CACR_out       ( cacr_out ),
        .VBR_out        ( vbr_out )
    );

    wire [23:1] A_cpu = addr_out[23:1];
    wire        is_wr = (busstate == 2'b11);
    wire  [5:0] step_cost = (busstate == 2'b01 || skipFetch) ? 6'(STEP_COST_INT) : 6'(STEP_COST_BUS);
    wire        cuds  = ~nUDS;             // D15:8
    wire        clds  = ~nLDS;             // D7:0
    assign dbg_addr     = {A_cpu, 1'b0};
    assign dbg_data     = data_in;
    assign dbg_busstate = busstate;

    // The bus the decode below sees: the CPU's, or the K055550's while it runs.
    // The DMA only writes, whole words.
    logic        dma_run;
    logic [23:1] dma_a;
    logic [15:0] k550 [32];             // K055550 registers, word-wide (m_prot_data)
    wire  [23:1] A    = dma_run ? dma_a : A_cpu;
    wire         uds  = dma_run ? 1'b1 : cuds;
    wire         lds  = dma_run ? 1'b1 : clds;
    wire  [15:0] wdat = dma_run ? k550[13] : data_write;
    assign dbg_dma = dma_run;

    // --------------------------------------------------------- decode
    wire sel_rom    = (A[23:21] == 3'b000);                     // 000000-1fffff
    wire sel_sprwin = (A[23:16] == 8'h40);                      // 400000-40ffff
    wire sel_vram   = (A[23:14] == 10'b0100_0001_00);           // 410000-413fff (mirror at 412000)
    wire sel_pal    = (A[23:13] == 11'b0100_0010_000);          // 420000-421fff
    wire sel_k46    = (A[23:3]  == 21'h086000);                 // 430000-430007
    wire sel_tmrb   = (A[23:14] == 10'h110);                    // 440000-443fff  tile ROM readback
    wire sel_sprrb  = (A[23:4]  == 20'h45000);                  // 450000-45000f  sprite ROM readback
    wire sel_k47    = (A[23:4]  == 20'h45001);                  // 450010-45001f
    wire sel_rozct  = (A[23:5]  == 19'h23000);                  // 460000-46001f
    wire sel_rozli  = (A[23:12] == 12'h470);                    // 470000-470fff
    wire sel_vacset = (A[23:6]  == 18'h12000);                  // 480000-48003f
    wire sel_vsccs  = (A[23:3]  == 21'h090400);                 // 482000-482007
    wire sel_clip   = (A[23:2]  == 22'h121000);                 // 484000-484003
    wire sel_k252   = (A[23:5]  == 19'h24300);                  // 486000-48601f
    wire sel_k555   = (A[23:8]  == 16'h4880);                   // 488000-4880ff
    wire sel_k321   = (A[23:5]  == 19'h24500);                  // 48a000-48a01f
    wire sel_k338   = (A[23:5]  == 19'h24600);                  // 48c000-48c01f
    wire sel_in0    = (A[23:1]  == 23'h247000);                 // 48e000
    wire sel_in1    = (A[23:1]  == 23'h247010);                 // 48e020
    wire sel_wram   = (A[23:16] == 8'h60);                      // 600000-60ffff
    wire sel_k550   = (A[23:6]  == 18'h1A000);                  // 680000-68003f  K055550
    wire sel_eep    = (A[23:1]  == 23'h350000);                 // 6a0000
    wire sel_rozen  = (A[23:1]  == 23'h360000);                 // 6c0000
    wire sel_sndirq = (A[23:1]  == 23'h370000);                 // 6e0000
    wire sel_rb0    = (A[23:19] == 5'b1000_0);                  // 800000-87ffff
    wire sel_rb1    = (A[23:19] == 5'b1010_0);                  // a00000-a7ffff
    wire sel_rb2    = (A[23:21] == 3'b110);                     // c00000-dfffff
    /* verilator lint_off UNUSEDSIGNAL */
    wire sel_wdog   = (A[23:1]  == 23'h700000);                 // e00000: decoded, deliberately ignored
    /* verilator lint_on UNUSEDSIGNAL */

    // -------------------------------------------------------- memories
    // work RAM 32K x 16, byte lanes
    logic [1:0][7:0] wram [32768];
    logic [15:0] wram_q;
    // palette: two 16-bit words per entry (00RR, GGBB), each a byte-enabled
    // RAM in Quartus's template form so it infers rather than becoming 64K
    // registers; the CPU and the mixer each read a copy
    logic [1:0][7:0] pal0 [2048] /*verilator public_flat_rd*/;
    logic [1:0][7:0] pal1 [2048] /*verilator public_flat_rd*/;
    logic [1:0][15:0] pal_cpu_q, pal_rd_q;
    logic        pal_we;
    logic [10:0] pal_waddr;
    logic  [1:0] pal_wsel;             // which word, {word1, word0}
    logic  [1:0] pal_wbe;              // {uds, lds}
    logic [15:0] pal_wdata;
    always_ff @(posedge clk) begin
        if (pal_we && pal_wsel[0]) begin
            if (pal_wbe[1]) pal0[pal_waddr][1] <= pal_wdata[15:8];
            if (pal_wbe[0]) pal0[pal_waddr][0] <= pal_wdata[7:0];
        end
        pal_cpu_q[0] <= pal0[A_cpu[12:2]];
        pal_rd_q[0]  <= pal0[pal_raddr];
    end
    always_ff @(posedge clk) begin
        if (pal_we && pal_wsel[1]) begin
            if (pal_wbe[1]) pal1[pal_waddr][1] <= pal_wdata[15:8];
            if (pal_wbe[0]) pal1[pal_waddr][0] <= pal_wdata[7:0];
        end
        pal_cpu_q[1] <= pal1[A_cpu[12:2]];
        pal_rd_q[1]  <= pal1[pal_raddr];
    end
    // sprite RAM 0x800 words behind the scattered window, plus the plain
    // 32K x 16 the rest of the 64 KB window lands in (the board has it, and
    // the self-test writes and reads all of it)
    logic [15:0] sram [2048] /*verilator public_flat_rd*/;
    logic [15:0] sram_cpu_q;
    logic [15:0] sshadow [32768];
    logic [15:0] sshadow_q;
    // ROZ line RAM
    logic [15:0] rozli [2048] /*verilator public_flat_rd*/;
    logic [15:0] rozli_q;
    // K053252 bytes (kept so reads return what was written)
    logic  [7:0] k252 [16];

    // tile-RAM page select: regs[0x19] bits {4:3, 1:0}, or the external
    // linescroll page when regs[0] bit 1 is set (not fitted on this board)
    wire [3:0] vram_page = {k56regs[25][4:3], k56regs[25][1:0]};
    wire       vram_ext  = k56regs[0][1];
    wire [15:0] vram_cpu_addr = {vram_page, A[12:1]};

    // scattered sprite window: word w of the chip lives at
    // 400000 + ((w & 0x7f8) << 5) + (w & 7) * 2; the rest is shadow RAM.
    // MAME's test is (word offset & 0x78) == 0, i.e. A[7:4] all clear --
    // four bits, not three.
    wire        spr_hit  = (A[7:4] == 4'd0);
    wire [10:0] spr_word = {A[15:8], A[3:1]};
    wire        spr_hit_c = (A_cpu[7:4] == 4'd0);               // the CPU's own, for reads

    always_ff @(posedge clk) begin
        wram_q      <= wram[A[15:1]];
        sram_cpu_q  <= sram[spr_word];
        sshadow_q   <= sshadow[A[15:1]];
        sram_q      <= sram[sram_raddr];
        rozli_q     <= rozli[A[11:1]];
        rozli_rq    <= rozli[rozli_raddr];
    end
    // xRGB888 across the two words: word0 = 00RR, word1 = GGBB
    assign pal_q = {pal_rd_q[0][7:0], pal_rd_q[1]};

    // ------------------------------------------------- bus sequencer
    typedef enum logic [3:0] {
        B_IDLE, B_RAM_RD, B_WAIT_ROM, B_WAIT_MAP0, B_WAIT_MAP0B, B_WAIT_MAP1, B_WAIT_CHR,
        B_WAIT_TROM, B_SROM_PREP, B_WAIT_SROM, B_WAIT_VRAM, B_WAIT_VRAMW
    } bst_t;
    bst_t bst;
    logic [5:0]  tok;
    logic        irq5_pend;
    logic [15:0] rd_mux;
    logic [7:0]  rb_hi;
    logic [15:0] in1_word;

    assign ipl_n    = irq5_pend ? 3'b010 : 3'b111;    // level 5

    // K056832 readback (k056832_device::mw_rom_word_r). The bank is the low byte
    // of regs[0x1a] | regs[0x1b] << 16 (MAME takes it modulo the 768 banks of
    // the region; only the first 256 hold ROM). A bank is 2048 five-byte groups;
    // the window is 16 KB, which spans two of them.
    /* verilator lint_off UNUSEDSIGNAL */
    wire [23:0] tile_bank32 = {k56regs[27][7:0], k56regs[26]};
    wire  [7:0] tile_bank   = tile_bank32[7:0];
    wire [19:0] trom_g_w    = {1'b0, tile_bank, 11'd0} + {8'd0, A_cpu[13:2]};   // two words a group: group = offset >> 1
    wire [19:0] trom_g_p    = {1'b0, tile_bank, 11'd0} + {9'd0, A_cpu[13:3]};   // fifth plane: group = offset >> 2
    wire        tile_plane5 = k56regsb[2][3];
    // K055673 readback: romofs from k053246 regs 6/7/4. Window word o = A[3:1]:
    //   o = 0,1,4,5   the u16 at index romofs + {2,3,0,1} of the sprite ROM
    //   o = 2,3 / 6,7 the byte at (romofs >> 1) + {1, 0} of the fifth plane area
    wire [23:0] spr_romofs  = {k46regs[6], k46regs[7], k46regs[4]};
    /* verilator lint_on UNUSEDSIGNAL */
    logic [23:0] sr_idx;                // u16 index, or byte index into the fifth plane area
    logic        sr_p5;                 // the fifth-plane byte form
    logic  [3:0] srom_sel;              // 0-3: a word of the 64-bit row; 4: the fifth plane's word, swapped; 5/6: its high/low byte
    logic        srom_oor;              // outside the ROM: reads 0
    assign dbg_irq5 = irq5_pend;
    // MAME's dddeeprom_r: an access that includes the high byte returns IN1
    // there with a zero low byte; only a low-byte access reads P2
    assign in1_word = {in1[7:2], eep_ready, eep_do, cuds ? 8'h00 : p2};

    // sources that answer in one cycle
    always_comb begin
        rd_mux = 16'h0000;
        if      (sel_wram)   rd_mux = wram_q;
        else if (sel_vram)   rd_mux = 16'h0000;            // only the external-linescroll mode reads here
        else if (sel_pal)    rd_mux = A_cpu[1] ? pal_cpu_q[1] : pal_cpu_q[0];
        else if (sel_sprwin) rd_mux = spr_hit_c ? sram_cpu_q : sshadow_q;
        else if (sel_rozli)  rd_mux = rozli_q;
        else if (sel_rozct)  rd_mux = rozctrl[A_cpu[4:1]];
        else if (sel_k252)   rd_mux = {8'h00, k252[A_cpu[4:1]]};
        else if (sel_in0)    rd_mux = in0_p1;
        else if (sel_in1)    rd_mux = in1_word;
        else if (sel_k321)   rd_mux = {snd_rdata, 8'h00};
        else if (sel_k550)   rd_mux = k550[A_cpu[5:1]];
        if (sel_tmrb)        rd_mux = 16'h0000;            // a group beyond the ROM
    end

    // the fifth plane's bits as mw_rom_word_r returns them: bit pairs of the byte
    // go to bits 12 and 4, one pair per word of the group
    function automatic logic [15:0] p5(input logic [7:0] t, input logic [1:0] b);
        logic [15:0] r;
        r = 16'h0000;
        case (b)
            2'd0: begin r[12] = t[7]; r[4] = t[6]; end   // (t & 0x80) << 5   | (t & 0x40) >> 2
            2'd1: begin r[12] = t[5]; r[4] = t[4]; end   // (t & 0x20) << 7   | (t & 0x10)
            2'd2: begin r[12] = t[3]; r[4] = t[2]; end   // (t & 0x08) << 9   | (t & 0x04) << 2
            2'd3: begin r[12] = t[1]; r[4] = t[0]; end   // (t & 0x02) << 11  | (t & 0x01) << 4
        endcase
        return r;
    endfunction

    // ---------------------------------------------- K055550 memset engine
    // Command 0x97 / 0x9f (the byte written to the high half of register 0):
    // fill (reg7:reg8) .. + (reg10:reg11) * ((reg0 & 0xff) + 1) bytes with reg13.
    // MAME does it in zero time at the write; the board's chip masters the bus,
    // so here the CPU is held for the word-a-clock the fill takes. Violent Storm's
    // other commands (0x87, 0x98, 0xa0, 0xc0) are not used by this game (a
    // 2,500-frame survey saw only 0x97) and are not modelled.
    typedef enum logic [2:0] { M_IDLE, M_ACC, M_RUN, M_VW } mst_t;
    mst_t        mst;
    logic        dma_start;
    logic  [8:0] m_cnt;
    logic [31:0] m_tot;
    logic [31:0] m_words;
    wire         dma_busy = dma_start || (mst != M_IDLE);

    // a CPU step is the 68000's bus cycle: the same sequencing as the Gaiapolis core
    wire cpu_step  = (bst == B_IDLE) && !dma_busy && (tok >= 6'(step_cost)) && !clkena && (step_gap == 3'd0);
    wire cpu_wr    = cpu_step && (fc != 3'b111) && !(busstate == 2'b01 || skipFetch) && is_wr;
    wire dma_wr    = (mst == M_RUN);
    wire do_wr     = cpu_wr || dma_wr;
    wire vram_wr   = sel_vram && !vram_ext;

    always_ff @(posedge clk) begin
        clkena   <= 1'b0;
        dbg_step <= 1'b0;
        dbg_spr_we <= 1'b0;
        snd_wr <= 1'b0; snd_rd <= 1'b0; snd_irq <= 1'b0; pal_we <= 1'b0;
        step_gap <= {step_gap[1:0], clkena};
        dma_start <= 1'b0;

        if (reset) begin
            bst <= B_IDLE; tok <= '0; step_gap <= '0; irq5_pend <= 1'b0; vc_req <= 1'b0;
            rom_req <= 1'b0; map_req <= 1'b0; chr_req <= 1'b0; trom_req <= 1'b0; srom_req <= 1'b0;
            roz_enable <= 1'b0; roz_rombank <= 2'd0;
            eep_di <= 1'b0; eep_cs <= 1'b0; eep_clk <= 1'b0;
            mst <= M_IDLE; dma_run <= 1'b0;
            for (int i = 0; i < 32; i++) begin k56regs[i] <= '0; k550[i] <= '0; end
            for (int i = 0; i < 4;  i++) k56regsb[i] <= '0;
            for (int i = 0; i < 48; i++) k55regs[i] <= '0;
            for (int i = 0; i < 16; i++) begin k38regs[i] <= '0; k252[i] <= '0; end
            for (int i = 0; i < 16; i++) rozctrl[i] <= '0;
            for (int i = 0; i < 8;  i++) begin k46regs[i] <= '0; k47regs[i] <= '0; end
            rozclip[0] <= '0; rozclip[1] <= '0;
        end else begin
            if (cen_16m && tok < 6'd48) tok <= tok + 6'(STEP_GAIN);

            // IRQ5 is asserted at vblank and held until the kernel's
            // interrupt-acknowledge cycle -- a *read* with FC = 111, which
            // TG68K performs even with IPL_autovector (MAME's HOLD_LINE).
            // Nothing on the board answers it; the vector is internal.
            if (vblank_rise) irq5_pend <= 1'b1;

            // ------------------------------------------------ the CPU's step
            case (bst)
                B_IDLE: if (cpu_step) begin
                    if (fc == 3'b111) begin
                        // interrupt acknowledge: the IRQ drops, the step completes
                        clkena <= 1'b1; tok <= tok - 6'(STEP_COST_BUS); dbg_step <= 1'b1;
                        irq5_pend <= 1'b0;
                    end else if (busstate == 2'b01 || skipFetch) begin
                        clkena <= 1'b1; tok <= tok - 6'(STEP_COST_INT); dbg_step <= 1'b1;
                    end else if (is_wr) begin
                        // writes are posted: complete immediately (the dispatch below
                        // turns this into a wait for the external tile RAM)
                        tok <= tok - 6'(STEP_COST_BUS); clkena <= 1'b1; dbg_step <= 1'b1;
                    end else begin
                        // reads
                        tok <= tok - 6'(STEP_COST_BUS);
                        if (sel_rom) begin
                            rom_addr <= A_cpu[22:1]; rom_req <= 1'b1; bst <= B_WAIT_ROM;
                        end else if (sel_vram && !vram_ext) begin
                            vc_req <= 1'b1; vc_we <= 1'b0; vc_addr <= vram_cpu_addr; bst <= B_WAIT_VRAM;
                        end else if (sel_rb0) begin
                            // (gfx4[off] << 8) | gfx4[0x40000 + off], off = word offset
                            map_addr <= {2'd0, A_cpu[18:1]}; map_req <= 1'b1; bst <= B_WAIT_MAP0;
                        end else if (sel_rb1) begin
                            // gfx4[off / 2] in the low byte
                            map_addr <= {3'd0, A_cpu[18:2]}; map_req <= 1'b1; bst <= B_WAIT_MAP1;
                        end else if (sel_rb2) begin
                            // gfx3[bank * 0x100000 + off] << 8
                            chr_addr <= {roz_rombank, A_cpu[20:1]}; chr_req <= 1'b1; bst <= B_WAIT_CHR;
                        end else if (sel_tmrb) begin
                            if (tile_plane5) begin
                                trom_addr <= trom_g_p[18:0];
                                if (trom_g_p[19]) bst <= B_RAM_RD;           // outside the ROM: reads 0
                                else begin trom_req <= 1'b1; bst <= B_WAIT_TROM; end
                            end else begin
                                trom_addr <= trom_g_w[18:0];
                                if (trom_g_w[19]) bst <= B_RAM_RD;
                                else begin trom_req <= 1'b1; bst <= B_WAIT_TROM; end
                            end
                        end else if (sel_sprrb) begin
                            case (A_cpu[3:1])
                                3'd0: begin sr_idx <= spr_romofs + 24'd2; sr_p5 <= 1'b0; end
                                3'd1: begin sr_idx <= spr_romofs + 24'd3; sr_p5 <= 1'b0; end
                                3'd2, 3'd3: begin sr_idx <= {1'b0, spr_romofs[23:1]} + 24'd1; sr_p5 <= 1'b1; end
                                3'd4: begin sr_idx <= spr_romofs;         sr_p5 <= 1'b0; end
                                3'd5: begin sr_idx <= spr_romofs + 24'd1; sr_p5 <= 1'b0; end
                                default: begin sr_idx <= {1'b0, spr_romofs[23:1]}; sr_p5 <= 1'b1; end
                            endcase
                            bst <= B_SROM_PREP;
                        end else begin
                            if (sel_k321) snd_rd <= 1'b1;
                            snd_off <= A_cpu[4:1];
                            bst <= B_RAM_RD;
                        end
                    end
                end

                // the sprite ROM's index becomes a row and a piece of it
                B_SROM_PREP: begin
                    srom_oor <= 1'b0;
                    if (sr_p5) begin
                        // byte j of the fifth plane area: row j >> 1, high byte if j is even
                        srom_addr <= sr_idx[20:1];
                        srom_sel  <= sr_idx[0] ? 4'd6 : 4'd5;
                        if (sr_idx[23:21] != 3'd0) srom_oor <= 1'b1;
                    end else if (sr_idx[23:22] == 2'd0) begin
                        // u16 i of the four low planes: row i >> 2, word i & 3
                        srom_addr <= sr_idx[21:2];
                        srom_sel  <= {2'd0, sr_idx[1:0]};
                    end else if (sr_idx[23:20] == 4'h4) begin
                        // the u16s just above them are the fifth plane area, as MAME's flat region has it
                        srom_addr <= sr_idx[19:0];
                        srom_sel  <= 4'd4;
                    end else srom_oor <= 1'b1;
                    srom_req <= 1'b1;
                    bst <= B_WAIT_SROM;
                end

                // block RAMs and latches answer one cycle after the live address
                B_RAM_RD: begin
                    data_in <= rd_mux; clkena <= 1'b1; dbg_step <= 1'b1; bst <= B_IDLE;
                end
                B_WAIT_ROM: if (rom_ack) begin
                    rom_req <= 1'b0; data_in <= rom_q; clkena <= 1'b1; dbg_step <= 1'b1; bst <= B_IDLE;
                end
                B_WAIT_VRAM: if (vc_ack) begin
                    vc_req <= 1'b0; data_in <= vc_q; clkena <= 1'b1; dbg_step <= 1'b1; bst <= B_IDLE;
                end
                B_WAIT_VRAMW: if (vc_ack) begin
                    vc_req <= 1'b0; clkena <= 1'b1; dbg_step <= 1'b1; bst <= B_IDLE;
                end
                B_WAIT_MAP0: if (map_ack) begin
                    rb_hi <= map_addr[0] ? map_q[7:0] : map_q[15:8];
                    map_addr <= 20'h40000 + {2'd0, A_cpu[18:1]}; bst <= B_WAIT_MAP0B;
                end
                B_WAIT_MAP0B: if (map_ack) begin
                    map_req <= 1'b0;
                    data_in <= {rb_hi, map_addr[0] ? map_q[7:0] : map_q[15:8]};
                    clkena <= 1'b1; dbg_step <= 1'b1; bst <= B_IDLE;
                end
                B_WAIT_MAP1: if (map_ack) begin
                    map_req <= 1'b0;
                    data_in <= {8'h00, map_addr[0] ? map_q[7:0] : map_q[15:8]};
                    clkena <= 1'b1; dbg_step <= 1'b1; bst <= B_IDLE;
                end
                B_WAIT_CHR: if (chr_ack) begin
                    chr_req <= 1'b0;
                    data_in <= {chr_addr[0] ? chr_q[7:0] : chr_q[15:8], 8'h00};
                    clkena <= 1'b1; dbg_step <= 1'b1; bst <= B_IDLE;
                end
                B_WAIT_TROM: if (trom_ack) begin
                    trom_req <= 1'b0;
                    if (tile_plane5) data_in <= p5(trom_q[7:0], A_cpu[2:1]);
                    else             data_in <= A_cpu[1] ? trom_q[23:8] : trom_q[39:24];
                    clkena <= 1'b1; dbg_step <= 1'b1; bst <= B_IDLE;
                end
                B_WAIT_SROM: if (srom_oor || srom_ack) begin
                    srom_req <= 1'b0;
                    // (u16*) view on a little-endian host: the low byte is the even byte
                    case (srom_sel)
                        4'd0: data_in <= {srom_q[71:64], srom_q[79:72]};
                        4'd1: data_in <= {srom_q[55:48], srom_q[63:56]};
                        4'd2: data_in <= {srom_q[39:32], srom_q[47:40]};
                        4'd3: data_in <= {srom_q[23:16], srom_q[31:24]};
                        4'd4: data_in <= {srom_q[7:0], srom_q[15:8]};
                        4'd5: data_in <= {8'h00, srom_q[15:8]};
                        default: data_in <= {8'h00, srom_q[7:0]};
                    endcase
                    if (srom_oor) data_in <= 16'h0000;
                    clkena <= 1'b1; dbg_step <= 1'b1; bst <= B_IDLE;
                end
                default: bst <= B_IDLE;
            endcase

            // ------------------------------------------------ the K055550's engine
            case (mst)
                M_IDLE: if (dma_start) begin
                    dma_a <= {k550[7][7:0], k550[8][15:1]};
                    m_cnt <= {1'b0, k550[0][7:0]} + 9'd1;
                    m_tot <= '0;
                    mst <= M_ACC;
                end
                // bytes = unit size * count, by repeated addition (no multiplier for a rare command)
                M_ACC: begin
                    if (m_cnt != 9'd0) begin
                        m_tot <= m_tot + {8'd0, k550[10][7:0], k550[11]};
                        m_cnt <= m_cnt - 9'd1;
                    end else begin
                        m_words <= (m_tot + 32'd1) >> 1;
                        if (m_tot == 32'd0) mst <= M_IDLE;
                        else begin mst <= M_RUN; dma_run <= 1'b1; end
                    end
                end
                // one word a clock through the same decode as a CPU write
                M_RUN: begin
                    if (vram_wr) mst <= M_VW;                        // the tile RAM answers with an ack
                    else begin
                        dma_a <= dma_a + 23'd1; m_words <= m_words - 32'd1;
                        if (m_words == 32'd1) begin mst <= M_IDLE; dma_run <= 1'b0; end
                    end
                end
                M_VW: if (vc_ack) begin
                    vc_req <= 1'b0;
                    dma_a <= dma_a + 23'd1; m_words <= m_words - 32'd1;
                    if (m_words == 32'd1) begin mst <= M_IDLE; dma_run <= 1'b0; end
                    else mst <= M_RUN;
                end
                default: mst <= M_IDLE;
            endcase

            // ------------------------------------------------ the write dispatch
            // A CPU write or a DMA word, by the decode above. (A write the CPU
            // posts has already been completed; the external tile RAM is the
            // exception, which holds the kernel until its ack.)
            if (do_wr) begin
                if (sel_wram) begin
                    if (uds) wram[A[15:1]][1] <= wdat[15:8];
                    if (lds) wram[A[15:1]][0] <= wdat[7:0];
                end else if (sel_vram) begin
                    if (!vram_ext) begin
                        vc_req <= 1'b1; vc_we <= 1'b1; vc_addr <= vram_cpu_addr;
                        vc_be <= {uds, lds}; vc_wdata <= wdat;
                        if (cpu_wr) begin clkena <= 1'b0; dbg_step <= 1'b0; bst <= B_WAIT_VRAMW; end
                    end
                end else if (sel_pal) begin
                    pal_we <= 1'b1; pal_waddr <= A[12:2]; pal_wsel <= {A[1], ~A[1]};
                    pal_wbe <= {uds, lds}; pal_wdata <= wdat;
                end else if (sel_sprwin) begin
                    if (spr_hit && cpu_wr) dbg_spr_we <= 1'b1;
                    if (spr_hit)
                        sram[spr_word] <= {uds ? wdat[15:8] : sram_cpu_q[15:8],
                                           lds ? wdat[7:0]  : sram_cpu_q[7:0]};
                    else
                        sshadow[A[15:1]] <= {uds ? wdat[15:8] : sshadow_q[15:8],
                                             lds ? wdat[7:0]  : sshadow_q[7:0]};
                end else if (sel_k46) begin
                    // k053246_w: byte pair per word
                    if (uds) k46regs[{A[2:1], 1'b0}] <= wdat[15:8];
                    if (lds) k46regs[{A[2:1], 1'b1}] <= wdat[7:0];
                end else if (sel_k47) begin
                    k47regs[A[3:1]] <= {uds ? wdat[15:8] : k47regs[A[3:1]][15:8],
                                        lds ? wdat[7:0]  : k47regs[A[3:1]][7:0]};
                end else if (sel_rozct) begin
                    // 16 words: 0-7 zoom coefficients, 8-15 the chip's own clip window
                    // (unused by the renderer, but they must not alias onto the coefficients)
                    rozctrl[A[4:1]] <= {uds ? wdat[15:8] : rozctrl[A[4:1]][15:8],
                                        lds ? wdat[7:0]  : rozctrl[A[4:1]][7:0]};
                end else if (sel_rozli) begin
                    rozli[A[11:1]] <= {uds ? wdat[15:8] : rozli_q[15:8],
                                       lds ? wdat[7:0]  : rozli_q[7:0]};
                end else if (sel_vacset) begin
                    k56regs[A[5:1]] <= {uds ? wdat[15:8] : k56regs[A[5:1]][15:8],
                                        lds ? wdat[7:0]  : k56regs[A[5:1]][7:0]};
                end else if (sel_vsccs) begin
                    k56regsb[A[2:1]] <= {uds ? wdat[15:8] : k56regsb[A[2:1]][15:8],
                                         lds ? wdat[7:0]  : k56regsb[A[2:1]][7:0]};
                end else if (sel_clip) begin
                    rozclip[A[1]] <= {uds ? wdat[15:8] : rozclip[A[1]][15:8],
                                      lds ? wdat[7:0]  : rozclip[A[1]][7:0]};
                end else if (sel_k252) begin
                    if (lds) k252[A[4:1]] <= wdat[7:0];
                end else if (sel_k555) begin
                    // K055555_word_w: low byte if only LDS, else the high byte
                    if (A[7:1] < 7'd48)
                        k55regs[A[6:1]] <= (lds && !uds) ? wdat[7:0] : wdat[15:8];
                end else if (sel_k321) begin
                    // umask16(0xff00): the high byte
                    if (uds) begin snd_wr <= 1'b1; snd_off <= A[4:1]; snd_wdata <= wdat[15:8]; end
                end else if (sel_k338) begin
                    k38regs[A[4:1]] <= {uds ? wdat[15:8] : k38regs[A[4:1]][15:8],
                                        lds ? wdat[7:0]  : k38regs[A[4:1]][7:0]};
                end else if (sel_k550) begin
                    // word registers; a write of 0x97 / 0x9f to the high half of register 0 runs the memset
                    k550[A[5:1]] <= {uds ? wdat[15:8] : k550[A[5:1]][15:8],
                                     lds ? wdat[7:0]  : k550[A[5:1]][7:0]};
                    if (cpu_wr && A[5:1] == 5'd0 && uds && (wdat[15:8] == 8'h97 || wdat[15:8] == 8'h9f))
                        dma_start <= 1'b1;
                end else if (sel_eep) begin
                    if (lds) begin eep_di <= wdat[0]; eep_cs <= wdat[1]; eep_clk <= wdat[2]; end
                end else if (sel_rozen) begin
                    if (uds) begin roz_enable <= wdat[8]; roz_rombank <= wdat[15:14]; end
                end else if (sel_sndirq) begin
                    snd_irq <= 1'b1;
                end
                // sel_wdog and anything unmapped: ignored
            end
        end
    end
endmodule
