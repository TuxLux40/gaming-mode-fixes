#!/bin/sh
# Gaming CPU+GPU tuning for os93-steam-pc (Ryzen 5 5600G + RX 7600, amd-pstate-epp).
# Pins performance governor + re-enables CPU boost (PPD "balanced" disables it,
# and PPD "performance" is EINVAL-broken on this kernel), and forces the RX 7600
# to its high DPM power state instead of "auto" (auto was observed stuck at the
# mid clock tier under 100% load during capped-framerate games). Persists across reboot.
#
#   Run:  sudo sh ~/apply-gaming-perf.sh
#
set -e

echo ">> governor -> performance (all policies)"
for g in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do
    echo performance > "$g"
done

echo ">> CPU boost -> on (global node; dodges the per-policy EINVAL bug)"
if echo 1 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null; then :; else
    echo "   !! global boost node rejected the write"
fi
BOOST=$(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || echo '?')

echo ">> GPU (RX 7600, matched by PCI vendor:device, not card number) -> high perf level"
for c in /sys/class/drm/card*/device; do
    v=$(cat "$c/vendor" 2>/dev/null)
    d=$(cat "$c/device" 2>/dev/null)
    if [ "$v" = "0x1002" ] && [ "$d" = "0x7480" ]; then
        echo high > "$c/power_dpm_force_performance_level" 2>/dev/null || echo "   !! $c rejected the write"
    fi
done

echo ">> masking power-profiles-daemon (kills the boost-disabler + broken perf profile)"
systemctl mask --now power-profiles-daemon.service || true

echo ">> installing boot-persistence service"
cat > /etc/systemd/system/cpu-gaming-performance.service <<'EOF'
[Unit]
Description=CPU performance governor + boost, and GPU high perf level, for gaming
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for g in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do echo performance > "$g"; done; echo 1 > /sys/devices/system/cpu/cpufreq/boost || true; for c in /sys/class/drm/card*/device; do v=$(cat "$c/vendor" 2>/dev/null); d=$(cat "$c/device" 2>/dev/null); if [ "$v" = "0x1002" ] && [ "$d" = "0x7480" ]; then echo high > "$c/power_dpm_force_performance_level" 2>/dev/null || true; fi; done'

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cpu-gaming-performance.service

echo ""
echo "=== RESULT ==="
printf 'boost:     '; cat /sys/devices/system/cpu/cpufreq/boost
printf 'governors: '; for g in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do printf '%s ' "$(cat "$g")"; done; echo
printf 'gpu level: '; for c in /sys/class/drm/card*/device; do v=$(cat "$c/vendor" 2>/dev/null); d=$(cat "$c/device" 2>/dev/null); [ "$v" = "0x1002" ] && [ "$d" = "0x7480" ] && cat "$c/power_dpm_force_performance_level"; done
echo ""
if [ "$BOOST" = "1" ]; then
    echo "OK  -> boost ON + governor performance, persists across reboot."
else
    echo "PARTIAL -> governor set, but BOOST stayed off (kernel boost node broken)."
    echo "          Fix boost in BIOS: enable 'Core Performance Boost' / disable Eco Mode,"
    echo "          or add  amd_pstate=guided  to the kernel cmdline."
fi
