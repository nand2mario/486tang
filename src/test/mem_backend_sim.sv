// Not used by memtest_top anymore.
// 
// Simple memory backend model for main_memory.sv interface
// - 32-bit data, byte enables
// - Supports single and burst reads; single and burst writes (treated per-cycle)
// - Zero wait-state (mem_busy=0); read data returned with 1-cycle latency per beat
module mem_backend_sim (
    input             clk,
    input             reset,

    input      [31:0] mem_addr,
    input      [31:0] mem_din,
    output reg [31:0] mem_dout,
    output reg        mem_dout_ready,
    input      [3:0]  mem_be,
    input      [7:0]  mem_burstcount,
    output            mem_busy,
    input             mem_rd,
    input             mem_we
);

assign mem_busy = 1'b0;

localparam WORDS = 1<<20; // 4MB (WORDS of 32-bit)
reg [31:0] ram [0:WORDS-1];

reg read_active;
reg [31:0] read_addr;
reg [7:0]  read_remaining;

wire [31:0] word_addr = {mem_addr[31:2], 2'b00};

always @(posedge clk) begin
    mem_dout_ready <= 1'b0;
    if (reset) begin
        read_active <= 1'b0;
        read_remaining <= 8'd0;
    end else begin
        // Start a read burst on mem_rd if idle
        if (mem_rd && !read_active) begin
            read_active   <= 1'b1;
            read_addr     <= word_addr;
            read_remaining<= (mem_burstcount == 0) ? 8'd1 : mem_burstcount;
        end

        // Process an active read: 1 beat per cycle
        if (read_active) begin
            mem_dout       <= ram[read_addr[31:2]];
            mem_dout_ready <= 1'b1;
            read_addr      <= {read_addr[31:2] + 30'd1, 2'b00};
            if (read_remaining <= 8'd1) begin
                read_active <= 1'b0;
                read_remaining <= 8'd0;
            end else begin
                read_remaining <= read_remaining - 8'd1;
            end
        end

        // Writes: perform immediately on each cycle mem_we is asserted
        if (mem_we) begin
            reg [31:0] cur;
            reg [31:0] nxt;
            cur = ram[word_addr[31:2]];
            nxt[7:0]   =  mem_be[0] ? mem_din[7:0]   : cur[7:0];
            nxt[15:8]  =  mem_be[1] ? mem_din[15:8]  : cur[15:8];
            nxt[23:16] =  mem_be[2] ? mem_din[23:16] : cur[23:16];
            nxt[31:24] =  mem_be[3] ? mem_din[31:24] : cur[31:24];
            ram[word_addr[31:2]] <= nxt;
        end
    end
end

endmodule

