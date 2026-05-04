# Set Windows DNS to Pi-hole running in WSL2
# Adapter: WLAN (interface index 18)
# Pi-hole: 172.29.227.51 (WSL2 eth0)

Set-DnsClientServerAddress -InterfaceIndex 18 -ServerAddresses "172.29.227.51"
ipconfig /flushdns
"DNS now:"
Get-DnsClientServerAddress -InterfaceIndex 18 -AddressFamily IPv4 | Format-Table -AutoSize
"--- nslookup test ---"
nslookup doubleclick.net 2>&1 | Out-String
nslookup example.com 2>&1 | Out-String
Read-Host "Press Enter to close"
