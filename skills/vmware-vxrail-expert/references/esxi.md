# ESXi reference: logs, decoding, failure modes

Covers ESX 3.x through ESX 9.x. Facts current as of November 2026. Broadcom KBs are cited as `KB <new ID>` (legacy VMware ID in brackets where confirmed); open them at `knowledge.broadcom.com/external/article/<id>` or `knowledge.broadcom.com/external/article?legacyId=<old id>`. **[verify]** = practitioner knowledge not confirmed against a current Broadcom document — confirm on a host (`<command> --help`) or in the KB before relying on it.

## Contents
1. Log files and line formats
2. SCSI sense-code decoding
3. Storage failures: APD, PDL, latency, VMFS, NFS, boot media
4. PSOD analysis and core dumps
5. Networking and vMotion
6. Host not responding / management agents
7. Performance (esxtop)
8. Hardware
9. VM-level failures
10. Patching and upgrade failures
11. Command toolkit
12. KB index

---

## 1. Log files and line formats

All ESXi 5.0+ logs are under `/var/run/log` (symlinked from `/var/log`). Storage: scratch partition on 5.x/6.x; the **ESX-OSData** VMFS-L volume on 7.0+. Canonical list: KB 306962. Rotated logs are `<name>.N.gz`.

| Log | Read it for |
|---|---|
| `vmkernel.log` | Storage paths, SCSI errors, drivers, networking, vSAN kernel, VM start |
| `vmkwarning.log` | Warning subset of vmkernel — fastest first read after an incident |
| `vobd.log` | VMkernel observations (`esx.problem.*`, `vob.*`) — the events vCenter alarms are built on |
| `vmksummary.log` | Boots, shutdowns, hourly heartbeat — proves an unclean reboot (heartbeats stop, then a boot with no shutdown) |
| `hostd.log` | Host management: tasks, VM operations, vCenter/SDK calls |
| `hostd-probe.log` | hostd responsiveness |
| `vpxa.log` | vCenter agent; pairs with vCenter `vpxd.log` |
| `fdm.log` | vSphere HA agent |
| `syslog.log` | Service init, watchdog, cron, DCUI, NTP, smartd |
| `auth.log` / `shell.log` | Logins / every shell command typed |
| `esxupdate.log` | VIB/patch installation |
| `lifecycle.log`, `loadESX.log` | vLCM image operations, Quick Boot **[verify]** |
| `sysboot.log`, `boot.gz` | Early boot, module load (`zcat /var/log/boot.gz`) |
| `rhttpproxy.log`, `envoy-access.log` | Host web/API front end |
| `lacp.log` | LACP |
| `sensord.log` | Hardware sensors / IPMI polling |
| `vmsyslogd-dropped.log`, `/var/log/.vmsyslogd.err` | Lost log messages, syslog errors |
| `clomd.log`, `vsanmgmt.log`, `osfsd.log`, `vsansystem.log` | vSAN (see vsan.md) |
| `nsx-syslog.log`, `nsxaVim.log` | NSX on the host (`nsx-syslog.log` can flood on 8.0 — KB 376709) |
| `vmware.log` (VM folder) | The VM's own log; rotated `vmware-N.log` |

**Version history of locations** **[verify]**: ESX 3.x/4.x classic — `/var/log/vmkernel`, `/var/log/messages`, `/var/log/vmware/hostd.log`, `/var/log/vmware/vpx/vpxa.log`, `/var/log/vmware/aam/` (legacy HA). ESXi 3.5/4.x — mostly interleaved in `/var/log/messages`, in RAM unless syslog/scratch configured. ESXi 5.x–6.7 — per-component files on scratch; on USB/SD with no scratch, logs live in a ramdisk and are lost at reboot (vCenter warns "System logs on host are stored on non-persistent storage").

**ESXi 8.0 changed the line format** (KB 421596). Every vmsyslogd log now carries `Sev(PRI) program[pid]:` after the timestamp. Severity tokens: `Em Al Cr Er Wa No In Db`. Parsers and regexes written for 7.x silently miss 8.x lines. Remote syslog framing also changed and cannot be reverted; `?formatter=RFC_3164` / `?formatter=RFC_5424` on the log host URI selects the wrapper.

