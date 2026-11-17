# Adopted by import on 2026-08-22 from the live controller — not authored by hand.
# A bad apply here can sever the path it is applied over. Plan first, always.
# __generated__ by OpenTofu from "69cfc94fcefe6560e6b42750"
resource "unifi_network" "tst" {
  auto_scale = false
  dhcp_server = {
    boot = {
      enabled = false
    }
    conflict_checking   = true
    enabled             = true
    gateway_enabled     = false
    leasetime           = "12h0m0s"
    start               = "192.168.88.50"
    stop                = "192.168.88.200"
    time_offset_enabled = false
    dns = {
      enabled = false
      servers = ["10.10.99.3"]
    }
    ntp = {
      enabled = false
    }
    wins = {
      enabled = false
    }
  }
  dhcp_v6_server  = null
  domain_name     = "dcunha.io"
  enabled         = true
  gateway_type    = "default"
  igmp_snooping   = false
  internet_access = true
  ipv6 = {
    aliases                   = null
    client_address_assignment = null
    interface_type            = "none"
    pd = {
      auto_prefixid_enabled = false
      interface             = null
      prefixid              = null
      start                 = null
      stop                  = null
    }
    ra = {
      enabled            = false
      preferred_lifetime = null
      priority           = null
      valid_lifetime     = null
    }
    static_subnet = null
  }
  lte_lan             = true
  multicast_dns       = true
  name                = "TST"
  network_isolation   = false
  purpose             = "corporate"
  setting_preference  = "manual"
  site                = "default"
  subnet              = "192.168.88.1/24"
  third_party_gateway = false
  vlan                = 1088
}
