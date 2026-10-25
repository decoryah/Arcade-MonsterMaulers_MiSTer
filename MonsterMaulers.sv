//============================================================================
//
//  Konami "pre-GX" GX170 arcade board -- Monster Maulers (1993) -- for MiSTer.
//
//  The machine (rtl/) descends from the Gaiapolis core written for the Analogue
//  Pocket by plasticbugs (https://github.com/plasticbugs/analogue-pocket-gaiapolis),
//  as carried to MiSTer in gaiapolis-mister: Gaiapolis and Monster Maulers are
//  boards of the same family (MAME's mystwarr.cpp), and this is that machine
//  adapted to this game (5-bit tiles and sprites, an 8bpp rotating plane, the
//  K055550, a mixer that blends and fades). This file is its MiSTer platform
//  layer: memory (target/mister), clocks, video, audio, controls and ROM/NVRAM
//  loading through the MiSTer framework.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 3 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S   = 1;       // signed samples
assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

wire [127:0] status;
wire   [1:0] buttons;
wire         forced_scandoubler;
wire         direct_video;
wire  [21:0] gamma_bus;

// Aspect ratio and Scale. The framework's video_freak (after arcade_video, below) turns the two into VIDEO_ARX/ARY: with
// Scale Normal they pass through as they are; the integer modes replace them with the exact size in pixels (bit 12 set)
// that the HDMI scaler should give the picture. The menu's order is the user's; video_freak's SCALE input counts
// 0 Normal, 1 V-Integer, 2 Narrower HV-Integer, 3 HV-Integer+ (wider), 4 HV-Integer
reg   [2:0] scale_sel;
always @* case (status[34:32])
	3'd1:    scale_sel = 3'd1;   // V-Integer
	3'd2:    scale_sel = 3'd4;   // HV-Integer
	3'd3:    scale_sel = 3'd2;   // Narrower HV-Integer
	3'd4:    scale_sel = 3'd3;   // HV-Integer+
	default: scale_sel = 3'd0;   // Normal