```
7.0  2025-..T..:..:..630Z cpu0:262792)Jumpstart plugin swapobjd activated.
8.0  2025-..T..:..:..810Z In(182) vmkernel: cpu0:2098001)Jumpstart plugin swapobjd activated.
7.0  ...266Z error hostd[265267] [Originator@6876 sub=Default] ...
8.0  ...073Z Er(163) Hostd[2098450]: [Originator@6876 sub=Default] ...
```

No 9.0-specific on-disk format change was found; confirm with `ls /var/run/log` on a 9.x host.

Known defect: a deadlock that stops logging on all files (host can go unresponsive) is fixed in ESXi 8.0 U3e (KB 419488).

## 2. SCSI sense-code decoding

Storage failure lines in vmkernel.log have the form (KB 337796 [289902]):

```
NMP: nmp_ThrottleLogForDevice: Cmd 0x2a (...) to dev "naa.600..." on path "vmhba2:C0:T1:L5"
Failed: H:0x0 D:0x2 P:0x0 Valid sense data: 0x6 0x29 0x0. Act:NONE
```

- `Cmd 0x..` = SCSI opcode. `H:` = host/HBA status (transport side). `D:` = device status (the array answered). `P:` = plugin (NMP/HPP) status.
- Sense data (key / ASC / ASCQ) is meaningful only when `D:0x2` (CHECK CONDITION) and the line says **Valid** sense data. "Possible sense data" = not flagged valid — don't trust it.
- `Act:` = NMP action: `NONE`, `EVAL` (re-evaluate path), `FAILOVER` **[verify]**.
- Many CHECK CONDITIONs are informational (KB 343525, KB 413628). Hardware faults go to the storage/hardware vendor.

**H: host status** (KB 337796)
| H: | Meaning | Reading |
|---|---|---|
| 0x0 | OK | |
| 0x1 | NO_CONNECT | Path dead; all paths → APD |
| 0x2 | BUS_BUSY | Congestion; retried |
| 0x3 | TIMEOUT | Command timed out in the HBA |
| 0x4 | BAD_TARGET | Target not responding |
| 0x5 | ABORT | ESXi/driver aborted after timeout — look for latency or fabric loss just before |
| 0x6 | PARITY | |
| 0x7 | ERROR | HBA/driver internal error; frequent → driver/firmware or FC frame drops |
| 0x8 | RESET | Bus/LUN/target reset; clusters of them = abort escalation |
| 0x9 | BAD_INTR | |
| 0xa | PASSTHROUGH | |
| 0xb | SOFT_ERROR | Driver requests retry |

**D: device status** (KB 337796): 0x00 GOOD · 0x02 CHECK CONDITION · 0x04 CONDITION MET · 0x08 BUSY (array busy, retried) · 0x18 RESERVATION CONFLICT (SCSI-2/3 reservation held elsewhere — WSFC/MSCS RDMs, non-ATS locking, stuck reservation) · 0x28 TASK SET FULL (array queue full — check queue depth, DSNRO, adaptive queuing) · 0x30 ACA ACTIVE · 0x40 TASK ABORTED.

**P: plugin status** **[verify against the virten.net decoder]**: 0x0 GOOD · 0x1 TRANSIENT · 0x2 SNAPSHOT · 0x3 RESERVATION_LOST · 0x4 REQUEUE · 0x5 ATS_MISCOMPARE · 0x6 THINPROV_BUSY_GROWING · 0x7 THINPROV_ATQUOTA · 0x8 THINPROV_NOSPACE.

**Sense keys** (T10 SPC): 0x0 NO SENSE · 0x1 RECOVERED ERROR · 0x2 NOT READY · 0x3 MEDIUM ERROR · 0x4 HARDWARE ERROR · 0x5 ILLEGAL REQUEST · 0x6 UNIT ATTENTION · 0x7 DATA PROTECT · 0x8 BLANK CHECK · 0xA COPY ABORTED · 0xB ABORTED COMMAND · 0xD VOLUME OVERFLOW · 0xE MISCOMPARE.

