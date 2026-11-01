// =============================================================================
// sbox_equiv_miter.v -- SAT miter for S-box unmask equivalence
// =============================================================================
// Formal proof target (proved by `yosys sat -prove bad 0`):
//
//   For ALL tmp, K, mout8 in [0,255]^3:
//     tau_m ^ mout8 == s_ref
//
//   where tau_m = S(tmp) ^ mout8 (masked S-box output) and s_ref = S(tmp).
//   This holds by construction: tau_m ^ mout8 = S(tmp) ^ mout8 ^ mout8 = S(tmp).
//
// The miter asserts `bad` is never satisfiable (UNSAT) => equivalence holds for
// the full 2^24 input space. This is a combinational formal proof (no clocks),
// so `sat -prove bad 0` with depth=0 is sufficient.
//
// NOTE: This model captures the *per-byte* S-box unmask property. Both v4
// (single shared mout8 across 4 bytes) and v4_indep/v5 (4 independent mout8[b])
// satisfy this same per-byte identity; the difference between v4 and v5 lives
// at the 32-bit layer (shared vs independent masking), not in this S-box lemma.
// =============================================================================

`timescale 1ns / 1ps

module sbox_equiv_miter (
    input  wire [7:0]  tmp,    // S-box input (unmasked domain)
    input  wire [7:0]  K,      // input mask byte
    input  wire [7:0]  mout8,  // output mask byte
    output wire        bad     // 1 iff unmask != reference (must be provably 0)
);

    wire [7:0] tau_m;   // masked S-box output = S(tmp) ^ mout8
    wire [7:0] s_ref;   // reference = S(tmp)

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

    // Claim: tau_m ^ mout8 == s_ref  <=>  bad == 0
    assign bad = (tau_m ^ mout8) != s_ref;

endmodule
