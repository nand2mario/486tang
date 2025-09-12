// SD card module for ao486 simulation.
// nand2mario, 7/2024
module driver_sd (
    input               clk,
    input               rst_n,
    
    // slave port: command and status
    // 0: base address (write) or status (read)
    //    status: 0: initializing, 1: init error, 2: idle (ready), 3: reading, 4: writing, 5: operation error
    // 1: sector number
    // 2: sector count
    // 3: start command (1: init, 2: read, 3: write)
    input       [1:0]   avs_address,
    input               avs_read,
    output reg  [31:0]  avs_readdata,
    input               avs_write,
    input       [31:0]  avs_writedata,
    
    // master port: data transfer from/to SD card
    // read: avm_write=1, transmit 32-bit every cycle
    // write: avm_read=1, when avm_readdatavalid=1, receive 32 bits until enough data is received
    // handshake is avm_read & !avm_waitrequest, or avm_write & !avm_waitrequest
    output reg  [31:0]  avm_address,
    input               avm_waitrequest,
    output reg          avm_read,
    input       [31:0]  avm_readdata,
    input               avm_readdatavalid,
    output reg          avm_write,
    output reg  [31:0]  avm_writedata,
    
    // fake sd interface
    output reg          sd_clk,
    inout               sd_cmd,
    inout       [3:0]   sd_dat
);

reg [2:0] state;
localparam INIT = 0;
localparam IDLE = 1;
localparam READ = 2;
localparam WRITE = 3;

reg [31:0] base_address;
reg [23:0] sd_sector;
reg [7:0] sd_sector_count;

localparam SD_BUF_SIZE = 128*1024*1024;
logic [7:0] sd_buf[0:SD_BUF_SIZE-1] /* verilator public */;
int unsigned sd_size;

export "DPI-C" task sd_write;
task sd_write(
    input  int unsigned        addr,
    input  byte unsigned       data
);
    // if (addr < 16) $display("DPI sd_write(%m): addr=%x, data=%02x", addr, data);
    if (addr >= SD_BUF_SIZE) $display("sd_write overflow: %x >= %x", addr, SD_BUF_SIZE);
    sd_buf[addr] = data;
endtask

// initial $readmemh("dos6.vhd.hex", sd_buf);

// slave port
always @(posedge clk) begin
    if (!rst_n) begin
        // nothing
    end else begin
        if (avs_read && avs_address == 2'd0) begin
            avs_readdata <= 0;         // initializing
            if (state == IDLE) begin
                avs_readdata <= 2;     // idle
            end else if (state == READ) begin
                avs_readdata <= 3;     // reading
            end else if (state == WRITE) begin
                avs_readdata <= 4;     // writing
            end
        end else if (avs_read && avs_address == 2'd2) begin
            avs_readdata <= 2;         // acquire mutex

        end
    end
end

reg [29:0] sd_buf_ptr, sd_buf_ptr_end;

always @(posedge clk) begin
    if (!rst_n) begin
        state <= IDLE;
        avm_read <= 0;
        avm_write <= 0;
    end else begin
        avm_write <= 0;
        avm_read <= 0;
        case (state)
            IDLE: begin
                if (avs_write) begin
                    if (avs_address == 2'd0) begin
                        base_address <= avs_writedata;       // base address
                    end else if (avs_address == 2'd1) begin
                        sd_sector <= avs_writedata;          // sector number
                    end else if (avs_address == 2'd2) begin
                        sd_sector_count <= avs_writedata;    // sector count
                    end else if (avs_address == 2'd3) begin
                        sd_buf_ptr <= sd_sector * 512;       // start address
                        sd_buf_ptr_end <= (sd_sector + sd_sector_count) * 512; // end address
                        if (avs_writedata == 32'd2) begin
                            state <= READ;
                            avm_address <= base_address;
                            // $display("READ: sd_sector=%x, sd_sector_count=%x", sd_sector, sd_sector_count);
                        end else if (avs_writedata == 32'd3) begin
                            state <= WRITE;
                            avm_read <= 1;
                        end
                    end
                end
            end
            READ: begin
                avm_write <= 1;
                avm_writedata <= {sd_buf[sd_buf_ptr+3], sd_buf[sd_buf_ptr+2], sd_buf[sd_buf_ptr+1], sd_buf[sd_buf_ptr]};
                // Debug: show first few reads to verify SD card data
                // if (sd_buf_ptr < 32) begin
                //     $display("SD READ (%m): ptr=%x, data=%02x%02x%02x%02x", sd_buf_ptr,
                //              sd_buf[sd_buf_ptr+3], sd_buf[sd_buf_ptr+2], 
                //              sd_buf[sd_buf_ptr+1], sd_buf[sd_buf_ptr]);
                // end
                if (avm_write && !avm_waitrequest) begin     // handshake
                    sd_buf_ptr <= sd_buf_ptr + 4;
                    avm_writedata <= {sd_buf[sd_buf_ptr+7], sd_buf[sd_buf_ptr+6], sd_buf[sd_buf_ptr+5], sd_buf[sd_buf_ptr+4]};
                    avm_address <= avm_address + 4;
                    if (sd_buf_ptr + 4 == sd_buf_ptr_end) begin
                        avm_write <= 0;
                        state <= IDLE;
                    end
                end
            end
            WRITE: if (avm_readdatavalid) begin  // drive hdd-to-sd streaming with avm_read
                $display("WRITE: sd[%x]=%x", sd_buf_ptr, avm_readdata);
                sd_buf[sd_buf_ptr] <= avm_readdata[7:0];
                sd_buf[sd_buf_ptr+1] <= avm_readdata[15:8];
                sd_buf[sd_buf_ptr+2] <= avm_readdata[23:16];
                sd_buf[sd_buf_ptr+3] <= avm_readdata[31:24];
                sd_buf_ptr <= sd_buf_ptr + 4;
                if (sd_buf_ptr + 4 == sd_buf_ptr_end)
                    state <= IDLE;
                else
                    avm_read <= 1;
            end
        endcase
    end
end


endmodule