**Common triplets** (key ASC ASCQ). Rows marked ✔ are from Broadcom KBs; the rest are T10 assignments with practitioner reading **[verify]**.
| Sense | Meaning | Reading |
|---|---|---|
| 0x5 0x24 0x0 ✔ | Invalid field in CDB | Device doesn't support a page ESXi probed; expected during rescans — benign |
| 0x5 0x20 0x0 ✔ | Invalid command opcode | Unsupported command (VAAI primitive, smartd ATA pass-through) — benign |
| 0x5 0x25 0x0 ✔ | LU not supported | **PDL** — LUN unmapped/removed |
| 0x? 0x68 0x0 ✔ | LU not configured | **PDL** |
| 0x4/0x2 0x4c 0x0, 0x3e 0x1, 0x3e 0x3 ✔ | Self-config failed / LU failure / self-test failed | **PDL** |
| 0x2 0x4 0x3 ✔ | Not ready, manual intervention required | Array-side action needed |
| 0x2 0x4 0xc ✔ | Not ready, target port unavailable | Datastores inaccessible (KB 375946) |
| 0xb 0x44 0x0 ✔ | Aborted command, internal target failure | Hung VMs/tasks — array fault (KB 452886) |
| 0x2 0x3a 0x0 | Medium not present | Empty CD/virtual media/iDRAC card reader — benign |
| 0x6 0x29 0x0 | Power-on/reset occurred | First command after a reset; investigate only if frequent |
| 0x6 0x2a 0x6 | ALUA state changed | Controller failover / path state change |
| 0x6 0x3f 0xe | Reported LUNs data changed | LUN presented/unpresented — rescan |
| 0x6 0x38 0x7 | Thin provisioning soft threshold | Array pool warning |
| 0x7 0x27 0x7 | Space allocation failed | Thin LUN out of space — VMs pause |
| 0x2 0x4 0xa / 0xb | ALUA transition / standby | Failover in progress |
| 0x5 0x21 0x0 | LBA out of range | Shrunk LUN / bad partition table |
| 0x3 0x11 0x0 | Unrecovered read error | Real media fault |
| 0x4 0x44 0x0 | Hardware error, internal target failure | Array/drive firmware or hardware |
| 0xe 0x1d 0x0 | Miscompare | ATS (COMPARE AND WRITE) miscompare |

**Opcodes** **[verify]**: 0x00 TEST UNIT READY · 0x12 INQUIRY · 0x1a MODE SENSE(6) · 0x25/0x9e READ CAPACITY · 0x28/0x88 READ · 0x2a/0x8a WRITE · 0x35 SYNC CACHE · 0x42 UNMAP · 0x83 XCOPY · 0x89 COMPARE AND WRITE (ATS) · 0x93 WRITE SAME(16) · 0xa0 REPORT LUNS · 0xa3 MAINTENANCE IN (RTPG/ALUA) · 0x85 ATA PASS-THROUGH.

**NVMe:** no official Broadcom NVMe status-code table was found. Do not improvise one; decode against the NVMe Base Specification "Status Field" and quote the HPP line verbatim.

Community decoder: virten.net "ESXi SCSI Sense Code Decoder".

## 3. Storage failures

**APD vs PDL** (KB 318712 [2004684])
| | APD (All Paths Down) | PDL (Permanent Device Loss) |
|---|---|---|
| Cause | Transport gone; array says nothing | Array explicitly reports the LUN is gone (sense 0x25/0x0, 0x68/0x0 …) |
| Host behaviour | Treats as transient; keeps retrying; after the APD timeout fast-fails non-VM I/O | Stops I/O to the device immediately |
| Signatures | `... due to Not found (APD), try again...` · `Not all VMFS volumes were updated; the error encountered was 'No connection'.` · HPP: `is changing to 'APD' from 'on'.` · vob `vob.storage.apd.start` | `(PERM LOSS) command 0xa3 failed with status Device is permanently unavailable.` · `has been removed or is permanently inaccessible.` · `NMP Device ... is blocked. Not starting I/O from device.` · `has no more open connections. It is now safe to unmount datastores (if any) and delete the device.` · `Device naa.... APD Notify PERM LOSS` · HPP: `HppIsDevicePDL: PDL detected for HPP device` · VM question `msg.hbacommon.askonpermanentdeviceloss` |

