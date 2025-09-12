// Top-level test wrapper for main_memory + mem_backend_sim
module memtest_top (
    input             clk,
    input             reset,

    // CPU-side interface into main_memory
    input      [31:0] cpu_addr,
    input      [31:0] cpu_din,
    output     [31:0] cpu_dout,
    output            cpu_dout_ready,
    input      [3:0]  cpu_be,
    input      [7:0]  cpu_burstcount,
    output            cpu_busy,
    input             cpu_rd,
    input             cpu_we
);

wire [31:0] mem_addr;
wire [31:0] mem_din;
wire [31:0] mem_dout;
wire        mem_dout_ready;
wire [3:0]  mem_be;
wire [7:0]  mem_burstcount;
wire        mem_busy;
wire        mem_rd;
wire        mem_we;

wire [16:0] vga_address;
wire [7:0]  vga_readdata = 8'h00;
wire [7:0]  vga_writedata;
wire        vga_read;
wire        vga_write;
wire [2:0]  vga_memmode = 3'b000; // default branch disables VGA region inside main_memory
wire [5:0]  vga_wr_seg = 6'd0;
wire [5:0]  vga_rd_seg = 6'd0;
wire        vga_fb_en  = 1'b0;

// Device under test
main_memory dut (
    .clk            (clk),
    .reset          (reset),
    .cpu_reset_n    (1'b1),
    .cpu_addr       (cpu_addr),
    .cpu_din        (cpu_din),
    .cpu_dout       (cpu_dout),
    .cpu_dout_ready (cpu_dout_ready),
    .cpu_be         (cpu_be),
    .cpu_burstcount (cpu_burstcount),
    .cpu_busy       (cpu_busy),
    .cpu_rd         (cpu_rd),
    .cpu_we         (cpu_we),

    .mem_addr       (mem_addr),
    .mem_din        (mem_din),
    .mem_dout       (mem_dout),
    .mem_dout_ready (mem_dout_ready),
    .mem_be         (mem_be),
    .mem_burstcount (mem_burstcount),
    .mem_busy       (mem_busy),
    .mem_rd         (mem_rd),
    .mem_we         (mem_we),

    .vga_address    (vga_address),
    .vga_readdata   (vga_readdata),
    .vga_writedata  (vga_writedata),
    .vga_memmode    (vga_memmode),
    .vga_read       (vga_read),
    .vga_write      (vga_write),
    .vga_wr_seg     (vga_wr_seg),
    .vga_rd_seg     (vga_rd_seg),
    .vga_fb_en      (vga_fb_en)
);

// Simple memory backend
// Adapt mem_* to sdram_sim port 0 (req/ack toggle)
wire mem_ack;
wire mem_req = (mem_rd | mem_we) ? ~mem_ack : mem_req_r;
reg  mem_req_r;
always @(posedge clk) mem_req_r <= mem_req;

// SDRAM simulation backend (port 0 used)
sdram #(.FREQ(50_000_000)) mem0 (
    .clk               (clk),
    .resetn            (1'b1),
    .refresh_allowed   (1'b1),
    .busy              (mem_busy),

    .req0              (mem_req),
    .ack0              (mem_ack),
    .wr0               (mem_we),
    .addr0             (mem_addr[24:0]),
    .din0              (mem_din),
    .dout0             (mem_dout),
    .ready0            (mem_dout_ready),
    .be0               (mem_be),
    .burst_cnt0        (mem_burstcount[3:0]),
    .burst_done0       (),

    // Unused ports 1 and 2
    .req1              (1'b0), .ack1(), .wr1(1'b0), .addr1(25'd0), .din1(32'd0), .dout1(), .be1(4'd0), .ready1(), .burst_cnt1(4'd0), .burst_done1(),
    .req2              (1'b0), .ack2(), .wr2(1'b0), .addr2(25'd0), .din2(32'd0), .dout2(), .be2(4'd0), .ready2(), .burst_cnt2(4'd0), .burst_done2()
);

endmodule
