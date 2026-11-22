//------------------------------------------------------------------------------
// axi_cfg.svh  (included by axi_vip_pkg)
// Agent configuration object. One per agent instance.
// The build phase uses it to pick driver type (manager/subordinate),
// coverage collector (AXI4 / AXI4-Lite) and debug behaviour.
//------------------------------------------------------------------------------
class axi_cfg extends uvm_object;
  `uvm_object_utils(axi_cfg)

  // connection
  virtual axi_if            vif;
  uvm_active_passive_enum   is_active = UVM_ACTIVE;
  axi_role_e                role      = AXI_MANAGER;
  axi_mode_e                mode      = AXI4;

  // feature switches
  bit enable_coverage   = 1;
  bit enable_assertions = 1;

  // subordinate behaviour (used by subordinate driver)
  int unsigned max_ready_delay = 3;   // cycles before AWREADY/WREADY/ARREADY
  int unsigned max_resp_delay  = 5;   // cycles before BVALID / RVALID

  // debug features (paper Sec. IV-E)
  bit          trace_txn           = 0;      // print every transaction
  bit          dump_on_error       = 1;      // dump internal queues on error
  int unsigned hang_timeout_cycles = 10000;  // watchdog for stuck handshakes

  function new(string name = "axi_cfg");
    super.new(name);
  endfunction

  function string convert2string();
    return $sformatf("role=%s mode=%s active=%s cov=%0b asrt=%0b trace=%0b timeout=%0d",
                     role.name(), mode.name(), is_active.name(),
                     enable_coverage, enable_assertions, trace_txn, hang_timeout_cycles);
  endfunction
endclass
