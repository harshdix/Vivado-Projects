//------------------------------------------------------------------------------
// axi_sub_agent.svh  (included by axi_vip_pkg)
// Subordinate agent: reactive memory driver (if active) + monitor.
// The subordinate needs no sequences: it responds to whatever arrives.
// The parent must set 'cfg' right after creating the agent.
//------------------------------------------------------------------------------
class axi_sub_agent extends uvm_agent;
  `uvm_component_utils(axi_sub_agent)

  axi_cfg        cfg;
  axi_sub_driver drv;
  axi_monitor    mon;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    if (cfg == null) `uvm_fatal("CFG", "axi_sub_agent: cfg not set")
    if (cfg.vif == null) `uvm_fatal("CFG", "axi_sub_agent: cfg.vif is null")
    mon     = axi_monitor::type_id::create("mon", this);
    mon.cfg = cfg;
    if (cfg.is_active == UVM_ACTIVE) begin
      drv     = axi_sub_driver::type_id::create("drv", this);
      drv.cfg = cfg;
    end
    `uvm_info("AGENT", {get_full_name(), ": ", cfg.convert2string()}, UVM_LOW)
  endfunction
endclass
