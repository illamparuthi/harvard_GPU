module gpu (
    input clk,
    input rst_n,
    input start,
    output done,
    input [5:0] cfg, 

    output [9:0] instr_addr,
    input  [31:0] instr_data,
    output [9:0] mem_addr,
    input  [31:0] mem_data_in,
    output [31:0] mem_data_out,
    output mem_we,

    output [1:0] warp_active,
    output core_stall,
    output simd_active
);

wire rst;

reset_sync rs (
    .clk(clk),
    .rst_n(rst_n),
    .rst(rst)
);

compute_core core (
    .clk(clk),
    .rst(rst),
    .start(start),
    .done(done),
    .instr_addr(instr_addr),
    .instr_data(instr_data),
    .mem_addr(mem_addr),
    .mem_data_in(mem_data_in),
    .mem_data_out(mem_data_out),
    .mem_we(mem_we),
    .warp_id(warp_active),
    .core_stall(core_stall),
    .simd_active(simd_active)
);

endmodule