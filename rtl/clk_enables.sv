//------------------------------------------------------------------------------
// Clock enables from the 96 MHz system clock.
//   cen_16m : 96 / 6   68000
//   cen_8m  : 96 / 12  Z80
//   cen_pix : 96 / 16  video: the K053252's 6 MHz pixel clock (384 clocks of it
//                      make the 64 us line, 6,144 system clocks)
//   cen_48k : 96 / 2000 K054539 sample rate (18.432 MHz / 384)
//------------------------------------------------------------------------------
`default_nettype none

module clk_enables (
    input  logic clk,
    input  logic reset,
    output logic cen_16m,
    output logic cen_8m,
    output logic cen_pix,
    output logic cen_48k
);
    logic [3:0] div;
    logic [3:0] pdiv;
    logic [10:0] sdiv;
    always_ff @(posedge clk) begin
        if (reset) begin
            div <= '0; pdiv <= '0; sdiv <= '0;
            cen_16m <= 1'b0; cen_8m <= 1'b0; cen_pix <= 1'b0; cen_48k <= 1'b0;
        end else begin
            sdiv    <= (sdiv == 11'd1999) ? 11'd0 : sdiv + 11'd1;
            cen_48k <= (sdiv == 11'd1999);
            div     <= (div == 4'd11) ? 4'd0 : div + 4'd1;
            cen_16m <= (div == 4'd11) || (div == 4'd5);
            cen_8m  <= (div == 4'd11);
            pdiv    <= pdiv + 4'd1;
            cen_pix <= (pdiv == 4'd15);
        end
    end
endmodule
