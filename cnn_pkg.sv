



package cnn_pkg;


  localparam int IFM_H = 8;
  localparam int IFM_W = 8;


  localparam int KS    = 3;
  localparam int P     = 4;


  localparam int OFM_H = IFM_H - KS + 1;
  localparam int OFM_W = IFM_W - KS + 1;


  localparam int N_PATCH = OFM_H * OFM_W;
  localparam int N_TAP   = KS * KS;



  localparam int DW    = 8;
  localparam int ACC_W = 20;


  localparam int LAT   = 2;


  localparam int A_DEPTH = IFM_H * IFM_W;
  localparam int B_DEPTH = N_TAP * P;
  localparam int C_DEPTH = N_PATCH * P;


  localparam int A_ADDR_W = $clog2(A_DEPTH);
  localparam int B_ADDR_W = $clog2(B_DEPTH);
  localparam int C_ADDR_W = $clog2(C_DEPTH);
  localparam int LD_ADDR_W = (A_ADDR_W > B_ADDR_W) ? A_ADDR_W : B_ADDR_W;


  localparam int PATCH_W  = $clog2(N_PATCH);
  localparam int TAP_W    = $clog2(N_TAP);
  localparam int FILTER_W = $clog2(P);

endpackage
