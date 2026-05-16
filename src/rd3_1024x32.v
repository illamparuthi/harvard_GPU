// File: rd3_1024x32_synth.v
// Use ONLY for Genus Synthesis and Innovus implementation
module rd3_1024x32 (
    input  wire        CE1,
    input  wire        CSB1,
    input  wire        OEB1,
    input  wire        WEB1,
    input  wire [9:0]  A1,
    input  wire [31:0] I1,
    output wire [31:0] O1,

    input  wire        CE2,
    input  wire        CSB2,
    input  wire        OEB2,
    input  wire        WEB2,
    input  wire [9:0]  A2,
    input  wire [31:0] I2,
    output wire [31:0] O2
);
// Absolutely no logic inside. 
endmodule