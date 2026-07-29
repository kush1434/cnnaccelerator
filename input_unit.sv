import cnn_pkg::*;

module input_unit (
  input  logic                         clk,
  input  logic                         rst_n,

  // Host interface used to load the complete input image into memA.
  input  logic                         ld_en,
  input  logic [LD_ADDR_W-1:0]         ld_addr,
  input  logic signed [DW-1:0]         ld_data,

  // Pulsed to begin loading the very first 3x3 window.
  input  logic                         start_window,

  // Current convolution-controller counters.
  //
  // i = current output patch
  // j = current filter
  // k = current kernel tap within the active 3x3 window
  input  logic [PATCH_W-1:0]           i,
  input  logic [FILTER_W-1:0]          j,
  input  logic [TAP_W-1:0]             k,
  input  logic                         valid_in,

  // Goes high after the first window has been loaded.
  output logic                         window_ready,

  // Pixel sent to the compute unit.
  // k selects one of the nine pixels from the active window.
  output logic signed [DW-1:0]         a_data
);

  // Double-buffered 3x3 windows.
  //
  // One bank supplies pixels to the MAC while the other bank is prepared
  // for the next output patch.
  logic signed [DW-1:0] window0 [0:N_TAP-1];
  logic signed [DW-1:0] window1 [0:N_TAP-1];

  // active_bank = 0: MAC reads window0; window1 may be prepared.
  // active_bank = 1: MAC reads window1; window0 may be prepared.
  logic active_bank;

  // Read interface to input-image memory.
  //
  // a_raddr is generated combinationally below.
  // mem_rdata is the pixel currently returned by memA.
  logic [A_ADDR_W-1:0]  a_raddr;
  logic signed [DW-1:0] mem_rdata;

  // Initial-window loader.
  //
  // init_count runs from 0 through N_TAP-1 and loads all nine pixels
  // into window0 before convolution begins.
  logic             init_loading;
  logic [TAP_W-1:0] init_count;

  // Next-window prefetch state.
  //
  // loading_next = 1 while the inactive bank is being prepared.
  // load_count identifies the memory read currently being performed.
  logic             loading_next;
  logic [TAP_W-1:0] load_count;

  // full_load = 0:
  //   Moving one patch to the right. Copy six overlapping pixels and
  //   read only the three new pixels in the rightmost column.
  //
  // full_load = 1:
  //   Moving from the end of one output row to the beginning of the next.
  //   Horizontal reuse is not possible, so read all nine pixels.
  logic full_load;

  // Signals identifying the beginning and end of one complete patch.
  logic patch_begin;
  logic patch_done;

  // Location of the patch that follows the current patch.
  logic [PATCH_W-1:0]       next_i;
  logic [$clog2(OFM_H)-1:0] next_row;
  logic [$clog2(OFM_W)-1:0] next_col;

  integer t;

  // A patch begins when computation starts on filter 0, tap 0.
  //
  // Prefetching starts here so it has the entire current patch's MAC
  // processing time to prepare the next window.
  assign patch_begin =
      valid_in &&
      (j == 0) &&
      (k == 0);

  // A patch is finished after the final tap of the final filter.
  //
  // At this point the inactive window must already contain the next patch.
  assign patch_done =
      valid_in &&
      (j == P - 1) &&
      (k == N_TAP - 1);

  // Convert the next flattened patch number into row and column coordinates.
  //
  // This assumes i remains stable during processing of the current patch.
  assign next_i   = i + 1'b1;
  assign next_row = next_i / OFM_W;
  assign next_col = next_i % OFM_W;

  // Combinational read from the currently active window.
  //
  // active_bank = 0 -> a_data = window0[k]
  // active_bank = 1 -> a_data = window1[k]
  //
  // The compute unit sees the pixel selected by the current tap counter k.
  assign a_data =
      active_bank ? window1[k] : window0[k];

  // Generate the input-memory read address.
  //
  // IMPORTANT TIMING:
  //
  // 1. init_count/load_count changes at a rising clock edge.
  // 2. This combinational block immediately calculates a new a_raddr.
  // 3. Asynchronous memA produces the corresponding mem_rdata.
  // 4. At the next rising clock edge, mem_rdata is stored in a window.
  always_comb begin

    // Safe default when no memory read is needed.
    // This also prevents latch inference.
    a_raddr = '0;

    if (init_loading) begin

      // Load the first complete 3x3 window.
      //
      // For KS = 3:
      //
      // init_count:  0 1 2 3 4 5 6 7 8
      // row:         0 0 0 1 1 1 2 2 2
      // column:      0 1 2 0 1 2 0 1 2
      //
      // Flattened image address:
      // address = row * IFM_W + column
      a_raddr =
          (init_count / KS) * IFM_W
        + (init_count % KS);

    end else if (loading_next) begin

      if (full_load) begin

        // At an output-row boundary, load all nine pixels of the next window.
        //
        // load_count / KS gives the row inside the 3x3 window.
        // load_count % KS gives the column inside the 3x3 window.
        a_raddr =
            (next_row + load_count / KS) * IFM_W
          + (next_col + load_count % KS);

      end else begin

        // Normal horizontal movement.
        //
        // Six overlapping pixels are copied directly between window banks.
        // Therefore, memory supplies only the new rightmost column.
        //
        // load_count = 0 -> top-right pixel
        // load_count = 1 -> middle-right pixel
        // load_count = 2 -> bottom-right pixel
        //
        // KS - 1 is the rightmost column inside the next window.
        a_raddr =
            (next_row + load_count) * IFM_W
          + (next_col + KS - 1);
      end
    end
  end

  // Input-image storage.
  //
  // During image loading:
  //   ld_en, ld_addr and ld_data write pixels into memA.
  //
  // During convolution:
  //   a_raddr selects a pixel and mem_rdata returns it.
  //
  // This input_unit timing assumes memA has asynchronous read behavior.
  mem #(
    .DW    (DW),
    .DEPTH (A_DEPTH)
  ) memA (
    .clk   (clk),
    .we    (ld_en),
    .waddr (ld_addr[A_ADDR_W-1:0]),
    .wdata (ld_data),
    .raddr (a_raddr),
    .rdata (mem_rdata)
  );

  always_ff @(posedge clk) begin
    if (!rst_n) begin

      // After reset, window0 is selected, but neither bank contains
      // a valid convolution window yet.
      active_bank  <= 0;
      window_ready <= 0;

      init_loading <= 0;
      init_count   <= 0;

      loading_next <= 0;
      load_count   <= 0;
      full_load    <= 0;

      for (t = 0; t < N_TAP; t = t + 1) begin
        window0[t] <= 0;
        window1[t] <= 0;
      end

    end else if (start_window) begin

      // Restart the window system and begin loading the first patch.
      //
      // Because these are nonblocking assignments, init_loading becomes
      // visible after this rising edge. The combinational address block
      // then presents the address for init_count = 0 during the next cycle.
      active_bank  <= 0;
      window_ready <= 0;

      init_loading <= 1;
      init_count   <= 0;

      loading_next <= 0;
      load_count   <= 0;

    end else if (init_loading) begin

      // mem_rdata corresponds to the a_raddr that was present during
      // the cycle immediately before this rising edge.
      //
      // Store that returned pixel into the corresponding window position.
      window0[init_count] <= mem_rdata;

      if (init_count == N_TAP - 1) begin

        // The ninth pixel is captured on this edge.
        // After the edge, window0 contains the complete first window.
        init_loading <= 0;
        init_count   <= 0;
        window_ready <= 1;

      end else begin

        // After this edge, the address-generation block calculates
        // the memory address for the next pixel.
        init_count <= init_count + 1'b1;
      end

    end else begin

      // Start preparing the next window at the beginning of each patch.
      //
      // This occurs while the current active bank continues feeding
      // pixels to the MAC.
      if (patch_begin && (i < N_PATCH - 1)) begin

        // Nonblocking-assignment detail:
        //
        // loading_next becomes 1 after this clock edge.
        // Therefore, the "if (loading_next)" block below does not perform
        // the first memory capture on this same edge. The first capture
        // occurs on the following edge, after memA has had one cycle to
        // respond to the newly generated address.
        loading_next <= 1;
        load_count   <= 0;

        // At the final patch column, the next patch starts a new row.
        // That transition requires a complete nine-pixel load.
        full_load <= ((i % OFM_W) == OFM_W - 1);

        // For an ordinary one-column shift, immediately copy the six
        // overlapping pixels from the active bank into the inactive bank.
        //
        // Old window:
        //
        //   0 1 2
        //   3 4 5
        //   6 7 8
        //
        // New window after moving right:
        //
        //   old[1] old[2] new
        //   old[4] old[5] new
        //   old[7] old[8] new
        //
        // New memory pixels later fill indexes 2, 5 and 8.
        if ((i % OFM_W) != OFM_W - 1) begin

          if (!active_bank) begin

            // window0 is active, so prepare window1.
            window1[0] <= window0[1];
            window1[1] <= window0[2];

            window1[3] <= window0[4];
            window1[4] <= window0[5];

            window1[6] <= window0[7];
            window1[7] <= window0[8];

          end else begin

            // window1 is active, so prepare window0.
            window0[0] <= window1[1];
            window0[1] <= window1[2];

            window0[3] <= window1[4];
            window0[4] <= window1[5];

            window0[6] <= window1[7];
            window0[7] <= window1[8];
          end
        end
      end

      if (loading_next) begin

        // Capture the memory value requested during the preceding cycle
        // into the inactive window bank.
        if (!active_bank) begin

          // window0 is feeding the MAC, so write into window1.
          if (full_load) begin

            // Complete reload:
            // load_count walks directly through indexes 0 through 8.
            window1[load_count] <= mem_rdata;

          end else begin

            // Horizontal shift:
            // only indexes 2, 5 and 8 need new memory data.
            //
            // KS = 3:
            // load_count=0 -> 0*3+2 = 2
            // load_count=1 -> 1*3+2 = 5
            // load_count=2 -> 2*3+2 = 8
            window1[load_count * KS + (KS - 1)] <= mem_rdata;
          end

        end else begin

          // window1 is feeding the MAC, so write into window0.
          if (full_load) begin
            window0[load_count] <= mem_rdata;
          end else begin
            window0[load_count * KS + (KS - 1)] <= mem_rdata;
          end
        end

        // A full reload performs N_TAP memory reads.
        // A horizontal shift performs only KS memory reads.
        if ((full_load  && (load_count == N_TAP - 1)) ||
            (!full_load && (load_count == KS - 1))) begin

          // The final pixel is captured on this edge.
          // After the edge, the inactive bank is complete.
          loading_next <= 0;
          load_count   <= 0;

        end else begin

          // Select the next memory address for the following cycle.
          load_count <= load_count + 1'b1;
        end
      end

      // Only switch banks after every filter and every tap for the current
      // patch has finished.
      //
      // By this time, loading_next should already be zero and the inactive
      // bank should contain the next patch.
      //
      // The bank switch occurs after this edge:
      //   active_bank 0 -> 1
      //   active_bank 1 -> 0
      if (patch_done && (i < N_PATCH - 1)) begin
        active_bank <= ~active_bank;
      end
    end
  end

`ifndef SYNTHESIS

  // Simulation-only safety checks.
  //
  // These assertions are removed during synthesis and therefore do not
  // become hardware.
  always_ff @(posedge clk) begin
    if (rst_n) begin

      // Detect an invalid memory address.
      assert (a_raddr < A_DEPTH)
        else $error(
          "input_unit: a_raddr=%0d out of range",
          a_raddr
        );

      // The next window must finish loading before the current patch ends.
      //
      // Failure means that the controller reached patch_done too quickly,
      // the memory was too slow, or the prefetch logic did not start in time.
      if (patch_done && (i < N_PATCH - 1)) begin
        assert (!loading_next)
          else $error(
            "input_unit: next window not ready at patch boundary"
          );
      end
    end
  end

`endif

endmodule