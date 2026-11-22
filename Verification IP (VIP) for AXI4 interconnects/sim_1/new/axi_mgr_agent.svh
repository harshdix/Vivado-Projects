//------------------------------------------------------------------------------
// axi_mgr_agent.svh  (included by axi_vip_pkg)
// Manager agent: sequencer + manager driver (if active) + monitor.
// The parent must set 'cfg' right after creating the agent.
//------------------------------------------------------------------------------
class axi_mgr_agent extends uvm_agent;
  `uvm_component_utils(axi_mgr_agent)

  axi_cfg        cfg;
  axi_sequencer  sqr;
  axi_mgr_driver drv;
  axi_monitor    mon;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    if (cfg == null) `uvm_fatal("CFG", "axi_mgr_agent: cfg not set")
    if (cfg.vif == null) `uvm_fatal("CFG", "axi_mgr_agent: cfg.vif is null")
    mon     = axi_monitor::type_id::create("mon", this);
    mon.cfg = cfg;
    if (cfg.is_active == UVM_ACTIVE) begin
      sqr     = axi_sequencer::type_id::create("sqr", this);
      drv     = axi_mgr_driver::type_id::create("drv", this);
      drv.cfg = cfg;
    end
    `uvm_info("AGENT", {get_full_name(), ": ", cfg.convert2string()}, UVM_LOW)
  endfunction

  function void connect_phase(uvm_phase phase);
    if (cfg.is_active == UVM_ACTIVE)
      drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass
