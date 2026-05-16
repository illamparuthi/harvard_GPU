module simd_wrapper (
    input  wire [511:0] a,
    input  wire [511:0] b,
    input  wire [2:0]   opcode,
    input  wire [15:0]  mask,
    output wire [511:0] result
);

// Safely catch the 32-bit output of each ALU before packing it
wire [31:0] alu_out [0:15];

genvar i;
generate
    for (i = 0; i < 16; i = i + 1) begin : lanes
        // Only execute math if the lane's mask bit is set
        wire [31:0] masked_a = mask[i] ? a[i*32 + 31 : i*32] : 32'd0;
        wire [31:0] masked_b = mask[i] ? b[i*32 + 31 : i*32] : 32'd0;
        
        alu alu_i (
            .a(masked_a),
            .b(masked_b),
            .opcode(opcode),
            .out(alu_out[i])   // <--- FIXED: Now matches your alu.v perfectly!
        );
        
        // Pack the array into the massive 512-bit result bus
        assign result[i*32 + 31 : i*32] = alu_out[i];
    end
endgenerate

endmodule