# Restore Windows DNS to original setting (before Pi-hole experiment)
# Original adapter: WLAN (interface index 18)
# Original DNS:     192.168.0.1 (home router)
# Backed up:        2026-05-04
#
# Run this in an elevated PowerShell window (Admin).

Set-DnsClientServerAddress -InterfaceIndex 18 -ServerAddresses "192.168.0.1"

# Alternative: reset to DHCP-assigned DNS
# Set-DnsClientServerAddress -InterfaceIndex 18 -ResetServerAddresses

ipconfig /flushdns
Write-Host "DNS restored. Verify with: Get-DnsClientServerAddress -InterfaceIndex 18"
