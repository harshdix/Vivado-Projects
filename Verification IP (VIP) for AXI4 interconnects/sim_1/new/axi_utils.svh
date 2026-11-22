//------------------------------------------------------------------------------
// axi_utils.svh  (included by axi_vip_pkg)
// AXI4 address / byte-lane math straight from the spec (IHI0022, A3.4).
// Shared by sequences, the subordinate memory model and the scoreboard.
//------------------------------------------------------------------------------

// Address of beat N of a burst
function automatic bit [AXI_ADDR_W-1:0] axi_beat_addr(
    bit [AXI_ADDR_W-1:0] addr, bit [7:0] len, bit [2:0] size,
    axi_burst_e burst, int beat);
  longint unsigned nb      = longint'(1) << size;            // bytes per beat
  longint unsigned aligned = (addr / nb) * nb;
  longint unsigned total   = nb * (longint'(len) + 1);       // bytes in burst
  longint unsigned lower;
  case (burst)
    BURST_FIXED: return addr;
    BURST_INCR : return (beat == 0) ? addr : AXI_ADDR_W'(aligned + beat * nb);
    BURST_WRAP : begin
      lower = (addr / total) * total;                        // wrap boundary
      return AXI_ADDR_W'(lower + ((aligned - lower + beat * nb) % total));
    end
    default    : return addr;
  endcase
endfunction

// Byte lanes that are allowed to carry data on beat N (WSTRB legal mask)
function automatic bit [AXI_STRB_W-1:0] axi_lane_mask(
    bit [AXI_ADDR_W-1:0] addr, bit [7:0] len, bit [2:0] size,
    axi_burst_e burst, int beat);
  longint unsigned nb   = longint'(1) << size;
  longint unsigned dbb  = AXI_STRB_W;                        // data bus bytes
  longint unsigned a    = axi_beat_addr(addr, len, size, burst, beat);
  longint unsigned base = (a / dbb) * dbb;
  longint unsigned lo   = a - base;
  longint unsigned hi   = (a / nb) * nb + (nb - 1) - base;
  bit [AXI_STRB_W-1:0] m = '0;
  for (longint unsigned k = lo; k <= hi && k < dbb; k++)
    m[k] = 1'b1;
  return m;
endfunction

// Is this AxCACHE value legal in AXI4? (bits[3:2]!=0 requires Modifiable bit[1])
function automatic bit axi_cache_legal(bit [3:0] cache);
  return !((cache[3:2] != 2'b00) && !cache[1]);
endfunction

function automatic bit [AXI_DATA_W-1:0] axi_rand_data();
  bit [AXI_DATA_W-1:0] d = '0;
  for (int i = 0; i < (AXI_DATA_W + 31) / 32; i++)
    d = {d, 32'($urandom)};
  return d;
endfunction
