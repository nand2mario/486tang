// Simple SDRAM controller for Tang Mega 60K and Tang SDRAM module
// nand2mario
//
// 2024.10: initial version.
// 2025.08: convert to 32-bit with burst read support.
//
// This is a 32-bit, low-latency and non-bursting controller for accessing the SDRAM module
// on Tang Mega 138K. The SDRAM is 4 banks x 8192 rows x 512 columns x 16 bits (32MB in total).
//
// Read timings (burst_cnt=2):
//   clk        /‾‾‾\___/‾‾‾\___/‾‾‾\___/‾‾‾\___/‾‾‾\___/‾‾‾\___/‾‾‾\___/‾‾‾\___/
//   host       |  req  |       |       |       |       |       |       |  ack  |
//   sdram              |  RAS  |  CAS1 |  CAS2 |  CAS2 |  CAS3 |
//   dq                                         |lo word|hi word|lo word|hi word|
//   ready                                              | ready |       | ready |
//   burst_done                                                         | done  |
//   cycle          0       1       2       3       4       5       6       7
//
// Under default settings (CL2, max 66.7MHz):
// - Read latency is T_RCD + CAS + 2*burst_cnt - 1 cycles from ACT to last data.
// - Write latency: ACT at t0, low-half write at t=T_RCD, high-half write at t=T_RCD+2
//   (auto-precharge on the high half), ack after T_WR from the high half.
// - Read burst of at most 15 32-bit dwords. Bursts must not cross a row boundary.
// - Write is always a single 32-bit word with byte-enable support. No burst write.
// - Refresh is done automatically every ~7.8us when idle and refresh_allowed==1.

module sdram
#(
    // Clock frequency, max 66.7MHz with current set of T_xx/CAS parameters.
    parameter         FREQ = 64_800_000,

    // Time delays for 66.7MHz max clock (min clock cycle 15ns)
    // The SDRAM supports max 166.7MHz (RP/RCD/RC need changes)
    parameter [3:0]   CAS  = 4'd2,     // 2/3 cycles, set in mode register
    parameter [3:0]   T_WR = 4'd2,     // 2 cycles, write recovery
    parameter [3:0]   T_MRD= 4'd2,     // 2 cycles, mode register set
    parameter [3:0]   T_RP = 4'd1,     // 15ns, precharge to active
    parameter [3:0]   T_RCD= 4'd1,     // 15ns, active to r/w
    parameter [3:0]   T_RC = 4'd4      // 60ns, ref/active to ref/active
)
(
    // SDRAM side interface (16-bit data bus)
    inout      [15:0] SDRAM_DQ,
    output     [12:0] SDRAM_A,
    output reg [1:0]  SDRAM_DQM,
    output reg [1:0]  SDRAM_BA,
    output            SDRAM_nWE,
    output            SDRAM_nRAS,
    output            SDRAM_nCAS,
    output            SDRAM_nCS,    // always 0
    output            SDRAM_CKE,    // always 1

    // Logic side interface (32-bit)
    input             clk,
    input             resetn,
    input             nce,            // for x2 wrapper, 1: do not accept new request or auto-refresh 
    input             refresh_allowed,      // set to 1 to allow auto-refresh
    output            busy,

    // 3 requesters, 0 has highest priority
    input             req0,         // request toggle
    output reg        ack0,         // acknowledge toggle (for reads, on LAST data)
    input             wr0,          // 1: write (single dword), 0: read
    input      [24:0] addr0,        // dword address (bits [1:0] ignored)
    input      [31:0] din0,         // 32-bit write data
    output     [31:0] dout0,        // 32-bit read data
    input       [3:0] be0,          // byte enable
    output            ready0,       // pulses when a 32-bit read word is ready
    input       [3:0] burst_cnt0,   // read burst dwords (max 15)
    output            burst_done0,  // pulses when read burst completes

    input             req1,
    output reg        ack1,
    input             wr1,
    input      [24:0] addr1,
    input      [31:0] din1,
    output     [31:0] dout1,
    input       [3:0] be1,
    output            ready1,
    input       [3:0] burst_cnt1,
    output            burst_done1,

    input             req2,
    output reg        ack2,
    input             wr2,
    input      [24:0] addr2,
    input      [31:0] din2,
    output     [31:0] dout2,
    input       [3:0] be2,
    output            ready2,
    input       [3:0] burst_cnt2,
    output            burst_done2
);

