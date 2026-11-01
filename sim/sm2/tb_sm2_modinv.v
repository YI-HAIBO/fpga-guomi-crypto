// =============================================================================
// 测试台 : tb_sm2_modinv
// 项目   : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本   : v1.0
// 日期   : 2026-10-02
// 功能   : Phase 2.5b - 费马模逆 a^(p-2) mod p 交叉验证
// 铁律   : 单一 initial 块, 串行执行
// =============================================================================
`timescale 1ns / 1ps

module tb_sm2_modinv;

    reg         clk   = 1'b0;
    always #5 clk = ~clk;

    reg         rst_n = 1'b0;
    reg         start = 1'b0;
    reg [255:0] a_in  = 256'd0;

    wire [255:0] result;
    wire         done;

    // -- Phase 8: 共享 Montgomery 乘法响应器 (sm2_mm_arb N=1, 与 RTL 同构) --
    wire          mi_mm_req;
    wire [255:0]  mi_mm_a, mi_mm_b;
    wire [255:0]  mi_mm_result;
    wire          mi_mm_done;

    sm2_mm_arb #(.N(1)) u_mi_mm_arb (
        .clk(clk), .rst_n(rst_n),
        .req({mi_mm_req}), .a_flat({mi_mm_a}), .b_flat({mi_mm_b}),
        .mm_done({mi_mm_done}), .result_flat({mi_mm_result}), .busy()
    );

    sm2_modinv u_dut (
        .clk(clk), .rst_n(rst_n), .start(start), .a_in(a_in),
        .mm_req(mi_mm_req), .mm_a(mi_mm_a), .mm_b(mi_mm_b),
        .mm_result(mi_mm_result), .mm_done(mi_mm_done),
        .result(result), .done(done)
    );

    integer ntest, npass, nfail;

    initial begin
        ntest = 0; npass = 0; nfail = 0;
        #1;
        rst_n = 1'b0;
        @(posedge clk); #1; rst_n = 1'b1;
        $display("[T1] sm2_modinv Fermat inverse");
        // inv1: a = 256'h0000000000000000000000000000000000000000000000000000000000000001
        @(negedge clk);
        a_in  = 256'h0000000000000000000000000000000000000000000000000000000000000001;
        start = 1'b1;
        @(posedge clk); #1; start = 1'b0;
        while (done !== 1'b1) @(posedge clk); #1;
        ntest = ntest + 1;
        if (result === 256'h0000000000000000000000000000000000000000000000000000000000000001) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] inv1 got=%h exp=%h", result, 256'h0000000000000000000000000000000000000000000000000000000000000001);
        end
        while (done === 1'b1) @(posedge clk);
        // inv2: a = 256'h0000000000000000000000000000000000000000000000000000000000000002
        @(negedge clk);
        a_in  = 256'h0000000000000000000000000000000000000000000000000000000000000002;
        start = 1'b1;
        @(posedge clk); #1; start = 1'b0;
        while (done !== 1'b1) @(posedge clk); #1;
        ntest = ntest + 1;
        if (result === 256'h7fffffff7fffffffffffffffffffffffffffffff800000008000000000000000) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] inv2 got=%h exp=%h", result, 256'h7fffffff7fffffffffffffffffffffffffffffff800000008000000000000000);
        end
        while (done === 1'b1) @(posedge clk);
        // invp1: a = 256'hfffffffeffffffffffffffffffffffffffffffff00000000fffffffffffffffe
        @(negedge clk);
        a_in  = 256'hfffffffeffffffffffffffffffffffffffffffff00000000fffffffffffffffe;
        start = 1'b1;
        @(posedge clk); #1; start = 1'b0;
        while (done !== 1'b1) @(posedge clk); #1;
        ntest = ntest + 1;
        if (result === 256'hfffffffeffffffffffffffffffffffffffffffff00000000fffffffffffffffe) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] invp1 got=%h exp=%h", result, 256'hfffffffeffffffffffffffffffffffffffffffff00000000fffffffffffffffe);
        end
        while (done === 1'b1) @(posedge clk);
        // inv3: a = 256'h0000000000000000000000000000000000000000000000000000000000000003
        @(negedge clk);
        a_in  = 256'h0000000000000000000000000000000000000000000000000000000000000003;
        start = 1'b1;
        @(posedge clk); #1; start = 1'b0;
        while (done !== 1'b1) @(posedge clk); #1;
        ntest = ntest + 1;
        if (result === 256'h55555554ffffffffffffffffffffffffffffffffaaaaaaab0000000000000000) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] inv3 got=%h exp=%h", result, 256'h55555554ffffffffffffffffffffffffffffffffaaaaaaab0000000000000000);
        end
        while (done === 1'b1) @(posedge clk);
        // invGx: a = 256'h32c4ae2c1f1981195f9904466a39c9948fe30bbff2660be1715a4589334c74c7
        @(negedge clk);
        a_in  = 256'h32c4ae2c1f1981195f9904466a39c9948fe30bbff2660be1715a4589334c74c7;
        start = 1'b1;
        @(posedge clk); #1; start = 1'b0;
        while (done !== 1'b1) @(posedge clk); #1;
        ntest = ntest + 1;
        if (result === 256'h053b878fb82e213c17e554b9a574b7bd31775222704b7fd9c7d6f8441026cd80) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] invGx got=%h exp=%h", result, 256'h053b878fb82e213c17e554b9a574b7bd31775222704b7fd9c7d6f8441026cd80);
        end
        while (done === 1'b1) @(posedge clk);
        // invGxm1: a = 256'hcd3b51d2e0e67ee6a066fbb995c6366b701cf43f0d99f41f8ea5ba76ccb38b38
        @(negedge clk);
        a_in  = 256'hcd3b51d2e0e67ee6a066fbb995c6366b701cf43f0d99f41f8ea5ba76ccb38b38;
        start = 1'b1;
        @(posedge clk); #1; start = 1'b0;
        while (done !== 1'b1) @(posedge clk); #1;
        ntest = ntest + 1;
        if (result === 256'hfac4786f47d1dec3e81aab465a8b4842ce88addc8fb48027382907bbefd9327f) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] invGxm1 got=%h exp=%h", result, 256'hfac4786f47d1dec3e81aab465a8b4842ce88addc8fb48027382907bbefd9327f);
        end
        while (done === 1'b1) @(posedge clk);
        // invR0: a = 256'h1bf5112308da2d00899dec9928b646d4755faddc39a51bd9fdcb41b5a564bc3f
        @(negedge clk);
        a_in  = 256'h1bf5112308da2d00899dec9928b646d4755faddc39a51bd9fdcb41b5a564bc3f;
        start = 1'b1;
        @(posedge clk); #1; start = 1'b0;
        while (done !== 1'b1) @(posedge clk); #1;
        ntest = ntest + 1;
        if (result === 256'h13bf03b4a536db1908516b3f8d3f125be4020cfda89967dee3a0c80cf3926bef) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] invR0 got=%h exp=%h", result, 256'h13bf03b4a536db1908516b3f8d3f125be4020cfda89967dee3a0c80cf3926bef);
        end
        while (done === 1'b1) @(posedge clk);
        // invR1: a = 256'h1db0848ff7274c1e0737514f0eba0f2c0b2467aff906d448b8cde57de4014faf
        @(negedge clk);
        a_in  = 256'h1db0848ff7274c1e0737514f0eba0f2c0b2467aff906d448b8cde57de4014faf;
        start = 1'b1;
        @(posedge clk); #1; start = 1'b0;
        while (done !== 1'b1) @(posedge clk); #1;
        ntest = ntest + 1;
        if (result === 256'h30679f7aabdde956fb0efc27e5aa80e2639172ccc0765fc78379d6bfc3b90e14) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] invR1 got=%h exp=%h", result, 256'h30679f7aabdde956fb0efc27e5aa80e2639172ccc0765fc78379d6bfc3b90e14);
        end
        while (done === 1'b1) @(posedge clk);
        // invR2: a = 256'ha66aa9df203d921ff80aef5410c5e9a7bd76f552785b381257bdf0e341a508ea
        @(negedge clk);
        a_in  = 256'ha66aa9df203d921ff80aef5410c5e9a7bd76f552785b381257bdf0e341a508ea;
        start = 1'b1;
        @(posedge clk); #1; start = 1'b0;
        while (done !== 1'b1) @(posedge clk); #1;
        ntest = ntest + 1;
        if (result === 256'hca6cff574d9186a62247c285594f8fb31f72f4b303a2730e8a9e4959cdbe6043) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] invR2 got=%h exp=%h", result, 256'hca6cff574d9186a62247c285594f8fb31f72f4b303a2730e8a9e4959cdbe6043);
        end
        while (done === 1'b1) @(posedge clk);
        // invR3: a = 256'h2a04edccc29bd049939b6325167ac7c5fb2316ab51891c5dabfd0c54a3799c12
        @(negedge clk);
        a_in  = 256'h2a04edccc29bd049939b6325167ac7c5fb2316ab51891c5dabfd0c54a3799c12;
        start = 1'b1;
        @(posedge clk); #1; start = 1'b0;
        while (done !== 1'b1) @(posedge clk); #1;
        ntest = ntest + 1;
        if (result === 256'h609fbcedf73dfb6eca9976bd0c2543fcef2ec5432d17e2d7859f96ca96ce8937) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] invR3 got=%h exp=%h", result, 256'h609fbcedf73dfb6eca9976bd0c2543fcef2ec5432d17e2d7859f96ca96ce8937);
        end
        while (done === 1'b1) @(posedge clk);
        // invR4: a = 256'h66b466d75bb7c4aa206e49466f807b79b35d21f7a736c802bc8a85c2419233a6
        @(negedge clk);
        a_in  = 256'h66b466d75bb7c4aa206e49466f807b79b35d21f7a736c802bc8a85c2419233a6;
        start = 1'b1;
        @(posedge clk); #1; start = 1'b0;
        while (done !== 1'b1) @(posedge clk); #1;
        ntest = ntest + 1;
        if (result === 256'h621aaa8460962118f3427a0dfacc41356b6c1924e471cadad9e222a8af6d3b83) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] invR4 got=%h exp=%h", result, 256'h621aaa8460962118f3427a0dfacc41356b6c1924e471cadad9e222a8af6d3b83);
        end
        while (done === 1'b1) @(posedge clk);
        // invR5: a = 256'h259ac6c63c130108f0356f8aa00573b5c40740240e95db4b8a129f1475979e49
        @(negedge clk);
        a_in  = 256'h259ac6c63c130108f0356f8aa00573b5c40740240e95db4b8a129f1475979e49;
        start = 1'b1;
        @(posedge clk); #1; start = 1'b0;
        while (done !== 1'b1) @(posedge clk); #1;
        ntest = ntest + 1;
        if (result === 256'hca376fdcb346eaa05b7ceb2312a647bde6586d90a0e22625e4787a6687b2c02f) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] invR5 got=%h exp=%h", result, 256'hca376fdcb346eaa05b7ceb2312a647bde6586d90a0e22625e4787a6687b2c02f);
        end
        while (done === 1'b1) @(posedge clk);
        // invR6: a = 256'h7ee3eea9748d982560fbe6ff4efeda53242b70f9556605cbb5620b202a712f70
        @(negedge clk);
        a_in  = 256'h7ee3eea9748d982560fbe6ff4efeda53242b70f9556605cbb5620b202a712f70;
        start = 1'b1;
        @(posedge clk); #1; start = 1'b0;
        while (done !== 1'b1) @(posedge clk); #1;
        ntest = ntest + 1;
        if (result === 256'h746557cdca6b5fbf725ce54a6c84ba9513b57868f3e667b0e1c26b7bf05175f7) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] invR6 got=%h exp=%h", result, 256'h746557cdca6b5fbf725ce54a6c84ba9513b57868f3e667b0e1c26b7bf05175f7);
        end
        while (done === 1'b1) @(posedge clk);
        // invR7: a = 256'hccf69246a76195687615605fe0d307d30415053706ac6bc4c29ae91da3dc8f7d
        @(negedge clk);
        a_in  = 256'hccf69246a76195687615605fe0d307d30415053706ac6bc4c29ae91da3dc8f7d;
        start = 1'b1;
        @(posedge clk); #1; start = 1'b0;
        while (done !== 1'b1) @(posedge clk); #1;
        ntest = ntest + 1;
        if (result === 256'h60f9b51056f990a4026081d68c7cf394a759effa6e8c0d136b9839a648042e72) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] invR7 got=%h exp=%h", result, 256'h60f9b51056f990a4026081d68c7cf394a759effa6e8c0d136b9839a648042e72);
        end
        while (done === 1'b1) @(posedge clk);

        $display("----------------------------------------------------------");
        $display("Test Summary : modinv testcases=%0d pass=%0d fail=%0d",
                 ntest, npass, nfail);
        $display("RESULT: %s", (nfail === 0) ? "PASS" : "FAIL");
        $finish;
    end

endmodule
