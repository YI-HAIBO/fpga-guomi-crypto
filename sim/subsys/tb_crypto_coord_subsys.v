// =============================================================================
// Testbench : tb_crypto_coord_subsys
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v1.0
// 日期     : 2026-10-02
// 视角     : sim-verifier (魏波形)
// 目标     : 验证 crypto_coord_subsys 子系统级集成 (SM4 / SM3 / TRNG / SM2)
//   T1   SM4_ENC   GB/T 32907-2016 标准向量
//   T2   SM4_DEC   解密 roundtrip
//   T3   SM3_CMP   GB/T 32905-2016 官向量 (IV + "abc" 首块 -> 66c7f0f4...)
//   T4   SM3_CMP   多块链式: 第 2 块以 T3 输出为 prev
//   T5   TRNG_128  密钥非零 / 两次取值
//   T6   TRNG_256  两块拼接正确 (高位在前) 且非零
//   T7   SM2_SIGN  (d,e,k) -> (r,s) 对照 Python 参考模型
//   T8   SM2_VER   正确签名 -> ok=1
//   T9   SM2_VER   篡改 s -> ok=0 (且不能报硬件错误码)
//   T10  非法 op   -> err=0x02 且 ok=0
//   T11  busy 期间 start 被忽略, 首个请求结果仍正确
//   T12  复位行为  -> ra/rb/ok/busy 清零
//   T13  协调链    TRNG_256 -> SM2_SIGN -> SM2_VER (硬件随机 k 自产自验)
// =============================================================================

