//------------------------------------------------------------------------------
// axi_types_pkg.sv
// Global AXI widths and enums shared by the interface, VIP classes and tests.
// Change widths HERE only - interface and VIP pick them up automatically.
// (Fixed widths avoid parameterized virtual interfaces, which make UVM painful.)
//------------------------------------------------------------------------------
package axi_types_pkg;

  localparam int AXI_ID_W   = 4;
  localparam int AXI_ADDR_W = 32;
  localparam int AXI_DATA_W = 128;
  localparam int AXI_STRB_W = AXI_DATA_W / 8;
  localparam int AXI_MAX_SIZE = $clog2(AXI_STRB_W);   // 4 -> 16 bytes for 128-bit bus

  typedef enum logic [1:0] {
    BURST_FIXED = 2'b00,
    BURST_INCR  = 2'b01,
    BURST_WRAP  = 2'b10,
    BURST_RSVD  = 2'b11
  } axi_burst_e;

  typedef enum logic [1:0] {
    RESP_OKAY   = 2'b00,
    RESP_EXOKAY = 2'b01,
    RESP_SLVERR = 2'b10,
    RESP_DECERR = 2'b11
  } axi_resp_e;

  typedef enum { AXI4, AXI4_LITE }          axi_mode_e;
  typedef enum { AXI_MANAGER, AXI_SUBORDINATE } axi_role_e;

endpackage