- APD timeline **[verify]**: `Misc.APDTimeout` default 140 s. `esx.problem.storage.apd.start` → (140 s) `esx.problem.storage.apd.timeout` ("I/Os will now be fast failed") → `esx.clear.storage.apd.exit`. VM I/O keeps retrying.
- **VMCP** (HA setting, 6.0+): PDL and APD responses (Disabled / Issue events / Power off and restart). APD response adds a failover delay (default 3 min) on top of the APD timeout **[verify]**.
- Some one-LUN-per-target iSCSI arrays cannot signal PDL.
- Related KBs: APD 318850, 310620; planned LUN removal 323128; PDL log spam after unexpected removal 409335; PDL deadlocking management agents 451740; OSDATA exhaustion with APD/PDL 454304; Emulex silent driver hang → sudden APD 432997.
- **Planned LUN removal** = unmount datastore → detach device on every host → unmap on array → rescan. Unmapping first causes PDL.

**Latency** (KB 318927 [2007236]): `... performance has deteriorated. I/O latency increased from average value of N microseconds to M microseconds.` with a later `performance has improved`. Pair by device ID to get duration. Example: 456 µs → 11,849 µs.

**VMFS heartbeat / ATS miscompare** (KB 326437 [2113956]): ATS heartbeat is on by default for VMFS5/6. A false miscompare (`ATS Miscompare detected between test and set HB images`) makes the host re-verify access → `Lost access to volume <uuid> (<name>) due to connectivity issues. Recovery attempt is in progress...` then `Successfully restored access to volume...`. The time between the two = outage length. **Only disable ATS heartbeat (`/VMFS3/UseATSForHBOnVMFS5`) if the miscompare lines are present and the array vendor says so** (IBM Storwize/SVC does). Sense key 0x4 with "closed with dirty buffers" and failed ATS = array hardware error (KB 445277).

**VMFS corruption** **[verify]**: `Lock [type ... offset ...] is corrupted`, `Resource cluster metadata corruption detected`, vob `esx.problem.vmfs.resource.corruptondisk`. Check with VOMA: `voma -m vmfs -f check -d /vmfs/devices/disks/naa.xxx:1` — datastore must be offline on all hosts, no running VMs. Prefer check-only and engage Broadcom before any fix mode.

**Queue depth** **[verify]**: effective device queue = min(HBA device queue depth, "No of outstanding IOs with competing worlds"). View with `esxcli storage core device list -d naa.x`; set DSNRO with `esxcli storage core device set -d naa.x -O <n>`. In esxtop `u`, KAVG > 2 ms with QUED > 0 = queuing in the host.

**NFS** **[verify]**: never mount the same export as NFS 3 on some hosts and 4.1 on others (corruption risk). Signatures: vob `esx.problem.vmfs.nfs.server.disconnect` / `...restored`, vmkernel `NFS: ... Lost connection to the server <ip> mount point <path>`. Commands: `esxcli storage nfs list`, `esxcli storage nfs41 list`, `vmkping -I vmkN <server>`, `nc -z <ip> 2049`.

**Snapshots / consolidation** **[verify]**: "Virtual machine disks consolidation is needed" usually = file lock held by a backup proxy (HotAdd disk still attached), CBT problems, or no space. CID chain: each delta's `parentCID` must equal its parent's `CID`. Check with `vmkfstools -e <top>.vmdk`. Error text: "The content ID of the parent virtual disk does not match the corresponding parent content ID in the child". Never delete delta files by hand.

**Boot media**: SD/USB guidance KB 317631. 7.0 U2 symptom `Bootbank cannot be found at path '/bootbank'` (config not persisting) — fixed in 7.0 U2c. Intermittent `/bootbank` loss on USB/SD: KB 318611 [83376]. VMFS-L LOCKER corruption on SD logs `[esx.problem.vmfs.resource.corruptondisk]`. Move OSData to durable media. ESX 9.0 adds remote boot-device failure monitoring (KB 380716).

## 4. PSOD analysis and core dumps

Read a PSOD top-down (KB 343033 [1004250]):
1. **Error message** — what failed (finite set).
2. **Registers** — rip, cr2 (faulting address), error code.
3. **CPU and world** at failure (`CPU0:` prefix; older builds mark with `*`).
4. **Backtrace** — function+offset; `@module` names the owner.
5. **VMK uptime** and TSC.
6. **Core dump progress** (`Dumping using slot ...`).

**Backtrace reading** **[verify]**: frames look like `0x45...:[0x4180...]FunctionName@(module)#<None>+0xOFF`. Skip panic/exception-handler frames at the top; read down to the first non-`vmkernel` module (`i40en`, `nmlx5_core`, `lpfc`, `qlnativefc`, `nvme_pcie`, `lsi_mr3`, `vsan`, `nsxt-vsip`...). That driver + its firmware is the suspect — check the pair against the Broadcom Compatibility Guide.

