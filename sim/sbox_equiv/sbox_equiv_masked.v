// =============================================================================
// sbox_equiv_masked.v -- v4 masked S-box lookup (extracted from sm4_engine_masked_v4.v)
// =============================================================================
// v4 masking scheme:
//   tbl[z]  = S(z ^ K) ^ mout8     (masked table, refreshed each cycle)
//   addr[b] = tmp[b] ^ K           (lookup address in masked domain)
//   tau_m[b] = tbl[addr[b]]        (masked output)
//
// After unmasking:
//   tau_m[b] ^ mout8 = S(addr[b] ^ K) ^ mout8 ^ mout8
//                     = S(tmp[b] ^ K ^ K) = S(tmp[b])
//
// This module captures the combinational essence: given K, mout8, and tmp,
// compute tau_m and prove tau_m ^ mout8 == S(tmp).
// =============================================================================

`timescale 1ns / 1ps

module sbox_equiv_masked (
    input  wire [7:0]  tmp,       // S-box input (unmasked domain)
    input  wire [7:0]  K,        // Input mask byte
    input  wire [7:0]  mout8,    // Output mask byte
    output wire [7:0]  tau_m     // Masked output: S(tmp) ^ mout8
);

    // ---- masked table: tbl[z] = S(z ^ K) ^ mout8 ----
    function [7:0] sm4_sbox;
        input [7:0] x;
        case (x)
            8'h00: sm4_sbox = 8'hD6;  8'h01: sm4_sbox = 8'h90;
            8'h02: sm4_sbox = 8'hE9;  8'h03: sm4_sbox = 8'hFE;
            8'h04: sm4_sbox = 8'hCC;  8'h05: sm4_sbox = 8'hE1;
            8'h06: sm4_sbox = 8'h3D;  8'h07: sm4_sbox = 8'hB7;
            8'h08: sm4_sbox = 8'h16;  8'h09: sm4_sbox = 8'hB6;
            8'h0A: sm4_sbox = 8'h14;  8'h0B: sm4_sbox = 8'hC2;
            8'h0C: sm4_sbox = 8'h28;  8'h0D: sm4_sbox = 8'hFB;
            8'h0E: sm4_sbox = 8'h2C;  8'h0F: sm4_sbox = 8'h05;
            8'h10: sm4_sbox = 8'h2B;  8'h11: sm4_sbox = 8'h67;
            8'h12: sm4_sbox = 8'h9A;  8'h13: sm4_sbox = 8'h76;
            8'h14: sm4_sbox = 8'h2A;  8'h15: sm4_sbox = 8'hBE;
            8'h16: sm4_sbox = 8'h04;  8'h17: sm4_sbox = 8'hC3;
            8'h18: sm4_sbox = 8'hAA;  8'h19: sm4_sbox = 8'h44;
            8'h1A: sm4_sbox = 8'h13;  8'h1B: sm4_sbox = 8'h26;
            8'h1C: sm4_sbox = 8'h49;  8'h1D: sm4_sbox = 8'h86;
            8'h1E: sm4_sbox = 8'h06;  8'h1F: sm4_sbox = 8'h99;
            8'h20: sm4_sbox = 8'h9C;  8'h21: sm4_sbox = 8'h42;
            8'h22: sm4_sbox = 8'h50;  8'h23: sm4_sbox = 8'hF4;
            8'h24: sm4_sbox = 8'h91;  8'h25: sm4_sbox = 8'hEF;
            8'h26: sm4_sbox = 8'h98;  8'h27: sm4_sbox = 8'h7A;
            8'h28: sm4_sbox = 8'h33;  8'h29: sm4_sbox = 8'h54;
            8'h2A: sm4_sbox = 8'h0B;  8'h2B: sm4_sbox = 8'h43;
            8'h2C: sm4_sbox = 8'hED;  8'h2D: sm4_sbox = 8'hCF;
            8'h2E: sm4_sbox = 8'hAC;  8'h2F: sm4_sbox = 8'h62;
            8'h30: sm4_sbox = 8'hE4;  8'h31: sm4_sbox = 8'hB3;
            8'h32: sm4_sbox = 8'h1C;  8'h33: sm4_sbox = 8'hA9;
            8'h34: sm4_sbox = 8'hC9;  8'h35: sm4_sbox = 8'h08;
            8'h36: sm4_sbox = 8'hE8;  8'h37: sm4_sbox = 8'h95;
            8'h38: sm4_sbox = 8'h80;  8'h39: sm4_sbox = 8'hDF;
            8'h3A: sm4_sbox = 8'h94;  8'h3B: sm4_sbox = 8'hFA;
            8'h3C: sm4_sbox = 8'h75;  8'h3D: sm4_sbox = 8'h8F;
            8'h3E: sm4_sbox = 8'h3F;  8'h3F: sm4_sbox = 8'hA6;
            8'h40: sm4_sbox = 8'h47;  8'h41: sm4_sbox = 8'h07;
            8'h42: sm4_sbox = 8'hA7;  8'h43: sm4_sbox = 8'hFC;
            8'h44: sm4_sbox = 8'hF3;  8'h45: sm4_sbox = 8'h73;
            8'h46: sm4_sbox = 8'h17;  8'h47: sm4_sbox = 8'hBA;
            8'h48: sm4_sbox = 8'h83;  8'h49: sm4_sbox = 8'h59;
            8'h4A: sm4_sbox = 8'h3C;  8'h4B: sm4_sbox = 8'h19;
            8'h4C: sm4_sbox = 8'hE6;  8'h4D: sm4_sbox = 8'h85;
            8'h4E: sm4_sbox = 8'h4F;  8'h4F: sm4_sbox = 8'hA8;
            8'h50: sm4_sbox = 8'h68;  8'h51: sm4_sbox = 8'h6B;
            8'h52: sm4_sbox = 8'h81;  8'h53: sm4_sbox = 8'hB2;
            8'h54: sm4_sbox = 8'h71;  8'h55: sm4_sbox = 8'h64;
            8'h56: sm4_sbox = 8'hDA;  8'h57: sm4_sbox = 8'h8B;
            8'h58: sm4_sbox = 8'hF8;  8'h59: sm4_sbox = 8'hEB;
            8'h5A: sm4_sbox = 8'h0F;  8'h5B: sm4_sbox = 8'h4B;
            8'h5C: sm4_sbox = 8'h70;  8'h5D: sm4_sbox = 8'h56;
            8'h5E: sm4_sbox = 8'h9D;  8'h5F: sm4_sbox = 8'h35;
            8'h60: sm4_sbox = 8'h1E;  8'h61: sm4_sbox = 8'h24;
            8'h62: sm4_sbox = 8'h0E;  8'h63: sm4_sbox = 8'h5E;
            8'h64: sm4_sbox = 8'h63;  8'h65: sm4_sbox = 8'h58;
            8'h66: sm4_sbox = 8'hD1;  8'h67: sm4_sbox = 8'hA2;
            8'h68: sm4_sbox = 8'h25;  8'h69: sm4_sbox = 8'h22;
            8'h6A: sm4_sbox = 8'h7C;  8'h6B: sm4_sbox = 8'h3B;
            8'h6C: sm4_sbox = 8'h01;  8'h6D: sm4_sbox = 8'h21;
            8'h6E: sm4_sbox = 8'h78;  8'h6F: sm4_sbox = 8'h87;
            8'h70: sm4_sbox = 8'hD4;  8'h71: sm4_sbox = 8'h00;
            8'h72: sm4_sbox = 8'h46;  8'h73: sm4_sbox = 8'h57;
            8'h74: sm4_sbox = 8'h9F;  8'h75: sm4_sbox = 8'hD3;
            8'h76: sm4_sbox = 8'h27;  8'h77: sm4_sbox = 8'h52;
            8'h78: sm4_sbox = 8'h4C;  8'h79: sm4_sbox = 8'h36;
            8'h7A: sm4_sbox = 8'h02;  8'h7B: sm4_sbox = 8'hE7;
            8'h7C: sm4_sbox = 8'hA0;  8'h7D: sm4_sbox = 8'hC4;
            8'h7E: sm4_sbox = 8'hC8;  8'h7F: sm4_sbox = 8'h9E;
            8'h80: sm4_sbox = 8'hEA;  8'h81: sm4_sbox = 8'hBF;
            8'h82: sm4_sbox = 8'h8A;  8'h83: sm4_sbox = 8'hD2;
            8'h84: sm4_sbox = 8'h40;  8'h85: sm4_sbox = 8'hC7;
            8'h86: sm4_sbox = 8'h38;  8'h87: sm4_sbox = 8'hB5;
            8'h88: sm4_sbox = 8'hA3;  8'h89: sm4_sbox = 8'hF7;
            8'h8A: sm4_sbox = 8'hF2;  8'h8B: sm4_sbox = 8'hCE;
            8'h8C: sm4_sbox = 8'hF9;  8'h8D: sm4_sbox = 8'h61;
            8'h8E: sm4_sbox = 8'h15;  8'h8F: sm4_sbox = 8'hA1;
            8'h90: sm4_sbox = 8'hE0;  8'h91: sm4_sbox = 8'hAE;
            8'h92: sm4_sbox = 8'h5D;  8'h93: sm4_sbox = 8'hA4;
            8'h94: sm4_sbox = 8'h9B;  8'h95: sm4_sbox = 8'h34;
            8'h96: sm4_sbox = 8'h1A;  8'h97: sm4_sbox = 8'h55;
            8'h98: sm4_sbox = 8'hAD;  8'h99: sm4_sbox = 8'h93;
            8'h9A: sm4_sbox = 8'h32;  8'h9B: sm4_sbox = 8'h30;
            8'h9C: sm4_sbox = 8'hF5;  8'h9D: sm4_sbox = 8'h8C;
            8'h9E: sm4_sbox = 8'hB1;  8'h9F: sm4_sbox = 8'hE3;
            8'hA0: sm4_sbox = 8'h1D;  8'hA1: sm4_sbox = 8'hF6;
            8'hA2: sm4_sbox = 8'hE2;  8'hA3: sm4_sbox = 8'h2E;
            8'hA4: sm4_sbox = 8'h82;  8'hA5: sm4_sbox = 8'h66;
            8'hA6: sm4_sbox = 8'hCA;  8'hA7: sm4_sbox = 8'h60;
            8'hA8: sm4_sbox = 8'hC0;  8'hA9: sm4_sbox = 8'h29;
            8'hAA: sm4_sbox = 8'h23;  8'hAB: sm4_sbox = 8'hAB;
            8'hAC: sm4_sbox = 8'h0D;  8'hAD: sm4_sbox = 8'h53;
            8'hAE: sm4_sbox = 8'h4E;  8'hAF: sm4_sbox = 8'h6F;
            8'hB0: sm4_sbox = 8'hD5;  8'hB1: sm4_sbox = 8'hDB;
            8'hB2: sm4_sbox = 8'h37;  8'hB3: sm4_sbox = 8'h45;
            8'hB4: sm4_sbox = 8'hDE;  8'hB5: sm4_sbox = 8'hFD;
            8'hB6: sm4_sbox = 8'h8E;  8'hB7: sm4_sbox = 8'h2F;
            8'hB8: sm4_sbox = 8'h03;  8'hB9: sm4_sbox = 8'hFF;
            8'hBA: sm4_sbox = 8'h6A;  8'hBB: sm4_sbox = 8'h72;
            8'hBC: sm4_sbox = 8'h6D;  8'hBD: sm4_sbox = 8'h6C;
            8'hBE: sm4_sbox = 8'h5B;  8'hBF: sm4_sbox = 8'h51;
            8'hC0: sm4_sbox = 8'h8D;  8'hC1: sm4_sbox = 8'h1B;
            8'hC2: sm4_sbox = 8'hAF;  8'hC3: sm4_sbox = 8'h92;
            8'hC4: sm4_sbox = 8'hBB;  8'hC5: sm4_sbox = 8'hDD;
            8'hC6: sm4_sbox = 8'hBC;  8'hC7: sm4_sbox = 8'h7F;
            8'hC8: sm4_sbox = 8'h11;  8'hC9: sm4_sbox = 8'hD9;
            8'hCA: sm4_sbox = 8'h5C;  8'hCB: sm4_sbox = 8'h41;
            8'hCC: sm4_sbox = 8'h1F;  8'hCD: sm4_sbox = 8'h10;
            8'hCE: sm4_sbox = 8'h5A;  8'hCF: sm4_sbox = 8'hD8;
            8'hD0: sm4_sbox = 8'h0A;  8'hD1: sm4_sbox = 8'hC1;
            8'hD2: sm4_sbox = 8'h31;  8'hD3: sm4_sbox = 8'h88;
            8'hD4: sm4_sbox = 8'hA5;  8'hD5: sm4_sbox = 8'hCD;
            8'hD6: sm4_sbox = 8'h7B;  8'hD7: sm4_sbox = 8'hBD;
            8'hD8: sm4_sbox = 8'h2D;  8'hD9: sm4_sbox = 8'h74;
            8'hDA: sm4_sbox = 8'hD0;  8'hDB: sm4_sbox = 8'h12;
            8'hDC: sm4_sbox = 8'hB8;  8'hDD: sm4_sbox = 8'hE5;
            8'hDE: sm4_sbox = 8'hB4;  8'hDF: sm4_sbox = 8'hB0;
            8'hE0: sm4_sbox = 8'h89;  8'hE1: sm4_sbox = 8'h69;
            8'hE2: sm4_sbox = 8'h97;  8'hE3: sm4_sbox = 8'h4A;
            8'hE4: sm4_sbox = 8'h0C;  8'hE5: sm4_sbox = 8'h96;
            8'hE6: sm4_sbox = 8'h77;  8'hE7: sm4_sbox = 8'h7E;
            8'hE8: sm4_sbox = 8'h65;  8'hE9: sm4_sbox = 8'hB9;
            8'hEA: sm4_sbox = 8'hF1;  8'hEB: sm4_sbox = 8'h09;
            8'hEC: sm4_sbox = 8'hC5;  8'hED: sm4_sbox = 8'h6E;
            8'hEE: sm4_sbox = 8'hC6;  8'hEF: sm4_sbox = 8'h84;
            8'hF0: sm4_sbox = 8'h18;  8'hF1: sm4_sbox = 8'hF0;
            8'hF2: sm4_sbox = 8'h7D;  8'hF3: sm4_sbox = 8'hEC;
            8'hF4: sm4_sbox = 8'h3A;  8'hF5: sm4_sbox = 8'hDC;
            8'hF6: sm4_sbox = 8'h4D;  8'hF7: sm4_sbox = 8'h20;
            8'hF8: sm4_sbox = 8'h79;  8'hF9: sm4_sbox = 8'hEE;
            8'hFA: sm4_sbox = 8'h5F;  8'hFB: sm4_sbox = 8'h3E;
            8'hFC: sm4_sbox = 8'hD7;  8'hFD: sm4_sbox = 8'hCB;
            8'hFE: sm4_sbox = 8'h39;  8'hFF: sm4_sbox = 8'h48;
            default: sm4_sbox = 8'h00;
        endcase
    endfunction

    // addr = tmp ^ K  (lookup address in masked domain)
    wire [7:0] addr = tmp ^ K;

    // tbl[addr] = S(addr ^ K) ^ mout8 = S(tmp ^ K ^ K) ^ mout8 = S(tmp) ^ mout8
    wire [7:0] tbl_val = sm4_sbox(addr ^ K) ^ mout8;

    // tau_m = tbl[addr] = S(tmp) ^ mout8
    assign tau_m = tbl_val;

endmodule