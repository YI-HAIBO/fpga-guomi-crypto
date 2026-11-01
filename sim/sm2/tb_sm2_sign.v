// =============================================================================
// 模块名称 : tb_sm2_sign
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v1.0   (由 .workbuddy/tmp/gen_tb_25c.py 生成, 不要手改)
// 视角     : sim-verifier
// 覆盖     : sm2_pmul / sm2_nmul / sm2_ninv / sm2_sign (签名 + 验签 + 边界)
// =============================================================================
`timescale 1ns / 1ps

module tb_sm2_sign;

    reg          clk = 1'b0;
    always #5 clk = ~clk;            // 100MHz

    // ---------------- 时钟与复位 ----------------
    reg rst_n = 1'b0;
    initial begin
        #23; rst_n = 1'b1;
    end

    // ---------------- sm2_pmul ----------------
    reg          pm_start;
    reg  [255:0] pm_scalar, pm_px, pm_py;
    wire [255:0] pm_xo, pm_yo, pm_zo;
    wire         pm_inf, pm_done;
    // -- Phase 8: sm2_pmul 的 point_add 乘法请求响应器 (sm2_mm_arb N=1) --
    wire          pm_mm_req;
    wire [255:0]  pm_mm_a, pm_mm_b;
    wire [255:0]  pm_mm_result;
    wire          pm_mm_done;

    sm2_mm_arb #(.N(1)) u_pm_mm_arb (
        .clk(clk), .rst_n(rst_n),
        .req({pm_mm_req}), .a_flat({pm_mm_a}), .b_flat({pm_mm_b}),
        .mm_done({pm_mm_done}), .result_flat({pm_mm_result}), .busy()
    );

    sm2_pmul u_pmul (
        .clk(clk), .rst_n(rst_n), .start(pm_start),
        .scalar(pm_scalar), .px(pm_px), .py(pm_py),
        .x_out(pm_xo), .y_out(pm_yo), .z_out(pm_zo),
        .inf_flag(pm_inf), .done(pm_done),
        .pa_mm_req(pm_mm_req), .pa_mm_a(pm_mm_a), .pa_mm_b(pm_mm_b),
        .pa_mm_result(pm_mm_result), .pa_mm_done(pm_mm_done)
    );

    // ---------------- sm2_nmul / sm2_ninv ----------------
    reg          nm_start;
    reg  [255:0] nm_a, nm_b;
    wire [255:0] nm_res;
    wire         nm_done;
    sm2_nmul u_nmul (
        .clk(clk), .rst_n(rst_n), .start(nm_start),
        .a(nm_a), .b(nm_b), .result(nm_res), .done(nm_done)
    );
    reg          ni_start;
    reg  [255:0] ni_a;
    wire [255:0] ni_res;
    wire         ni_done;
    // -- Phase 8: sm2_ninv 的 mod-n 乘法请求响应器 (sm2_nm_arb N=1) --
    wire          ni_nm_req;
    wire [255:0]  ni_nm_a, ni_nm_b;
    wire [255:0]  ni_nm_result;
    wire          ni_nm_done;

    sm2_nm_arb #(.N(1)) u_ni_nm_arb (
        .clk(clk), .rst_n(rst_n),
        .req({ni_nm_req}), .a_flat({ni_nm_a}), .b_flat({ni_nm_b}),
        .nm_done({ni_nm_done}), .result_flat({ni_nm_result}), .busy()
    );

    sm2_ninv u_ninv (
        .clk(clk), .rst_n(rst_n), .start(ni_start),
        .a(ni_a), .result(ni_res), .done(ni_done),
        .nm_req(ni_nm_req), .nm_a(ni_nm_a), .nm_b(ni_nm_b),
        .nm_result(ni_nm_result), .nm_done(ni_nm_done)
    );

    // ---------------- sm2_sign (v3.0 SIGN-ONLY: op/qx/qy/r/s/sig_ok 端口已删除) ----
    reg          sg_start;
    reg  [255:0] sg_d, sg_e, sg_k;
    wire [255:0] sg_rout, sg_sout;
    sm2_sign u_sign (
        .clk(clk), .rst_n(rst_n), .start(sg_start),
        .d_in(sg_d), .e_in(sg_e), .k_in(sg_k),
        .r_out(sg_rout), .s_out(sg_sout),
        .err(sg_err), .done(sg_done)
    );

    wire sg_err, sg_done;

    integer ntest = 0, npass = 0, nfail = 0;
    integer tk = 0;   // wait_done 的超时计数器 (必须模块级: -g2005 不支持块内声明)

    // =========================================================================
    // 单一 initial 块: 全部测试串行
    // =========================================================================
    initial begin
        pm_start = 1'b0; pm_scalar = 256'd0; pm_px = 256'd0; pm_py = 256'd0;
        nm_start = 1'b0; nm_a = 256'd0; nm_b = 256'd0;
        ni_start = 1'b0; ni_a = 256'd0;
        sg_start = 1'b0; sg_d = 256'd0; sg_e = 256'd0; sg_k = 256'd0;
        #23;   // 等复位释放

        $display("[T1] sm2_pmul  [k]G  (Jacobian, Montgomery 形式)");
        // [T1.k1]
        @(negedge clk);
        pm_scalar = 256'h0000000000000000000000000000000000000000000000000000000000000001;
        pm_px = 256'h91167a5ee1c13b05d6a1ed99ac24c3c33e7981eddca6c05061328990f418029e;
        pm_py = 256'h63cd65d481d735bd8d4cfb066e2a48f8c1f5e5788d3295fac1354e593c2d0ddd;
        pm_start = 1'b1;
        @(posedge clk); #1; pm_start = 1'b0;
        begin
            tk = 0;
            while (pm_done !== 1'b1 && tk < 2000000) begin
                @(posedge clk); tk = tk + 1;
            end
            if (pm_done !== 1'b1) begin
                nfail = nfail + 1;
                $display("[TIMEOUT] T1.k1  no done after %0d cycles", 2000000);
            end else begin
                @(posedge clk); #1;
            end
        end
        ntest = ntest + 1;
        if (pm_xo === 256'h91167a5ee1c13b05d6a1ed99ac24c3c33e7981eddca6c05061328990f418029e && pm_yo === 256'h63cd65d481d735bd8d4cfb066e2a48f8c1f5e5788d3295fac1354e593c2d0ddd && pm_zo === 256'h0000000100000000000000000000000000000000ffffffff0000000000000001 && pm_inf === 1'b0) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] T1.k1  got X=%h Y=%h Z=%h inf=%b", pm_xo, pm_yo, pm_zo, pm_inf);
            $display("[FAIL] T1.k1  exp X=256'h91167a5ee1c13b05d6a1ed99ac24c3c33e7981eddca6c05061328990f418029e Y=256'h63cd65d481d735bd8d4cfb066e2a48f8c1f5e5788d3295fac1354e593c2d0ddd Z=256'h0000000100000000000000000000000000000000ffffffff0000000000000001 inf=1'b0");
        end
        // [T1.k2]
        @(negedge clk);
        pm_scalar = 256'h0000000000000000000000000000000000000000000000000000000000000002;
        pm_px = 256'h91167a5ee1c13b05d6a1ed99ac24c3c33e7981eddca6c05061328990f418029e;
        pm_py = 256'h63cd65d481d735bd8d4cfb066e2a48f8c1f5e5788d3295fac1354e593c2d0ddd;
        pm_start = 1'b1;
        @(posedge clk); #1; pm_start = 1'b0;
        begin
            tk = 0;
            while (pm_done !== 1'b1 && tk < 2000000) begin
                @(posedge clk); tk = tk + 1;
            end
            if (pm_done !== 1'b1) begin
                nfail = nfail + 1;
                $display("[TIMEOUT] T1.k2  no done after %0d cycles", 2000000);
            end else begin
                @(posedge clk); #1;
            end
        end
        ntest = ntest + 1;
        if (pm_xo === 256'h398874c476a3b1f77aef3e862601440903243d78d5b614a62eda8381e63c48d6 && pm_yo === 256'h1fbbdfdddaf4fd475a86a7ae64921d4829f04a88f6cf4dc128385681c1a73e40 && pm_zo === 256'hc79acba903ae6b7b1a99f60cdc5491f183ebcaf11a652bf5826a9cb2785a1bba && pm_inf === 1'b0) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] T1.k2  got X=%h Y=%h Z=%h inf=%b", pm_xo, pm_yo, pm_zo, pm_inf);
            $display("[FAIL] T1.k2  exp X=256'h398874c476a3b1f77aef3e862601440903243d78d5b614a62eda8381e63c48d6 Y=256'h1fbbdfdddaf4fd475a86a7ae64921d4829f04a88f6cf4dc128385681c1a73e40 Z=256'hc79acba903ae6b7b1a99f60cdc5491f183ebcaf11a652bf5826a9cb2785a1bba inf=1'b0");
        end
        // [T1.k3]
        @(negedge clk);
        pm_scalar = 256'h0000000000000000000000000000000000000000000000000000000000000003;
        pm_px = 256'h91167a5ee1c13b05d6a1ed99ac24c3c33e7981eddca6c05061328990f418029e;
        pm_py = 256'h63cd65d481d735bd8d4cfb066e2a48f8c1f5e5788d3295fac1354e593c2d0ddd;
        pm_start = 1'b1;
        @(posedge clk); #1; pm_start = 1'b0;
        begin
            tk = 0;
            while (pm_done !== 1'b1 && tk < 2000000) begin
                @(posedge clk); tk = tk + 1;
            end
            if (pm_done !== 1'b1) begin
                nfail = nfail + 1;
                $display("[TIMEOUT] T1.k3  no done after %0d cycles", 2000000);
            end else begin
                @(posedge clk); #1;
            end
        end
        ntest = ntest + 1;
        if (pm_xo === 256'hc056b481df2300a1775dbef2f7c0df90f147ad031f142af014a5303d4d263438 && pm_yo === 256'h4c1055380f2f77d3ce47047418c7ea5b082b3ab8cede9e2095fa23b42074661f && pm_zo === 256'h385bdb480d7bd163fa7be0a4df92e43b4f9ad9a70221a97b5d1dc679a7ac999c && pm_inf === 1'b0) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] T1.k3  got X=%h Y=%h Z=%h inf=%b", pm_xo, pm_yo, pm_zo, pm_inf);
            $display("[FAIL] T1.k3  exp X=256'hc056b481df2300a1775dbef2f7c0df90f147ad031f142af014a5303d4d263438 Y=256'h4c1055380f2f77d3ce47047418c7ea5b082b3ab8cede9e2095fa23b42074661f Z=256'h385bdb480d7bd163fa7be0a4df92e43b4f9ad9a70221a97b5d1dc679a7ac999c inf=1'b0");
        end
        // [T1.k7]
        @(negedge clk);
        pm_scalar = 256'h0000000000000000000000000000000000000000000000000000000000000007;
        pm_px = 256'h91167a5ee1c13b05d6a1ed99ac24c3c33e7981eddca6c05061328990f418029e;
        pm_py = 256'h63cd65d481d735bd8d4cfb066e2a48f8c1f5e5788d3295fac1354e593c2d0ddd;
        pm_start = 1'b1;
        @(posedge clk); #1; pm_start = 1'b0;
        begin
            tk = 0;
            while (pm_done !== 1'b1 && tk < 2000000) begin
                @(posedge clk); tk = tk + 1;
            end
            if (pm_done !== 1'b1) begin
                nfail = nfail + 1;
                $display("[TIMEOUT] T1.k7  no done after %0d cycles", 2000000);
            end else begin
                @(posedge clk); #1;
            end
        end
        ntest = ntest + 1;
        if (pm_xo === 256'h3833abe60a3b6287dfdce182bdb9c336debf2780c73f4148cb43190fa206fda9 && pm_yo === 256'h17e40cdfcdda2278198c519ba8a8d7098a375f58a26dd8622ff8823c2633e86c && pm_zo === 256'h2ca6775da7d53900965b28212f13795b3a08867bcadf468ef505cfc8328d4d38 && pm_inf === 1'b0) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] T1.k7  got X=%h Y=%h Z=%h inf=%b", pm_xo, pm_yo, pm_zo, pm_inf);
            $display("[FAIL] T1.k7  exp X=256'h3833abe60a3b6287dfdce182bdb9c336debf2780c73f4148cb43190fa206fda9 Y=256'h17e40cdfcdda2278198c519ba8a8d7098a375f58a26dd8622ff8823c2633e86c Z=256'h2ca6775da7d53900965b28212f13795b3a08867bcadf468ef505cfc8328d4d38 inf=1'b0");
        end
        // [T1.k255]
        @(negedge clk);
        pm_scalar = 256'h00000000000000000000000000000000000000000000000000000000000000ff;
        pm_px = 256'h91167a5ee1c13b05d6a1ed99ac24c3c33e7981eddca6c05061328990f418029e;
        pm_py = 256'h63cd65d481d735bd8d4cfb066e2a48f8c1f5e5788d3295fac1354e593c2d0ddd;
        pm_start = 1'b1;
        @(posedge clk); #1; pm_start = 1'b0;
        begin
            tk = 0;
            while (pm_done !== 1'b1 && tk < 2000000) begin
                @(posedge clk); tk = tk + 1;
            end
            if (pm_done !== 1'b1) begin
                nfail = nfail + 1;
                $display("[TIMEOUT] T1.k255  no done after %0d cycles", 2000000);
            end else begin
                @(posedge clk); #1;
            end
        end
        ntest = ntest + 1;
        if (pm_xo === 256'h2876c1a9ccc3ebe38c4c2f9c5ee78f23ea1bb27afe8c05608db6a9008e247f78 && pm_yo === 256'hbb0235bcadd2ca0f53482e7e85791af5331b87194bbf98f6545e0d8ec9e8b840 && pm_zo === 256'hebb50321e598a31fb3d9115c16d204308250142f3eee00289c105489db7efbde && pm_inf === 1'b0) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] T1.k255  got X=%h Y=%h Z=%h inf=%b", pm_xo, pm_yo, pm_zo, pm_inf);
            $display("[FAIL] T1.k255  exp X=256'h2876c1a9ccc3ebe38c4c2f9c5ee78f23ea1bb27afe8c05608db6a9008e247f78 Y=256'hbb0235bcadd2ca0f53482e7e85791af5331b87194bbf98f6545e0d8ec9e8b840 Z=256'hebb50321e598a31fb3d9115c16d204308250142f3eee00289c105489db7efbde inf=1'b0");
        end
        // [T1.k0]
        @(negedge clk);
        pm_scalar = 256'h8000000000000000000000000000000000000000000000000000000000000000;
        pm_px = 256'h91167a5ee1c13b05d6a1ed99ac24c3c33e7981eddca6c05061328990f418029e;
        pm_py = 256'h63cd65d481d735bd8d4cfb066e2a48f8c1f5e5788d3295fac1354e593c2d0ddd;
        pm_start = 1'b1;
        @(posedge clk); #1; pm_start = 1'b0;
        begin
            tk = 0;
            while (pm_done !== 1'b1 && tk < 2000000) begin
                @(posedge clk); tk = tk + 1;
            end
            if (pm_done !== 1'b1) begin
                nfail = nfail + 1;
                $display("[TIMEOUT] T1.k0  no done after %0d cycles", 2000000);
            end else begin
                @(posedge clk); #1;
            end
        end
        ntest = ntest + 1;
        if (pm_xo === 256'h4b217961bd51c806daff6b4f9ef1ff755cba716ed28bd92483ca77e6da678bc7 && pm_yo === 256'hb03effa0240e7d32b014c272a92f33c2d1fd2d08c7a9ce86636228c569931c15 && pm_zo === 256'h443c86da317ade397c190c1e9081c92c5073a7ac0cf7c17818c5b259f45fbbe3 && pm_inf === 1'b0) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] T1.k0  got X=%h Y=%h Z=%h inf=%b", pm_xo, pm_yo, pm_zo, pm_inf);
            $display("[FAIL] T1.k0  exp X=256'h4b217961bd51c806daff6b4f9ef1ff755cba716ed28bd92483ca77e6da678bc7 Y=256'hb03effa0240e7d32b014c272a92f33c2d1fd2d08c7a9ce86636228c569931c15 Z=256'h443c86da317ade397c190c1e9081c92c5073a7ac0cf7c17818c5b259f45fbbe3 inf=1'b0");
        end
        // [T1.k154548465]
        @(negedge clk);
        pm_scalar = 256'h67e5da215ed68ab48a949f26ea3ed8f8dcdc8696243aa3d1ad68138b293638f1;
        pm_px = 256'h91167a5ee1c13b05d6a1ed99ac24c3c33e7981eddca6c05061328990f418029e;
        pm_py = 256'h63cd65d481d735bd8d4cfb066e2a48f8c1f5e5788d3295fac1354e593c2d0ddd;
        pm_start = 1'b1;
        @(posedge clk); #1; pm_start = 1'b0;
        begin
            tk = 0;
            while (pm_done !== 1'b1 && tk < 2000000) begin
                @(posedge clk); tk = tk + 1;
            end
            if (pm_done !== 1'b1) begin
                nfail = nfail + 1;
                $display("[TIMEOUT] T1.k154548465  no done after %0d cycles", 2000000);
            end else begin
                @(posedge clk); #1;
            end
        end
        ntest = ntest + 1;
        if (pm_xo === 256'ha6210fc743541bd4f8efc0641de4a4282278a054e0405a9425f77f7971400186 && pm_yo === 256'hc045deff83fb4676a6d4e9a4352cf8dafd0d2a3e92d8ad327fdc2ad7f6eba1f2 && pm_zo === 256'hd242e300439809858acbabc7df7e5db9997a696ce9cd82df9c8d6a0a7c4f5c2f && pm_inf === 1'b0) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] T1.k154548465  got X=%h Y=%h Z=%h inf=%b", pm_xo, pm_yo, pm_zo, pm_inf);
            $display("[FAIL] T1.k154548465  exp X=256'ha6210fc743541bd4f8efc0641de4a4282278a054e0405a9425f77f7971400186 Y=256'hc045deff83fb4676a6d4e9a4352cf8dafd0d2a3e92d8ad327fdc2ad7f6eba1f2 Z=256'hd242e300439809858acbabc7df7e5db9997a696ce9cd82df9c8d6a0a7c4f5c2f inf=1'b0");
        end
        // [T1.k55268986]
        @(negedge clk);
        pm_scalar = 256'h5101d9e37f9bf305e524e32ca697706e17faed2ae91d5cc05a70546bb34b567a;
        pm_px = 256'h91167a5ee1c13b05d6a1ed99ac24c3c33e7981eddca6c05061328990f418029e;
        pm_py = 256'h63cd65d481d735bd8d4cfb066e2a48f8c1f5e5788d3295fac1354e593c2d0ddd;
        pm_start = 1'b1;
        @(posedge clk); #1; pm_start = 1'b0;
        begin
            tk = 0;
            while (pm_done !== 1'b1 && tk < 2000000) begin
                @(posedge clk); tk = tk + 1;
            end
            if (pm_done !== 1'b1) begin
                nfail = nfail + 1;
                $display("[TIMEOUT] T1.k55268986  no done after %0d cycles", 2000000);
            end else begin
                @(posedge clk); #1;
            end
        end
        ntest = ntest + 1;
        if (pm_xo === 256'ha3aad40831064dacdf725e61e361a04b60ed8cf59fd5b76b9b75d372a92b56bb && pm_yo === 256'hfd64d37f6a8bb48fceaffe1eb8490f567bd193b8b23abf0b6691dba0a3898eec && pm_zo === 256'hc7404497346061425a7135d63c78d3648a5dc3cb4908dc95bab9dc59cab274bb && pm_inf === 1'b0) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] T1.k55268986  got X=%h Y=%h Z=%h inf=%b", pm_xo, pm_yo, pm_zo, pm_inf);
            $display("[FAIL] T1.k55268986  exp X=256'ha3aad40831064dacdf725e61e361a04b60ed8cf59fd5b76b9b75d372a92b56bb Y=256'hfd64d37f6a8bb48fceaffe1eb8490f567bd193b8b23abf0b6691dba0a3898eec Z=256'hc7404497346061425a7135d63c78d3648a5dc3cb4908dc95bab9dc59cab274bb inf=1'b0");
        end
        // [T1.kN]
        @(negedge clk);
        pm_scalar = 256'hfffffffeffffffffffffffffffffffff7203df6b21c6052b53bbf40939d54123;
        pm_px = 256'h91167a5ee1c13b05d6a1ed99ac24c3c33e7981eddca6c05061328990f418029e;
        pm_py = 256'h63cd65d481d735bd8d4cfb066e2a48f8c1f5e5788d3295fac1354e593c2d0ddd;
        pm_start = 1'b1;
        @(posedge clk); #1; pm_start = 1'b0;
        begin
            tk = 0;
            while (pm_done !== 1'b1 && tk < 2000000) begin
                @(posedge clk); tk = tk + 1;
            end
            if (pm_done !== 1'b1) begin
                nfail = nfail + 1;
                $display("[TIMEOUT] T1.kN  no done after %0d cycles", 2000000);
            end else begin
                @(posedge clk); #1;
            end
        end
        ntest = ntest + 1;
        if (pm_xo === 256'd0 && pm_yo === 256'd0 && pm_zo === 256'd0 && pm_inf === 1'b1) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] T1.kN  got X=%h Y=%h Z=%h inf=%b", pm_xo, pm_yo, pm_zo, pm_inf);
            $display("[FAIL] T1.kN  exp X=256'd0 Y=256'd0 Z=256'd0 inf=1'b1");
        end
        // [T1.k0]
        @(negedge clk);
        pm_scalar = 256'h0000000000000000000000000000000000000000000000000000000000000000;
        pm_px = 256'h91167a5ee1c13b05d6a1ed99ac24c3c33e7981eddca6c05061328990f418029e;
        pm_py = 256'h63cd65d481d735bd8d4cfb066e2a48f8c1f5e5788d3295fac1354e593c2d0ddd;
        pm_start = 1'b1;
        @(posedge clk); #1; pm_start = 1'b0;
        begin
            tk = 0;
            while (pm_done !== 1'b1 && tk < 2000000) begin
                @(posedge clk); tk = tk + 1;
            end
            if (pm_done !== 1'b1) begin
                nfail = nfail + 1;
                $display("[TIMEOUT] T1.k0  no done after %0d cycles", 2000000);
            end else begin
                @(posedge clk); #1;
            end
        end
        ntest = ntest + 1;
        if (pm_xo === 256'd0 && pm_yo === 256'd0 && pm_zo === 256'd0 && pm_inf === 1'b1) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] T1.k0  got X=%h Y=%h Z=%h inf=%b", pm_xo, pm_yo, pm_zo, pm_inf);
            $display("[FAIL] T1.k0  exp X=256'd0 Y=256'd0 Z=256'd0 inf=1'b1");
        end

        $display("[T2] sm2_nmul  a*b mod n");
        // [T2.15162]
        @(negedge clk);
        nm_a = 256'hd20a5679e5b210469c866455dd2d0b60bc11492f9bdd4bf87a1d291745a63b3a;
        nm_b = 256'hb87ebb0e732df182ae712d62e0b634a8e062f74a0378fbf0444c2992c3556d9c;
        nm_start = 1'b1;
        @(posedge clk); #1; nm_start = 1'b0;
        begin
            tk = 0;
            while (nm_done !== 1'b1 && tk < 2000000) begin
                @(posedge clk); tk = tk + 1;
            end
            if (nm_done !== 1'b1) begin
                nfail = nfail + 1;
                $display("[TIMEOUT] T2.15162  no done after %0d cycles", 2000000);
            end else begin
                @(posedge clk); #1;
            end
        end
        if (nm_res === 256'h4ab6fcb190c25dfe738a151e0d4a5905e910f64efd7566b1e85e7df5c2e0460f) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] T2.15162  got nm_res=%h exp=256'h4ab6fcb190c25dfe738a151e0d4a5905e910f64efd7566b1e85e7df5c2e0460f", nm_res);
        end
        ntest = ntest + 1;
        // [T2.33951]
        @(negedge clk);
        nm_a = 256'h1d45e903a25d509383264c83155430158449250160e321c6493cc2ee3545849f;
        nm_b = 256'hc3e1490ce4469563dbc01b571c0628f3a46b9d7436d4eb42c2aab1d0041bb9cd;
        nm_start = 1'b1;
        @(posedge clk); #1; nm_start = 1'b0;
        begin
            tk = 0;
            while (nm_done !== 1'b1 && tk < 2000000) begin
                @(posedge clk); tk = tk + 1;
            end
            if (nm_done !== 1'b1) begin
                nfail = nfail + 1;
                $display("[TIMEOUT] T2.33951  no done after %0d cycles", 2000000);
            end else begin
                @(posedge clk); #1;
            end
        end
        if (nm_res === 256'h3e3ffad36a5538a6336720a6756400b3a25ef9a2bf65a5c167a8845b747b0ce1) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] T2.33951  got nm_res=%h exp=256'h3e3ffad36a5538a6336720a6756400b3a25ef9a2bf65a5c167a8845b747b0ce1", nm_res);
        end
        ntest = ntest + 1;
        // [T2.12954]
        @(negedge clk);
        nm_a = 256'hc2b6e55eebd601400d2614bab21901e9fec7e0521344b18a5657093620d7329a;
        nm_b = 256'h7bbc73ff5377fd2acaf0327d42aec0486cbc5204743f8dfe9f84a59324b15334;
        nm_start = 1'b1;
        @(posedge clk); #1; nm_start = 1'b0;
        begin
            tk = 0;
            while (nm_done !== 1'b1 && tk < 2000000) begin
                @(posedge clk); tk = tk + 1;
            end
            if (nm_done !== 1'b1) begin
                nfail = nfail + 1;
                $display("[TIMEOUT] T2.12954  no done after %0d cycles", 2000000);
            end else begin
                @(posedge clk); #1;
            end
        end
        if (nm_res === 256'h2a21e8856822b5114ea8061e90b462d82f9db6d5356db46a965c6fa05b861304) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] T2.12954  got nm_res=%h exp=256'h2a21e8856822b5114ea8061e90b462d82f9db6d5356db46a965c6fa05b861304", nm_res);
        end
        ntest = ntest + 1;
        // [T2.11085]
        @(negedge clk);
        nm_a = 256'h6599818f643e238db02cb9edd0e7a4557db7c8c23d43f2c7c5d68ab197a92b4d;
        nm_b = 256'h963bd679cea9b1340d539c6e31f4b240afaa322adf0975bb6223415b2ff73db9;
        nm_start = 1'b1;
        @(posedge clk); #1; nm_start = 1'b0;
        begin
            tk = 0;
            while (nm_done !== 1'b1 && tk < 2000000) begin
                @(posedge clk); tk = tk + 1;
            end
            if (nm_done !== 1'b1) begin
                nfail = nfail + 1;
                $display("[TIMEOUT] T2.11085  no done after %0d cycles", 2000000);
            end else begin
                @(posedge clk); #1;
            end
        end
        if (nm_res === 256'hc2408ec5f6d0b0dffeb76fc2d898e7aee354a8bfe73d3a62da44b554b2773bd2) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] T2.11085  got nm_res=%h exp=256'hc2408ec5f6d0b0dffeb76fc2d898e7aee354a8bfe73d3a62da44b554b2773bd2", nm_res);
        end
        ntest = ntest + 1;
        // [T2.small]
        @(negedge clk);
        nm_a = 256'h0000000000000000000000000000000000000000000000000000000000000003;
        nm_b = 256'h0000000000000000000000000000000000000000000000000000000000000005;
        nm_start = 1'b1;
        @(posedge clk); #1; nm_start = 1'b0;
        begin
            tk = 0;
            while (nm_done !== 1'b1 && tk < 2000000) begin
                @(posedge clk); tk = tk + 1;
            end
            if (nm_done !== 1'b1) begin
                nfail = nfail + 1;
                $display("[TIMEOUT] T2.small  no done after %0d cycles", 2000000);
            end else begin
                @(posedge clk); #1;
            end
        end
        if (nm_res === 256'h000000000000000000000000000000000000000000000000000000000000000f) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] T2.small  got nm_res=%h exp=256'h000000000000000000000000000000000000000000000000000000000000000f", nm_res);
        end
        ntest = ntest + 1;

        $display("[T3] sm2_ninv  a^-1 mod n");
        // [T3.2]
        @(negedge clk);
        ni_a = 256'h0000000000000000000000000000000000000000000000000000000000000002;
        ni_start = 1'b1;
        @(posedge clk); #1; ni_start = 1'b0;
        begin
            tk = 0;
            while (ni_done !== 1'b1 && tk < 2000000) begin
                @(posedge clk); tk = tk + 1;
            end
            if (ni_done !== 1'b1) begin
                nfail = nfail + 1;
                $display("[TIMEOUT] T3.2  no done after %0d cycles", 2000000);
            end else begin
                @(posedge clk); #1;
            end
        end
        if (ni_res === 256'h7fffffff7fffffffffffffffffffffffb901efb590e30295a9ddfa049ceaa092) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] T3.2  got ni_res=%h exp=256'h7fffffff7fffffffffffffffffffffffb901efb590e30295a9ddfa049ceaa092", ni_res);
        end
        ntest = ntest + 1;
        // [T3.3]
        @(negedge clk);
        ni_a = 256'h0000000000000000000000000000000000000000000000000000000000000003;
        ni_start = 1'b1;
        @(posedge clk); #1; ni_start = 1'b0;
        begin
            tk = 0;
            while (ni_done !== 1'b1 && tk < 2000000) begin
                @(posedge clk); tk = tk + 1;
            end
            if (ni_done !== 1'b1) begin
                nfail = nfail + 1;
                $display("[TIMEOUT] T3.3  no done after %0d cycles", 2000000);
            end else begin
                @(posedge clk); #1;
            end
        end
        if (ni_res === 256'haaaaaaa9ffffffffffffffffffffffffa157ea476bd958c78d27f806268e2b6d) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] T3.3  got ni_res=%h exp=256'haaaaaaa9ffffffffffffffffffffffffa157ea476bd958c78d27f806268e2b6d", ni_res);
        end
        ntest = ntest + 1;
        // [T3.5]
        @(negedge clk);
        ni_a = 256'h0000000000000000000000000000000000000000000000000000000000000005;
        ni_start = 1'b1;
        @(posedge clk); #1; ni_start = 1'b0;
        begin
            tk = 0;
            while (ni_done !== 1'b1 && tk < 2000000) begin
                @(posedge clk); tk = tk + 1;
            end
            if (ni_done !== 1'b1) begin
                nfail = nfail + 1;
                $display("[TIMEOUT] T3.5  no done after %0d cycles", 2000000);
            end else begin
                @(posedge clk); #1;
            end
        end
        if (ni_res === 256'h99999998ffffffffffffffffffffffffaacf1fa6addd364d323d926bef7ff3e2) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] T3.5  got ni_res=%h exp=256'h99999998ffffffffffffffffffffffffaacf1fa6addd364d323d926bef7ff3e2", ni_res);
        end
        ntest = ntest + 1;
        // [T3.182347953]
        @(negedge clk);
        ni_a = 256'h000000000000000000000000000000000000000000000000000000003ade68b1;
        ni_start = 1'b1;
        @(posedge clk); #1; ni_start = 1'b0;
        begin
            tk = 0;
            while (ni_done !== 1'b1 && tk < 2000000) begin
                @(posedge clk); tk = tk + 1;
            end
            if (ni_done !== 1'b1) begin
                nfail = nfail + 1;
                $display("[TIMEOUT] T3.182347953  no done after %0d cycles", 2000000);
            end else begin
                @(posedge clk); #1;
            end
        end
        if (ni_res === 256'h4be716dfef96b2e577c7945a4899914400b0f447200672245e3e228ba3d3d41e) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] T3.182347953  got ni_res=%h exp=256'h4be716dfef96b2e577c7945a4899914400b0f447200672245e3e228ba3d3d41e", ni_res);
        end
        ntest = ntest + 1;
        // [T3.164970785]
        @(negedge clk);
        ni_a = 256'hfffffffeffffffffffffffffffffffff7203df6b21c6052b53bbf40939d54121;
        ni_start = 1'b1;
        @(posedge clk); #1; ni_start = 1'b0;
        begin
            tk = 0;
            while (ni_done !== 1'b1 && tk < 2000000) begin
                @(posedge clk); tk = tk + 1;
            end
            if (ni_done !== 1'b1) begin
                nfail = nfail + 1;
                $display("[TIMEOUT] T3.164970785  no done after %0d cycles", 2000000);
            end else begin
                @(posedge clk); #1;
            end
        end
        if (ni_res === 256'h7fffffff7fffffffffffffffffffffffb901efb590e30295a9ddfa049ceaa091) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] T3.164970785  got ni_res=%h exp=256'h7fffffff7fffffffffffffffffffffffb901efb590e30295a9ddfa049ceaa091", ni_res);
        end
        ntest = ntest + 1;

        $display("[T4] sm2_sign  sign  (标准式 r/s)");
        // [T4.0]
        @(negedge clk);
        sg_d  = 256'ha9aa4026022809eefe9c27ba5935c64e795c83923a1e9668cf1bac6cf858c4d7;
        sg_e  = 256'h58f1ab520bfdfab566e54c08b64b75392586b6fee4067adef587981741222a41;
        sg_k  = 256'h44541f3a3c85616c0886482bf44b6c1a3290248e8ac78b3ddf49f3aa92d2e5df;
        sg_start = 1'b1;
        @(posedge clk); #1; sg_start = 1'b0;
        begin
            tk = 0;
            while (sg_done !== 1'b1 && tk < 2000000) begin
                @(posedge clk); tk = tk + 1;
            end
            if (sg_done !== 1'b1) begin
                nfail = nfail + 1;
                $display("[TIMEOUT] T4.0  no done after %0d cycles", 2000000);
            end else begin
                @(posedge clk); #1;
            end
        end
        ntest = ntest + 1;
        if (sg_rout === 256'ha57162f434afb05efdd70546160e56952de9a968251da63f5e84d818def357b8 && sg_sout === 256'h6ca7fa2ec10979ff92e5f226447fbb46512dc47af74f650664a3c3d96e47280a && sg_err === 1'b0) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] T4.0  got r=%h s=%h err=%b", sg_rout, sg_sout, sg_err);
            $display("[FAIL] T4.0  exp r=256'ha57162f434afb05efdd70546160e56952de9a968251da63f5e84d818def357b8 s=256'h6ca7fa2ec10979ff92e5f226447fbb46512dc47af74f650664a3c3d96e47280a");
        end
        // [T4.1]
        @(negedge clk);
        sg_d  = 256'h729156fd68fe8578d8ffd6ec4b10bb4bc7f5a7c9a39ee07e8ec2d7cc56858054;
        sg_e  = 256'h7915f4f86c89f4c1a4cd8ff8eb2393d6e46cc13f2f504bd5b588a9b0d4bff273;
        sg_k  = 256'h09a7faa2f5e5720d2292e5d91549d9d913837088a2a3718d2208580610315e39;
        sg_start = 1'b1;
        @(posedge clk); #1; sg_start = 1'b0;
        begin
            tk = 0;
            while (sg_done !== 1'b1 && tk < 2000000) begin
                @(posedge clk); tk = tk + 1;
            end
            if (sg_done !== 1'b1) begin
                nfail = nfail + 1;
                $display("[TIMEOUT] T4.1  no done after %0d cycles", 2000000);
            end else begin
                @(posedge clk); #1;
            end
        end
        ntest = ntest + 1;
        if (sg_rout === 256'hd378878f80165a04e8c05794cfac67c945aa1ca9376458f6d2b4cdd43c14ddcf && sg_sout === 256'h74d0289fbd3fc6a744d6242bd7b1a08aa4818dffe1b4f4689513a1f57d2d5eba && sg_err === 1'b0) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] T4.1  got r=%h s=%h err=%b", sg_rout, sg_sout, sg_err);
            $display("[FAIL] T4.1  exp r=256'hd378878f80165a04e8c05794cfac67c945aa1ca9376458f6d2b4cdd43c14ddcf s=256'h74d0289fbd3fc6a744d6242bd7b1a08aa4818dffe1b4f4689513a1f57d2d5eba");
        end
        // [T4.2]
        @(negedge clk);
        sg_d  = 256'h0ee6f2a03ffdec2420a3ae3d0fa2f089b731f880899cfcecb2cc454ffb9ab0e0;
        sg_e  = 256'h256b05827f7051b9fc0f7d17bf0d5e2c151b2c98fd75f232eb410b5e82aea8c0;
        sg_k  = 256'h4bc1e2dde14787a477a7c41865736549538b0599eb4c1ea51a791db267fb1b27;
        sg_start = 1'b1;
        @(posedge clk); #1; sg_start = 1'b0;
        begin
            tk = 0;
            while (sg_done !== 1'b1 && tk < 2000000) begin
                @(posedge clk); tk = tk + 1;
            end
            if (sg_done !== 1'b1) begin
                nfail = nfail + 1;
                $display("[TIMEOUT] T4.2  no done after %0d cycles", 2000000);
            end else begin
                @(posedge clk); #1;
            end
        end
        ntest = ntest + 1;
        if (sg_rout === 256'h313514b886f78b6bd35d025e30e052a0797777718935ec5c363c07a7007bc3ec && sg_sout === 256'h207f7b58ecec0bde6adc79b8436db030645e562fd11dc0f0c0b5dd618fe6f553 && sg_err === 1'b0) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] T4.2  got r=%h s=%h err=%b", sg_rout, sg_sout, sg_err);
            $display("[FAIL] T4.2  exp r=256'h313514b886f78b6bd35d025e30e052a0797777718935ec5c363c07a7007bc3ec s=256'h207f7b58ecec0bde6adc79b8436db030645e562fd11dc0f0c0b5dd618fe6f553");
        end
        // [T4.3]
        @(negedge clk);
        sg_d  = 256'h2cd770708d3fd33e9f1357a29f17019d2b27467f7064398263b7f7b909881f44;
        sg_e  = 256'hbb91bac36dd3672742736360616c151d420d13a86487ab1063b71fc1cc788162;
        sg_k  = 256'ha9715d4f635b38dbd9e5b8a1d38e3714585b2fa9808cd7a3686956e37b9ca5b0;
        sg_start = 1'b1;
        @(posedge clk); #1; sg_start = 1'b0;
        begin
            tk = 0;
            while (sg_done !== 1'b1 && tk < 2000000) begin
                @(posedge clk); tk = tk + 1;
            end
            if (sg_done !== 1'b1) begin
                nfail = nfail + 1;
                $display("[TIMEOUT] T4.3  no done after %0d cycles", 2000000);
            end else begin
                @(posedge clk); #1;
            end
        end
        ntest = ntest + 1;
        if (sg_rout === 256'h08442f1fda927f2f6e9e298ca110c5ee09979c44bb87a73e959ace9c6e7ab140 && sg_sout === 256'h45305d85ec0cc061ad5f1a80c21a301b870323e6138ecb1fd6465c82215ea5fc && sg_err === 1'b0) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] T4.3  got r=%h s=%h err=%b", sg_rout, sg_sout, sg_err);
            $display("[FAIL] T4.3  exp r=256'h08442f1fda927f2f6e9e298ca110c5ee09979c44bb87a73e959ace9c6e7ab140 s=256'h45305d85ec0cc061ad5f1a80c21a301b870323e6138ecb1fd6465c82215ea5fc");
        end

        $display("[T8] sm2_sign  sign (d/k 非法) -> 期望 err=1");
        // [T8.0]
        @(negedge clk);
        sg_d  = 256'h0000000000000000000000000000000000000000000000000000000000000000;
        sg_e  = 256'h58f1ab520bfdfab566e54c08b64b75392586b6fee4067adef587981741222a41;
        sg_k  = 256'h0000000000000000000000000000000000000000000000000000000000000003;
        sg_start = 1'b1;
        @(posedge clk); #1; sg_start = 1'b0;
        begin
            tk = 0;
            while (sg_done !== 1'b1 && tk < 2000000) begin
                @(posedge clk); tk = tk + 1;
            end
            if (sg_done !== 1'b1) begin
                nfail = nfail + 1;
                $display("[TIMEOUT] T8.0  no done after %0d cycles", 2000000);
            end else begin
                @(posedge clk); #1;
            end
        end
        ntest = ntest + 1;
        if (sg_err === 1'b1) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] T8.0  err=%b (expect err=1)", sg_err);
        end
        // [T8.1]
        @(negedge clk);
        sg_d  = 256'h0000000000000000000000000000000000000000000000000000000000000003;
        sg_e  = 256'h58f1ab520bfdfab566e54c08b64b75392586b6fee4067adef587981741222a41;
        sg_k  = 256'h0000000000000000000000000000000000000000000000000000000000000000;
        sg_start = 1'b1;
        @(posedge clk); #1; sg_start = 1'b0;
        begin
            tk = 0;
            while (sg_done !== 1'b1 && tk < 2000000) begin
                @(posedge clk); tk = tk + 1;
            end
            if (sg_done !== 1'b1) begin
                nfail = nfail + 1;
                $display("[TIMEOUT] T8.1  no done after %0d cycles", 2000000);
            end else begin
                @(posedge clk); #1;
            end
        end
        ntest = ntest + 1;
        if (sg_err === 1'b1) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] T8.1  err=%b (expect err=1)", sg_err);
        end
        // [T8.2]
        @(negedge clk);
        sg_d  = 256'hfffffffeffffffffffffffffffffffff7203df6b21c6052b53bbf40939d54123;
        sg_e  = 256'h58f1ab520bfdfab566e54c08b64b75392586b6fee4067adef587981741222a41;
        sg_k  = 256'h0000000000000000000000000000000000000000000000000000000000000003;
        sg_start = 1'b1;
        @(posedge clk); #1; sg_start = 1'b0;
        begin
            tk = 0;
            while (sg_done !== 1'b1 && tk < 2000000) begin
                @(posedge clk); tk = tk + 1;
            end
            if (sg_done !== 1'b1) begin
                nfail = nfail + 1;
                $display("[TIMEOUT] T8.2  no done after %0d cycles", 2000000);
            end else begin
                @(posedge clk); #1;
            end
        end
        ntest = ntest + 1;
        if (sg_err === 1'b1) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] T8.2  err=%b (expect err=1)", sg_err);
        end
        // [T8.3]
        @(negedge clk);
        sg_d  = 256'h0000000000000000000000000000000000000000000000000000000000000003;
        sg_e  = 256'h58f1ab520bfdfab566e54c08b64b75392586b6fee4067adef587981741222a41;
        sg_k  = 256'hfffffffeffffffffffffffffffffffff7203df6b21c6052b53bbf40939d54123;
        sg_start = 1'b1;
        @(posedge clk); #1; sg_start = 1'b0;
        begin
            tk = 0;
            while (sg_done !== 1'b1 && tk < 2000000) begin
                @(posedge clk); tk = tk + 1;
            end
            if (sg_done !== 1'b1) begin
                nfail = nfail + 1;
                $display("[TIMEOUT] T8.3  no done after %0d cycles", 2000000);
            end else begin
                @(posedge clk); #1;
            end
        end
        ntest = ntest + 1;
        if (sg_err === 1'b1) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] T8.3  err=%b (expect err=1)", sg_err);
        end

        $display("[T9] sm2_sign  sign (T4 向量复测, v3.0 SIGN-ONLY)");
        // [T9.s0]
        @(negedge clk);
        sg_d  = 256'ha9aa4026022809eefe9c27ba5935c64e795c83923a1e9668cf1bac6cf858c4d7;
        sg_e  = 256'h58f1ab520bfdfab566e54c08b64b75392586b6fee4067adef587981741222a41;
        sg_k  = 256'h44541f3a3c85616c0886482bf44b6c1a3290248e8ac78b3ddf49f3aa92d2e5df;
        sg_start = 1'b1;
        @(posedge clk); #1; sg_start = 1'b0;
        begin
            tk = 0;
            while (sg_done !== 1'b1 && tk < 2000000) begin
                @(posedge clk); tk = tk + 1;
            end
            if (sg_done !== 1'b1) begin
                nfail = nfail + 1;
                $display("[TIMEOUT] T9.s0  no done after %0d cycles", 2000000);
            end else begin
                @(posedge clk); #1;
            end
        end
        ntest = ntest + 1;
        if (sg_rout === 256'ha57162f434afb05efdd70546160e56952de9a968251da63f5e84d818def357b8 && sg_sout === 256'h6ca7fa2ec10979ff92e5f226447fbb46512dc47af74f650664a3c3d96e47280a && sg_err === 1'b0) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] T9.s0  got r=%h s=%h err=%b", sg_rout, sg_sout, sg_err);
            $display("[FAIL] T9.s0  exp r=256'ha57162f434afb05efdd70546160e56952de9a968251da63f5e84d818def357b8 s=256'h6ca7fa2ec10979ff92e5f226447fbb46512dc47af74f650664a3c3d96e47280a");
        end
        // [T9.s1]
        @(negedge clk);
        sg_d  = 256'h729156fd68fe8578d8ffd6ec4b10bb4bc7f5a7c9a39ee07e8ec2d7cc56858054;
        sg_e  = 256'h7915f4f86c89f4c1a4cd8ff8eb2393d6e46cc13f2f504bd5b588a9b0d4bff273;
        sg_k  = 256'h09a7faa2f5e5720d2292e5d91549d9d913837088a2a3718d2208580610315e39;
        sg_start = 1'b1;
        @(posedge clk); #1; sg_start = 1'b0;
        begin
            tk = 0;
            while (sg_done !== 1'b1 && tk < 2000000) begin
                @(posedge clk); tk = tk + 1;
            end
            if (sg_done !== 1'b1) begin
                nfail = nfail + 1;
                $display("[TIMEOUT] T9.s1  no done after %0d cycles", 2000000);
            end else begin
                @(posedge clk); #1;
            end
        end
        ntest = ntest + 1;
        if (sg_rout === 256'hd378878f80165a04e8c05794cfac67c945aa1ca9376458f6d2b4cdd43c14ddcf && sg_sout === 256'h74d0289fbd3fc6a744d6242bd7b1a08aa4818dffe1b4f4689513a1f57d2d5eba && sg_err === 1'b0) npass = npass + 1;
        else begin
            nfail = nfail + 1;
            $display("[FAIL] T9.s1  got r=%h s=%h err=%b", sg_rout, sg_sout, sg_err);
            $display("[FAIL] T9.s1  exp r=256'hd378878f80165a04e8c05794cfac67c945aa1ca9376458f6d2b4cdd43c14ddcf s=256'h74d0289fbd3fc6a744d6242bd7b1a08aa4818dffe1b4f4689513a1f57d2d5eba");
        end

        // ---------------- 汇总 ----------------
        $display("ntest=%0d npass=%0d nfail=%0d", ntest, npass, nfail);
        if (nfail === 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL");
        $finish;
    end

endmodule