**Pattern rule** (KB 343033): different messages/stacks across crashes → hardware; identical stack → software/driver; same PCPU every time → that CPU; same world → that workload.

| First line | Meaning |
|---|---|
| `#PF Exception 14 in world <id>:<name> IP ... addr 0x...` | Page fault. addr 0x0–0xfff = NULL dereference → software bug (KB 343251, 303440) |
| `#GP Exception 13` | General protection — illegal memory access |
| Exception 18 `#MC` / `Machine Check Exception` / `Fatal (unrecoverable) MCE` | **Hardware.** Correlate with iDRAC/BMC SEL at the same timestamp |
| `LINT1/NMI (motherboard nonmaskable interrupt), undiagnosed. This may be a hardware problem` | NMI from platform (KB 333947); also `ApeiHESTNmiHandler has diagnosed a PCI fatal error` (KB 415684) |
| `PCPU [n] didn't have a heartbeat for [X] seconds` → `NMI IPI: Panic requested by another PCPU` | CPU stuck with interrupts off — memory error/page retire (KB 441389) or vmnic + storage timeouts (KB 444524) |
| `Spin count exceeded / possible deadlock` | Lock held too long in a critical section |
| `PCPU N locked up. Failed to ack TLB invalidate.` | Locked-up CPU (KB 324947) |
| `PANIC ... ASSERT` / `NOT_REACHED` **[verify]** | Kernel assertion — software |

Exception numbers: 0 #DE, 2 NMI, 6 #UD, 8 #DF, 13 #GP, 14 #PF, 18 #MC.

**Core dumps** **[verify syntax with `--help`]**: ≤6.x dedicated diagnostic partition; 7.0+ a coredump file on OSData/VMFS. After reboot the dump is copied to `/var/core/vmkernel-zdump.N`.
- `esxcli system coredump partition get` / `esxcli system coredump file list`
- `esxcfg-dumppart --log /var/core/vmkernel-zdump.1` → writes `vmkernel-log.1`: **the pre-crash kernel log plus the PSOD text — the most useful single artifact.**
- `vm-support` includes `/var/core` automatically.
- Ask for a photo/screenshot of the PSOD screen if no dump was saved.

Known CPU-erratum PSOD family: Xeon E5 v4 / E7 v4 / D-1500 (KB 340044).

## 5. Networking and vMotion

This section is practitioner knowledge, not re-verified against KBs **[verify]**.

| Problem | Signature | Check |
|---|---|---|
| Link flap | vmkernel `vmnicX: NIC Link is Down` / `Up`; vob `esx.problem.net.vmnic.linkstate.down`, `esx.problem.net.redundancy.lost` | `esxcli network nic list`, `esxcli network nic get -n vmnicX` (driver/firmware), `esxcli network nic stats get -n vmnicX` (CRC, rx_missed) |
| Driver/firmware mismatch | Flaps, drops, PSODs naming the NIC module | `vmkchdev -l` (VID:DID:SVID:SSID) → Broadcom Compatibility Guide. **On VxRail, do not update NIC firmware/drivers outside VxRail LCM** |
| MTU mismatch | Large packets fail, small succeed; vMotion/vSAN/NFS stalls | `vmkping -I vmk1 -s 8972 -d <ip>` (9000 MTU; `-s 1472` for 1500; `-S vmotion` for the vMotion stack). NSX TEP underlay ≥1600 |
| Duplicate IP | `Duplicate IP address detected for <ip> on interface vmkN` | `esxcli network ip neighbor list` |
| vDS out of sync | vCenter "out of sync" warning; hostd/vpxa `DVS ... out of sync` | `net-dvs -l`; Rectify host in vCenter |
| LACP | `lacp.log` | `esxcli network vswitch dvs vmware lacp status get`. LACP needs IP hash; never beacon probing with IP hash/LACP |
| Drops | esxtop `n` %DRPRX/%DRPTX > 1 | VM port drops on vmxnet3 = guest rx ring exhaustion; uplink `rx_no_bufs` = pNIC ring too small (`esxcli network nic ring current get -n vmnicX`) |
| Capture | | `pktcap-uw --uplink vmnic0 --dir 2 -o /tmp/cap.pcap`; `--vmk vmk0`; `--switchport <id>`; `--capture Drop`. `tcpdump-uw -i vmk0` for vmknics only |

