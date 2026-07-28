package cnn_pkg;
  localparam int DW      = 8;
  localparam int IFM_H   = 8;
  localparam int IFM_W   = 8;
  localparam int OFM_H   = 6;
  localparam int OFM_W   = 6;
  localparam int KS      = 3;
  localparam int A_DEPTH = IFM_H * IFM_W;
  localparam int N_PATCH = OFM_H * OFM_W;
  localparam int N_TAP   = KS * KS;
endpackage
