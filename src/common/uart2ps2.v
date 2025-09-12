// Minimal UART-to-PS/2 bridge
// - Parses frames: 0xAA [len_hi] [len_lo] [cmd] [payload...]
// - Implements cmd 0x0C: payload is PS/2 keyboard Set-2 bytes to transmit
// - Implements cmd 0x0E: payload is PS/2 mouse bytes to transmit
// - Sends host->device bytes via response 0x06 to BL616
// - Drives ps2_device to generate PS/2 waveforms to the SoC controller

module uart2ps2 #(
    parameter CLK_FREQ = 20_000_000,
    parameter BAUD     = 115200,
    parameter PS2_DIV  = 1666           // ~12.5 kHz from 25 MHz
)(
    input  wire clk,
    input  wire resetn,
    input  wire uart_rx,
    output wire uart_tx,

    // Decoded PS/2 Set-2 bytes for keyboard device
    output reg  [7:0] kbd_data,
    output reg        kbd_we,

    // Decoded PS/2 mouse bytes to inject into device
    output reg  [7:0] mouse_data,
    output reg        mouse_we,

    // Host->device bytes captured from controller (mouse channel)
    input  wire [8:0] mouse_host_cmd,
    output reg        mouse_host_cmd_rd,

    // Debug stream from core, to be framed and sent over UART (type 0x07)
    input  wire [7:0] dbg_byte,
    input  wire       dbg_we
);

    // UART receiver
    wire [7:0] rx_data;
    wire       rx_valid;

    // synchronize uart_rx to clk
    reg rx_r=1'b1, rx_rr=1'b1;
    always @(posedge clk) begin
        rx_r  <= uart_rx;
        rx_rr <= rx_r;
    end

    async_receiver #(.ClkFrequency(CLK_FREQ), .Baud(BAUD)) u_rx (
        .clk(clk), .RxD(rx_rr), .RxD_data(rx_data), .RxD_data_ready(rx_valid)
    );

    // UART transmitter
    wire tx_busy;
    reg  tx_start;
    reg  [7:0] tx_data;
    async_transmitter #(.ClkFrequency(CLK_FREQ), .Baud(BAUD)) u_tx (
        .clk(clk), .TxD(uart_tx), .TxD_data(tx_data), .TxD_start(tx_start), .TxD_busy(tx_busy)
    );

    // Frame parser
    localparam S_IDLE  = 3'd0;
    localparam S_LEN1  = 3'd1;
    localparam S_LEN2  = 3'd2;
    localparam S_CMD   = 3'd3;
    localparam S_PARAM = 3'd4;

    reg [2:0]  st;
    reg [15:0] flen;
    reg [7:0]  cmd;
    reg [15:0] cnt;

    // Parser FSM
    always @(posedge clk) begin
        if (!resetn) begin
            st <= S_IDLE; flen <= 0; cmd <= 0; cnt <= 0; kbd_we <= 0; kbd_data <= 0; mouse_we <= 0; mouse_data <= 0;
        end else begin
            kbd_we   <= 0;
            mouse_we <= 0;
            if (rx_valid) begin
                case (st)
                    S_IDLE:  if (rx_data == 8'hAA) st <= S_LEN1; else st <= S_IDLE;
                    S_LEN1:  begin flen[15:8] <= rx_data; st <= S_LEN2; end
                    S_LEN2:  begin flen[7:0]  <= rx_data; st <= S_CMD;  end
                    S_CMD:   begin cmd <= rx_data; cnt <= 0; st <= (flen>1) ? S_PARAM : S_IDLE; end
                    S_PARAM: begin
                        // 0x0C: PS/2 keyboard scancode stream
                        // 0x0E: PS/2 mouse data stream
                        if (cmd == 8'h0C) begin
                            kbd_data <= rx_data;
                            kbd_we   <= 1'b1;
                            cnt      <= cnt + 1'b1;
                        end else if (cmd == 8'h0E) begin
                            mouse_data <= rx_data;
                            mouse_we   <= 1'b1;
                            cnt        <= cnt + 1'b1;
                        end else begin
                            cnt <= cnt + 1'b1; // consume unknown
                        end
                        if (cnt + 16'd2 == flen) st <= S_IDLE; // consumed len-1 bytes
                    end
                    default: st <= S_IDLE;
                endcase
            end
        end
    end

    // --------- UART framed transmitter (0x06 for mouse host->device; 0x07 for debug) ---------

    // Debug FIFO to buffer dbg_byte inputs
    reg [7:0] dbg_fifo[0:255];
    reg [7:0] dbg_wr, dbg_rd;
    reg [8:0] dbg_cnt;
    wire dbg_empty = (dbg_cnt == 0);

    localparam UF_IDLE   = 3'd0;
    localparam UF_AA     = 3'd1;
    localparam UF_LEN_H  = 3'd2;
    localparam UF_LEN_L  = 3'd3;
    localparam UF_TYPE   = 3'd4;
    localparam UF_DATA   = 3'd5;
    localparam UF_DONE   = 3'd6;

    reg [2:0]  uf_st;
    reg [7:0]  uf_type;
    reg [15:0] uf_len;
    reg [7:0]  uf_payload;

    always @(posedge clk) begin
        if (!resetn) begin
            uf_st <= UF_IDLE; tx_start <= 1'b0; mouse_host_cmd_rd <= 1'b0;
            dbg_rd <= 0; 
            dbg_wr <= 0; dbg_cnt <= 0;
        end else begin
            tx_start <= 1'b0;
            mouse_host_cmd_rd <= 1'b0;

            case (uf_st)
                UF_IDLE: begin
                    // choose next payload
                    if (mouse_host_cmd[8]) begin
                        uf_type    <= 8'h06;
                        uf_len     <= 16'd2;      // type + 1 byte
                        uf_payload <= mouse_host_cmd[7:0];
                        mouse_host_cmd_rd <= 1'b1;   // pop now
                        uf_st      <= UF_AA;
                    end else if (!dbg_empty) begin
                        uf_type    <= 8'h07;
                        uf_len     <= 16'd2;
                        uf_payload <= dbg_fifo[dbg_rd];
                        dbg_rd     <= dbg_rd + 1'b1;
                        dbg_cnt    <= dbg_cnt - 1'b1;
                        uf_st      <= UF_AA;
                    end
                end
                UF_AA:    if (!tx_busy & !tx_start) begin tx_data<=8'hAA; tx_start<=1'b1; uf_st<=UF_LEN_H; end
                UF_LEN_H: if (!tx_busy & !tx_start) begin tx_data<=uf_len[15:8]; tx_start<=1'b1; uf_st<=UF_LEN_L; end
                UF_LEN_L: if (!tx_busy & !tx_start) begin tx_data<=uf_len[7:0];  tx_start<=1'b1; uf_st<=UF_TYPE;  end
                UF_TYPE:  if (!tx_busy & !tx_start) begin tx_data<=uf_type;      tx_start<=1'b1; uf_st<=UF_DATA;  end
                UF_DATA:  if (!tx_busy & !tx_start) begin tx_data<=uf_payload;   tx_start<=1'b1; uf_st<=UF_DONE;  end
                UF_DONE:  if (!tx_busy & !tx_start) begin uf_st<=UF_IDLE; end
                default: uf_st <= UF_IDLE;
            endcase

            if (dbg_we && dbg_cnt != 9'd256) begin
                dbg_fifo[dbg_wr] <= dbg_byte;
                dbg_wr <= dbg_wr + 1'b1;
                dbg_cnt <= dbg_cnt + 1'b1;
            end
            // read handled in FSM when we consume a byte            
        end
    end

endmodule
