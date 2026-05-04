# Add Hyper-V Firewall rules to allow inbound traffic to WSL2 services.
# Required because WSL2 mirrored networking uses a separate Hyper-V firewall
# layer that blocks inbound by default — only ICMP and mDNS are allowed.

$vmCreatorId = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'

@(
    @{ Name = 'WSL-Pihole-DNS-UDP'; Display = 'Pi-hole DNS UDP/53';  Proto = 'UDP'; Port = 53 },
    @{ Name = 'WSL-Pihole-DNS-TCP'; Display = 'Pi-hole DNS TCP/53';  Proto = 'TCP'; Port = 53 },
    @{ Name = 'WSL-Pihole-HTTP';    Display = 'Pi-hole admin HTTP/80'; Proto = 'TCP'; Port = 80 }
) | ForEach-Object {
    Remove-NetFirewallHyperVRule -Name $_.Name -ErrorAction SilentlyContinue
    New-NetFirewallHyperVRule `
        -Name $_.Name `
        -DisplayName $_.Display `
        -Direction Inbound `
        -VMCreatorId $vmCreatorId `
        -Protocol $_.Proto `
        -LocalPorts $_.Port `
        -Action Allow | Out-Null
    "Added: $($_.Display)"
}

""
"--- new rules ---"
Get-NetFirewallHyperVRule -Name 'WSL-Pihole-*' | Format-Table Name,DisplayName,Direction,Action -AutoSize

Read-Host "Press Enter to close"
