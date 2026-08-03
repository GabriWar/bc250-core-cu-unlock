echo " "
echo "=== BC-250  P5.00_clv + 8 core unlock (v2) + custom logo ==="
echo " "
echo "Backing up your current chip to PREFLASH.ROM ..."
AfuEfix64.efi PREFLASH.ROM /O
echo " "
echo "Flashing BC250_P5clv_8core_v2.ROM ..."
AfuEfix64.efi BC250_P5clv_8core_v2.ROM /p /b /n /k /x /rlc:e /clrcfg
echo " "
echo "=== DONE ==="
echo "Power OFF completely (not reset), then boot into BIOS:"
echo "  Advanced -> Advanced CPU Settings -> Unlock CPU Cores -> Enabled"
