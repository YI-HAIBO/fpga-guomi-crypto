`timescale 1ns / 1ps
module tb_dbg;
    reg clk = 1'b0; always #5 clk = ~clk;
    reg  rx = 1'b1; wire tx, trig; wire [7:0] led;
    localparam [31:0] BIT = 32'd960;
    sm4_tvla_top #(.USE_MASKED(1'd0), .OV(6)) dut (
        .clk(clk), .uart_rxd(rx), .uart_txd(tx), .trigger(trig), .led(led));
    task send_byte(input [7:0] b); integer i; begin
        rx = 1'b0; #(BIT);
        for (i=0;i<8;i=i+1) begin rx=b[i]; #(BIT); end
        rx = 1'b1; #(BIT);
    end endtask
    task recv_byte(output [7:0] b); integer i; begin
        $display("%0t recv: waiting negedge tx (tx=%b)...", $time, tx);
        @(negedge tx);
        #(BIT + BIT/2);
        for (i=0;i<8;i=i+1) begin b[i]=tx; #(BIT); end
        $display("%0t recv got %02X", $time, b);
    end endtask
    reg [7:0] ct [0:15]; integer k;
    always @(posedge clk) if (dut.tx_start) $display("%0t DUT-TX byte=%02X cnt=%0d", $time, dut.tx_data, dut.tx_cnt);
    initial begin
        #60000;
        send_byte(8'hA5);
        send_byte(8'h01); send_byte(8'h23); send_byte(8'h45); send_byte(8'h67);
        send_byte(8'h89); send_byte(8'hAB); send_byte(8'hCD); send_byte(8'hEF);
        send_byte(8'hFE); send_byte(8'hDC); send_byte(8'hBA); send_byte(8'h98);
        send_byte(8'h76); send_byte(8'h54); send_byte(8'h32); send_byte(8'h10);
        $display("%0t frame sent, pt_reg=%032X", $time, dut.pt_reg);
        for (k=0;k<16;k=k+1) recv_byte(ct[k]);
        $display("%0t ALL 16 received", $time);
        $finish;
    end
    initial begin #3000000; $display("TIMEOUT k=%0d tx=%b echo=%b est=%0d", k, tx, dut.echo_en, dut.est); $finish; end
endmodule
