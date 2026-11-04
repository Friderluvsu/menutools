# System stat details

CPU, GPU, RAM, TEMP, NET, BAT and DISK on the dashboard open a detail page. The header title becomes the metric name and **X** returns to the dashboard, same crossfade as Sessions. The page does not scroll; it is only the short set of rows below. FAN still opens fan control. On that metrics row the fan tile is one column and the disk tile is the other two. LAN and WAN still copy.

The detail snapshot lives on `SystemStatDetails`, which only the detail page observes. A history push does not re-render the metric tiles.

## What each page shows

| Page | Rows |
|---|---|
| CPU | Total, system / user / idle (nice is included in user), performance and efficiency when the machine has both, load (1 / 5 / 15 minutes), uptime, top 8 processes by CPU |
| GPU | Device utilization, renderer and tiler when the accelerator publishes them, in-use and allocated memory, core count, model, GPU temperature when an SMC key exists, top 8 processes by GPU time |
| Memory | Used of total, app / wired / compressed / cached, swap when it is at least 50 MB, memory pressure, top 8 processes by physical footprint |
| Temp | CPU temperature and, when the Mac has fans and a speed is known, the current RPM |
| Network | Down and up, bytes received and sent since boot, link kind (Wi-Fi, Ethernet, or VPN), peak down and up in the stored window, latency and jitter to 1.1.1.1 while the panel is open |
| Battery | Charge, source, time remaining, health, cycle count, watts, current, voltage, max and design capacity, battery temperature, Low Power Mode. A row is omitted when the power source does not publish it |
| Disk | Startup volume used, free and total, internal or external, then up to four other visible mounts |

FAN opens the same way as the other tiles: the header becomes Fan and **X** returns. It is the fan control (auto, curve, fixed speed), not a separate window.

Each page except Battery, Disk and Fan draws the last 10 minutes (300 samples, one every 2 s). Upload is drawn upward from the center and download downward, each on its own scale, so a spike on one does not flatten the other. Sampling starts at launch and keeps running while the panel is closed, so opening the panel draws the stored series and then keeps extending it. CPU, memory, temperature and GPU scale to the recent samples. Network uses the center line as zero. A new sample eases in from the previous tip over about 0.7 s; once the buffer is full the line scrolls one slot instead of stepping. The CPU and memory process lists move a row when its rank changes, and the rank and value tick with it.

## Where the numbers come from

The 2 s history tick (`SystemMonitorManager.startHistorySampling`) runs from launch, off the main thread. Opening the panel publishes the same numbers on the tiles. Closing the panel leaves the tick running and does not clear the series:

- CPU total, system, user and idle: `host_statistics(HOST_CPU_LOAD_INFO)`. Same counters as the tile.
- Performance and efficiency: `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`. Core indexes come from `IODeviceTree:/cpus` (`logical-cpu-id` and `cluster-type`). perflevel 0 is the performance cluster, but the processor list is not in that order — M1 lists efficiency cores first — so the device tree is the map. No split is shown when the tree has no E and P cores.
- Load: `getloadavg`. Pressure: `kern.memorystatus_vm_pressure_level`. Swap: `vm.swapusage`.
- Memory breakdown: the `vm_statistics64` sample already used for the tile. App is internal minus purgeable. Cached is purgeable plus external. Used stays active + wired + compressed, matching the tile.
- Temperature: the existing SMC average, every other tick.
- GPU: `IOAccelerator` `PerformanceStatistics` (`Device Utilization %`, renderer, tiler, in-use and allocated memory) plus `model` and `gpu-core-count`. Temperature is the SMC GPU keys only; if none exist the row is omitted. Per-process share is the delta of `accumulatedGPUTime` (nanoseconds) on `AGXDeviceUserClient`, divided by the wall-clock delta. The walk runs only while the GPU page is open. The first sample has no delta, so the list says “Sampling” until the second.
- Network totals: the same interface byte counters as the speed sample. The link kind comes from the primary IPv4 interface (`State:/Network/Global/IPv4`); an AirPort entry is shown as Wi-Fi. Peak down and up are the max of the stored window. Latency is one ping of 1.1.1.1 every 3 s while the panel is open. Jitter is the average change between those round trips. No addresses are shown on this page.
- Disk: mounted volumes via URL resource values, on the same 2 s tick. The startup volume is `/`. Free space is `volumeAvailableCapacityForImportantUsage` when the volume publishes it, otherwise `volumeAvailableCapacity`. Volumes under `/System` (the Data volume shares the startup container) are skipped. The tile shows used percent and free space.
- Top processes: `proc_pid_rusage` (`RUSAGE_INFO_V0`). CPU time is mach absolute ticks, so a process’s share of one core is the tick delta divided by the `mach_absolute_time` delta. Memory is `ri_phys_footprint`. Names are the executable’s last path component. The walk runs only while the CPU or Memory page is open (one sample immediately, another 0.7 s later, then on the 2 s tick). The first sample has no delta, so the CPU list says “Sampling” until the second.

Battery extras are filled on the same power-source notification. IOPS rarely publishes cycles or current on Apple batteries, so the missing fields are read from the `AppleSmartBattery` registry entry. Health is `AppleRawMaxCapacity` / `DesignCapacity` (nominal charge if the raw max is absent), otherwise the `BatteryHealth` word. Capacity shows those two milliamp-hour figures. Watts are |mA| × mV. Voltage is the registry millivolts. Current is signed: positive charges, negative discharges. A temperature above 200 is centi-celsius. A current stored as a full-width unsigned value is read as signed.

`--stat-diagnose` prints the cluster map, load, pressure, GPU utilization, the link kind and the top processes, then exits. It does not print addresses.
