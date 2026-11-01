// =============================================================================
// sbox_equiv_top.v -- Top-level module for SymbiYosys formal equivalence check
// =============================================================================
// Proves: v4 masked S-box (after unmasking) == standard SM4 S-box
//
//   tau_m = S(tmp) ^ mout8   (masked output)
//   tau_m ^ mout8 = S(tmp)   (after unmasking)
//
// The assertion is: for all tmp, K, mout8:
//   tau_m ^ mout8 == s_ref
// =============================================================================

`timescale 1ns / 1ps

module sbox_equiv_top (
    input  wire [7:0]  tmp,
    input  wire [7:0]  K,
    input  wire [7:0]  mout8,
    output wire [7:0]  tau_m,
    output wire [7:0]  s_ref
);

    sbox_equiv_masked u_masked (
        .tmp    (tmp),
        .K      (K),
        .mout8  (mout8),
        .tau_m  (tau_m)
    );

    sbox_equiv_ref u_ref (
        .tmp    (tmp),
        .s_ref  (s_ref)
    );

    // Equivalence: masked output after unmasking == reference S-box
    // tau_m ^ mout8 == s_ref
    wire [7:0] unmasked = tau_m ^ mout8;

    assert_equiv: assert property (
        unmasked == s_ref
    );

    // Coverage: ensure all 256 inputs are covered
    cover property (tmp == 8'h00);
    cover property (tmp == 8'hFF);

endmodule