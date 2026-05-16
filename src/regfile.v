module regfile (
    input clk,
    input rst,                  
    input [3:0] rs1, rs2, rd,
    input [31:0] wd,
    input we,
    output [31:0] rd1, rd2
);

reg [31:0] regs[0:15];
integer i;

always @(posedge clk) begin
    if (rst) begin
        for (i = 0; i < 16; i = i + 1) begin
            regs[i] <= 32'b0;   // Synthesizable deterministic reset state
        end
    end else if (we) begin
        regs[rd] <= wd;
    end
end

assign rd1 = regs[rs1];
assign rd2 = regs[rs2];

endmodule