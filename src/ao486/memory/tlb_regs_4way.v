 /*
 * 4-way set associative TLB with 32 total entries (8 sets x 4 ways)
 * Interface compatible with tlb_regs.v
 *
 * 9/2025, nand2mario
 */

`include "defines.v"

module tlb_regs(
    input               clk,
    input               rst_n,
    
    //RESP:
    input               tlbflushsingle_do,
    input   [31:0]      tlbflushsingle_address,
    //END
    
    //RESP:
    input               tlbflushall_do,
    //END
    
    input               rw,
    
    //RESP:
    input               tlbregs_write_do,
    input   [31:0]      tlbregs_write_linear,
    input   [31:0]      tlbregs_write_physical,
    
    input               tlbregs_write_pwt,
    input               tlbregs_write_pcd,
    input               tlbregs_write_combined_rw,
    input               tlbregs_write_combined_su,
    //END
    
    //RESP:
    input               translate_do,
    input   [31:0]      translate_linear,
    output              translate_valid,
    output  [31:0]      translate_physical,
    output              translate_pwt,
    output              translate_pcd,
    output              translate_combined_rw,
    output              translate_combined_su
    //END
);

    // Entry layout:
    // [19:0]  linear page (tag)
    // [39:20] physical page
    // [40]    PWT
    // [41]    PCD
    // [42]    VALID
    // [43]    combined RW
    // [44]    combined SU
    // [45]    DIRTY (set on write fill)

    localparam WAYS = 4;
    localparam SETS = 8;          // 32 entries total
    localparam SETBITS = 3;       // log2(SETS)

    reg  [45:0] tlb   [0:SETS-1][0:WAYS-1];
    reg  [1:0]  rrptr [0:SETS-1];    // simple round-robin replacement per set

    wire [19:0] lin_page_t  = translate_linear[31:12];
    wire [SETBITS-1:0] set_t = translate_linear[12 +: SETBITS];    // bits [14:12]
    wire [SETBITS-1:0] set_w = tlbregs_write_linear[12 +: SETBITS];

    // Hit detection within selected set
    wire [WAYS-1:0] way_valid_t;
    wire [WAYS-1:0] way_hit;

    genvar wi;
    generate
        for (wi = 0; wi < WAYS; wi = wi + 1) begin : g_hit
            assign way_valid_t[wi] = tlb[set_t][wi][42];
            assign way_hit[wi]     = translate_do && way_valid_t[wi] && (tlb[set_t][wi][19:0] == lin_page_t);
        end
    endgenerate

    // Selected entry mux (one-hot)
    reg  [45:0] selected;
    always @* begin
        selected = 46'd0;
        unique case (1'b1)
            way_hit[0]: selected = tlb[set_t][0];
            way_hit[1]: selected = tlb[set_t][1];
            way_hit[2]: selected = tlb[set_t][2];
            way_hit[3]: selected = tlb[set_t][3];
            default:    ;
        endcase
    end

    // Outputs
    wire hit_any = |way_hit;
    wire translate_valid_but_not_dirty = hit_any && rw && ~selected[45];

    assign translate_valid       = hit_any && (~rw || selected[45]);
    assign translate_physical    = translate_valid ? { selected[39:20], translate_linear[11:0] } : translate_linear;
    assign translate_pwt         = selected[40];
    assign translate_pcd         = selected[41];
    assign translate_combined_rw = selected[43];
    assign translate_combined_su = selected[44];

    // Single flush comparator against full tag
    wire [19:0] lin_page_flush = tlbflushsingle_address[31:12];

    // Write selection within write set
    wire [WAYS-1:0] way_valid_w;
    wire [WAYS-1:0] free_way;
    generate
        for (wi = 0; wi < WAYS; wi = wi + 1) begin : g_free
            assign way_valid_w[wi] = tlb[set_w][wi][42];
            assign free_way[wi]    = ~way_valid_w[wi];
        end
    endgenerate
    wire any_free = |free_way;

    // pick first free or rrptr when full
    reg  [1:0] sel_way_w;
    always @* begin
        if (any_free) begin
            // first free way (0..3)
            casez (free_way)
                4'b1???: sel_way_w = 2'd0;
                4'b01??: sel_way_w = 2'd1;
                4'b001?: sel_way_w = 2'd2;
                4'b0001: sel_way_w = 2'd3;
                default: sel_way_w = 2'd0;
            endcase
        end else begin
            sel_way_w = rrptr[set_w];
        end
    end

    // Compose write data
    wire [45:0] write_data = { rw, tlbregs_write_combined_su, tlbregs_write_combined_rw, 1'b1,
                               tlbregs_write_pcd, tlbregs_write_pwt,
                               tlbregs_write_physical[31:12], tlbregs_write_linear[31:12] };

    integer si, sj;
    always @(posedge clk) begin
        if (rst_n == 1'b0) begin
            for (si = 0; si < SETS; si = si + 1) begin
                rrptr[si] <= 2'd0;
                for (sj = 0; sj < WAYS; sj = sj + 1)
                    tlb[si][sj] <= 46'd0;
            end
        end else begin
            // Flush-all
            if (tlbflushall_do) begin
                for (si = 0; si < SETS; si = si + 1)
                    for (sj = 0; sj < WAYS; sj = sj + 1)
                        tlb[si][sj] <= 46'd0;
            end else begin
                // Flush single and dirty-miss invalidation
                for (si = 0; si < SETS; si = si + 1) begin
                    for (sj = 0; sj < WAYS; sj = sj + 1) begin
                        // default stay
                        reg do_inval;
                        do_inval = 1'b0;
                        // explicit single flush
                        if (tlbflushsingle_do && tlb[si][sj][42] && tlb[si][sj][19:0] == lin_page_flush)
                            do_inval = 1'b1;
                        // write requires dirty but entry is clean: invalidate hit entry in its set
                        if (translate_valid_but_not_dirty && way_hit[sj] && si[SETBITS-1:0] == set_t)
                            do_inval = 1'b1;
                        if (do_inval)
                            tlb[si][sj] <= 46'd0;
                    end
                end

                // Install write (fill)
                if (tlbregs_write_do) begin
                    tlb[set_w][sel_way_w] <= write_data;
                    if (~any_free)
                        rrptr[set_w] <= rrptr[set_w] + 2'd1; // advance replacement on full set
                end

                // Optional: on hit, bump rrptr to favor others (weak aging)
                if (hit_any)
                    rrptr[set_t] <= rrptr[set_t] + 2'd1;
            end
        end
    end

    // synthesis translate_off
    wire _unused_ok = &{1'b0, translate_linear[11:0], tlbflushsingle_address[11:0], tlbregs_write_linear[11:0], 1'b0};
    // synthesis translate_on

endmodule
