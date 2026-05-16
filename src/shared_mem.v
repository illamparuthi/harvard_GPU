module shared_mem (
    input  wire        clk,
    // Port A: Instruction Fetch
    input  wire [9:0]  addr_a,
    output wire [31:0] dout_a,
    // Port B: Data Access
    input  wire        we_b,
    input  wire [9:0]  addr_b,
    input  wire [31:0] din_b,
    output wire [31:0] dout_b
);

    // Instantiate the SCL 180nm DPRAM Macro
    rd3_1024x32 mem_macro (
        // Port 1 -> Connect to Port A (Read-Only)
        .CE1(clk),
        .CSB1(1'b0),        // Chip Select Active Low (Always ON)
        .OEB1(1'b0),        // Output Enable Active Low (Always ON)
        .WEB1(1'b1),        // Write Enable Active Low (Always High = READ ONLY)
        .A1(addr_a),
        .I1(32'd0),         // Data Input 1 (unused)
        .O1(dout_a),

        // Port 2 -> Connect to Port B (Read/Write)
        .CE2(clk),
        .CSB2(1'b0),        // Chip Select Active Low
        .OEB2(1'b0),        // Output Enable Active Low
        .WEB2(~we_b),       // Macro uses Active Low WEB
        .A2(addr_b),
        .I2(din_b),
        .O2(dout_b)
    );

endmodule