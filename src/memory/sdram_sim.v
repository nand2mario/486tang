// Simulation model for sdram.v
// - 3 ports
// - 32-bit interface on 16-bit SDRAM
// - CL2
// - singlr or burst read, single write
module sdram
#(
    parameter         FREQ = 50_000_000  // Dummy parameter for compatibility
)
(
    // SDRAM side interface (dummy pins for simulation)
    inout      [15:0] SDRAM_DQ,
    output     [12:0] SDRAM_A,
    output     [1:0]  SDRAM_DQM,
    output     [1:0]  SDRAM_BA,
    output            SDRAM_nWE,
    output            SDRAM_nRAS,
    output            SDRAM_nCAS,
    output            SDRAM_nCS,
    output            SDRAM_CKE,
    
    // Logic side interface
    input             clk,
    input             resetn,
    input             refresh_allowed,
    output            busy,

    // Port 0 - higher priority
    input             req0,         // request toggle
    output reg        ack0,         // acknowledge toggle (req0==ack0 is also burstdone)
    input             wr0,          // 1: write, 0: read
    input      [24:0] addr0,        // address
    input      [31:0] din0,         // data input
    output reg [31:0] dout0,        // data output
    input       [3:0] be0,          // byte enable
    output            ready0,       // data ready
    input       [3:0] burst_cnt0,   // burst count for reads (max 15 - 60 bytes)
    output            burst_done0,  // burst done signal

    // Port 1
    input             req1, 
    output reg        ack1, 
    input             wr1,
    input      [24:0] addr1,
    input      [31:0] din1,
    output reg [31:0] dout1,
    input       [3:0] be1,
    output            ready1,
    input       [3:0] burst_cnt1,
    output            burst_done1,

    // Port 2
    input             req2, 
    output reg        ack2, 
    input             wr2,
    input      [24:0] addr2,
    input      [31:0] din2,
    output reg [31:0] dout2,
    input       [3:0] be2,
    output            ready2,
    input       [3:0] burst_cnt2,
    output            burst_done2
);

// Expose for Verilator C++ testbench via hierarchy access
reg [15:0] mem [0:16*1024*1024-1] /* verilator public_flat_rw */ ;  // 32MB of memory
reg [2:0] cycle;
reg busy_buf = 1;
assign busy = busy_buf;

reg [3:0] start_cnt = 15;
reg [3:0] burst_cnt;

reg [2:0] state;
reg [1:0] port;
localparam IDLE = 0;
localparam RAS = 1;
localparam CAS0 = 2;
localparam CAS1 = 3;
// localparam READY = 4;

reg [24:1] addr;
reg [31:0] din;
reg wr;
reg [3:0] be;
reg hi;

wire [15:0] din16 = hi ? din[31:16] : din[15:0];

always @(posedge clk) begin
    start_cnt <= start_cnt == 0 ? 0 : start_cnt - 1;
    if (start_cnt == 1)
        busy_buf <= 0;

    ready0 <= 0; ready1 <= 0; ready2 <= 0;
    burst_done0 <= 0; burst_done1 <= 0; burst_done2 <= 0;
    case (state)
    IDLE: begin
        if (req0 != ack0) begin
            addr <= {addr0[24:2],1'b0};  // convert to 16-bit word address
            din <= din0;
            wr <= wr0;
            be <= be0;
            burst_cnt <= burst_cnt0;
            port <= 0;
            busy_buf <= 1;
            state <= RAS;
        end else if (req1 != ack1) begin
            addr <= {addr1[24:2],1'b0};
            din <= din1;
            wr <= wr1;
            be <= be1;
            burst_cnt <= burst_cnt1;
            port <= 1;
            busy_buf <= 1;
            state <= RAS;
        end else if (req2 != ack2) begin
            addr <= {addr2[24:2],1'b0};
            din <= din2;
            wr <= wr2;
            be <= be2;
            port <= 2;
            busy_buf <= 1;
            state <= RAS;
        end
    end

    RAS: state <= CAS0;

    CAS0: begin          // leading wait cycle
        hi <= 0;         // start from lower 16-bit
        state <= CAS1;   
        // Debug VGA memory writes (0xA0000-0xBFFFF range)
        // if (wr && addr >= 'h780 && addr < 'hA00)  // text mode text line 3
        //     $display("SDRAM WRITE port%d [%06h]=%h be=%h", port, addr, din, be);
    end

    CAS1: begin          // process one 16-bit word per cycle
        if (wr) begin
            if (be[{hi,1'b0}]) begin
                mem[addr][7:0] <= din16[7:0];
                // $display("sdram_sim: low[%h] = %h", addr, din16[7:0]);
            end
            if (be[{hi,1'b1}]) begin
                mem[addr][15:8] <= din16[15:8];
                // $display("sdram_sim: high[%h] = %h", addr, din16[15:8]);
            end
        end else begin
            if (port == 0) begin
                if (hi) dout0[31:16] <= mem[addr];
                else    dout0[15:0] <= mem[addr];
                if (hi) begin
                    ready0 <= 1;
                    // if ({addr,1'b0} == 25'hC0600)
                    //     $display("sdram_sim: dout[%h] = %h", addr, {mem[addr], dout0[15:0]});
                end
                if (hi && burst_cnt <= 1) begin
                    burst_done0 <= 1;
                end
                if ({addr,1'b0} == 25'hC0600)
                    $display("sdram[%h] = %h", {addr,1'b0}, mem[addr]);
            end else if (port == 1) begin
                if (hi) dout1[31:16] <= mem[addr];
                else    dout1[15:0] <= mem[addr];
                if (hi) ready1 <= 1;
                if (hi && burst_cnt <= 1) begin
                    burst_done1 <= 1;
                end
            end else begin
                if (hi) dout2[31:16] <= mem[addr];
                else    dout2[15:0] <= mem[addr];
                if (hi) ready2 <= 1;
                if (hi && burst_cnt <= 1) begin
                    burst_done2 <= 1;
                end
            end
        end
        addr <= addr + 1;
        if (hi) begin
            if (burst_cnt <= 1 || wr) begin  // all done
                state <= IDLE;
                busy_buf <= 0;
                if (port == 0) begin
                    ack0 <= req0;
                end else if (port == 1) begin
                    ack1 <= req1;
                end else if (port == 2) begin
                    ack2 <= req2;
                end
            end
            burst_cnt <= burst_cnt - 1;
        end
        hi <= ~hi;
    end

    default: ;

    endcase
end

endmodule
