module scoreboard (
    input clk,
    input rst,
    
    // Read Ports for Hazard Detection
    input [1:0] warp_id,
    input [3:0] rs1, 
    input [3:0] rs2,
    output stall,
    
    // Write Ports to update the scoreboard
    input       set_busy,
    input [3:0] dest_reg_set,
    input       clear_busy,
    input [3:0] dest_reg_clear
);

    reg [15:0] busy [0:3]; 
    integer i;

    assign stall = busy[warp_id][rs1] | busy[warp_id][rs2];

    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < 4; i = i + 1) begin
                busy[i] <= 16'd0;
            end
        end else begin
            if (clear_busy) begin
                busy[warp_id][dest_reg_clear] <= 1'b0;
            end
            
            if (set_busy && !stall) begin
                busy[warp_id][dest_reg_set] <= 1'b1;
            end
        end
    end

endmodule