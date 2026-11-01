// =============================================================================
// 模块名称 : sm2_nmul_rand
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 阶段     : Phase 0.5.3  路线图创新项 A2
// 版本     : v1.0
// 日期     : 2026-10-04
// 视角     : rtl-designer
// 功能     : 标量域 (mod n) 模乘  result = a * b mod n   —— 抗时序硬化变体
// 曲线     : sm2p256v1, n = 0xFFFFFFFEFFFFFFFFFFFFFFFFFFFFFFFF7203DF6B21C6052B53BBF40939D54123
// 契约     : 与 sm2_nmul v1.1 完全一致 (plain 进 / plain 出), 另加 rand_seed 输入
//            与 nop_cnt 观测输出; 结果数学上与 v1.1 恒等, 与随机源取值无关.
//
// 为什么做这个模块
//   攻击面定位: sm2_nmul v1.1 的 S_RUN 中
//        if (Breg[0]) acc <= f_addn(acc, Areg);
//   在 sm2_ninv (标量域费马模逆 a^{n-2} mod n) 驱动下, Breg 装载的是 mul_y,
//   而 mul_y 在 S_SQ 分支为 r (秘密中间值)、在 S_MUL 分支为 aa_buf = a
//   (签名时 a = k, 秘密随机数). 于是 "acc 是否被写入" 这一事件直接取决于
//   秘密比特, 属数据依赖写使能, 是真正的时序/功耗泄漏源.
//
//   注: sm2_ninv / sm2_modinv 自身的控制流只依赖公开指数 (n-2 / p-2),
//   不含秘密依赖分支, 故硬化落点选在模乘原语本身.
//
// 三项措施
//   M1 无分支掩码加 (RANDOMIZE=1)
//        sum_mont   = f_addn(acc, Areg)          // 每拍无条件计算
//        bit_mask   = {256{Breg[0]}}
//        acc        <= (sum_mont & bit_mask) | (acc & ~bit_mask)
//      加法器输入与 acc 的写使能均不再依赖秘密比特; 只有 256 个 AND/OR 门
//      的选择信号依赖 Breg[0], 其逻辑深度恒定、且不门控加法器.
//      注意: M1 只消除数据依赖的时序/写使能通道, 不防御 DPA
//      (bit_mask 的功耗仍随数据变化) —— 1 阶 DPA 防护由路线图 C1 承担.
//
//   M2 随机冗余轮次 (RANDOMIZE=1)
//        LFSR 抽取 n_extra = NMIN_EXTRA + seed[3:0]  ∈ [NMIN_EXTRA, NMIN_EXTRA+15]
//        在 256 个真实轮次之间, 由 LFSR 决定插入位置; 插入的轮次对
//        acc/Areg/Breg/cnt 全部冻结, 是数学上严格恒等的 NOP.
//      效果: 总延迟随机化, 每个秘密依赖事件落在观察窗口的绝对位置随机化.
//      完备性: gap_cnt 超过 STALL_GAP (默认 15) 步未插入时强制插入,
//      故最坏情形 15*16 = 240 <= 256 步内必然插完全部 16 个 stall,
//      不会因 LFSR 低位连续 0 而漏插.
//
//   M3 秘密状态两段清零 (RANDOMIZE=1)
//      上半段: S_OUT (结果已锁入 result 的那一拍) 立即抹除 acc/Areg/Breg.
//        v1.1 在 done 之后仍保留上一轮的密钥材料 (acc 最终值 = a*b mod n,
//        Areg = a*2^256 mod n —— 256 次模加倍并不归零, 不能靠移位自然清零),
//        任何 post-operation 探测都能读到残留秘密.
//      下半段: S_IDLE 期间 Areg/Breg 每拍恒定为 0.
//      acc 的 start 清零不受 RANDOMIZE 门控 (对齐 v1.1 第 82 行), 否则
//      RANDOMIZE=0 下 acc 会变成跨运算累加器 —— 首轮实测已踩此坑.
//
// 随机源
//   rand_seed[31:0] 由上层注入 (接入 TRNG 的 32 bit); 本模块内为
//   32-bit Galois LFSR, 特征多项式 x^32 + x^22 + x^2 + x + 1
//   (已在 .workbuddy/tmp/nmul_rand_ref.py 中验证为原始多项式, 阶 = 2^32-1).
//   种子为 0 时使用内置非零默认值, 避免 LFSR 死锁在 0 状态.
//   生产接线: 建议每笔运算刷新一次 rand_seed (TRNG -> sm2_ninv -> 本模块).
//
// 参数
//   RANDOMIZE   0 = 结构等价 sm2_nmul v1.1 (对照基线, 用于逐位对拍)
//               1 = 启用 M1 + M2 + M3 (默认)
//   NMIN_EXTRA  冗余轮次下界 (1..15)
//   STALL_GAP   两次 stall 之间的最大真实轮次间隔 (强制插入阈值)
//
// 时序
//   RANDOMIZE=0: 256 步 + 2 状态开销, 与 v1.1 完全一致
//   RANDOMIZE=1: 256 步 + 2 状态开销 + nop_cnt 个 stall (每个 stall 1 拍)
//   -> 额外延迟 = nop_cnt 拍, 严格等于 nop_cnt 输出值
//
// 综合说明
//   RANDOMIZE 是 elaboration 期参数, 两种配置只实例化其中一套路径,
//   RANDOMIZE=0 时 nop_cnt/nop_left/gap_cnt/lfsr 为死逻辑, 会被优化掉.
//   M1 新增逻辑 = 1 个 256-bit AND-OR 选择网络 (加法器已存在, 无重复).
//
// Verilog-2005 合规 (本机 iverilog -g2005 实测拒绝的写法均已规避):
//   - 无变量边界 part-select (用 lfsr[0] / lfsr[30:0] 常量边界)
//   - 无文件作用域 parameter/localparam
//   - 无 localparam 数组
//   - 无 begin 块内变量声明
// =============================================================================

