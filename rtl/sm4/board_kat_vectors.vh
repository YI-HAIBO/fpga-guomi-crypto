// 由 .workbuddy/tmp/gen_board_vectors.py 自动生成, 请勿手改
// 锚点自检: blk0 的 pt = 标准向量 0123456789ABCDEF... -> ct = 681EDF34D206965E86B3E94F536E4246
function [127:0] bv_exp_ct;
    input [2:0] idx;
    begin
        case (idx)
        3'd0: bv_exp_ct = 128'h681EDF34D206965E86B3E94F536E4246;
        3'd1: bv_exp_ct = 128'hFF4C61765B3AABEB90D5ADDF4E6395EC;
        3'd2: bv_exp_ct = 128'h0BF4485D2D1E7255B5C1452A4C739EA0;
        3'd3: bv_exp_ct = 128'h95274903B6EA8CF208FC293DDBEBB2F0;
        3'd4: bv_exp_ct = 128'h117A3E9CB609643C767F0CCBAB464A8C;
        3'd5: bv_exp_ct = 128'hCE053B646B5164F5510F70B970C4533E;
        3'd6: bv_exp_ct = 128'hB5B751CAA874DD4EB9606DF24A7C2432;
        3'd7: bv_exp_ct = 128'hF18B6D92564E61E6D77A29B9C537D2E9;
        default: bv_exp_ct = 128'h681EDF34D206965E86B3E94F536E4246;
        endcase
    end
endfunction

function [127:0] bv_pt_of;
    input [2:0] idx;
    begin
        case (idx)
        3'd0: bv_pt_of = 128'h0123456789ABCDEFFEDCBA9876543210;
        3'd1: bv_pt_of = 128'h032147658BA9CFEDFCDEB89A74563012;
        3'd2: bv_pt_of = 128'h022046648AA8CEECFDDFB99B75573113;
        3'd3: bv_pt_of = 128'h052741638DAFC9EBFAD8BE9C72503614;
        3'd4: bv_pt_of = 128'h042640628CAEC8EAFBD9BF9D73513715;
        3'd5: bv_pt_of = 128'h072543618FADCBE9F8DABC9E70523416;
        3'd6: bv_pt_of = 128'h062442608EACCAE8F9DBBD9F71533517;
        3'd7: bv_pt_of = 128'h092B4D6F81A3C5E7F6D4B2907E5C3A18;
        default: bv_pt_of = 128'h0123456789ABCDEFFEDCBA9876543210;
        endcase
    end
endfunction

