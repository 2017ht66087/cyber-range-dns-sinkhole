@{
    # =====================================================================
    # Cyber Range - single source of truth for networks, VMs, and scenario
    # Consumed by all scripts under cyber-range/deploy, /scenario, /validate
    # =====================================================================

    Settings = @{
        RangeName        = 'PurpleRange'
        BaseVMPath       = 'C:\CyberRange\VMs'          # where clones are created
        TemplatePath     = 'C:\CyberRange\Templates'    # golden base .vmx templates live here
        SnapshotArmed    = 'scenario-armed'
        SnapshotClean    = 'baseline-clean'

        # Scenario resolution targets
        SinkholeIP       = '10.10.60.5'    # dead-end sink listener (SOC zone)
        InternalDNS      = '10.10.20.10'   # SVC-DC (Path A / sinkhole ON)
        SinkholeDNS      = '10.10.20.11'   # SVC-SINK resolver
        ExternalDNS      = '10.10.50.53'   # EXT-DNS (Path B / sinkhole OFF)
        AttackerIP       = '10.10.40.10'   # ATK-C2
        UsersVMnet       = 'VMnet12'
        MaliciousDomains = @('updates.evil-c2.range', 'bad-exfil.range')
    }

    # HostAdapter = $true  -> host gets a virtual NIC on this vnet (MGMT/SOC access)
    # HostAdapter = $false -> fully blind segment (attacker/external/users/servers)
    Networks = @(
        @{ Name='VMnet10'; Zone='MGMT';     Subnet='10.10.10.0'; Mask='255.255.255.0'; Gateway='10.10.10.1'; HostAdapter=$true  }
        @{ Name='VMnet11'; Zone='SERVERS';  Subnet='10.10.20.0'; Mask='255.255.255.0'; Gateway='10.10.20.1'; HostAdapter=$false }
        @{ Name='VMnet12'; Zone='USERS';    Subnet='10.10.30.0'; Mask='255.255.255.0'; Gateway='10.10.30.1'; HostAdapter=$false }
        @{ Name='VMnet13'; Zone='ATTACKER'; Subnet='10.10.40.0'; Mask='255.255.255.0'; Gateway='10.10.40.1'; HostAdapter=$false }
        @{ Name='VMnet14'; Zone='EXTERNAL'; Subnet='10.10.50.0'; Mask='255.255.255.0'; Gateway='10.10.50.1'; HostAdapter=$false }
        @{ Name='VMnet15'; Zone='SOC';      Subnet='10.10.60.0'; Mask='255.255.255.0'; Gateway='10.10.60.1'; HostAdapter=$true  }
    )

    # BootTier controls start order (asc) and shutdown order (desc).
    VMs = @(
        @{ Name='SEC-GW';       Role='firewall';   Template='template-pfsense';      CPU=2; MemMB=2048; BootTier=1;
           Nics=@('VMnet10','VMnet11','VMnet12','VMnet13','VMnet14','VMnet15'); IP='per-leg .1' }

        @{ Name='SOC-SEConion'; Role='siem';       Template='template-securityonion'; CPU=4; MemMB=8192; BootTier=2;
           Nics=@('VMnet15'); IP='10.10.60.10' }
        @{ Name='SVC-LOG';      Role='logging';    Template='template-ubuntu22';     CPU=2; MemMB=4096; BootTier=2;
           Nics=@('VMnet11'); IP='10.10.20.20' }
        @{ Name='SOC-DASH';     Role='dashboards'; Template='template-ubuntu22';     CPU=2; MemMB=4096; BootTier=2;
           Nics=@('VMnet15'); IP='10.10.60.20' }

        @{ Name='MGMT-JUMP';    Role='bastion';    Template='template-debian12';     CPU=2; MemMB=2048; BootTier=3;
           Nics=@('VMnet10'); IP='10.10.10.10' }
        @{ Name='MGMT-ORCH';    Role='ansible';    Template='template-debian12';     CPU=2; MemMB=2048; BootTier=3;
           Nics=@('VMnet10'); IP='10.10.10.20' }
        @{ Name='MGMT-BKP';     Role='backup';     Template='template-debian12';     CPU=1; MemMB=2048; BootTier=3;
           Nics=@('VMnet10'); IP='10.10.10.30' }

        @{ Name='SVC-DC';       Role='ad-dns';     Template='template-win2022';      CPU=2; MemMB=4096; BootTier=4;
           Nics=@('VMnet11'); IP='10.10.20.10' }
        @{ Name='SVC-SINK';     Role='sinkhole';   Template='template-debian12';     CPU=1; MemMB=1024; BootTier=4;
           Nics=@('VMnet11'); IP='10.10.20.11' }

        @{ Name='EXT-DNS';      Role='ext-dns';    Template='template-debian12';     CPU=1; MemMB=1024; BootTier=5;
           Nics=@('VMnet14'); IP='10.10.50.53' }
        @{ Name='EXT-INETSIM';  Role='mock-inet';  Template='template-debian12';     CPU=2; MemMB=2048; BootTier=5;
           Nics=@('VMnet14'); IP='10.10.50.80' }
        @{ Name='ATK-C2';       Role='attacker';   Template='template-kali';         CPU=2; MemMB=2048; BootTier=5;
           Nics=@('VMnet13'); IP='10.10.40.10' }

        @{ Name='EP-CLEAN';     Role='endpoint';   Template='template-win10';        CPU=2; MemMB=4096; BootTier=6;
           Nics=@('VMnet12'); IP='dhcp (.100)' }
        @{ Name='EP-INFECTED';  Role='endpoint';   Template='template-win10';        CPU=2; MemMB=4096; BootTier=6;
           Nics=@('VMnet12'); IP='dhcp (.101)' }
    )
}