`timescale 1ns / 1ps

module sm2_nmul_rand #(
    parameter RANDOMIZE  = 1,     // 0 = v1.1 等价基线; 1 = M1+M2+M3 硬化
    parameter NMIN_EXTRA = 1,     // 随机冗余轮次下界
    parameter STALL_GAP  = 15     // stall 强制插入阈值 (两次 stall 间最大真实轮次)
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,            // 启动脉冲
    input  wire [255:0] a,               // plain, < n
    input  wire [255:0] b,               // plain, < n
    input  wire [31:0]  rand_seed,       // LFSR 种子 (0 时用内置默认值)
    output reg  [255:0] result,          // a*b mod n, plain
    output reg          done,            // 完成脉冲 (1 cycle)
    output reg  [7:0]   nop_cnt          // 本次运算实际插入的冗余轮次数
);

    // =========================================================================
    // 曲线阶 n —— 与 sm2_nmul.v 的 NN 逐位一致
    // =========================================================================
    localparam [255:0] NN = 256'hfffffffeffffffffffffffffffffffff7203df6b21c6052b53bbf40939d54123;

    // =========================================================================
    // LFSR 常数: x^32 + x^22 + x^2 + x + 1 (原始多项式, 阶 = 2^32 - 1)
    //   反馈项 = x^22 + x^2 + x + 1 = 0x00400007
    // =========================================================================
    localparam [31:0] LFSR_POLY_LOW  = 32'h00400007;
    localparam [31:0] LFSR_DEF_SEED  = 32'hdecaf11e;   // rand_seed == 0 时的兜底种子

    // =========================================================================
    // 组合模加 (mod n): x,y < n 时 x+y < 2n < 2^257, 溢出位或越界时减一次 n
    //   —— 与 sm2_nmul.v 的 f_addn 逐位一致
    // =========================================================================
    function [255:0] f_addn;
        input [255:0] x;
        input [255:0] y;
        reg [256:0] e;
        begin
            e = {1'b0, x} + {1'b0, y};
            f_addn = (e[256] || (e[255:0] >= NN)) ? (e[255:0] - NN) : e[255:0];
        end
    endfunction

    // =========================================================================
    // FSM
    // =========================================================================
    localparam [2:0] S_IDLE = 3'd0;
    localparam [2:0] S_RUN  = 3'd1;
    localparam [2:0] S_OUT  = 3'd2;

    reg  [2:0]  st;
    reg  [8:0]  cnt;         // 256 步; 9 位避免 v1.0 的漏 bit255 缺陷
    reg  [255:0] acc;
    reg  [255:0] Areg;
    reg  [255:0] Breg;
    reg  [7:0]  nop_left;    // 剩余待插入 stall 数
    reg  [7:0]  gap_cnt;     // 距上次插入以来的真实轮次数
    reg  [31:0] lfsr;

    // =========================================================================
    // M1: 无分支掩码加
    //   Breg[0] = 0 -> bit_mask 全 0 -> acc 保持
    //   Breg[0] = 1 -> bit_mask 全 1 -> acc = sum_mont
    //   加法器 f_addn(acc, Areg) 每拍无条件计算, 写使能恒为 1.
    // =========================================================================
    wire [255:0] sum_mont   = f_addn(acc, Areg);
    wire [255:0] bit_mask   = {256{Breg[0]}};
    wire [255:0] acc_masked = (sum_mont & bit_mask) | (acc & ~bit_mask);

    // =========================================================================
    // LFSR (Galois 型, 等价于 GF(2^32) 域内乘 x)
    // =========================================================================
    wire [31:0] seed_in        = (rand_seed == 32'd0) ? LFSR_DEF_SEED : rand_seed;
    wire [31:0] lfsr_from_seed = seed_in ^ LFSR_POLY_LOW;     // 先走一步, 避免种子低位直接当计数
    wire [31:0] lfsr_next      = {lfsr[30:0], 1'b0} ^ (lfsr[31] ? LFSR_POLY_LOW : 32'd0);
    wire [7:0]  n_extra        = {3'd0, lfsr_from_seed[3:0]} + {5'd0, NMIN_EXTRA};

    // stall 判定: 有预算 且 (LFSR 判定插入 或 距上次插入已过 STALL_GAP 步)
    wire stall_now = (nop_left != 8'd0) &&
                     ((lfsr[0] == 1'b1) || (gap_cnt >= STALL_GAP));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st       <= S_IDLE;
            acc      <= 256'd0;
            Areg     <= 256'd0;
            Breg     <= 256'd0;
            cnt      <= 9'd0;
            nop_left <= 8'd0;
            nop_cnt  <= 8'd0;
            gap_cnt  <= 8'd0;
            lfsr     <= 32'd0;
            result   <= 256'd0;
            done     <= 1'b0;
        end else begin
            case (st)
                S_IDLE: begin
                    done <= 1'b0;
                    // M3: 空闲期恒定清零, 消除上一轮残留的密钥材料
                    //   注意 acc 的清零必须落在 if(start) 里且不受 RANDOMIZE 门控
                    //   (对齐 v1.1 第 82 行)。若把 acc 清零只放在 RANDOMIZE!=0 分支,
                    //   RANDOMIZE=0 下 acc 会变成交替累加器: 首轮正确、第二轮起
                    //   base[i] = base[i-1] + a*b mod n, 全错 —— 首轮实测已踩此坑。
                    if (RANDOMIZE != 0) begin
                        Areg <= 256'd0;
                        Breg <= 256'd0;
                    end
                    if (start) begin
                        acc     <= 256'd0;      // 无条件清零, 两种配置都必须有
                        Areg    <= a;
                        Breg    <= b;
                        cnt     <= 9'd256;      // 256 步: bit255..bit0 全部吸收
                        lfsr    <= lfsr_from_seed;
                        gap_cnt <= 8'd0;
                        nop_cnt <= 8'd0;
                        if (RANDOMIZE == 0) begin
                            nop_left <= 8'd0;
                        end else begin
                            nop_left <= n_extra;
                        end
                        st      <= S_RUN;
                    end
                end

                S_RUN: begin
                    if (stall_now) begin
                        // M2: 数学恒等的 NOP —— acc/Areg/Breg/cnt 全部冻结
                        nop_left <= nop_left - 8'd1;
                        nop_cnt  <= nop_cnt + 8'd1;
                        gap_cnt  <= 8'd0;
                        lfsr     <= lfsr_next;
                        st       <= S_RUN;
                    end else if (cnt == 9'd0) begin
                        result <= acc;
                        st     <= S_OUT;
                    end else begin
                        // 256 步 shift-and-add
                        if (RANDOMIZE == 0) begin
                            // 基线: 逐位复刻 sm2_nmul v1.1, acc 写使能依赖 Breg[0]
                            if (Breg[0]) acc <= f_addn(acc, Areg);
                        end else begin
                            // M1: 无条件写 + 无条件模加
                            acc <= acc_masked;
                        end
                        Areg    <= f_addn(Areg, Areg);
                        Breg    <= {1'b0, Breg[255:1]};
                        cnt     <= cnt - 9'd1;
                        lfsr    <= lfsr_next;
                        gap_cnt <= gap_cnt + 8'd1;
                        st      <= S_RUN;
                    end
                end

                S_OUT: begin
                    done <= 1'b1;
                    st   <= S_IDLE;
                    // M3 (下半段): 结果已在 cnt==0 那拍锁入 result, 此处把残留的
                    //   秘密状态全部抹掉 —— 否则 acc 会一直保留 a*b mod n (即被
                    //   sm2_ninv 驱动时的签名随机数 k 的函数), 成为跨运算的秘密
                    //   驻留寄存器。Areg 在 256 次模加倍后并不保证为 0
                    //   (Areg = a*2^256 mod n), 故必须显式清零, 不能靠移位自然归零。
                    //   RANDOMIZE=0 分支不清, 以保持与 sm2_nmul v1.1 的内部状态
                    //   结构完全同构 (便于逐拍等价性论证)。
                    if (RANDOMIZE != 0) begin
                        acc  <= 256'd0;
                        Areg <= 256'd0;
                        Breg <= 256'd0;
                    end
                end

                default: begin
                    st <= S_IDLE;
                end
            endcase
        end
    end

endmodule
