//------------------------------------------------------------------------------
// Raster timing for Monster Maulers: the K053252's job, at this board's settings.
//
// 6 MHz pixel clock (the chip's 24 MHz input / 4), 384 x 264 -> 15.625 kHz,
// 59.1856 Hz; visible 288 x 224 at origin (24, 17). The game programs the chip
// once at boot (registers 0/1 = 0x017F H max, 2/3 = 0x0019, 4/5 = 0x0027,
// 8/9 = 0x0107 V max, 10 = 0x10, 11 = 0x0F, 12 = 0x73) and SiliconRE's model of the
// chip, run with those values (not kept in this repository), gives:
//   hblank 96 pixels, starting at the end of the picture; hsync 32 pixels, 24
//   after hblank starts; vblank 40 lines (17 before the picture, 23 after it);
//   vsync 8 lines, 16 lines after vblank starts, so it wraps over the frame's end.
// That is MAME's raster for this driver too (set_raw(6 MHz, 384, ..., 264)); unlike
// Gaiapolis there is nothing to choose between.
//
// Each visible line is rendered into the line buffers during the line before
// it: at the start of raster line r this pulses `line_start` for line r+1,
// and the renderers have the full 384-pixel line (6,144 clocks) to finish.
// If any is still busy at the next pulse, `overrun` pulses for that line -- that is
// the budget being exceeded, and it must never be silent.
//
// Scan-out: `px` is the visible pixel index of the pixel period that is
// running; the line buffers and mixer need a few clocks after `px` changes, so
// the colour is stable by the cen_pix tick that ends the period, and de/hs/vs
// change at the same ticks as px and px_valid -- level with px, which is
// what the colour at that tick belongs to. (A frame rendered by the machine
// against MAME's of the same state is the check: sim/tb_mm.cpp with
// DUMPSTATE, see tools/cmp_state.py. The signals were once delayed by one
// further pixel, which showed the picture from its second column.)
//------------------------------------------------------------------------------
`default_nettype none

module mm_video #(
    parameter int HTOTAL   = 384,
    parameter int VTOTAL   = 264,
    parameter int HS_START = 336,     // 24 pixels after hblank starts (the picture ends at 312)
    parameter int HS_LEN   = 32,
    parameter int VS_START = 257,     // 16 lines after vblank starts at 241
    parameter int VS_LEN   = 8,       // ... to line 0 of the next frame
    parameter int VIS_W  = 288,
    parameter int VIS_H  = 224,
    parameter int VIS_X0 = 24,
    parameter int VIS_Y0 = 17
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        cen_pix,        // 6 MHz

    // to the renderers
    output logic        line_start,
    output logic  [8:0] render_line,
    output logic        prestart,       // one pulse a few raster lines before the visible area (the ROZ plane pre-renders)
    input  logic  [2:0] renderers_busy, // {tilemap, ROZ, sprites}
    output logic        overrun,
    output logic        overrun_line,   // one clock per line that began with a renderer still busy (`overrun` is a level that holds)
    output logic  [2:0] overrun_src,    // which of them, with the pulse

    // scan-out
    output logic  [8:0] px,             // visible pixel index, valid with px_valid
    output logic        px_valid,
    output logic  [8:0] hcount,
    output logic  [8:0] vcount,

    // timing, level with px (aligned with the mixer's rgb at the cen_pix that ends the pixel)
    output logic        hsync,
    output logic        vsync,
    output logic        de,
    output logic        hde,            // de without the vertical window: the horizontal blank alone, on every line
    output logic        vblank,
    output logic        vblank_rise     // one clk pulse at the start of vblank
);
    logic in_active_x, in_active_y;
    assign in_active_x = (hcount >= 9'(VIS_X0)) && (hcount < 9'(VIS_X0 + VIS_W));
    assign in_active_y = (vcount >= 9'(VIS_Y0)) && (vcount < 9'(VIS_Y0 + VIS_H));

    logic vb_r;
    logic vb_prev;

    localparam int VS_END_WRAPPED = VS_START + VS_LEN - VTOTAL;     // > 0 when the window wraps the frame
    wire hs_c = (hcount >= 9'(HS_START)) && (hcount < 9'(HS_START + HS_LEN));
    wire vs_c = (vcount >= 9'(VS_START)) || (VS_END_WRAPPED > 0 && vcount < 9'(VS_END_WRAPPED < 0 ? 0 : VS_END_WRAPPED));

    always_ff @(posedge clk) begin
        line_start  <= 1'b0;
        overrun_line <= 1'b0;
        prestart    <= 1'b0;
        vblank_rise <= 1'b0;
        if (reset) begin
            hcount <= '0; vcount <= '0; overrun <= 1'b0; overrun_src <= '0;
            hsync <= 1'b0; vsync <= 1'b0; de <= 1'b0; hde <= 1'b0; vblank <= 1'b1; vb_prev <= 1'b1;
            px <= '0; px_valid <= 1'b0; render_line <= '0;
        end else if (cen_pix) begin
            // raster counters
            if (hcount == 9'(HTOTAL - 1)) begin
                hcount <= '0;
                vcount <= (vcount == 9'(VTOTAL - 1)) ? 9'd0 : vcount + 9'd1;
            end else hcount <= hcount + 9'd1;

            // start rendering the next line as this one begins
            if (hcount == 9'd0) begin
                logic [8:0] nxt;
                nxt = (vcount == 9'(VTOTAL - 1)) ? 9'd0 : vcount + 9'd1;
                // ... including the pulse after the last visible line, so the
                // renderers hand over their last buffer as they do every other
                if (nxt >= 9'(VIS_Y0) && nxt <= 9'(VIS_Y0 + VIS_H)) begin
                    line_start  <= 1'b1;
                    render_line <= nxt;
                    overrun <= |renderers_busy;     // a level: it stays up over consecutive overrunning lines
                    overrun_line <= |renderers_busy;
                    overrun_src <= renderers_busy;
                end
                if (vcount == 9'(VIS_Y0 - 6)) prestart <= 1'b1;
            end

            // scan-out address for this pixel
            px       <= hcount - 9'(VIS_X0);
            px_valid <= in_active_x && in_active_y;

            // timing outputs, level with px / px_valid (and so with the colour that ends this period)
            de     <= in_active_x && in_active_y;
            hde    <= in_active_x;
            hsync  <= hs_c;
            vsync  <= vs_c;
            vb_r   <= !in_active_y;
            vblank <= !in_active_y;

            vb_prev <= vb_r;
            if (vb_r && !vb_prev) vblank_rise <= 1'b1;
        end
    end
endmodule
