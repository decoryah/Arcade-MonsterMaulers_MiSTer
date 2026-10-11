//------------------------------------------------------------------------------
// Sprite row cache: a direct-mapped cache of 16-pixel sprite rows (80 bits) in
// front of the sprite ROM's request/ack port.
//
// Why: the Red Dragon fight puts well over a hundred tile fetches on its
// heaviest lines (the dragon's neck is a chain of 4x4 objects of the same tile
// set, its shadow a chain of 4x1 strips of one more), and every fetch costs the
// SDRAM's latency, tens of clocks, so those lines overran the 6,144-clock
// budget and the objects drawn last (the fighters) lost their lower rows. The
// rows those objects ask for are the same few hundred, line after line and
// frame after frame, so almost all of them hit here and cost three clocks.
//
// Port protocol is the renderer's: a level request with its address held, a
// one-clock ack that carries the data on the same cycle, a request that may be
// withdrawn at any time (then no ack comes). The memory side is the same.
// The cache is cleared for 512 clocks after reset; requests wait for it.
//------------------------------------------------------------------------------
`default_nettype none

module spr_rowcache #(
    parameter int AW = 20,                // {code[15:0], row[3:0]}
    parameter int DW = 80,
    parameter int IW = 9                  // 512 rows
) (
    input  logic          clk,
    input  logic          reset,          // the machine's reset, which a ROM load holds

    // client (the renderer)
    input  logic          c_req,
    input  logic [AW-1:0] c_addr,
    output logic          c_ack,
    output logic [DW-1:0] c_q,

    // memory (towards the arbiter)
    output logic          m_req,
    output logic [AW-1:0] m_addr,
    input  logic          m_ack,
    input  logic [DW-1:0] m_q,

    // statistics for the benches
    output logic [31:0]   dbg_hits, dbg_misses
);
    localparam int TW = AW - 4;           // the code
    localparam int NE = 1 << IW;

    // the index: the row, and the code's bits folded so that the tiles of one
    // object, and the same tile numbers in different banks, fall apart
    function automatic logic [IW-1:0] index(input logic [AW-1:0] a);
        logic [4:0] f;
        f = a[8:4] ^ a[13:9] ^ a[18:14] ^ {4'd0, a[19]};
        return {f, a[3:0]};
    endfunction

    logic [DW-1:0] dmem [NE];
    logic [TW:0]   tmem [NE];             // {valid, code}

    typedef enum logic [2:0] { S_CLR, S_IDLE, S_LOOK, S_RESP, S_MISS } state_t;
    state_t st;

    logic [IW-1:0] clr_i;
    logic [AW-1:0] a_r;
    logic [DW-1:0] d_q, hit_d;
    logic [TW:0]   t_q;
    logic [IW-1:0] rd_idx;
    logic [IW-1:0] idx_a;

    assign idx_a  = index(a_r);
    assign rd_idx = index(c_addr);        // the read address is the client's, the cycle the request is seen

    always_ff @(posedge clk) begin
        d_q <= dmem[rd_idx];
        t_q <= tmem[rd_idx];
    end

    wire hit = t_q[TW] && (t_q[TW-1:0] == a_r[AW-1:4]);

    // one write port: the clear, then the fills
    wire fill = (st == S_MISS) && m_ack && c_req && (c_addr == a_r);
    always_ff @(posedge clk) begin
        if (st == S_CLR) tmem[clr_i] <= '0;
        else if (fill) begin
            tmem[idx_a] <= {1'b1, a_r[AW-1:4]};
            dmem[idx_a] <= m_q;
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            st <= S_CLR; clr_i <= '0;
            dbg_hits <= '0; dbg_misses <= '0;
        end else begin
            case (st)
                S_CLR: begin
                    clr_i <= clr_i + 1'd1;
                    if (clr_i == IW'(NE - 1)) st <= S_IDLE;
                end
                S_IDLE: if (c_req) begin
                    a_r <= c_addr;
                    st  <= S_LOOK;
                end
                S_LOOK: begin
                    if (!c_req || c_addr != a_r) st <= S_IDLE;
                    else if (hit) begin hit_d <= d_q; dbg_hits <= dbg_hits + 1'd1; st <= S_RESP; end
                    else begin dbg_misses <= dbg_misses + 1'd1; st <= S_MISS; end
                end
                S_RESP: st <= S_IDLE;                      // the ack (below) is this cycle's
                S_MISS: begin
                    if (!c_req || c_addr != a_r || m_ack) st <= S_IDLE;
                end
                default: st <= S_IDLE;
            endcase
        end
    end

    assign m_req  = (st == S_MISS) && c_req && (c_addr == a_r);
    assign m_addr = a_r;
    assign c_ack  = ((st == S_RESP) && c_req && (c_addr == a_r)) || fill;
    assign c_q    = (st == S_RESP) ? hit_d : m_q;
endmodule
