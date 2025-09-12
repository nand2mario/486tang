// Dual-port RAM of any size
module dpram
 #(  parameter ADRW = 8, // address width (therefore total size is 2**ADRW)
     parameter DATW = 8, // data width
     parameter FILE = "", // initialization hex file, optional
     parameter SSRAM = 0
  )( input                 clock    , // clock
     input                 wren_a , // write enable for port A
     input                 wren_b , // write enable for port B
     input      [ADRW-1:0] address_a , // address      for port A
     input      [ADRW-1:0] address_b , // address      for port B
     input      [DATW-1:0] data_a, // write data   for port A
     input      [DATW-1:0] data_b, // write data   for port B
     output reg [DATW-1:0] q_a, // read  data   for port A
     output reg [DATW-1:0] q_b  // read  data   for port B
  );

    localparam MEMD = 1 << ADRW;

    // initialize RAM, with zeros if ZERO or file if FILE.
    integer i;

    reg [DATW-1:0] mem [0:MEMD-1]; // memory array
    initial
        if (FILE != "") $readmemh(FILE, mem);

    // PORT A
    always @(posedge clock) 
        if (wren_a)
            mem[address_a] <= data_a;

    always @(posedge clock) 
        if (!wren_a)
            q_a <= mem[address_a]; 

    // PORT B
    always @(posedge clock) 
        if (wren_b) 
            mem[address_b] <= data_b;

    always @(posedge clock)
        if (!wren_b)
            q_b <= mem[address_b];

endmodule

// Dual-port RAM of any size, with different clocks for each port
/* verilator lint_off MULTIDRIVEN */
module dpram_difclk
 #(  parameter ADRW = 8, // address width (therefore total size is 2**ADRW)
     parameter DATW = 8, // data width
     parameter FILE = ""  // initialization hex file, optional
  )( input                 clk_a,
     input                 clk_b,

     input      [ADRW-1:0] address_a , // address      for port A
     input      [DATW-1:0] data_a, // write data   for port A
     input                 wren_a , // write enable for port A
     input                 enable_a, // clock enable for port A
     output reg [DATW-1:0] q_a, // read  data   for port A

     input      [ADRW-1:0] address_b , // address      for port B
     input      [DATW-1:0] data_b, // write data   for port B
     input                 wren_b , // write enable for port B
     input                 enable_b, // clock enable for port B
     output reg [DATW-1:0] q_b  // read  data   for port B
  );

    localparam MEMD = 1 << ADRW;

    // initialize RAM, with zeros if ZERO or file if FILE.
    integer i;

    reg [DATW-1:0] mem [0:MEMD-1]; // memory array
    initial
        if (FILE != "") $readmemh(FILE, mem);

    // PORT A
    always @(posedge clk_a) 
        if (wren_a)
            mem[address_a] <= data_a;

    always @(posedge clk_a) 
        if (enable_a && !wren_a)
            q_a <= mem[address_a]; 

    // PORT B
    always @(posedge clk_b) 
        if (wren_b) 
            mem[address_b] <= data_b;

    always @(posedge clk_b)
        if (enable_b && !wren_b)
            q_b <= mem[address_b];

endmodule
/* verilator lint_on MULTIDRIVEN */

// Dual-port RAM with byte enable
module dpram_be
 #(  parameter ADRW = 8, // address width (therefore total size is 2**ADRW)
     parameter DATW = 32 // data width
  )( input                 clock    , // clock
     input                 wren_a , // write enable for port A
     input                 wren_b , // write enable for port B
     input      [ADRW-1:0] address_a , // address      for port A
     input      [ADRW-1:0] address_b , // address      for port B
     input      [DATW/4-1:0] be_a, // byte enable for port A
     input      [DATW/4-1:0] be_b, // byte enable for port B
     input      [DATW-1:0] data_a, // write data   for port A
     input      [DATW-1:0] data_b, // write data   for port B
     output reg [DATW-1:0] q_a, // read  data   for port A
     output reg [DATW-1:0] q_b  // read  data   for port B
  );

    localparam MEMD = 1 << ADRW;

    // initialize RAM, with zeros if ZERO or file if FILE.
    integer i;

    reg [DATW-1:0] mem [0:MEMD-1]; // memory array

    // PORT A

    always @(posedge clock) 
        if (wren_a) 
            for (i = 0; i < DATW/8; i = i + 1'd1) begin
                if (be_a[i]) mem[address_a][i*8 +: 8] <= data_a[i*8 +: 8];
            end

    always @(posedge clock) 
        if (!wren_a)
            q_a <= mem[address_a]; 

    // PORT B
    always @(posedge clock) 
        if (wren_b) 
            for (i = 0; i < DATW/8; i = i + 1'd1) begin
                if (be_b[i]) mem[address_b][i*8 +: 8] <= data_b[i*8 +: 8];
            end

    always @(posedge clock)
        if (!wren_b)
            q_b <= mem[address_b];

endmodule

// Dual-port RAM with asynchronous read, modeling `altdpram`
module dpram_async #(
    parameter width = 8,
    parameter widthad = 8
) (
    input               clk,
    
    input [widthad-1:0] rdaddress, // read address
    input [widthad-1:0] wraddress, // write address
    input [width-1:0]   data,
    input               wren,
    output [width-1:0]  q
);

    reg [width-1:0] mem [0:2**widthad-1];

    assign q = mem[rdaddress];

    always @(posedge clk)
        if (wren)
            mem[wraddress] <= data;
endmodule