**vMotion failure stages** (KB-backed percentages): 14% — KB 308424; 20–21% — KBs 328814, 437735, 338283; 22% — KB 440845; 63% — KB 310514; 68% — KB 434539. Broadcom's main vMotion KB (321009) has no percentage table; other "it fails at X%" mappings are field heuristics. Low-percentage failures are usually vMotion network reachability, MTU, or duplicate IPs (`vmkping -S vmotion` both ways). Logs: source and destination `vmkernel.log` (`Migrate:`, `VMotion:`), the VM's `vmware.log` on both sides, `hostd.log`, vCenter `vpxd.log` — correlate by opID/migration ID. EVC/CPU mismatches fail at the compatibility check, not in vmkernel.

## 6. Host not responding / management agents

Most often: full ramdisk, storage APD/PDL hanging hostd threads, or blocked heartbeat (UDP 902 host → vCenter) **[verify port]**.

1. `vdf -h` and `esxcli system visorfs ramdisk list` (inode exhaustion gives "No space left on device" with free bytes).
   - `/etc` full from oversized `/etc/likewise/lib/krb5cc_lsass` on 8.x — KB 420756.
   - `hostdstats` 100% — KB 307384. `/tmp` 100% — KB 429012, 318795. "ramdisk 'root' is full" — KB 394550. General — KB 318926.
2. Check storage: APD/PDL can deadlock hostd (KB 451740, 454304).
3. hostd won't start if `/` or `/var/log` is full; a running-but-hung hostd gives "Timed Out" (KB 316598).
4. Restart individual agents: `/etc/init.d/hostd restart`, then `/etc/init.d/vpxa restart` (or DCUI → Troubleshooting Options → Restart Management Agents). Running VMs are not stopped; in-flight tasks fail.
5. **Avoid `services.sh restart`** when LACP is configured (uplinks bounce — critical if vSAN rides LACP), when NSX is installed, or on vSAN hosts unless a KB says so **[verify]**.
6. When hostd is hung, `localcli` runs the same namespaces as `esxcli` without hostd **[verify]**.

Other host-management areas **[verify]**:
- **Lockdown mode:** strict disables DCUI; if vCenter is lost and no exception user exists, reinstall is the only path.
- **Host certificates:** `/etc/vmware/ssl/rui.crt`; check expiry with `openssl x509 -in /etc/vmware/ssl/rui.crt -noout -dates`. Expired host certs cause disconnects and vSAN/HA issues.
- **Time:** `esxcli system ntp get`, `esxcli hardware clock get`. PTP supported 7.0 U2+.
- **TPM / encryption (7.0 U2+):** `esxcli system settings encryption get`; **back up the recovery key** with `esxcli system settings encryption recovery list` — a motherboard/TPM replacement on a TPM-sealed host needs it at boot.
- **ConfigStore (7.0 U1+):** `configstorecli config current get -c esx -g <group> -k <key>`.
- **Account lockout:** `pam_tally2 --user root --reset` (≤7.x), `faillock --user root --reset` (8.0+).

## 7. Performance (esxtop)

Thresholds are rules of thumb (Yellow-Bricks), not hard limits.

| View | Metric | Threshold | Meaning |
|---|---|---|---|
| `c` | %RDY | 10 per vCPU | Waiting for pCPU. VM row is summed — divide by vCPUs or expand with `e` |
| `c` | %CSTP | 3 | Co-stop — too many vCPUs |
| `c` | %MLMTD | > 0 | Throttled by a CPU limit |
| `c` | %SWPWT | 5 | Waiting on swapped pages |
| `m` | MCTLSZ | > 0 | Ballooning — host memory pressure |
| `m` | SWCUR / SWR/s / SWW/s | > 0 | Swapping (current activity = serious) |
| `m` | CACHEUSD, ZIP/s | > 0 | Memory compression |
| `m` | N%L | < 80 | Poor NUMA locality |
| `n` | %DRPTX / %DRPRX | 1 | Dropped packets |
| `u`/`d`/`v` | DAVG | 25 ms | Array/fabric latency |
| `u` | KAVG | 2 ms | VMkernel queuing — check QUED |
| `u` | GAVG | 25 ms | What the guest sees = DAVG + KAVG |
| `u` | ABRTS/s, RESETS/s | > 0 | Guest aborts / SCSI resets — storage not answering |
| `u` | CONS/s | 20 | Reservation conflicts |
| `x` | SDLAT | 5 | vSAN latency standard deviation |

