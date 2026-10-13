- **The NTP restart guard fires on hardware again.** `setup_ntp_server` gated
  its one restart on `pidof sysntpd`, but busybox `pidof` matches the process
  comm and the service runs as `/usr/sbin/ntpd` (`PROG=` in
  `/etc/init.d/sysntpd`) — so the probe never matched and a running router
  upgraded in place kept its old, non-listening `ntpd` until the next interface
  event or reboot, even though `enable_server=1` was committed. The guard now
  probes `ntpd` (measured in `openwrt/rootfs:x86_64-openwrt-25.12`: `pidof
  sysntpd` empty, `pidof ntpd` returns the pid). `/etc/init.d/sysntpd running`
  is deliberately not used — `rc.common`'s `running()` is a procd/ubus query
  and reports "not running" for a live-but-unregistered `ntpd`. The offline
  suite's fake `pidof` now answers to the real comm and a new case asserts the
  probed name against the `PROG` read off the live init script, so the guard
  cannot go dead again unnoticed
  ([#648](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/648)).
