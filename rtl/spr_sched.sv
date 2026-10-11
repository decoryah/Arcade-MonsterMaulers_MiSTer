//------------------------------------------------------------------------------
// Sprite line scheduler: when the drawer works on which line.
//
// The drawer used to be pulsed once per raster line, for the line after the
// one being scanned out, and had that one line period (6,144 clocks) to
// finish whatever the line held. A line with a hundred and seventy tile rows
// on it (the Red Dragon's neck and its shadow, a fighter in front of them)
// takes longer than that at the SDRAM's latency, and the objects drawn last
// were lost -- the fighters' lower legs. The lines before it are light.
//
// Now the drawer runs ahead through a ring of line buffers, as far as the
// ring allows: it starts the next line as soon as it is idle, provided the
// slot that line will use has been scanned out. A heavy run of lines borrows
// the time the light lines left, and only a run longer than the ring can bank
// is late.
//
//   * lines are numbered as the raster counts them (the first visible one is
//     VIS_Y0), and line L lives in ring slot L mod 2**SB;
//   * the list is rebuilt once a frame (list_rebuild), which stops the drawer
//     and drops whatever it was doing; the list done pulse arms the next
//     frame, whose first visible line is begun 2**SB - 1 raster lines early;
//   * `late` is what mm_video samples at a line's start: the line about to be
//     scanned out is not finished;
//   * a line is given until the scan-out reaches its first pixel (the old
//     drawer's one line period, and more when the lead was banked); then it is
//     dropped as it stands -- whatever was drawn is what shows, the objects
//     drawn first -- and the next line begun. In an overload that is what the
//     per-line pulse did, so the picture degrades the same way; a line dropped
//     while its slot was still being cleared shows nothing (rd_ok), not what
//     the slot held eight lines ago.
//------------------------------------------------------------------------------
`default_nettype none

module spr_sched #(
    parameter int SB     = 2,            // ring of 2**SB lines
    parameter int VIS_Y0 = 17,
    parameter int VIS_H  = 224,
    parameter int VIS_X0 = 24
) (
    input  logic       clk,
    input  logic       reset,
    input  logic [8:0] vcount,           // the raster line being scanned (changes in the blanking)
    input  logic [8:0] hcount,           // the pixel period in it; the picture starts at VIS_X0
    input  logic       dr_clearing,      // the drawer is clearing the slot it started on
    input  logic       list_rebuild,     // one pulse: the list is about to be rebuilt
    input  logic       list_done,        // one pulse: the new list is ready
    input  logic       dr_busy,

    output logic       line_start,       // to the drawer
    output logic [8:0] line,             // held while the drawer is busy with it
    output logic       abort,
    output logic       late,             // the line being scanned out was not finished in time
    output logic       rd_ok,            // the slot being scanned holds a line that was started this frame
    output logic [8:0] done_line         // the last line finished (for the benches)
);
    localparam logic [8:0] LAST  = 9'(VIS_Y0 + VIS_H - 1);
    localparam logic [8:0] FIRST = 9'(VIS_Y0);
    localparam int         LEAD  = (1 << SB) - 1;

    logic        active;                 // a list is valid for the frame about to be (or being) shown
    logic [8:0]  next_l;                 // the next line to start
    logic [1:0]  run;                    // 0 idle, 1 start issued, 2 drawing
    logic [8:0]  cur_l;
    logic [8:0]  tag [1 << SB];          // the line last started in each slot, 0 = none

    wire vis    = (vcount >= FIRST) && (vcount <= LAST);
    // the line the lead is counted from: the one being shown, before the picture the raster line itself (so the
    // first line is begun SB lines of time ahead, no earlier: the CPU may still be writing the chips' registers, which
    // the drawer reads as it goes), and in the vblank after the picture none (the list is about to be rebuilt)
    wire [8:0] ref_l = vis ? vcount : ((vcount < FIRST) ? vcount : 9'd0);
    wire [9:0] limit = {1'b0, ref_l} + 10'(LEAD);

    always_ff @(posedge clk) begin
        line_start <= 1'b0;
        abort      <= 1'b0;
        if (reset) begin
            active <= 1'b0; run <= 2'd0; next_l <= FIRST; done_line <= FIRST - 9'd1; line <= FIRST;
            for (int i = 0; i < (1 << SB); i++) tag[i] <= 9'd0;
        end else begin
            if (list_rebuild) begin
                active <= 1'b0;
                if (run != 2'd0) abort <= 1'b1;
                run <= 2'd0;
                for (int i = 0; i < (1 << SB); i++) tag[i] <= 9'd0;
            end else if (list_done) begin
                active <= 1'b1; next_l <= FIRST; done_line <= FIRST - 9'd1; run <= 2'd0;
                for (int i = 0; i < (1 << SB); i++) tag[i] <= 9'd0;
            end else begin
                case (run)
                    2'd0: if (active && next_l <= LAST) begin
                        if (vis && next_l < vcount) next_l <= vcount;       // (never expected: a line is dropped as its picture starts)
                        else if ({1'b0, next_l} <= limit) begin
                            line <= next_l; cur_l <= next_l; next_l <= next_l + 9'd1;
                            tag[next_l[SB-1:0]] <= next_l;
                            line_start <= 1'b1; run <= 2'd1;
                        end
                    end
                    2'd1: if (dr_busy) run <= 2'd2;
                    2'd2: begin
                        if (!dr_busy) begin done_line <= cur_l; run <= 2'd0; end
                        else if (vis && (cur_l < vcount || (cur_l == vcount && hcount >= 9'(VIS_X0)))) begin
                            // its time is up: keep what is drawn (not done: `late` stays up until a line is)
                            abort <= 1'b1; run <= 2'd0;
                            if (dr_clearing) tag[cur_l[SB-1:0]] <= 9'd0;
                        end
                    end
                    default: run <= 2'd0;
                endcase
            end
        end
    end

    // mm_video's sample, at a visible line's start: has the line that is about to be shown been finished?
    assign late  = active && vis && (done_line < vcount);
    assign rd_ok = (tag[vcount[SB-1:0]] == vcount);
endmodule