`timescale 1ns / 1ps

module tb_crypto_coord_subsys;

    localparam CLK_HALF = 5;            // 100 MHz

    // 操作码 (与 crypto_coord_subsys 一致)
    localparam [3:0] OP_SM4_ENC = 4'h0;
    localparam [3:0] OP_SM4_DEC = 4'h1;
    localparam [3:0] OP_SM3_CMP = 4'h2;
    localparam [3:0] OP_TRNG128 = 4'h3;
    localparam [3:0] OP_TRNG256 = 4'h4;
    localparam [3:0] OP_SM2_SGN = 4'h5;
    localparam [3:0] OP_SM2_VER = 4'h6;
    localparam [3:0] OP_BAD     = 4'hF;

    reg         clk   = 1'b0;
    reg         rst_n = 1'b0;
    reg         start = 1'b0;
    reg  [3:0]  op    = 4'h0;
    reg  [511:0] ia    = 512'd0;
    reg  [511:0] ib    = 512'd0;
    reg  [255:0] ic    = 256'd0;

    wire [255:0] ra;
    wire [255:0] rb;
    wire         ok;
    wire         done;
    wire         busy;
    wire [7:0]   err;

    integer ntest = 0;
    integer npass = 0;
    integer nfail = 0;
    reg  [63:0]  mask_seed_init = 64'hA5A5A5A5A5A5A5A5;

    // crypto_coord_subsys v1.4 起 USE_SM2 默认 0 (板级裁剪), 子系统级
    // 回归必须显式传 1 才能覆盖 SM2_SIGN 通路 (T7/T8/T9/T13)。
    crypto_coord_subsys #(
        .USE_SM2 (1)
    ) u_dut (
        .clk   (clk),
        .rst_n (rst_n),
        .start (start),
        .op    (op),
        .ia    (ia),
        .ib    (ib),
        .ic    (ic),
        .mask_seed_init (mask_seed_init),
        .ra    (ra),
        .rb    (rb),
        .ok    (ok),
        .done  (done),
        .busy  (busy),
        .err   (err)
    );

    always #(CLK_HALF) clk = ~clk;

    // -----------------------------------------------------------------------
    task do_reset;
        begin
            rst_n   = 1'b0;
            start   = 1'b0;
            op      = 4'h0;
            ia      = 512'd0;
            ib      = 512'd0;
            ic      = 256'd0;
            repeat (10) @(posedge clk);
            rst_n   = 1'b1;
            repeat (2)  @(posedge clk);
        end
    endtask

    // -----------------------------------------------------------------------
    // wait_done() -> R / R2 / OK / E
    //   只在 done 拉高后取结果。done 是 1 拍脉冲, 由非阻塞赋值在 posedge 产生,
    //   所以必须 @(posedge clk) 之后再 #1 越过 NBA 区采样, 否则会在同一时间步
    //   读到旧值、整条脉冲被漏掉而挂死。
    // -----------------------------------------------------------------------
    task wait_done(output [255:0] R,
                   output [255:0] R2,
                   output         OK,
                   output [7:0]   E);
        integer wc;
        begin
            wc = 0;
            while (done !== 1'b1) begin
                @(posedge clk);
                #1;
                wc = wc + 1;
                if (wc > 3000000) begin
                    $display("  ERROR: timeout waiting done (cycles=%0d)", wc);
                    $display("    [dump] state=%0d op_r=%h err_b=%02h start=%b done=%b busy=%b",
                             u_dut.state, u_dut.op_r, u_dut.err_b, start, done, busy);
                    $display("    [dump] sm4 bz=%b dn=%b | sm3 bz=%b dn=%b | sm2 dn=%b err=%b | eng_done=%b is_sm4=%b",
                             u_dut.sm4_busy, u_dut.sm4_done, u_dut.sm3_busy, u_dut.sm3_done,
                             u_dut.sm2_done, u_dut.sm2_err, u_dut.eng_done, u_dut.is_sm4);
                    $display("    [dump] trng st=%0d dvld=%b drdy=%b | tcnt=%b | ra=%064h ok=%b err=%02h",
                             u_dut.u_trng.state, u_dut.trng_data_vld, u_dut.trng_data_rdy,
                             u_dut.t_cnt, ra, ok, err);
                    disable wait_done;
                end
            end
            R  = ra;
            R2 = rb;
            OK = ok;
            E  = err;
        end
    endtask

    // -----------------------------------------------------------------------
    // do_request(o, A, B, C) -> R / R2 / OK / E
    //   等 idle -> 发 1 拍 start -> 等 done
    // -----------------------------------------------------------------------
    task do_request(input  [3:0]   o,
                    input  [511:0] A,
                    input  [511:0] B,
                    input  [255:0] C,
                    output [255:0] R,
                    output [255:0] R2,
                    output         OK,
                    output [7:0]   E);
        begin
            while (busy === 1'b1) @(posedge clk);
            @(negedge clk);
            op    = o;
            ia    = A;
            ib    = B;
            ic    = C;
            start = 1'b1;
            @(posedge clk);
            #1;
            start = 1'b0;
            wait_done(R, R2, OK, E);
        end
    endtask

    // 单独发 1 拍 start (不判 busy、不等 done), 供 T11 在忙态期间强行插桩用
    task issue_start(input  [3:0]   o,
                     input  [511:0] A,
                     input  [511:0] B,
                     input  [255:0] C);
        begin
            @(negedge clk);
            op    = o;
            ia    = A;
            ib    = B;
            ic    = C;
            start = 1'b1;
            @(posedge clk);
            #1;
            start = 1'b0;
        end
    endtask

    // -----------------------------------------------------------------------
    // 断言辅助: ntest 在 if 之前自增, 避免悬空 else
    // -----------------------------------------------------------------------
    task chk(input cond, input [8*64:1] tag);
        begin
            ntest = ntest + 1;
            if (cond) begin
                npass = npass + 1;
                $display("  PASS  %0s", tag);
            end else begin
                nfail = nfail + 1;
                $display("  FAIL  %0s", tag);
            end
        end
    endtask

    // =======================================================================
    // 主测试
    // =======================================================================
    reg [255:0] rv;
    reg [255:0] rv2;
    reg         rok;
    reg [7:0]   rerr;
    reg [255:0] sm3_v0;      // SM3 链上一块输出
    reg [255:0] rv3;         // 独立结果寄存器 (避免 task 多 output 指向同一变量)

    initial begin
        $display("========================================================");
        $display(" crypto_coord_subsys Subsystem Testbench");
        $display("========================================================");

        do_reset;

        // ------------------------------------------------------------------
        // T1: SM4_ENC
        // ------------------------------------------------------------------
        $display("");
        $display("[Test 1] op=0 SM4_ENC (GB/T 32907-2016 vector)");
        do_request(OP_SM4_ENC, {256'd0, 128'h0123456789abcdeffedcba9876543210}, {256'd0, 128'h0123456789abcdeffedcba9876543210}, 256'd0,
                   rv, rv2, rok, rerr);
        ntest = ntest + 1;
        if (rv === 256'h00000000000000000000000000000000681edf34d206965e86b3e94f536e4246 && rok === 1'b1 && rerr === 8'h00) begin
            npass = npass + 1;
            $display("  PASS  data_out=0x%064x", rv);
        end else begin
            nfail = nfail + 1;
            $display("  FAIL  got=0x%064x ok=%b err=0x%02h (exp 0x%064x)",
                     rv, rok, rerr, 256'h00000000000000000000000000000000681edf34d206965e86b3e94f536e4246);
        end

        // ------------------------------------------------------------------
        // T2: SM4_DEC
        // ------------------------------------------------------------------
        $display("");
        $display("[Test 2] op=1 SM4_DEC roundtrip");
        do_request(OP_SM4_DEC, {256'd0, 128'h0123456789abcdeffedcba9876543210}, {256'd0, 256'h00000000000000000000000000000000681edf34d206965e86b3e94f536e4246}, 256'd0,
                   rv, rv2, rok, rerr);
        chk(rv === 128'h0123456789abcdeffedcba9876543210, "SM4_DEC recovers the plaintext");

        // ------------------------------------------------------------------
        // T3: SM3_CMP 首块 -> 应等于完整哈希 (单块消息)
        // ------------------------------------------------------------------
        $display("");
        $display("[Test 3] op=2 SM3_CMP block0 (GB/T 32905 official vector)");
        do_request(OP_SM3_CMP, 512'h61626380000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000018, {256'd0, 256'h7380166f4914b2b9172442d7da8a0600a96f30bc163138aae38dee4db0fb0e4e}, 256'd0,
                   rv, rv2, rok, rerr);
        ntest = ntest + 1;
        if (rv === 256'h66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0 && rok === 1'b1 && rerr === 8'h00) begin
            npass = npass + 1;
            $display("  PASS  out_state=0x%064x", rv);
        end else begin
            nfail = nfail + 1;
            $display("  FAIL  got=0x%064x ok=%b err=0x%02h (exp 0x%064x)",
                     rv, rok, rerr, 256'h66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0);
        end
        sm3_v0 = rv;

        // ------------------------------------------------------------------
        // T4: SM3_CMP 第 2 块 (prev = T3 输出)
        // ------------------------------------------------------------------
        $display("");
        $display("[Test 4] op=2 SM3_CMP block1 (chained from T3)");
        do_request(OP_SM3_CMP, 512'h62636162636162636162636162636162636162636162636162636162636162636162636162636162636162636162636162636162636162636162636162636162, {256'd0, sm3_v0}, 256'd0,
                   rv, rv2, rok, rerr);
        chk(rv === 256'hd82b4ec6c6d84efbe75bc0eaa2ace157ffffef825f440a5ce4a446f30a25685f, "SM3 block1 chained output matches reference");

        // ------------------------------------------------------------------
        // T5: TRNG_128
        // ------------------------------------------------------------------
        $display("");
        $display("[Test 5] op=3 TRNG_128");
        do_request(OP_TRNG128, 512'd0, 512'd0, 256'd0, rv, rv2, rok, rerr);
        chk((rv !== 256'd0) && (rv[255:128] === 256'd0) && (rok === 1'b1) &&
            (rerr === 8'h00), "TRNG_128 nonzero, upper 128 bits zero");
        do_request(OP_TRNG128, 512'd0, 512'd0, 256'd0, rv3, rv2, rok, rerr);
        $display("  INFO  2nd draw = 0x%064x", rv3);

        // ------------------------------------------------------------------
        // T6: TRNG_256
        // ------------------------------------------------------------------
        $display("");
        $display("[Test 6] op=4 TRNG_256");
        do_request(OP_TRNG256, 512'd0, 512'd0, 256'd0, rv, rv2, rok, rerr);
        if ((rv !== 256'd0) && (rv[255:128] !== 256'd0) && (rok === 1'b1) &&
            (rerr === 8'h00))
            chk(1'b1, "TRNG_256 {hi,lo} nonzero, ok=1");
        else begin
            chk(1'b0, "TRNG_256 {hi,lo} nonzero, ok=1");
            $display("  INFO  ra=%064h ok=%b err=0x%02h", rv, rok, rerr);
        end

        // ------------------------------------------------------------------
        // T7: SM2_SIGN
        // ------------------------------------------------------------------
        $display("");
        $display("[Test 7] op=5 SM2_SIGN (r,s vs Python reference)");
        do_request(OP_SM2_SGN, {256'd0, 256'hdf42cd0ad4c7b58a515f64f816291053f41a9ba0297a907a090efac06bf11f3a}, {256'd0, 256'h9d472e1b1acf274cdd6a2bd2fc041cebe2a14cc561ac99fc3dab56eb034922bc}, {256'd0, 256'h05647563cefb52f37b566453df2785f3efd3616a377f219497cc8d3dde773720},
                   rv, rv2, rok, rerr);
        ntest = ntest + 1;
        if (rv === 256'h82dd90848a60013ad4cbeb305820d2f86b66baee0d1e8790c1284f4b94480ead && rv2 === 256'h931299e78aa4995ad1eabadc134fd2abbb2880db01743dd1ac93b5d39fae27ae && rok === 1'b1 && rerr === 8'h00) begin
            npass = npass + 1;
            $display("  PASS  r=0x%064x", rv);
            $display("        s=0x%064x", rv2);
        end else begin
            nfail = nfail + 1;
            $display("  FAIL  r=0x%064x (exp 0x%064x)", rv, 256'h82dd90848a60013ad4cbeb305820d2f86b66baee0d1e8790c1284f4b94480ead);
            $display("        s=0x%064x (exp 0x%064x) ok=%b err=0x%02h",
                     rv2, 256'h931299e78aa4995ad1eabadc134fd2abbb2880db01743dd1ac93b5d39fae27ae, rok, rerr);
        end

        // ------------------------------------------------------------------
        // T8: SM2_VER 正确签名
        //     v3.0 SIGN-ONLY: op=6 已降级为非法 op -> err=0x02, ok=0。
        //     TB 头注释已写明; 测试体在 v1.4 回归修复时对齐 (此前仍按旧验签
        //     语义断言 ok=1, 导致 USE_SM2=1 修复后这 3 项误报 FAIL)。
        // ------------------------------------------------------------------
        $display("");
        $display("[Test 8] op=6 SM2_VER (SIGN-ONLY: 非法 op 降级)");
        do_request(OP_SM2_VER, {256'he2837a44315cafa6f42ca09da1ed7677c524f4c4571f88b41f3e0a225459b456, 256'hd2c2112cb5af6ef88b2b629db51b324fcf0b20c65d46fc130bb43a6243255abf}, {256'h82dd90848a60013ad4cbeb305820d2f86b66baee0d1e8790c1284f4b94480ead, 256'h9d472e1b1acf274cdd6a2bd2fc041cebe2a14cc561ac99fc3dab56eb034922bc}, {256'h931299e78aa4995ad1eabadc134fd2abbb2880db01743dd1ac93b5d39fae27ae},
                   rv, rv2, rok, rerr);
        chk((rerr === 8'h02) && (rok === 1'b0), "SM2_VER op degraded to illegal (err=0x02)");

        // ------------------------------------------------------------------
        // T9: SM2_VER 篡改 s (同样落入非法 op 快速通道)
        // ------------------------------------------------------------------
        $display("");
        $display("[Test 9] op=6 SM2_VER tampered (SIGN-ONLY: 同样 err=0x02)");
        do_request(OP_SM2_VER, {256'he2837a44315cafa6f42ca09da1ed7677c524f4c4571f88b41f3e0a225459b456, 256'hd2c2112cb5af6ef88b2b629db51b324fcf0b20c65d46fc130bb43a6243255abf}, {256'h9d472e1b1acf274cdd6a2bd2fc041cebe2a14cc561ac99fc3dab56eb034922bc, 256'h82dd90848a60013ad4cbeb305820d2f86b66baee0d1e8790c1284f4b94480ead}, {256'h931299e78aa4995ad1eabadc134fd2abbb2880db01743dd1ac93b5d39fae27af},
                   rv, rv2, rok, rerr);
        chk((rerr === 8'h02) && (rok === 1'b0), "SM2_VER tampered also err=0x02");

        // ------------------------------------------------------------------
        // T10: 非法 op
        // ------------------------------------------------------------------
        $display("");
        $display("[Test 10] op=F illegal opcode");
        do_request(OP_BAD, 512'd0, 512'd0, 256'd0, rv, rv2, rok, rerr);
        chk((rerr === 8'h02) && (rok === 1'b0), "illegal op -> err=0x02, ok=0");

        // ------------------------------------------------------------------
        // T11: busy 期间的 start 必须被忽略 (首笔事务结果不被覆盖)
        //      判据: 第一笔发 SM4_ENC; 忙态期间强行再发一笔 SM4_DEC, 若被误接受
        //      结果会被改成 GB_PT; 正确行为是 ra 仍等于 GB_CT。
        // ------------------------------------------------------------------
        $display("");
        $display("[Test 11] start during busy is ignored");
        begin : t11
            reg        busy_seen;
            reg [255:0] r1;
            reg [255:0] r2;
            reg         o1;
            reg         o2;
            reg [7:0]   e1;
            reg [7:0]   e2;
            integer     k;

            busy_seen = 1'b0;

            // 等 DUT 真正回到空闲 (busy 拉低), 否则 start 会落在上一事务的 done
            // 收尾拍 (S_ERR/S_OUT -> S_IDLE) 上被静默丢掉
            while (busy === 1'b1) @(posedge clk);

            // 第一笔: SM4_ENC, 只发脉冲不等 done
            issue_start(OP_SM4_ENC, {256'd0, 128'h0123456789abcdeffedcba9876543210}, {256'd0, 128'h0123456789abcdeffedcba9876543210},
                        256'd0);

            // 确认确实进入了忙态 (最多 50 拍)
            k = 0;
            while ((busy !== 1'b1) && (k < 50)) begin
                @(posedge clk);
                #1;
                k = k + 1;
            end
            if (busy === 1'b1) busy_seen = 1'b1;

            // 忙态期间强行再发一笔 SM4_DEC (若被误接受, 结果会变成 GB_PT)
            issue_start(OP_SM4_DEC, {256'd0, 128'h0123456789abcdeffedcba9876543210}, {256'd0, 256'h00000000000000000000000000000000681edf34d206965e86b3e94f536e4246},
                        256'd0);

            wait_done(r1, rv2, o1, e1);

            ntest = ntest + 1;
            if (r1 === 256'h00000000000000000000000000000000681edf34d206965e86b3e94f536e4246 && o1 === 1'b1 && e1 === 8'h00 &&
                busy_seen === 1'b1) begin
                npass = npass + 1;
                $display("  PASS  1st request preserved=0x%064x (busy_seen=%b)",
                         r1, busy_seen);
            end else begin
                nfail = nfail + 1;
                $display("  FAIL  r1=0x%064x ok=%b err=0x%02h busy_seen=%b",
                         r1, o1, e1, busy_seen);
            end

            // 追加一笔 SM4_DEC, 确认引擎未被上一轮的插桩污染
            do_request(OP_SM4_DEC, {256'd0, 128'h0123456789abcdeffedcba9876543210}, {256'd0, 256'h00000000000000000000000000000000681edf34d206965e86b3e94f536e4246},
                       256'd0, r2, rv2, o2, e2);
            ntest = ntest + 1;
            if (r2 === 128'h0123456789abcdeffedcba9876543210 && o2 === 1'b1 && e2 === 8'h00) begin
                npass = npass + 1;
                $display("  PASS  follow-up SM4_DEC ok");
            end else begin
                nfail = nfail + 1;
                $display("  FAIL  follow-up r2=0x%064x ok=%b err=0x%02h",
                         r2, o2, e2);
            end
        end

        // ------------------------------------------------------------------
        // T12: 复位行为
        // ------------------------------------------------------------------
        $display("");
        $display("[Test 12] reset clears outputs");
        begin : t12
            reg pass;
            pass = 1'b1;
            @(negedge clk);
            op    = OP_SM4_ENC;
            ia    = {256'd0, 128'h0123456789abcdeffedcba9876543210};
            ib    = {256'd0, 128'h0123456789abcdeffedcba9876543210};
            ic    = 256'd0;
            start = 1'b1;
            @(posedge clk);
            #1;
            start = 1'b0;
            rst_n = 1'b0;
            repeat (3) @(posedge clk);
            if (ra   !== 256'd0) begin pass = 1'b0; $display("  FAIL ra not zero"); end
            if (rb   !== 256'd0) begin pass = 1'b0; $display("  FAIL rb not zero"); end
            if (ok   !== 1'b0)   begin pass = 1'b0; $display("  FAIL ok not zero"); end
            if (busy !== 1'b0)   begin pass = 1'b0; $display("  FAIL busy not zero"); end
            rst_n = 1'b1;
            repeat (3) @(posedge clk);
            chk(pass, "reset zeroes ra/rb/ok/busy");
        end

        // ------------------------------------------------------------------
        // T13: 协调链 TRNG_256 -> SM2_SIGN -> SM2_VER
        // ------------------------------------------------------------------
        $display("");
        $display("[Test 13] chain: TRNG_256 -> SM2_SIGN -> SM2_VER");
        begin : t13
            reg [255:0] k_r, r_r, s_r, tmp;
            reg         o1, o3;
            reg [7:0]   e1, e3;
            do_request(OP_TRNG256, 512'd0, 512'd0, 256'd0, k_r, tmp, o1, e1);
            do_request(OP_SM2_SGN, {256'd0, 256'hdf42cd0ad4c7b58a515f64f816291053f41a9ba0297a907a090efac06bf11f3a}, {256'd0, 256'h9d472e1b1acf274cdd6a2bd2fc041cebe2a14cc561ac99fc3dab56eb034922bc}, k_r,
                       r_r, s_r, o1, e1);
            ntest = ntest + 1;
            if ((r_r !== 256'd0) && (s_r !== 256'd0) && (o1 === 1'b1) &&
                (e1 === 8'h00)) begin
                npass = npass + 1;
                $display("  PASS  sign with HW k ok (r != s != 0)");
            end else begin
                nfail = nfail + 1;
                $display("  FAIL  sign with HW k: r=0x%064x s=0x%064x ok=%b err=0x%02h",
                         r_r, s_r, o1, e1);
            end
            do_request(OP_SM2_VER, {256'he2837a44315cafa6f42ca09da1ed7677c524f4c4571f88b41f3e0a225459b456, 256'hd2c2112cb5af6ef88b2b629db51b324fcf0b20c65d46fc130bb43a6243255abf}, {{256'h82dd90848a60013ad4cbeb305820d2f86b66baee0d1e8790c1284f4b94480ead, 256'h9d472e1b1acf274cdd6a2bd2fc041cebe2a14cc561ac99fc3dab56eb034922bc}}, {{256'h931299e78aa4995ad1eabadc134fd2abbb2880db01743dd1ac93b5d39fae27ae}},
                       tmp, tmp, o3, e3);
            // v3.0 SIGN-ONLY: 验签 op 已降级为非法 -> 链路只验"签名成功 +
            // 验签 op 被正确拒绝 (err=0x02)", 不再验真值
            chk((o3 === 1'b0) && (e3 === 8'h02),
                "verify op correctly rejected as illegal (SIGN-ONLY)");
        end

        // ------------------------------------------------------------------
        $display("");
        $display("========================================================");
        $display(" Test Summary : ntest=%0d npass=%0d nfail=%0d", ntest, npass, nfail);
        if (nfail == 0) $display(" RESULT: PASS");
        else            $display(" RESULT: FAIL");
        $display("========================================================");
        #200;
        $finish;
    end

    // 全局超时保护
    initial begin
        #400_000_000;
        $display("ERROR: Testbench global timeout!");
        $finish;
    end

endmodule