endcase
// Full Screen is ARX = ARY = 0 ("fill"), which has no proportions for the integer rule to size the width from: it sizes
// the height from the width instead and asks for more rows than the screen has (1344 on a 1080p display). With an integer
// Scale the screen's own proportions stand in for it, so the picture is a whole-number size in the screen's aspect
wire  [1:0] ar         = status[122:121];
wire        fs_int     = (ar == 2'd1) && (scale_sel != 3'd0) && (HDMI_WIDTH != 12'd0) && (HDMI_HEIGHT != 12'd0);
wire [11:0] arx        = fs_int ? HDMI_WIDTH  : (!ar) ? 12'd4 : (ar - 1'd1);
wire [11:0] ary        = fs_int ? HDMI_HEIGHT : (!ar) ? 12'd3 : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	"A.MMAULERS;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[34:32],Scale,Normal,V-Integer,HV-Integer,Narrower HV-Integer,HV-Integer+;",
	"O[35],Colours,Board DAC,MAME;",
	"O[12],Flip Screen,Off,On;",
	"O[5:3],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"P1,CRT Adjust;",
	"P1O[14],CRT Adjust,Off,On;",
	"H1P1O[19:15],CRT H-Size,0,+1,+2,+3,+4,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H1P1O[26:20],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H1P1O[31:27],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"-;",
	"O[6],Test Mode,Off,On;",
	"O[8],Audio,Stereo,Mono;",
	"-;",
	"O[9],Diagnostic overlay,Off,On;",
	"O[10],SDRAM read capture,Normal,Late;",
	"-;",
	"R0,Reset;",
	"J1,Weak Attack,Medium Attack,Strong Attack,Start,Coin;",
	"jn,A,B,R,Start,Select;",
	"V,v",`BUILD_DATE
};

////////////////////   CLOCKS   ///////////////////

wire clk_sys;           // 96 MHz: the whole machine
wire clk_sdram;         // 96 MHz, shifted: the SDRAM chip's clock pin
wire pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram),
	.locked(pll_locked)
);

///////////////////////////////////////////////////

wire         ioctl_download;
wire         ioctl_upload;
wire         ioctl_wr;
wire  [15:0] ioctl_index;
wire  [26:0] ioctl_addr;
wire   [7:0] ioctl_dout;
wire   [7:0] ioctl_din;
wire         ioctl_rd;
wire         ioctl_wait;
reg          ioctl_upload_req;

wire  [31:0] joystick_0, joystick_1;
wire  [10:0] ps2_key;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),

	.buttons(buttons),
	.status(status),
	.status_menumask({14'd0, ~status[14], direct_video}),
	.forced_scandoubler(forced_scandoubler),
	.video_rotated(1'b0),
	.direct_video(direct_video),
	.gamma_bus(gamma_bus),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(ioctl_upload_req),
	.ioctl_upload_index(8'd2),
	.ioctl_din(ioctl_din),
	.ioctl_rd(ioctl_rd),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.ps2_key(ps2_key)
);

///////////////////////   CONTROLS   ///////////////////////

// keyboard: 1/2 start, 5/6 coin, F2 test (MAME's defaults)
reg key_start1, key_start2, key_coin1, key_coin2, key_test;
always @(posedge clk_sys) begin
	reg old_stb;
	old_stb <= ps2_key[10];
	if (old_stb != ps2_key[10]) begin
		case (ps2_key[7:0])
			8'h16: key_start1 <= ps2_key[9];
			8'h1E: key_start2 <= ps2_key[9];
			8'h2E: key_coin1  <= ps2_key[9];
			8'h36: key_coin2  <= ps2_key[9];
			8'h06: key_test   <= ps2_key[9];
			default: ;
		endcase
	end
end

// joystick bits: 0 right, 1 left, 2 down, 3 up, 4-6 buttons 1-3, 7 start, 8 coin
wire j1_r = joystick_0[0], j1_l = joystick_0[1], j1_d = joystick_0[2], j1_u = joystick_0[3];
wire j1_b1 = joystick_0[4], j1_b2 = joystick_0[5], j1_b3 = joystick_0[6];
wire j1_start = joystick_0[7] | key_start1, j1_coin = joystick_0[8] | key_coin1;
wire j2_r = joystick_1[0], j2_l = joystick_1[1], j2_d = joystick_1[2], j2_u = joystick_1[3];
wire j2_b1 = joystick_1[4], j2_b2 = joystick_1[5], j2_b3 = joystick_1[6];
wire j2_start = joystick_1[7] | key_start2, j2_coin = joystick_1[8] | key_coin2;

// the board's inputs, active low (docs/hardware.md section 8; MAME's dadandrn ports):
//   IN0_P1: bit0 L, 1 R, 2 U, 3 D, 4-6 buttons 1-3, 7 start1, 8 coin1, 9 coin2, 11 test switch
//   P2: the same low byte
//   IN1: bit3 test (low = on), bit4 mono (0 = stereo), bit5 flip (1 = off, held: the tilemap renderer has no global flip); bits 1:0 are the EEPROM
//        pins, bit2 an unassigned input the game polls for 0
wire        test_sw = status[6] | key_test;
wire [15:0] in0_p1  = ~{2'b00, 1'b0, 1'b0, test_sw, 1'b0, j2_coin, j1_coin,
                        j1_start, j1_b3, j1_b2, j1_b1, j1_d, j1_u, j1_r, j1_l};
wire  [7:0] p2      = ~{j2_start, j2_b3, j2_b2, j2_b1, j2_d, j2_u, j2_r, j2_l};
wire  [7:0] in1     = {2'b11, 1'b1, status[8], ~test_sw, 1'b0, 2'b11};      // bit 5, flip: off (see the OSD note)

///////////////////////   MEMORIES   ///////////////////////

// the ROM image: MRA index 0
wire        rom_dl   = ioctl_download && (ioctl_index[7:0] == 8'd0);
wire        dl_we    = rom_dl && ioctl_wr;
// the EEPROM: its default (MRA index 2) and the saved file
wire        nv_dl_we = ioctl_download && (ioctl_index[7:0] == 8'd2) && ioctl_wr;

reg   rom_dl_d;
always @(posedge clk_sys) rom_dl_d <= rom_dl;
wire  dl_start = rom_dl && !rom_dl_d;
wire  dl_done  = !rom_dl && rom_dl_d;

// Fast load: with address= on the MRA's index-0 <rom>, Main_MiSTer copies the whole assembled image into the DDR3 in one
// go and then ends a download that has no data bytes, only a start address: the image's length (ioctl_addr, which
// is 0 at the start of an ordinary download). The core stays in reset from that start until mm_mem has read the image
// back and pushed it through the loader (fl_done), so the picture and the memory test see a finished load. An older
// Main_MiSTer ignores the attribute and streams the bytes as before; nothing here touches that path
reg         fast_dl /*verilator public_flat_rd*/ = 1'b0;
reg  [24:0] fast_len;
wire        fl_go   = fast_dl && dl_done;
wire        fl_done;
always @(posedge clk_sys) begin
	if (dl_start) begin fast_dl <= (ioctl_addr != 27'd0); fast_len <= ioctl_addr[24:0]; end
	else if (fl_done) fast_dl <= 1'b0;
end
// the load is over: when the stream ended, or, for a fast one, when the image has gone through the loader
wire        load_done = fast_dl ? fl_done : dl_done;

wire        mem_init = ~pll_locked | RESET;

wire        mem_ready, test_run, test_done, vram_ok;
wire  [6:0] test_ok, test_stable;
wire  [3:0] vram_bad;

// the built-in memory test: only with the diagnostic overlay on, at the end of a load
reg   test_start, test_hold;
always @(posedge clk_sys) begin
	test_start <= load_done && status[9];
	if (test_start) test_hold <= 1'b1;
	else if (test_done) test_hold <= 1'b0;
end

wire        prog_req, prog_ack, tile_req, tile_ack, map_req, map_ack, spr_req, spr_ack;
wire        blk_req, blk_wr, blk_ack; wire [15:0] blk_addr, blk_data; wire [6:0] blk_idx; wire [3:0] roz_lead;
wire        snd_req, snd_ack, pcm_req, pcm_ack;
wire [22:1] prog_addr; wire [18:0] tile_addr; wire [19:0] map_addr; wire [19:0] spr_addr;
wire [17:0] snd_addr; wire [21:0] pcm_addr;
wire [15:0] prog_q, map_q; wire [39:0] tile_q; wire [79:0] spr_q; wire [7:0] snd_q, pcm_q;
wire        vram_req, vram_we, vram_ack; wire [15:0] vram_addr, vram_wdata, vram_q; wire [1:0] vram_be;

wire        ddr_rd, ddr_we, ddr_busy, ddr_dready;
wire [24:0] ddr_addr; wire [7:0] ddr_burst, ddr_be; wire [63:0] ddr_din, ddr_dout;

wire        dram_cke;
wire  [1:0] dram_dqm;

mm_mem u_mem
(
	.clk(clk_sys), .clk_sdram(clk_sdram), .init(mem_init), .dl_start(dl_start), .ready(mem_ready),
	.test_start(test_start), .test_run(test_run), .test_done(test_done), .test_ok(test_ok), .test_stable(test_stable),
	.vram_ok(vram_ok), .vram_bad(vram_bad),
	.rd_late(status[10]), .burst_slow(1'b0),
	.dl_we(dl_we), .dl_addr(ioctl_addr[24:0]), .dl_data(ioctl_dout), .dl_wait(ioctl_wait),
	.fl_go(fl_go), .fl_len(fast_len), .fl_done(fl_done),
	.prog_req(prog_req), .prog_addr(prog_addr), .prog_ack(prog_ack), .prog_q(prog_q),
	.tile_req(tile_req), .tile_addr(tile_addr), .tile_ack(tile_ack), .tile_q(tile_q),
	.map_req(map_req), .map_addr(map_addr), .map_ack(map_ack), .map_q(map_q),
	.blk_req(blk_req), .blk_addr(blk_addr), .blk_wr(blk_wr), .blk_idx(blk_idx), .blk_data(blk_data), .blk_ack(blk_ack),
	.roz_lead(roz_lead),
	.spr_req(spr_req), .spr_addr(spr_addr), .spr_ack(spr_ack), .spr_q(spr_q),
	.snd_req(snd_req), .snd_addr(snd_addr), .snd_ack(snd_ack), .snd_q(snd_q),
	.pcm_req(pcm_req), .pcm_addr(pcm_addr), .pcm_ack(pcm_ack), .pcm_q(pcm_q),
	.vram_req(vram_req), .vram_we(vram_we), .vram_addr(vram_addr), .vram_be(vram_be), .vram_wdata(vram_wdata),
	.vram_ack(vram_ack), .vram_q(vram_q),
	.dram_dq(SDRAM_DQ), .dram_a(SDRAM_A), .dram_ba(SDRAM_BA), .dram_dqm(dram_dqm),
	.dram_clk(SDRAM_CLK), .dram_cke(dram_cke), .dram_ras_n(SDRAM_nRAS), .dram_cas_n(SDRAM_nCAS), .dram_we_n(SDRAM_nWE),
	.ddr_rd(ddr_rd), .ddr_we(ddr_we), .ddr_addr(ddr_addr), .ddr_burst(ddr_burst), .ddr_din(ddr_din), .ddr_be(ddr_be),
	.ddr_busy(ddr_busy), .ddr_dout(ddr_dout), .ddr_dready(ddr_dready)
);
assign SDRAM_CKE  = dram_cke;
assign SDRAM_nCS  = 1'b0;
assign {SDRAM_DQMH, SDRAM_DQML} = dram_dqm;

// DDR3: the core's ROZ client and Flip Screen's frame buffers
wire        ddr_overflow;
wire        fb_we, fl_rd, fl_busy, fl_dready;       // flip_buf: frame writes and line reads
wire [28:0] fb_addr;
wire [63:0] fb_din;
wire [24:0] fl_addr;
wire  [7:0] fl_burst;

ddr_arb u_ddr
(
	.clk(clk_sys), .reset(~pll_locked),
	.c_rd(ddr_rd), .c_we(ddr_we), .c_addr(ddr_addr), .c_burst(ddr_burst), .c_din(ddr_din), .c_be(ddr_be),
	.c_busy(ddr_busy), .c_dout(ddr_dout), .c_dready(ddr_dready),
	.r_we(fb_we), .r_addr(fb_addr), .r_din(fb_din), .r_be(8'hFF),
	.f_rd(fl_rd), .f_addr(fl_addr), .f_burst(fl_burst), .f_busy(fl_busy), .f_dready(fl_dready),
	.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
	.overflow(ddr_overflow)
);
assign DDRAM_CLK = clk_sys;

///////////////////////   THE MACHINE   ///////////////////////

wire        reset_sw  = RESET | status[0] | buttons[1];
// the machine's reset is registered: it fans out to the whole core, including the
// Z80's asynchronous reset, and the OR of its sources in front of that fan-out
// was the tightest recovery path of the Gaiapolis fits
wire        mm_reset_c = reset_sw | ioctl_download | fast_dl | ~mem_ready | test_hold | test_run;
reg         mm_reset = 1'b1;
always @(posedge clk_sys) mm_reset <= mm_reset_c;

// the EEPROM port: the default and the saved file in, the upload out
wire        eep_dirty;
wire  [7:0] eep_q;
wire        eep_we    = nv_dl_we;
wire  [6:0] eep_addr  = ioctl_addr[6:0];
wire  [7:0] eep_wdata = ioctl_dout;
assign      ioctl_din = eep_q;

wire        mm_cen_pix, mm_hs, mm_vs, mm_de, mm_hde, mm_vb;
wire [23:0] mm_rgb;
wire [15:0] mm_snd_l, mm_snd_r;
wire        mm_snd_valid;
wire [23:0] dbg_addr; wire [15:0] dbg_data; wire [1:0] dbg_busstate; wire [9:0] dbg_objcount; wire [8:0] dbg_vcount;
wire [15:0] dbg_zpc;
wire        dbg_overrun_line;
wire        dbg_step, dbg_irq5, dbg_overrun, dbg_unsupported, dbg_shadow_overlap, dbg_zstep, dbg_zwait, dbg_dma;
wire  [2:0] dbg_overrun_src;

mm_core #(.HEXDIR("rtl/data")) mm
(
	.clk(clk_sys), .reset(mm_reset), .vid_reset(~pll_locked),
	.prog_req(prog_req), .prog_addr(prog_addr), .prog_ack(prog_ack), .prog_q(prog_q),
	.tile_req(tile_req), .tile_addr(tile_addr), .tile_ack(tile_ack), .tile_q(tile_q),
	.map_req(map_req), .map_addr(map_addr), .map_ack(map_ack), .map_q(map_q),
	.blk_req(blk_req), .blk_addr(blk_addr), .blk_wr(blk_wr), .blk_idx(blk_idx), .blk_data(blk_data), .blk_ack(blk_ack), .roz_lead(roz_lead),
	.spr_req(spr_req), .spr_addr(spr_addr), .spr_ack(spr_ack), .spr_q(spr_q),
	.vram_req(vram_req), .vram_we(vram_we), .vram_addr(vram_addr), .vram_be(vram_be), .vram_wdata(vram_wdata),
	.vram_ack(vram_ack), .vram_q(vram_q),
	.snd_rom_req(snd_req), .snd_rom_addr(snd_addr), .snd_rom_ack(snd_ack), .snd_rom_q(snd_q),
	.pcm_req(pcm_req), .pcm_addr(pcm_addr), .pcm_ack(pcm_ack), .pcm_q(pcm_q),
	.eep_ld_we(eep_we), .eep_ld_addr(eep_addr), .eep_ld_wdata(eep_wdata), .eep_ld_q(eep_q), .eep_dirty(eep_dirty),
	.in0_p1(in0_p1), .in1(in1), .p2(p2),
	.cen_pix(mm_cen_pix), .rgb(mm_rgb), .hsync(mm_hs), .vsync(mm_vs), .de(mm_de), .hde(mm_hde), .vblank(mm_vb),
	.snd_l(mm_snd_l), .snd_r(mm_snd_r), .snd_valid(mm_snd_valid),
	.dbg_addr(dbg_addr), .dbg_data(dbg_data), .dbg_busstate(dbg_busstate), .dbg_step(dbg_step), .dbg_irq5(dbg_irq5),
	.dbg_overrun(dbg_overrun), .dbg_overrun_line(dbg_overrun_line), .dbg_overrun_src(dbg_overrun_src), .dbg_draw_objs(), .dbg_draw_rows(), .dbg_draw_cols(), .dbg_draw_pxw(),
	.dbg_spr_we(), .dbg_roz_en(), .dbg_rozctrl(), .dbg_rozclip(), .dbg_k55(),
	.dbg_unsupported(dbg_unsupported), .dbg_shadow_overlap(dbg_shadow_overlap),
	.dbg_objcount(dbg_objcount), .dbg_vcount(dbg_vcount), .dbg_zpc(dbg_zpc), .dbg_zstep(dbg_zstep), .dbg_zwait(dbg_zwait),
	.dbg_zwr(), .dbg_zrd(), .dbg_zwdata(), .dbg_dma(dbg_dma)
);

// NVRAM: ask the HPS to save the EEPROM a second after the game's last write
reg        old_dirty;
reg [26:0] save_timer;
always @(posedge clk_sys) begin
	ioctl_upload_req <= 1'b0;
	old_dirty <= eep_dirty;
	if (mm_reset) save_timer <= 0;
	else if (old_dirty != eep_dirty) save_timer <= 27'd96_000_000;
	else if (save_timer != 0) begin
		save_timer <= save_timer - 1'd1;
		if (save_timer == 27'd1) ioctl_upload_req <= 1'b1;
	end
end

///////////////////////   DIAGNOSTIC OVERLAY   ///////////////////////
// The bottom twelve lines show three rows of 32 squares, green = 1 (rtl/dbg_overlay.sv).
// The raster runs even while the machine is held in reset, so a black screen can still be read:
//   row 0  frame count[7:0] | pll locked, sdram+cache ready, download, test hold, 0, core reset, irq5, 68000 stepped |
//          core resets seen | test done, test running, tile RAM ok, tile RAM bad words (4), Z80 stepped
//   row 1  68000 bus address[23:0] | region read back ok: prog, snd, tile, chr, map, pcm, spr | sound heard
//   row 2  region read stable (7), ddr FIFO overflow | lines overrun last frame (8) |
//          sprites in the list / 4 (8) | unsupported mode met, second shadow on a pixel, K055550 ran, 0, flip line underrun, which renderers overran
reg  [7:0] ovl_frames, ovl_resets, ovl_overruns, ovl_overruns_l;
reg  [2:0] ovl_ovsrc, ovl_ovsrc_l;
reg        ovl_ovr_d, ovl_vs_d, ovl_rst_d, ovl_seen_step, ovl_seen_zstep, ovl_seen_snd, ovl_unsup, ovl_shadow, ovl_unsup_l, ovl_shadow_l;
reg        ovl_funder, ovl_funder_l, ovl_dma, ovl_dma_l;
always @(posedge clk_sys) begin
	ovl_vs_d <= mm_vs; ovl_rst_d <= mm_reset;
	if (mm_reset && !ovl_rst_d) ovl_resets <= ovl_resets + 8'd1;
	if (mm_vs && !ovl_vs_d) begin
		ovl_frames <= ovl_frames + 8'd1;
		ovl_seen_step <= 1'b0; ovl_seen_zstep <= 1'b0; ovl_seen_snd <= 1'b0;
		ovl_overruns_l <= ovl_overruns; ovl_overruns <= 8'd0;
		ovl_ovsrc_l <= ovl_ovsrc; ovl_ovsrc <= 3'd0;
		ovl_unsup_l <= ovl_unsup; ovl_unsup <= 1'b0; ovl_shadow_l <= ovl_shadow; ovl_shadow <= 1'b0;
		ovl_funder_l <= ovl_funder; ovl_funder <= 1'b0;
		ovl_dma_l <= ovl_dma; ovl_dma <= 1'b0;
	end
	ovl_ovr_d <= dbg_overrun;
	if (dbg_overrun_line && ovl_overruns != 8'hff) ovl_overruns <= ovl_overruns + 8'd1;     // lines, not runs of lines
	if (dbg_overrun_line) ovl_ovsrc <= ovl_ovsrc | dbg_overrun_src;
	if (dbg_unsupported)    ovl_unsup  <= 1'b1;
	if (dbg_shadow_overlap) ovl_shadow <= 1'b1;
	if (fb_underrun)        ovl_funder <= 1'b1;
	if (dbg_dma)            ovl_dma    <= 1'b1;
	if (dbg_step)  ovl_seen_step  <= 1'b1;
	if (dbg_zstep) ovl_seen_zstep <= 1'b1;
	if (mm_snd_valid && (mm_snd_l != 16'd0)) ovl_seen_snd <= 1'b1;
end
wire [95:0] ovl_status_d = {
	ovl_frames, pll_locked, mem_ready, ioctl_download | fast_dl, test_hold, 1'b0, mm_reset, dbg_irq5, ovl_seen_step,
	ovl_resets, test_done, test_run, vram_ok, vram_bad, ovl_seen_zstep,
	dbg_addr, test_ok[0], test_ok[1], test_ok[2], test_ok[3], test_ok[4], test_ok[5], test_ok[6], ovl_seen_snd,
	test_stable[0], test_stable[1], test_stable[2], test_stable[3], test_stable[4], test_stable[5], test_stable[6], ddr_overflow,
	ovl_overruns_l, dbg_objcount[9:2], ovl_unsup_l, ovl_shadow_l, ovl_dma_l, 1'd0, ovl_funder_l, ovl_ovsrc_l
};
// registered: the 68000's bus address (a read of its register file through an adder) is one of the squares, and the
// path from there through the overlay and the flip stage is longer than a clock; the panel is not time-critical
reg  [95:0] ovl_status;
always @(posedge clk_sys) ovl_status <= ovl_status_d;
// Colours: the board's video DAC (a Konami 054573 per channel) is not linear: its output rises faster near the top,
// so mid tones come out darker than MAME's straight 8-bit palette. Board DAC looks each channel up in the DAC's curve
// (tools/make_dac_table.py: 0 stays 0 and 255 stays 255, this game writing the full range); MAME passes the palette
// through. After the mixer, so a fade's brightness is in the code the table sees (on the board it scales the DAC's
// current instead, which makes faded mid tones a little brighter there). As in the Gaiapolis core, but not registered:
// this mixer's colour is final only in the clock its pixel enable is high (rtl/mm_mixer.sv), so a register here would
// hand the next stage the half-painted pixel of the clock before -- in the bench, a black picture
(* romstyle = "logic" *) reg [7:0] dac_tab [256];
initial $readmemh("rtl/data/k054573_dac.hex", dac_tab);
wire [23:0] dac_rgb = status[35] ? mm_rgb : {dac_tab[mm_rgb[23:16]], dac_tab[mm_rgb[15:8]], dac_tab[mm_rgb[7:0]]};

wire [7:0] ovl_r, ovl_g, ovl_b;
dbg_overlay ovl
(
	.clk(clk_sys), .cen_pix(mm_cen_pix), .enable(status[9]), .de(mm_de), .vsync(mm_vs),
	.r_in(dac_rgb[23:16]), .g_in(dac_rgb[15:8]), .b_in(dac_rgb[7:0]),
	.status(ovl_status), .r_out(ovl_r), .g_out(ovl_g), .b_out(ovl_b)
);

///////////////////////   AUDIO   ///////////////////////

reg [15:0] aud_l, aud_r;
always @(posedge clk_sys) if (mm_snd_valid) begin aud_l <= mm_snd_l; aud_r <= mm_snd_r; end
assign AUDIO_L = aud_l;
assign AUDIO_R = status[8] ? aud_l : aud_r;      // mono: the left mix on both

///////////////////////   VIDEO   ///////////////////////

// the core emits one pixel per 6 MHz enable on the 96 MHz clock and holds it
// for the sixteen clocks; its de is the visible rectangle, its vblank the
// vertical blanking. hblank_c follows de, so it is high through the vertical blank: CRT Adjust and Flip Screen want that.
// The framework's scandoubler and arcade_video take their line timing from the falling edges of HBlank and need it to
// toggle on every line of the frame, the vertical blank's included (VBlank is separate), so the scandoubler path (Scandoubler
// Fx, MiSTer.ini's forced_scandoubler) is given the horizontal blank alone (mm_hde, vq_hbh below). The 15 kHz path's
// output rows are the same either way: the video mixer ANDs the two blanks.
wire hblank_c = ~mm_de;

// Flip Screen: the finished picture (overlay included) turned 180 degrees, one frame late, through
// two frame buffers in the DDR3; the picture is untouched when it is off (target/mister/flip_buf.sv)
wire [23:0] flip_rgb;
wire        fb_underrun;
flip_buf #(.W(288), .H(224)) u_flip
(
	.clk(clk_sys), .cen(mm_cen_pix), .flip_en(status[12]),
	.rgb_i({ovl_r, ovl_g, ovl_b}), .de_i(mm_de), .vs_i(mm_vs), .rgb_o(flip_rgb),
	.wr_hold(1'b0), .wr_we(fb_we), .wr_addr(fb_addr), .wr_din(fb_din),
	.rd_req(fl_rd), .rd_addr(fl_addr), .rd_burst(fl_burst), .rd_busy(fl_busy), .rd_data(ddr_dout), .rd_ready(fl_dready),
	.underrun(fb_underrun)
);

// the finished picture's signals, one clock later, before they meet the CRT Adjust select: the long path from the
// 68000's registers through the diagnostic overlay's address squares ends in this register instead of behind the select
reg [23:0] vq_rgb;
reg        vq_hb, vq_hbh, vq_vb, vq_hs, vq_vs, vq_ce;
always @(posedge clk_sys) begin
	vq_rgb <= flip_rgb; vq_hb <= hblank_c; vq_hbh <= ~mm_hde; vq_vb <= mm_vb; vq_hs <= mm_hs; vq_vs <= mm_vs; vq_ce <= mm_cen_pix;
end

// CRT Adjust: the size, horizontal position and vertical position of the picture on a 15 kHz analog output
// (rmonic79's MiSTer-CRT-Adjust, modules/crt-adjust). The picture goes through a line buffer and is read out
// at a different pixel rate (H-Size) or a different place in the line (H-Position), and the vertical sync is
// delayed by whole lines (V-Shift); the sync pulses themselves keep their rate, so the monitor stays locked.
// Off, the picture takes the path it always had. It does nothing while the scandoubler is in use (31 kHz).
wire crt_sd = (|status[5:3]) | forced_scandoubler;
// the visible rows of mm_video (VIS_Y0, VIS_H): the module needs the vertical blank of the *next* line (see below)
localparam [8:0] VIS_Y0 = 9'd17, VIS_H = 9'd224;
wire crt_vb_next = ~(dbg_vcount >= VIS_Y0 - 9'd1 && dbg_vcount < VIS_Y0 + VIS_H - 9'd1);

// the OSD values, as the menu counts them: H-Size 0..+4 then -16..-1, H-Position 0..+20 then -48..-1, V-Shift
// signed 5-bit. The picture is 288 pixels in a line of 384; it starts 72 pixels after the hsync pulse starts and
// ends 24 before the next, so it cannot grow or move right by more than that (+4 is the most H-Size that fits at all)
localparam signed [8:0] CRT_HBIAS = -9'sd1;     // cancels the module's own one-pixel delay of the picture
wire        [4:0] crt_hs_i = status[19:15];
wire signed [5:0] crt_hsz = (crt_hs_i <= 5'd4) ? $signed({1'b0, crt_hs_i}) : $signed({1'b0, crt_hs_i}) - 6'sd21;
wire        [6:0] crt_hp = status[26:20];
wire signed [8:0] crt_hpos = (crt_hp <= 7'd20) ? $signed({2'b00, crt_hp}) : $signed({2'b00, crt_hp}) - 9'sd69;
// the picture is read a line after it is written, so the sync is delayed one line to keep its place; a positive
// V-Shift moves the picture down, which is the sync coming earlier. Negative delays count from the frame length
// the module is built for, which is this game's (264 lines)
wire signed [6:0] crt_vs_t = 7'sd1 - $signed({status[31], status[31], status[31:27]});
reg               crt_on;
reg signed  [4:0] crt_hsize;
reg signed  [8:0] crt_hoff;
reg signed  [5:0] crt_voff;
always @(posedge clk_sys) if (mm_cen_pix) begin
	crt_on    <= status[14] & ~crt_sd;
	crt_hsize <= crt_hsz[4:0];
	crt_hoff  <= crt_hpos + CRT_HBIAS;
	crt_voff  <= crt_vs_t[5:0];
end

// the pixel read enable: one every (64 + H-Size) quarters of a clock (sixteen clocks a pixel at 6 MHz), counted
// from the module's own line reference
wire       crt_hs_ref;
reg        crt_hs_ref_d;
wire [7:0] crt_period = 8'd64 + {{3{crt_hsize[4]}}, crt_hsize};
reg  [7:0] crt_acc;
wire       crt_tick = (crt_acc + 8'd4) >= {1'b0, crt_period};
always @(posedge clk_sys) begin
	crt_hs_ref_d <= crt_hs_ref;
	if      (crt_hs_ref & ~crt_hs_ref_d) crt_acc <= 8'd0;
	else if (crt_tick)                   crt_acc <= crt_acc + 8'd4 - {1'b0, crt_period};
	else                                 crt_acc <= crt_acc + 8'd4;
end
wire crt_rd_en = crt_on ? crt_tick : vq_ce;

wire [7:0] crt_r, crt_g, crt_b;
wire       crt_hs, crt_vs, crt_hb, crt_vb_unused;
crt_adjust #(.VTOTAL(264), .HTOTAL(384), .HPOS_MODE(1)) u_crt
(
	.clk(clk_sys), .pxl_cen(vq_ce), .pxl2_cen(crt_rd_en), .active(crt_on),
	.hsize(crt_hsize), .hoffset(crt_hoff), .voffset(crt_voff),
	.r_in(vq_rgb[23:16]), .g_in(vq_rgb[15:8]), .b_in(vq_rgb[7:0]),
	.hs_in(vq_hs), .vs_in(vq_vs), .hb_in(vq_hb), .vb_in(crt_vb_next),
	.r_out(crt_r), .g_out(crt_g), .b_out(crt_b),
	.hs_out(crt_hs), .vs_out(crt_vs), .hb_out(crt_hb), .vb_out(crt_vb_unused),
	.hs_ref_out(crt_hs_ref)
);

wire vga_de_av;
arcade_video #(.WIDTH(288), .DW(24), .GAMMA(1)) arcade_video
(
	.clk_video(clk_sys),
	.ce_pix(crt_on ? crt_rd_en : vq_ce),
	.RGB_in(crt_on ? {crt_r, crt_g, crt_b} : vq_rgb),
	.HBlank(crt_on ? (crt_hb | crt_hs) : vq_hbh),  // CRT Adjust: nothing of the picture inside the hsync pulse; else the horizontal blank alone
	.VBlank(crt_on ? 1'b0 : vq_vb),             // CRT Adjust: the module's blank already includes the vertical one
	.HSync(crt_on ? crt_hs : vq_hs),
	.VSync(crt_on ? crt_vs : vq_vs),

	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
	.VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(vga_de_av),
	.VGA_SL(VGA_SL),

	.fx(status[5:3]),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus)
);

// Scale: integer scaling on the HDMI scaler (framework module; it measures the picture's rows and width from the
// finished stream, scandoubler and CRT Adjust included, and works out the size from HDMI_WIDTH/HEIGHT). Crop is unused.
// With Normal it adds nothing but a few clocks of delay to VGA_DE.
video_freak video_freak
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),

	.VGA_DE_IN(vga_de_av),
	.ARX(arx),
	.ARY(ary),
	.CROP_SIZE(12'd0),
	.CROP_OFF(5'd0),
	.SCALE(scale_sel)
);

///////////////////////   LED   ///////////////////////

reg [26:0] act_cnt;
always @(posedge clk_sys) act_cnt <= act_cnt + 1'd1;
assign LED_USER = mm_reset ? act_cnt[24] : ~dbg_irq5 | act_cnt[26];

endmodule
