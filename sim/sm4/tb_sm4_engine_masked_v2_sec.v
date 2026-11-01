// =============================================================================
// 模块名称 : tb_sm4_engine_masked_v2_sec   (B-4 安全判据 TB)
// 项目     : GM-CRYPTO-COORD-2026
// 视角     : sim-verifier / fpga-fullflow-lead
// 来源     : 本文件即单一来源 (2026-10-05 由 T3 判据纠错定稿)
//            期望值 = 已裁决参考模型 (RTL S 盒 == gmssl == openssl == GB/T)
//            裁决要点: FK=a3b1bac6/56aa3350/677d9197/b27022dc,
//            T(A)=L(tau(A)) 无恒等项, CK_i 4 字节 = ((7*(4i+j))&0xFF) 高字节在前
// 运行     : iverilog -g2005 -Wall tb_..._sec.v rtl/sm4/sm4_engine_masked_v2.v
//            -> vvp b4.vvp  (driver: .workbuddy/tmp/run_b4.py)
// 目标     : B-4 规格要求的四项安全判据
//   T1   en=0 零回归     -- masked_en=0 时 GB/T 加解密逐 bit 等价
//   T2   en=1 掩码消码   -- masked_en=1 时 (内部刷新 + 外部注入) 数值零回归,
//                           且错位/投毒表的负控必须给出**不同**密文 (防空转)
//   T3   熵源独立       -- 掩码流只由片内 LFSR 派生:
//                           (a) 与 key/plaintext 无关  (b) 复位可复现
//                           (c) RTL 无外部熵源端口 (由生成器静态断言)
//   T4   均匀性         -- 掩码流 256 分箱 chi2 + 逐 bit 二项检验 + 游程检验
// 编译     : iverilog -g2005 -Wall tb_sm4_engine_masked_v2_sec.v
//            rtl/sm4/sm4_engine_masked_v2.v
// =============================================================================
`timescale 1ns / 1ps
module tb_sm4_engine_masked_v2_sec;

    // ---------------- DUT 激励 ----------------
    reg          clk          = 1'b0;
    reg          rst_n        = 1'b0;
    reg          start        = 1'b0;
    reg  [127:0] key          = 128'h0;
    reg  [127:0] plaintext    = 128'h0;
    reg          decrypt      = 1'b0;
    reg  [127:0] ciphertext   = 128'h0;

    // ---------------- B-3 新增控制 ----------------
    reg            masked_en         = 1'b0;
    reg            sbox_mask_ext_en  = 1'b0;
    reg  [7:0]     sbox_mask_c_ext   = 8'h00;
    reg  [2047:0]  sbox_mask_tbl_ext = 2048'h0;

    // ---------------- DUT 响应 ----------------
    wire [127:0] result;
    wire         done;
    wire         busy;
    wire [7:0]   sbox_addr_tap;
    wire [7:0]   sbox_mask_c_tap;
    wire         sbox_mask_valid;

    always #5 clk = ~clk;

    sm4_engine_masked_v2 dut (
        .clk               (clk),
        .rst_n             (rst_n),
        .start             (start),
        .key               (key),
        .plaintext         (plaintext),
        .decrypt           (decrypt),
        .ciphertext        (ciphertext),
        .result            (result),
        .done              (done),
        .busy              (busy),
        .masked_en         (masked_en),
        .sbox_mask_ext_en  (sbox_mask_ext_en),
        .sbox_mask_c_ext   (sbox_mask_c_ext),
        .sbox_mask_tbl_ext (sbox_mask_tbl_ext),
        .sbox_addr_tap     (sbox_addr_tap),
        .sbox_mask_c_tap   (sbox_mask_c_tap),
        .sbox_mask_valid   (sbox_mask_valid)
    );

    // ---------------- 测试向量 (由生成器填入) ----------------
    integer NV;
    reg [127:0] tv_k [0:15];
    reg [127:0] tv_p [0:15];
    reg [127:0] tv_c [0:15];

    // T2 外部注入表 (字面量 MSB = index 255, 与 sbox_mask_tbl_ext 左移3对齐一致)
    integer T2N;
    reg [7:0]     t2_c   [0:3];
    reg [2047:0]  t2_ok  [0:3];
    reg [2047:0]  t2_mis [0:3];
    reg [2047:0]  t2_poi [0:3];

    // ---------------- 通用 ----------------
    integer timeout_cnt;
    integer pass_cnt = 0;
    integer fail_cnt = 0;
    integer i, j, b;
    integer ok_dat;

    // ---------------- T3 掩码流历史 ----------------
    integer c_h1 [0:7];
    integer c_h2 [0:7];
    integer c_h3 [0:7];
    integer c_h4 [0:31];
    // 掩码 LFSR 解析模型: s' = {s[14:0], s[15]} ^ (s[15] ? 16'h6800 : 16'h0000)
    //   (与 RTL L355-L357 / B-2 mask_gen_lfsr.v 同式, 用于证明掩码流无数据反馈)
    reg  [15:0] m_st;
    reg  [15:0] m_nxt;
    reg  [7:0]  m_chk;

    // ---------------- T4 采样与统计 ----------------
    integer t4_n;
    reg  [7:0] samp [0:4095];
    integer hist     [0:255];
    integer ones_n, runs_n, nz_bins, d_tmp, chi2_256, chi2_bit;
    reg  [7:0] s_tmp;
    reg        s_bit;

    // ---------------- 任务 ----------------
    task do_sm4;
        input [127:0] k_in;
        input [127:0] data_in;
        input         dec_in;
        begin
            @(negedge clk);
            key        = k_in;
            plaintext  = data_in;
            ciphertext = data_in;
            decrypt    = dec_in;
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            timeout_cnt = 0;
            @(posedge clk);
            while (!done && timeout_cnt < 500) begin
                @(posedge clk);
                timeout_cnt = timeout_cnt + 1;
            end
            if (timeout_cnt >= 500) begin
                $display("  FAIL: timeout after %0d cycles", timeout_cnt);
                $finish;
            end
        end
    endtask

    task chk_eq;
        input [127:0] exp_v;
        input [9:0]   id_v;
        begin
            if (result === exp_v) begin
                $display("  PASS[#%02d]", id_v);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL[#%02d]: exp %h", id_v, exp_v);
                $display("           got      %h", result);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task chk_ne;
        input [127:0] exp_v;
        input [9:0]   id_v;
        begin
            if (result !== exp_v) begin
                $display("  PASS[#%02d] (negative control effective)", id_v);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL[#%02d]: negative control DEGENERATED (result == exp %h)",
                         id_v, exp_v);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // ---------------- 复位到已知状态 (sbox_seed = 16'hB000) ----------------
    task do_rst;
        begin
            rst_n = 1'b0;
            #20;
            @(negedge clk);
            rst_n = 1'b1;
            #10;
        end
    endtask

    // ---------------- 由生成器填入的向量 / 外部掩码表 ----------------
    initial begin
        NV = 7;
        tv_k[0] = 128'h0123456789abcdeffedcba9876543210;
        tv_p[0] = 128'h0123456789abcdeffedcba9876543210;
        tv_c[0] = 128'h681edf34d206965e86b3e94f536e4246;
        tv_k[1] = 128'h00000000000000000000000000000000;
        tv_p[1] = 128'h00000000000000000000000000000000;
        tv_c[1] = 128'h9f1f7bff6f5511384d9430531e538fd3;
        tv_k[2] = 128'hffffffffffffffffffffffffffffffff;
        tv_p[2] = 128'hffffffffffffffffffffffffffffffff;
        tv_c[2] = 128'hedb119f8455fd2327ad6fbedcb5b4f5d;
        tv_k[3] = 128'h55555555555555555555555555555555;
        tv_p[3] = 128'h55555555555555555555555555555555;
        tv_c[3] = 128'he69f5fbef0806447036a101fddd2b152;
        tv_k[4] = 128'h000102030405060708090a0b0c0d0e0f;
        tv_p[4] = 128'h0f0e0d0c0b0a09080706050403020100;
        tv_c[4] = 128'h370174d8f9fbd5dde0b60d82d80b2001;
        tv_k[5] = 128'h0123456789abcdeffedcba9876543210;
        tv_p[5] = 128'h0123456789abcdeffedcba9876543210;
        tv_c[5] = 128'h681edf34d206965e86b3e94f536e4246;
        tv_k[6] = 128'h736f6d657065727374617465736f6d65;
        tv_p[6] = 128'h64657374696e6174696f6e6279746573;
        tv_c[6] = 128'hf63fda94ca779ef8a58df2784deed882;
    end
    initial begin
        T2N = 4;
        t2_c[0]   = 8'h3c;
        t2_c[1]   = 8'ha5;
        t2_c[2]   = 8'hf1;
        t2_c[3]   = 8'h0e;
        // t2_ok : tbl
        t2_ok[0]   = 2048'h92af1b8d7fbcddbb415cd911d85a101f8831c10abd7bcda512d0742db0b4e5b84a9769897e77960c09f1b96584c66ec5ec7df018204ddc3a3e5fee794839cbd7d28abfeab538c740cef2f7a3a11561f9a45daee0551a349b303293ade3b18cf52ee2f61d60ca6682ab2329c06f4e530d4537dbd52f8efdde726aff03515b6c6dfca70747ba1773f3193c5983a84f85e6b2816b688bda64714b0febf8359d56705e0e241ea2d158633b7c222587782101574600d45227d39fe702364c9ec8c4a0fee990d6b73de1ccc214b616052cfb28769a672bc304be2a261344aa99068649f450429c7a98ef91430b543362accfeda91cb3e495e808c9fa94df80a63f8f75;
        t2_ok[1]   = 2048'h0f4bf8eb9d35705681b2686bda8b71643c1983594fa8e685a7fc470717baf37302e74c36c89ea0c44657d40027529fd37c3b2522788701210e5e1e24d1a263581326aa44069949869a762b6704c32abe14c216b62c0528fbe9fed6903db7cce194fa80df3fa6758f1ca9e4b3e895c9080b433354ac62edcf50f49c42987a91efd0122d74b4b0b8e531880ac17bbda5cd5c4111d95ad81f10af928d1bbc7fbbdd5f3e79ee3948d7cb7dec18f04d203adcf10965b9c684c56e974a8969777e0c963230ad93b1e3f58c5da4e0ae1a559b34f2cea3f715a1f9618ad2eabf38b540c76a7203ff5b516d6c3745d5db8e2fdefd23abc0294e6f0d53e22e1df6ca608266;
        t2_ok[2]   = 2048'h2c0528fb14c216b63db7cce1e9fed690069949861326aa4404c32abe9a762b67ac62edcf0b433354987a91ef50f49c423fa6758f94fa80dfe895c9081ca9e4b34fa8e6853c19835917baf373a7fc47079d3570560f4bf8ebda8b716481b2686b788701217c3b2522d1a263580e5e1e24c89ea0c402e74c3627529fd34657d40015a1f961f2cea3f738b540c78ad2eabfb1e3f58c3230ad931a559b345da4e0ae4e6f0d5323abc029ca608266e22e1df65b516d6c6a7203ff8e2fdefd3745d5db5ad81f105c4111d9bc7fbbddaf928d1bb4b0b8e5d0122d747bbda5cd31880ac1c684c56ef10965b9777e0c96974a89693948d7cb5f3e79ee4d203adc7dec18f0;
        t2_ok[3]   = 2048'hf018ec7ddc3a204dee793e5fcbd7483969894a97960c7e77b96509f16ec584c6c10a8831cda5bd7b742d12d0e5b8b0b41b8d92afddbb7fbcd911415c101fd85adbd54537fdde2f8eff03726a6c6d515bf61d2ee2668260ca29c0ab23530d6f4eaee0a45d349b551a93ad30328cf5e3b1bfead28ac740b538f7a3cef261f9a11500d45746d39f5227364ce702c4a09ec8241e5e0e5863a2d122253b7c210187786b68b28164718bdaebf84b0f5670359d0747fca773f3ba175983193c85e6a84fb3e4a91c08c995e8df80fa948f75a63f429cf450ef917a985433430bcfed62ac672b769abe2ac30444aa26138649990690d6fee9e1ccb73db616c214fb28052c;
        // t2_mis : tbl_mis
        t2_mis[0]   = 2048'h93ad30328cf5e3b1aee0a45d349b551af7a3cef261f9a115bfead28ac740b538ff03726a6c6d515bdbd54537fdde2f8e29c0ab23530d6f4ef61d2ee2668260ca742d12d0e5b8b0b4c10a8831cda5bd7bd911415c101fd85a1b8d92afddbb7fbcee793e5fcbd74839f018ec7ddc3a204db96509f16ec584c669894a97960c7e7744aa261386499906672b769abe2ac304b616c214fb28052c90d6fee9e1ccb73ddf80fa948f75a63fb3e4a91c08c995e85433430bcfed62ac429cf450ef917a98ebf84b0f5670359d6b68b28164718bda5983193c85e6a84f0747fca773f3ba17364ce702c4a09ec800d45746d39f522722253b7c21018778241e5e0e5863a2d1;
        t2_mis[1]   = 2048'hd690e9fecce13db716b614c228fb2c052b679a762abe04c3aa441326498606999c4250f491ef987a33540b43edcfac62e4b31ca9c908e89580df94fa758f3fa64707a7fcf37317ba83593c19e6854fa8686b81b27164da8bf8eb0f4b70569d351e240e5e6358d1a225227c3b01217887d40046579fd327524c3602e7a0c4c89eeabf8ad240c738b5a3f7f2cef96115a1e0ae5da49b341a55ad933230f58cb1e31df6e22e8266ca60c02923ab0d534e6fd5db3745defd8e2f03ff6a726d6c5b518d1baf92bbddbc7f11d95c411f105ad80ac13188a5cd7bbd2d74d012b8e5b4b08969974a0c96777e65b9f109c56ec68418f07dec3adc4d2079ee5f3ed7cb3948;
        t2_mis[2]   = 2048'h7164da8b686b81b270569d35f8eb0f4bf37317ba4707a7fce6854fa883593c199fd32752d4004657a0c4c89e4c3602e76358d1a21e240e5e0121788725227c3b2abe04c32b679a7649860699aa441326cce13db7d690e9fe28fb2c0516b614c2c908e895e4b31ca9758f3fa680df94fa91ef987a9c4250f4edcfac6233540b43a5cd7bbd0ac13188b8e5b4b02d74d012bbddbc7f8d1baf921f105ad811d95c413adc4d2018f07decd7cb394879ee5f3e0c96777e8969974ac56ec68465b9f1099b341a55e0ae5da4f58cb1e3ad93323040c738b5eabf8ad2f96115a1a3f7f2cedefd8e2fd5db37456d6c5b5103ff6a728266ca601df6e22e0d534e6fc02923ab;
        t2_mis[3]   = 2048'hab2329c06f4e530d2ee2f61d60ca6682726aff03515b6c6d4537dbd52f8efddecef2f7a3a11561f9d28abfeab538c740303293ade3b18cf5a45daee0551a349b09f1b96584c66ec54a9769897e77960c3e5fee794839cbd7ec7df018204ddc3a415cd911d85a101f92af1b8d7fbcddbb12d0742db0b4e5b88831c10abd7bcda5430b543362accfedf450429c7a98ef91fa94df80a63f8f75a91cb3e495e808c9c214b616052cfb28fee990d6b73de1cc261344aa99068649769a672bc304be2a3b7c2225877821015e0e241ea2d15863e702364c9ec8c4a0574600d45227d39f193c5983a84f85e6fca70747ba1773f34b0febf8359d5670b2816b688bda6471;
        // t2_poi : tbl_poi
        t2_poi[0]   = 2048'hc8f541d725e687e11b06834b82004a45d26b9b50e72197ff488a2e77eaeebfe210cd33d3242dcc5653abe33fde9c349fb627aa427a1786606405b4231263918d88d0e5b0ef629d1a94a8adf9fb4f3ba3fe07f4ba0f406ec16a68c9f7b9ebd6af74b8ac473a903cd8f179739a351409571f6d818f75d4a7842830a5590b013637a6fd5d1de04d29a9436603d9f215dfbce8db3132d1803e2b1155b1a26fc70c2a04547e44f88b02396126787fdd227b5b0d1c5a8e087d89c5bd586c16c4929efaa4b3ca8ced67bb96984eec4c5f76a1722cc03d71995ee4707c491ef0c35cdc13ae0a18c620c2b5cb19510e6938f695b7f346e9becfb25293a0ce85dafc65d52f;
        t2_poi[1]   = 2048'h5511a2b1c76f2a0cdbe8323180d12b3e6643d90315f2bcdffda61d5d4de0a92958bd166c92c4fa9e1c0d8e5a7d08c58926617f7822dd5b7b5404447e8bf83902497cf01e5cc313dcc02c713d5e9970e44e984cec765f72a1b3a48cca67ed96bbcea0da8565fc2fd546f3bee9b2cf93525119690ef638b7950aaec618c220cbb58a48772eeeeae2bf6bd2509b21e7ff97061b4b830082454af5c8d741e625e187056423b463128d9127b642aa177a6086ab533fe39cde9f34cd10d3332d2456cc686af7c9ebb9afd607febaf4400fc16ea894f9ad4ffba33bd088b0e562ef1a9d302859a5010b37366d1f8f81d47584a779f19a7314355709b87447ac903ad83c;
        t2_poi[2]   = 2048'h765f72a14e984cec67ed96bbb3a48cca5cc313dc497cf01e5e9970e4c02c713df638b7955119690ec220cbb50aaec61865fc2fd5cea0da85b2cf935246f3bee915f2bcdf6643d9034de0a929fda61d5dc76f2a0c5511a2b180d12b3edbe8323122dd5b7b26617f788bf839025404447e92c4fa9e58bd166c7d08c5891c0d8e5a4ffba33ba894f9ad62ef1a9dd088b0e5ebb9afd6686af7c9400fc16e07febaf41435570979f19a73903ad83cb87447ac010b3736302859a5d47584a76d1f8f810082454a061b4b83e625e187f5c8d741eeeae2bf8a48772e21e7ff976bd2509b9cde9f34ab533fe32d2456cccd10d33363128d91056423b4177a608627b642aa;
        t2_poi[3]   = 2048'haa42b62786607a17b4236405918d126333d310cdcc56242de33f53ab349fde9c9b50d26b97ffe7212e77488abfe2eaee41d7c8f587e125e6834b1b064a458200818f1f6da78475d4a559283036370b01ac4774b83cd83a90739af17909573514f4bafe076ec10f40c9f76a68d6afb9ebe5b088d09d1aef62adf994a83ba3fb4f5a8e0d1c89c5087d6c16bd589efac4927e4404540239f88b787f61267b5bdd223132e8db3e2bd180b1a211550c2a6fc75d1da6fd29a9e04d03d94366dfbcf215e9bef3465293cfb285daa0ced52ffc6518c6ae0ab5cb20c20e69195195b738f63d712cc0e470995e1ef07c49dc13c35cca8ca4b3bb96ed67ec4c984ea1725f76;
    end

    // =========================================================================
    // 主体
    // =========================================================================
    initial begin
        $dumpfile("tb_sm4_engine_masked_v2_sec.vcd");
        $dumpvars(0, dut.fsm_state, dut.sbox_seed, dut.sbox_c_a, dut.sbox_c_b,
                  dut.sbox_buf_sel, done, busy);

        rst_n            = 1'b0;
        masked_en        = 1'b0;
        sbox_mask_ext_en = 1'b0;
        sbox_mask_c_ext  = 8'h00;
        sbox_mask_tbl_ext = 2048'h0;
        #30;
        @(negedge clk);
        rst_n = 1'b1;
        #10;

        // =====================================================================
        // T1: masked_en=0 零回归
        // =====================================================================
        $display("=== T1: masked_en=0 zero regression (enc + dec) ===");
        masked_en = 1'b0;
        for (i = 0; i < NV; i = i + 1) begin
            do_sm4(tv_k[i], tv_p[i], 1'b0);
            chk_eq(tv_c[i], 10'd100 + i);
            do_sm4(tv_k[i], tv_c[i], 1'b1);
            chk_eq(tv_p[i], 10'd110 + i);
        end

        // =====================================================================
        // T2a: masked_en=1 内部刷新 -> 数值零回归 (核心判据)
        // =====================================================================
        $display("=== T2a: masked_en=1 zero regression (internal refresh) ===");
        masked_en        = 1'b1;
        sbox_mask_ext_en = 1'b0;
        for (i = 0; i < NV; i = i + 1) begin
            do_sm4(tv_k[i], tv_p[i], 1'b0);
            chk_eq(tv_c[i], 10'd200 + i);
            do_sm4(tv_k[i], tv_c[i], 1'b1);
            chk_eq(tv_p[i], 10'd210 + i);
        end

        // =====================================================================
        // T2b: masked_en=1 外部注入正确表 -> 数值零回归
        // =====================================================================
        $display("=== T2b: external injection (correct Tbl) ===");
        sbox_mask_ext_en = 1'b1;
        for (i = 0; i < T2N; i = i + 1) begin
            sbox_mask_c_ext   = t2_c[i];
            sbox_mask_tbl_ext = t2_ok[i];
            do_sm4(tv_k[0], tv_p[0], 1'b0);
            chk_eq(tv_c[0], 10'd310 + i);
        end

        // =====================================================================
        // T2c: 负控 -- 错位表 / 投毒表 必须产出**不同**密文
        //      (否则 T2b 是空转判据: 表根本没参与运算)
        // =====================================================================
        $display("=== T2c: negative controls (misrouted / poisoned table) ===");
        for (i = 0; i < T2N; i = i + 1) begin
            sbox_mask_c_ext   = t2_c[i];
            sbox_mask_tbl_ext = t2_mis[i];
            do_sm4(tv_k[0], tv_p[0], 1'b0);
            chk_ne(tv_c[0], 10'd330 + i);
        end
        for (i = 0; i < T2N; i = i + 1) begin
            sbox_mask_c_ext   = t2_c[i];
            sbox_mask_tbl_ext = t2_poi[i];
            do_sm4(tv_k[0], tv_p[0], 1'b0);
            chk_ne(tv_c[0], 10'd340 + i);
        end
        sbox_mask_ext_en = 1'b0;
        sbox_mask_c_ext  = 8'h00;

        // =====================================================================
        // T3: 熵源独立
        //   T3a 结构断言由生成器静态执行 (RTL 无 entropy/trng 输入端口,
        //        掩码仅由片内 sbox_seed LFSR 派生)
        //   T3b 第 n 块掩码 = 块号纯函数 m[n] = step^n(16'hB000)[15:8],
        //        与 key/plaintext 无关, 且复位可完全复现
        //   T3c 连续 32 块掩码流与 TB 侧解析 LFSR 模型逐块一致 (无数据反馈)
        // =====================================================================
        $display("=== T3: entropy-source independence ===");
        masked_en        = 1'b1;
        sbox_mask_ext_en = 1'b0;
        sbox_mask_c_ext  = 8'h00;
        do_rst();

        // #350: 起点数值零回归
        do_sm4(tv_k[0], tv_p[0], 1'b0);
        chk_eq(tv_c[0], 10'd350);

        // #351: 首块掩码 == 复位 seed 一次步进的高字节 (确定性)
        if (sbox_mask_c_tap === 8'h08) begin
            $display("  PASS[#351]: first-block mask == 8'h08 (deterministic)");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL[#351]: first-block mask = %02x (expect 08)",
                     sbox_mask_c_tap);
            fail_cnt = fail_cnt + 1;
        end

        // #352: 掩码流与数据无关 + 复位可复现
        //   三次"复位后都从第 1 块开始", 喂的数据 A / B / A。
        //   掩码若依赖数据, 三次必然不同; 若复位未复位熵源, 首块必然不同。
        do_rst();
        for (i = 0; i < 8; i = i + 1) begin
            do_sm4(tv_k[0], tv_p[0], 1'b0);
            c_h1[i] = sbox_mask_c_tap;
        end
        do_rst();
        for (i = 0; i < 8; i = i + 1) begin
            do_sm4(tv_k[1], tv_p[1], 1'b0);
            c_h2[i] = sbox_mask_c_tap;
        end
        do_rst();
        for (i = 0; i < 8; i = i + 1) begin
            do_sm4(tv_k[0], tv_p[0], 1'b0);
            c_h3[i] = sbox_mask_c_tap;
        end
        ok_dat = 1;
        for (i = 0; i < 8; i = i + 1) begin
            if ((c_h1[i] !== c_h2[i]) || (c_h1[i] !== c_h3[i])) ok_dat = 0;
            m_chk = c_h1[i] & 8'hFF;
            $write("       blk[%0d] A=%02x B=%0x A2=%0x\n",
                   i + 1, m_chk, c_h2[i], c_h3[i]);
        end
        if (ok_dat) begin
            $display("  PASS[#352]: mask stream data-independent + reset-reproducible");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL[#352]: mask stream data-dependent or NOT reproducible");
            fail_cnt = fail_cnt + 1;
        end

        // #353: 上述 24 块之后数值仍正确 (数据 B)
        do_sm4(tv_k[1], tv_p[1], 1'b0);
        chk_eq(tv_c[1], 10'd353);

        // #354: 连续 32 块与 TB 侧解析 LFSR 模型逐块比对
        //   途中不复位, 数据交替 A/B; 掩码若含数据反馈则必然失配
        do_rst();
        m_st   = 16'hB000;
        ok_dat = 1;
        for (i = 0; i < 32; i = i + 1) begin
            do_sm4(tv_k[i % 2], tv_p[i % 2], 1'b0);
            c_h4[i] = sbox_mask_c_tap;
            m_nxt   = {m_st[14:0], m_st[15]} ^ (m_st[15] ? 16'h6800 : 16'h0000);
            if (c_h4[i] !== m_nxt[15:8]) begin
                ok_dat = 0;
                m_chk  = m_nxt[15:8];
                $write("       mismatch blk[%0d] got=%0x exp=%0x\n",
                       i + 1, c_h4[i], m_chk);
            end
            m_st = m_nxt;
        end
        if (ok_dat) begin
            $display("  PASS[#354]: 32-block mask stream == in-chip LFSR model");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL[#354]: mask stream != LFSR model (data feedback?)");
            fail_cnt = fail_cnt + 1;
        end

        // #355: 32 块之后数值仍正确 (数据 A)
        do_sm4(tv_k[0], tv_p[0], 1'b0);
        chk_eq(tv_c[0], 10'd355);

        // =====================================================================
        // T4: 掩码流均匀性
        //   采样口径: masked_en=1 每块采 1 个 c_tap, 共 t4_n = 4096 个样本
        //   (1) 256 分箱 chi2 : e=16,   dof=255 -> 判据 chi2 < 400
        //   (2) 逐 bit 二项   : e=2048, dof=7   -> 判据 chi2 < 32
        //   (3) 游程检验 bit0 : E=2049, sd~45.3 -> 判据 1845 <= R <= 2253
        //   (4) 非退化        : 256 个分箱必须全被访问到
        // =====================================================================
        $display("=== T4: mask stream uniformity (%0d samples) ===", t4_n);
        masked_en = 1'b1;
        t4_n = 4096;          // 与 b4_vectors.json 的 t4.n_samples 一致 (生成器断言)
        for (i = 0; i < t4_n; i = i + 1) begin
            do_sm4(tv_k[0], tv_p[0], 1'b0);
            samp[i] = sbox_mask_c_tap;
        end

        for (i = 0; i < 256; i = i + 1) hist[i] = 0;
        for (i = 0; i < t4_n; i = i + 1) hist[samp[i]] = hist[samp[i]] + 1;
        nz_bins  = 0;
        chi2_256 = 0;
        for (i = 0; i < 256; i = i + 1) begin
            if (hist[i] > 0) nz_bins = nz_bins + 1;
            d_tmp    = hist[i] - 16;
            chi2_256 = chi2_256 + (d_tmp * d_tmp) / 16;
        end
        if ((chi2_256 < 400) && (nz_bins == 256)) begin
            $display("  PASS[#411]: chi2_256 = %0d < 400, bins = %0d/256",
                     chi2_256, nz_bins);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL[#411]: chi2_256 = %0d (>=400) or bins = %0d/256",
                     chi2_256, nz_bins);
            fail_cnt = fail_cnt + 1;
        end

        chi2_bit = 0;
        for (b = 0; b < 8; b = b + 1) begin
            ones_n = 0;
            for (i = 0; i < t4_n; i = i + 1) begin
                s_tmp = samp[i] >> b;
                if (s_tmp[0] == 1'b1) ones_n = ones_n + 1;
            end
            d_tmp    = ones_n - 2048;
            chi2_bit = chi2_bit + (d_tmp * d_tmp) / 2048;
        end
        if (chi2_bit < 32) begin
            $display("  PASS[#412]: chi2_bit = %0d < 32 (8 bits, dof=7)", chi2_bit);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL[#412]: chi2_bit = %0d (>= 32)", chi2_bit);
            fail_cnt = fail_cnt + 1;
        end

        runs_n = 1;
        s_tmp  = samp[0];
        s_bit  = s_tmp[0];
        for (i = 1; i < t4_n; i = i + 1) begin
            s_tmp = samp[i];
            if (s_tmp[0] !== s_bit) begin
                runs_n = runs_n + 1;
                s_bit  = s_tmp[0];
            end
        end
        if ((runs_n >= 1845) && (runs_n <= 2253)) begin
            $display("  PASS[#413]: runs(bit0) = %0d in [1845,2253]", runs_n);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL[#413]: runs(bit0) = %0d out of [1845,2253]", runs_n);
            fail_cnt = fail_cnt + 1;
        end

        // 汇总
        $display("====================================================");
        $display("SM4_ENGINE_MASKED_V2 (B-4 SEC) REGRESSION SUMMARY");
        $display("  PASS: %0d", pass_cnt);
        $display("  FAIL: %0d", fail_cnt);
        $display("====================================================");
        if (fail_cnt == 0) $display("ALL PASS");
        else               $display("SOME FAILED");
        $finish;
    end

    initial begin
        #600000000;
        $display("GLOBAL TIMEOUT");
        $finish;
    end

endmodule
