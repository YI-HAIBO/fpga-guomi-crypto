`timescale 1ns / 1ps
// tb_sm4_tvla.v -- 功能验证 sm4_tvla_top: UART 收发 + 引擎驱动 + trigger
// 用实例化一个 uart_rx 作为监视器连续解码回读密文(比阻塞式 recv_byte 更稳)。
// USE_MASKED 由 plusarg +USE_MASKED 选择: 0=未掩码(正对照), 1=掩码(被测)。
module tb;
    reg clk = 1'b0; always #5 clk = ~clk;                 // 100 MHz
    reg  rx = 1'b1; wire tx, trig; wire [7:0] led;
    localparam [31:0] BIT = 32'd960;                       // ns: 16*OV(6)*10ns

    // 实际被测变体由编译期 -D 决定; 这里的 +masked 只是让日志打印可区分
    reg use_masked = 1'b0;
`ifdef TVLA_MASKED
    localparam USE_MASKED_L = 1'b1;
`else
    localparam USE_MASKED_L = 1'b0;
`endif
    initial begin
        if ($test$plusargs("masked")) use_masked = 1'b1;
    end

`ifdef TVLA_MASKED
    sm4_tvla_top #(.USE_MASKED(1'd1), .OV(6)) dut (
        .clk(clk), .uart_rxd(rx), .uart_txd(tx), .trigger(trig), .led(led));
`else
    sm4_tvla_top #(.USE_MASKED(1'd0), .OV(6)) dut (
        .clk(clk), .uart_rxd(rx), .uart_txd(tx), .trigger(trig), .led(led));
`endif

    task send_byte(input [7:0] b); integer i; begin
        rx = 1'b0; #(BIT);
        for (i=0;i<8;i=i+1) begin rx=b[i]; #(BIT); end
        rx = 1'b1; #(BIT);
    end endtask

    // 回读监视器: 用另一个 uart_rx 连续解码 uart_txd
    wire [7:0] mon_data; wire mon_valid; wire mon_rst = dut.rst_n;
    uart_rx #(.OV(6)) mon_rx (.clk(clk), .rst_n(mon_rst), .rx(tx),
                              .data(mon_data), .valid(mon_valid));
    reg [7:0] ct [0:15]; integer ct_n = 0;
    always @(posedge clk) if (mon_valid && ct_n < 16) begin
        ct[ct_n] = mon_data; ct_n = ct_n + 1;
        $display("MON got byte=%02X n=%0d t=%0d", mon_data, ct_n-1, $time);
    end

    integer trig_count = 0;
    always @(posedge trig) trig_count = trig_count + 1;
    // 握手重叠自检: tx_start 与 tx_busy 不应同时为高
    integer overlap = 0;
    always @(posedge clk) if (dut.tx_start && dut.tx_busy) overlap = overlap + 1;

    reg [7:0] ex [0:15]; integer k, errors;
    initial begin
        ex[0]=8'h68; ex[1]=8'h1E; ex[2]=8'hDF; ex[3]=8'h34;
        ex[4]=8'hD2; ex[5]=8'h06; ex[6]=8'h96; ex[7]=8'h5E;
        ex[8]=8'h86; ex[9]=8'hB3; ex[10]=8'hE9; ex[11]=8'h4F;
        ex[12]=8'h53; ex[13]=8'h6E; ex[14]=8'h42; ex[15]=8'h46;
        errors = 0; rx = 1'b1;
        #60000;                                     // 等内部 POR 释放
        send_byte(8'hA5);
        send_byte(8'h01); send_byte(8'h23); send_byte(8'h45); send_byte(8'h67);
        send_byte(8'h89); send_byte(8'hAB); send_byte(8'hCD); send_byte(8'hEF);
        send_byte(8'hFE); send_byte(8'hDC); send_byte(8'hBA); send_byte(8'h98);
        send_byte(8'h76); send_byte(8'h54); send_byte(8'h32); send_byte(8'h10);
        // 等回读 16 字节
        wait (ct_n >= 16);
        #2000;
        for (k=0;k<16;k=k+1)
            if (ct[k] !== ex[k]) begin
                errors = errors + 1;
                $display("  ct[%0d]=%02X exp %02X", k, ct[k], ex[k]);
            end
        if (trig_count !== 1) begin errors=errors+1; $display("  trig_count=%0d (exp 1)", trig_count); end
        if (overlap !== 0)  begin errors=errors+1; $display("  tx overlap events=%0d", overlap); end
        $display("USE_MASKED=%0d trig=%0d overlap=%0d ct_n=%0d errors=%0d",
                 USE_MASKED_L, trig_count, overlap, ct_n, errors);
        if (errors==0) $display("TB PASS: ciphertext + trigger + handshake OK");
        else           $display("TB FAIL: %0d error(s)", errors);
        $finish;
    end
    initial begin #50000000; $display("TB TIMEOUT ct_n=%0d overlap=%0d trig=%0d", ct_n, overlap, trig_count); $finish; end
endmodule