- vCenter "CPU Ready (ms)" → % = ms ÷ (interval s × 1000) × 100; real-time interval is 20 s.
- Batch capture for offline analysis: `esxtop -b -d 2 -n 100 > esxtop.csv` (add `-a` for all counters).
- Memory states (high → clear → soft → hard → low) drive TPS → ballooning → compression/swap. Thresholds are minFree-relative and differ by version **[verify]**.
- High %LAT_C with low %RDY often points at power management (C-states): set BIOS to OS Controlled/Performance and ESXi power policy High Performance for latency-sensitive workloads **[verify]**.

## 8. Hardware

The BMC SEL (iDRAC, iLO, XCC) is the authoritative hardware record — time-correlate it with vmkernel.log.
- Memory errors → page retirement (`ApeiPageRetire`) and possible NMI IPI PSOD (KB 441389). Uncorrected error in guest memory kills that VM; in kernel memory → PSOD **[verify]**.
- PCIe fatal errors arrive as `ApeiHESTNmiHandler has diagnosed a PCI fatal error` (KB 415684).
- Commands **[verify]**: `esxcli hardware ipmi sel list`, `esxcli hardware platform get`, `esxcli hardware pci list`, `vmkchdev -l`, `esxcli storage core device smart get -d <dev>`, `smbiosDump`.
- `smartd` warnings land in `syslog.log`; RAID-backed devices return 0x5 0x20/0x24 to its pass-through — benign.
- ESX 9.0 device/driver deprecation lists: KB 391170.
- **On VxRail** use the VxRail Physical View, iDRAC, and the platform agent (see vxrail.md); firmware fixes come only through VxRail LCM.

## 9. VM-level failures

- **Kill a hung VM** (KB 308457): `esxcli vm process list` → `esxcli vm process kill --type=soft --world-id=<id>`, then `hard`, then `force`. If all fail, the host needs a reboot.
- **Locked files** (KB 316576 [2107795], KB 323140): `vmkfstools -D <file>` — the last 12 hex digits of `owner` are the MAC of the lock-holding host (all zeros = no owner) **[verify decode]**; `lsof | grep <file>`. Usual holders: backup proxy with a HotAdded disk, a stale VMX on another host, an in-flight Storage vMotion.
- **States:** orphaned (in vCenter, not on host — re-register), invalid (unreadable/locked .vmx — fix, `vim-cmd vmsvc/reload <id>`), inaccessible (storage gone), disconnected (host gone). Invalid after power outage: KB 443916.
- **vmware.log markers** **[verify]**: `Tools: Tools heartbeat timeout`, `scsi0:0: Command ... took N.NNN seconds` (I/O stalls ≥1 s), `Msg_Question`, `MONITOR PANIC` / `VMware ESX unrecoverable error: (vcpu-0)` with `vmx-zdump` files. Severity tokens 6.x–7.x `I125/W115/E105`; 8.0+ `In(05)/Wa(03)/Er(02)`.
- **Hardware versions** **[verify]**: 10 = 5.5, 11 = 6.0, 13 = 6.5, 14 = 6.7, 15 = 6.7 U2, 17 = 7.0, 18 = 7.0 U1, 19 = 7.0 U2, 20 = 8.0, 21 = 8.0 U2, 22 = 9.0. A VM can't power on or vMotion to a host older than its hardware version supports.

## 10. Patching and upgrade failures

