// ============================================================================
// cnn_pkg.sv  -- single source of truth for every parameter in the design.
// No module may hardcode a number that appears here.
// ============================================================================
package cnn_pkg;

  // ---- image --------------------------------------------------------------
  localparam int IFM_H = 8;                  // input feature map height
  localparam int IFM_W = 8;                  // input feature map width

  // ---- kernel -------------------------------------------------------------
  localparam int KS    = 3;                  // kernel is KS x KS
  localparam int P     = 4;                  // number of filters

  // ---- output (derived: no padding, stride 1) ------------------------------
  localparam int OFM_H = IFM_H - KS + 1;     // 6
  localparam int OFM_W = IFM_W - KS + 1;     // 6

  // ---- loop bounds --------------------------------------------------------
  localparam int N_PATCH = OFM_H * OFM_W;    // 36  -> counter i
  localparam int N_TAP   = KS * KS;          // 9   -> counter k
                                             // P   -> counter j

  // ---- datapath widths ----------------------------------------------------
  localparam int DW    = 8;                  // pixel / weight, signed
  localparam int ACC_W = 20;                 // accumulator, signed
                                             //   worst case |-128*-128|*9 = 147,456
                                             //   needs 19 signed bits; 20 = 1 bit margin
  localparam int LAT   = 2;                  // mac_unit pipeline depth

  // ---- memory depths ------------------------------------------------------
  localparam int A_DEPTH = IFM_H * IFM_W;    // 64   image
  localparam int B_DEPTH = N_TAP * P;        // 36   weights
  localparam int C_DEPTH = N_PATCH * P;      // 144  results

  // ---- address widths -----------------------------------------------------
  localparam int A_ADDR_W = $clog2(A_DEPTH); // 6
  localparam int B_ADDR_W = $clog2(B_DEPTH); // 6
  localparam int C_ADDR_W = $clog2(C_DEPTH); // 8
  localparam int LD_ADDR_W = (A_ADDR_W > B_ADDR_W) ? A_ADDR_W : B_ADDR_W;

  // ---- counter widths -----------------------------------------------------
  localparam int PATCH_W  = $clog2(N_PATCH); // 6   holds 0..35
  localparam int TAP_W    = $clog2(N_TAP);   // 4   holds 0..8
  localparam int FILTER_W = $clog2(P);       // 2   holds 0..3

endpackage