if (FREQ > 66_700_000 && CAS == 2)
    $error("ERROR: FREQ must be <= 66.7MHz for CAS=2. Lower FREQ or set CAS=3 and adjust T_RCD etc.");

reg busy_buf = 1'b1;
reg nce_r;
always @(posedge clk) nce_r <= nce;
reg busy_r;
always @(posedge clk) busy_r <= busy;
assign busy = ~nce_r ? busy_buf : busy_r;    // use busy_buf value the next cycle of CE

// Tri-state DQ
reg        dq_oen;          // 0: drive dq_out, 1: Hi-Z
reg [15:0] dq_out;
assign SDRAM_DQ = dq_oen ? {16{1'bZ}} : dq_out;
wire [15:0] dq_in = SDRAM_DQ;

// Command/address
reg [2:0]  cmd;
reg [12:0] a;
assign {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = cmd;
assign SDRAM_A  = a;
assign SDRAM_CKE= 1'b1;
assign SDRAM_nCS= 1'b0;

// Consolidate requester ports (SystemVerilog array-of-ports)
wire        req      [0:2] = '{req0, req1, req2};
wire [24:0] addr     [0:2] = '{addr0, addr1, addr2};
wire [31:0] din      [0:2] = '{din0,  din1,  din2 };
wire        wr       [0:2] = '{wr0,   wr1,   wr2  };
wire [3:0]  be       [0:2] = '{be0,   be1,   be2  };
wire [3:0]  burst_in [0:2] = '{burst_cnt0, burst_cnt1, burst_cnt2};

// Read data path
reg  [31:0] dout_buf [0:2];        // holds last completed word per port
reg  [31:0] dout_word;             // most recent completed word (active port)
reg         data_ready_pulse;      // 1-cycle pulse when a 32-bit word completes

assign ready0 = (req_id_buf == 2'd0) ? data_ready_pulse : 1'b0;
assign ready1 = (req_id_buf == 2'd1) ? data_ready_pulse : 1'b0;
assign ready2 = (req_id_buf == 2'd2) ? data_ready_pulse : 1'b0;

assign dout0  = ready0 ? dout_word : dout_buf[0];
assign dout1  = ready1 ? dout_word : dout_buf[1];
assign dout2  = ready2 ? dout_word : dout_buf[2];

// Burst-done pulse (on final word of a read burst)
reg burst_done_pulse;
assign burst_done0 = (req_id_buf == 2'd0) ? burst_done_pulse : 1'b0;
assign burst_done1 = (req_id_buf == 2'd1) ? burst_done_pulse : 1'b0;
assign burst_done2 = (req_id_buf == 2'd2) ? burst_done_pulse : 1'b0;

// FSM
reg [2:0] state;
localparam INIT    = 3'd0;
localparam CONFIG  = 3'd1;
localparam IDLE    = 3'd2;
localparam READ    = 3'd3;
localparam WRITE   = 3'd5;
localparam REFRESH = 3'd6;

// RAS# CAS# WE#
localparam CMD_SetModeReg  = 3'b000;
localparam CMD_AutoRefresh = 3'b001;
localparam CMD_PreCharge   = 3'b010;
localparam CMD_BankActivate= 3'b011;
localparam CMD_Write       = 3'b100;
localparam CMD_Read        = 3'b101;
localparam CMD_NOP         = 3'b111;

// Mode register: burst length = 1, sequential
localparam [2:0] BURST_LEN   = 3'b000;   // 1
localparam       BURST_MODE  = 1'b0;     // sequential
localparam [10:0] MODE_REG   = {4'b0000, CAS[2:0], BURST_MODE, BURST_LEN};

// Refresh period (~7.8us per row over 64ms total)
localparam REFRESH_CYCLES = (FREQ/1000) * 64 / 8192;

reg cfg_now;

reg [4:0]  cycle;             // small scheduler counter (saturates)
reg [24:0] addr_buf;
reg [31:0] din_buf;
reg [3:0]  be_buf;
reg [1:0]  req_id_buf;

reg [9:0]  refresh_cnt;
reg        need_refresh;

// READ pipeline counters (16-bit halfwords)
reg [4:0]  rd_total_halfs;    // = 2 * effective dword count (<= 30)
reg [4:0]  rd_issued;         // # of CAS commands already issued
reg [4:0]  rd_received;       // # of 16-bit words captured from dq
reg [7:0]  rd_col_base;       // starting dword column (0..255)
reg [15:0] rd_lo16;           // latch low-half before composing 32-bit

// simple refresh request
always @(posedge clk) begin
    if (!resetn) begin
        need_refresh<= 1'b0;
    end else begin
        if (refresh_cnt == 0)
            need_refresh <= 1'b0;
        else if (refresh_cnt == REFRESH_CYCLES)
            need_refresh <= 1'b1;
    end
end

// Main FSM
always @(posedge clk) begin
    automatic reg new_req;
    automatic reg [1:0] req_id;

    // defaults each cycle
    cmd               <= CMD_NOP;
    SDRAM_DQM         <= 2'b00;
    data_ready_pulse  <= 1'b0;
    burst_done_pulse  <= 1'b0;

    // saturating cycle counter
    cycle <= (cycle == 5'd31) ? cycle : (cycle + 5'd1);
    refresh_cnt <= refresh_cnt + 10'd1;

    // Request arbiter (toggle handshake)
    new_req = (req0 ^ ack0) | (req1 ^ ack1) | (req2 ^ ack2);
    req_id  = (req0 ^ ack0) ? 2'd0 :
              (req1 ^ ack1) ? 2'd1 : 2'd2;

    case (state)
    // Power-on wait → CONFIG sequence
    INIT: begin
        if (cfg_now) begin
            state  <= CONFIG;
            cycle  <= 5'd0;
        end
        busy_buf <= 1'b1;
        dq_oen   <= 1'b1;     // tri-state DQ during init
    end

    CONFIG: begin
        // t=0: PRECHG ALL
        if (cycle == 5'd0) begin
            cmd   <= CMD_PreCharge;
            a[10] <= 1'b1;                // precharge all
        end
        // t=T_RP: AutoRefresh #1
        if (cycle == T_RP) begin
            cmd <= CMD_AutoRefresh;
        end
        // t=T_RP+T_RC: AutoRefresh #2
        if (cycle == (T_RP+T_RC)) begin
            cmd <= CMD_AutoRefresh;
        end
        // t=T_RP+2*T_RC: Set Mode Register
        if (cycle == (T_RP+T_RC+T_RC)) begin
            cmd     <= CMD_SetModeReg;
            a[10:0] <= MODE_REG;
        end
        // t=...+T_MRD: done
        if (cycle == (T_RP+T_RC+T_RC+T_MRD)) begin
            state      <= IDLE;
            busy_buf   <= 1'b0;
            refresh_cnt<= 0;
        end
    end

    IDLE: if (~nce) begin     // change state on when nce == 0
        busy_buf <= 1'b0;
        if (new_req) begin
            // Latch request
            addr_buf       <= addr[req_id];
            din_buf        <= din [req_id];
            be_buf         <= be  [req_id];
            req_id_buf     <= req_id;

            // ACT to selected bank/row
            cmd       <= CMD_BankActivate;
            SDRAM_BA  <= addr[req_id][24:23];
            a         <= addr[req_id][22:10];     // row
            busy_buf  <= 1'b1;
            cycle     <= 5'd1;

            if (wr[req_id]) begin
                state <= WRITE;
            end else begin
                automatic reg [3:0] eff_burst;
                // Compute effective burst length clamped to row end (256 dword columns per row)
                rd_col_base     <= addr[req_id][9:2];     // dword column
                eff_burst       = (burst_in[req_id] == 0) ? 1 : burst_in[req_id];
                rd_total_halfs  <= {eff_burst,1'b0};     // *2
                rd_issued       <= 5'd0;
                rd_received     <= 5'd0;
                state           <= READ;
            end
        end else if (need_refresh && refresh_allowed) begin
            // Auto-refresh when idle
            cmd         <= CMD_AutoRefresh;
            refresh_cnt <= 0;
            busy_buf    <= 1'b1;
            cycle       <= 5'd1;
            state       <= REFRESH;
        end
    end

    // Issue length-1 READ commands every cycle after T_RCD.
    // Each READ returns one 16-bit half. We compose 32-bit words from pairs.
    READ: begin
        // Issue CAS READ one per cycle once T_RCD reached
        if ((cycle >= T_RCD) && (rd_issued < rd_total_halfs)) begin
            automatic reg [8:0] col16;
            cmd      <= CMD_Read;
            SDRAM_BA <= addr_buf[24:23];
            // Column: {dword_col + (rd_issued>>1), half_bit}
            // A[12:0] = {A12..A11=0, A10=auto-pre(last half), A9=0, A8..A0=column[8:0]}
            col16     = { (rd_col_base + (rd_issued[4:1])), rd_issued[0] };
            a         <= {2'b00, (rd_issued == rd_total_halfs-1), 1'b0, col16};
            rd_issued <= rd_issued + 5'd1;
        end

        // Capture returning 16-bit data after CAS latency
        if ((cycle >= (T_RCD + CAS + 1)) && (rd_received < rd_issued)) begin
            if (!rd_received[0]) begin
                rd_lo16 <= dq_in;                 // low half
            end else begin
                dout_word <= {dq_in, rd_lo16};    // high half completes a 32-bit word
                data_ready_pulse <= 1'b1;
                // Update per-port holding register so dout* remains valid after the pulse
                dout_buf[req_id_buf] <= {dq_in, rd_lo16};

                // If that was the last half in the burst, also toggle ack/burst_done and go idle
                if (rd_received + 5'd1 == rd_total_halfs) begin
                    case (req_id_buf)
                        2'd0: ack0 <= req0;
                        2'd1: ack1 <= req1;
                        2'd2: ack2 <= req2;
                    endcase
                    burst_done_pulse <= 1'b1;
                    busy_buf <= 1'b0;
                    state    <= IDLE;
                end
            end
            rd_received <= rd_received + 5'd1;
        end
    end

    // Single 32-bit write = two 16-bit WRITEs (low-half then high-half with auto-precharge)
    WRITE: begin
        // low half at T_RCD
        if (cycle == T_RCD) begin
            cmd      <= CMD_Write;
            SDRAM_BA <= addr_buf[24:23];
            a        <= {2'b00, 1'b0/*no AP*/, 1'b0, {addr_buf[9:2], 1'b0}};
            SDRAM_DQM<= {~be_buf[1], ~be_buf[0]};
            dq_out   <= din_buf[15:0];
            dq_oen   <= 1'b0;
        end
        // release bus
        if (cycle == (T_RCD+1)) begin
            dq_oen <= 1'b1;
        end
        // high half at T_RCD+2 with auto-precharge
        if (cycle == (T_RCD+2)) begin
            cmd      <= CMD_Write;
            SDRAM_BA <= addr_buf[24:23];
            a        <= {2'b00, 1'b1/*AP*/, 1'b0, {addr_buf[9:2], 1'b1}};
            SDRAM_DQM<= {~be_buf[3], ~be_buf[2]};
            dq_out   <= din_buf[31:16];
            dq_oen   <= 1'b0;
        end
        if (cycle == (T_RCD+3)) begin
            dq_oen <= 1'b1;
        end
        // ack after write recovery from the last write
        if (cycle == (T_RCD+3+T_WR-1)) begin
            case (req_id_buf)
                2'd0: ack0 <= req0;
                2'd1: ack1 <= req1;
                2'd2: ack2 <= req2;
            endcase
            busy_buf <= 1'b0;
            state    <= IDLE;
        end
    end

    REFRESH: begin
        if (cycle == T_RC) begin
            state    <= IDLE;
            busy_buf <= 1'b0;
        end
    end

    default: state <= IDLE;
    endcase

    // Reset
    if (!resetn) begin
        state      <= INIT;
        busy_buf   <= 1'b1;
        dq_oen     <= 1'b1;
        SDRAM_DQM  <= 2'b00;
        SDRAM_BA   <= 2'b00;
        a          <= 13'd0;
        cmd        <= CMD_NOP;

        cycle      <= 5'd0;
        refresh_cnt<= 10'd0;

        ack0 <= 1'b0;
        ack1 <= 1'b0;
        ack2 <= 1'b0;

        dout_buf[0] <= 32'd0;
        dout_buf[1] <= 32'd0;
        dout_buf[2] <= 32'd0;

        rd_total_halfs <= 5'd0;
        rd_issued      <= 5'd0;
        rd_received    <= 5'd0;

        data_ready_pulse <= 1'b0;
        burst_done_pulse <= 1'b0;
    end
end

// Generate cfg_now pulse after initialization delay (normally 200us)
reg  [23:0]   rst_cnt;        // enough for 200us at ~65MHz
reg           rst_done, rst_done_p1;

always @(posedge clk) begin
    rst_done_p1 <= rst_done;
    cfg_now     <= rst_done & ~rst_done_p1;     // rising edge

    if (rst_cnt != (FREQ/1000)*200/1000) begin  // count to 200us
        rst_cnt  <= rst_cnt + 24'd1;
        rst_done <= 1'b0;
    end else begin
        rst_done <= 1'b1;
    end

    if (!resetn) begin
        rst_cnt  <= 24'd0;
        rst_done <= 1'b0;
    end
end

endmodule