- **CPU support in ESX 9.x** (KB 318697). Deprecated (warning, still supported): AMD EPYC 7001/7002, Intel Cascade Lake-SP, Xeon E-2100/E-2200, Atom C3000. Discontinued (installer blocks): Broadwell (E5/E7 v4, D-1500), Skylake-S/D/W, Kaby Lake-S. **Skylake-SP status has an update in KB 428874 — read it before stating support.** Warning text: `CPU_SUPPORT_WARNING: The CPUs in this host may not be supported in future VCF releases.`
- **vLCM baselines are removed for ESX 9.** Convert clusters to image-based management before upgrading hosts (KB 379388).
- **Typical `esxcli software` errors** **[verify]**: `[DependencyError] VIB ... requires ..., but the requirement cannot be satisfied` (third-party/OEM VIB, or removed vmklinux driver in 7.0 — use the OEM custom image); `[InstallationError] ... No space left on device`; `[HardwareError] Hardware precheck ... CPU_SUPPORT` or `UNSUPPORTED_DEVICES`. Failed update with mismatched bootbanks: Shift+R at boot to roll back.
- `profile update` keeps newer/third-party VIBs; `profile install` replaces the image and removes VIBs not in the profile — avoid unless intended **[verify]**.
- **Depot change (2025):** downloads are token-based (`dl.broadcom.com/<token>/PROD/COMP/...`, master KB 390098). Stale tokens in vLCM: reset the vLCM DB per KB 390121 (**not on VxRail without Dell** — see vxrail.md).
- Version gates: 7.0 removed the vmklinux driver stack (native drivers only). Upgrade vCenter first, then hosts. Confirm every hop in the Broadcom Product Interoperability Matrix.
- **On VxRail, never patch ESXi with esxcli or vLCM directly** — use the VxRail bundle.

## 11. Command toolkit

Confirmed by KBs: `zcat /var/log/boot.gz`, `esxcli vm process list|kill`, `vmkfstools -D`, `lsof`, `vdf -h`, `esxtop -b`. Everything else here is long-standing syntax **[verify with `--help`]**.

| Area | Commands |
|---|---|
| Identity | `vmware -vl` · `esxcli system version get` · `esxcli system stats uptime get` |
| Logs | `grep -iE "H:0x|sense data" /var/run/log/vmkernel.log` · `esxcli system syslog config get` · `esxcli system syslog mark -s "text"` |
| Bundle | `vm-support` (writes `/var/tmp/esx-<host>-<date>.tgz`; `-w <datastore path>` to write elsewhere) |
| Storage | `esxcli storage core device list -d naa.x` · `esxcli storage core path list` · `esxcli storage nmp device list` · `esxcli storage hpp device list` · `esxcli storage core adapter rescan --all` · `esxcli storage filesystem list` · `esxcli storage core device detached list` · `partedUtil getptbl <dev>` |
| Network | `esxcli network nic list` · `esxcli network ip interface list` · `vmkping -I vmkN -s 8972 -d <ip>` · `net-dvs -l` · `pktcap-uw` · `nc -z <ip> <port>` |
| VM | `vim-cmd vmsvc/getallvms` · `vim-cmd vmsvc/power.getstate <id>` · `vim-cmd vmsvc/reload <id>` · `vim-cmd solo/registervm <vmx>` |
| Services | `/etc/init.d/hostd restart` · `/etc/init.d/vpxa restart` · `/etc/init.d/<svc> status` |
| Config | `esxcli system settings advanced list -d` (non-default only) · `esxcli system settings advanced list -o /Path/Option` |
| Resources | `vdf -h` · `esxcli system visorfs ramdisk list` · `esxtop` |
| Hardware | `esxcli hardware ipmi sel list` · `esxcli hardware platform get` · `vmkchdev -l` |
| Core dump | `esxcli system coredump file list` · `esxcfg-dumppart --log <zdump>` |
| Software | `esxcli software vib list` · `esxcli software profile get` · `esxcli software baseimage get` (7.0+) |
| vSAN | see vsan.md |

## 12. KB index

306962 ESXi log files · 421596 ESXi 8.0 log format · 318939 syslog · 337796 [289902] SCSI sense codes · 343525 rescan check conditions · 345174 [1003433] SCSI events triggering failover · 318712 [2004684] PDL/APD · 318850, 310620 APD · 318927 [2007236] performance deteriorated · 326437 [2113956] ATS miscompare · 319797 disabling ATS · 317631 SD/USB guidance · 318611 [83376] bootbank loss · 343033 [1004250] interpreting a PSOD · 303440 exception 13/14 · 343251 #PF 14 · 324947 TLB invalidate · 333947 LINT1/NMI · 441389, 444524 NMI IPI · 367431 collecting diagnostics · 316598 hostd · 318926 disk space · 420756 /etc full · 308457 kill VM · 316576 [2107795] locked disks · 323140 file locked · 318697 VCF 9 CPU support · 428874 Skylake-SP update · 391170 ESX 9 device deprecation · 379388 vLCM images · 390098 download tokens · 390121 vLCM DB reset.
