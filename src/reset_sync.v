module reset_sync (
    input clk,
    input rst_n,
    output reg rst
);

reg r1;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        r1 <= 1;
        rst <= 1;
    end else begin
        r1 <= 0;
        rst <= r1;
    end
end

endmodule