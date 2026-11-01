`timescale 1ns / 1ps
// tb_sm4_tvla.v -- 功能验证 sm4_tvla_top 的 UART 收发 + 引擎驱动 + trigger
// 用未掩码引擎(USE_MASKED=0)验证 harness 逻辑; 送 KAT 明文, 校验回读密文与 trigger。
module tb;
    reg clk = 1'b0;
    always #5 clk = ~clk;                 // 100 MHz
    reg  rx = 1'b1;
    wire tx, trig;
    wire [7:0] led;

    localparam [31:0] BIT = 32'd960;      // ns: 16*OV(6)*10ns

    sm4_tvla_top #(.USE_MASKED(1'd1), .OV(6)) dut (
        .clk(clk), .uart_rxd(rx), .uart_txd(tx), .trigger(trig), .led(led)
    );

    integer trig_count = 0;
    always @(posedge trig) trig_count = trig_count + 1;

    task send_byte(input [7:0] b);
        integer i;
        begin
            rx = 1'b0; #(BIT);                 // start
            for (i = 0; i < 8; i = i + 1) begin rx = b[i]; #(BIT); end
            rx = 1'b1; #(BIT);                 // stop
        end
    endtask

    task recv_byte(output [7:0] b);
        integer i;
        begin
            @(negedge tx);                     // start bit 下降沿
            #(BIT + BIT/2);                    // 到 bit0 中心
            for (i = 0; i < 8; i = i + 1) begin b[i] = tx; #(BIT); end
        end
    endtask

    reg [7:0] ct [0:15];
    reg [7:0] ex [0:15];
    integer k, errors;

    initial begin
        ex[0]=8'h68; ex[1]=8'h1E; ex[2]=8'hDF; ex[3]=8'h34;
        ex[4]=8'hD2; ex[5]=8'h06; ex[6]=8'h96; ex[7]=8'h5E;
        ex[8]=8'h86; ex[9]=8'hB3; ex[10]=8'hE9; ex[11]=8'h4F;
        ex[12]=8'h53; ex[13]=8'h6E; ex[14]=8'h42; ex[15]=8'h46;
        errors = 0;
        rx = 1'b1;
        #60000;                                // 等内部 POR 释放 (por_cnt->4095 ~= 41us)

        // 协议: 0xA5 + 16 字节明文(大端 0123...3210)
        send_byte(8'hA5);
        send_byte(8'h01); send_byte(8'h23); send_byte(8'h45); send_byte(8'h67);
        send_byte(8'h89); send_byte(8'hAB); send_byte(8'hCD); send_byte(8'hEF);
        send_byte(8'hFE); send_byte(8'hDC); send_byte(8'hBA); send_byte(8'h98);
        send_byte(8'h76); send_byte(8'h54); send_byte(8'h32); send_byte(8'h10);

        for (k = 0; k < 16; k = k + 1) recv_byte(ct[k]);

        for (k = 0; k < 16; k = k + 1)
            if (ct[k] !== ex[k]) begin
                errors = errors + 1;
                $display("  ct[%0d] = %02X  expected %02X", k, ct[k], ex[k]);
            end
        if (trig_count !== 1) begin
            errors = errors + 1;
            $display("  trigger count = %0d (expected 1)", trig_count);
        end
        $display("trigger_count = %0d, ciphertext errors = %0d", trig_count, errors);
        if (errors == 0) $display("TB PASS: UART<->engine path + trigger OK");
        else              $display("TB FAIL: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #50000000;                             // 50 ms 看门狗
        $display("TB TIMEOUT");
        $finish;
    end
endmodule
