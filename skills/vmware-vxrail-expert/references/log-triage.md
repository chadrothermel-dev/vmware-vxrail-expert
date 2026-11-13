# Log triage playbook

How to read VMware and VxRail logs the user pastes or uploads, and which log to ask for. Product-specific signatures are in esxi.md, vcenter.md, vsan.md, vxrail.md and vcf-nsx-portfolio.md. Items marked **[verify]** are practitioner knowledge.

## Contents
1. The method
2. Symptom → which logs to ask for
3. Recognising a log from its lines
4. Correlating across components
5. High-value search patterns
6. Asking for logs: bundles and size limits
7. Pitfalls when reading logs

---

## 1. The method

1. **Anchor the event.** Get the exact time the problem happened **and the timezone**. ESXi and vCenter logs are UTC (`...Z`); UI task times are local. Convert before searching.
2. **Identify the log.** Name the file and component from its line format (section 3). If the user didn't say, say what you think it is.
3. **Find the first error, not the loudest one.** Read backwards from the symptom to the earliest abnormal line. A storm of later errors is usually a consequence.
4. **Decode every line you rely on.** Translate codes (SCSI `H:/D:/P:` and sense data, PSOD exception, vSAN state, vMotion %, HTTP status) into plain language.
5. **Separate noise from signal.** Many repeating lines are benign (e.g. sense `0x5 0x24 0x0` during rescans, `0x2 0x3a 0x0` from empty virtual media). Say so explicitly so the user doesn't chase them.
6. **Correlate.** Confirm the hypothesis in a second log (section 4) before declaring a root cause.
7. **State confidence.** "Confirmed by X and Y" vs "Consistent with X; to confirm, run Z."
8. **Give the next action and the evidence that would prove you wrong.**

## 2. Symptom → which logs to ask for

| Symptom | Ask for (in this order) |
|---|---|
| Datastore inaccessible / VMs hung / latency | Host `vmkernel.log`, `vobd.log`, `vmkwarning.log` around the event; `esxcli storage core path list -d <naa>` output |
| Host PSOD | Photo of the screen; `/var/core/vmkernel-zdump.*` → `esxcfg-dumppart --log` output (`vmkernel-log.N`); BMC SEL / iDRAC lifecycle log for the same time |
| Host not responding in vCenter | `vdf -h` output; host `hostd.log`, `vpxa.log`, `vmkernel.log`; vCenter `vpxd.log` for that host |
| Unexpected reboot | `vmksummary.log`, `vmkernel.log` before the gap, BMC SEL |
| VM won't power on / crashed | VM `vmware.log`, host `hostd.log`, `vmkernel.log` |
| vMotion failed | The % it failed at; vCenter `vpxd.log`; source+destination `vmkernel.log`, `hostd.log`; the VM's `vmware.log` |
| HA errors | Host `fdm.log` (and `fdm-installer.log`); vCenter `vpxd.log` |
| vCenter UI 503 / no healthy upstream | `service-control --status --all`, `df -h`, `df -i`; `vpxd.log` tail; vmon log |
| vCenter upgrade failed | `/var/log/firstboot/firstbootStatus.json` and the named `_stderr.log`; `/var/log/vmware/upgrade/`; RDU: `vlcm/vlcm.log` |
| Certificate / login errors | vCert check output; STS/websso logs; `vpxd.log` |
| vLCM remediation / compliance | vCenter `vmware-vum-server.log`, `imageservices.log`; host `lifecycle.log`, `esxupdate.log` |
| vSAN object inaccessible / degraded | `esxcli vsan debug object health summary get`; `esxcli vsan cluster get` from every host; `vobd.log`, `vmkernel.log`, `vsandevicemonitord.log`, `clomd.log` |
| vSAN partition | `esxcli vsan cluster get` + `esxcli vsan cluster unicastagent list` from **every** host; `vmkping -d -s 8972` results |
| vSAN disk alarm | `vobd.log`, `vsandevicemonitord.log`, `vmkernel.log`; `esxcli vsan storage list`; dedup status |
| VxRail plugin / Physical View / LCM | VxRail Manager `short.term.log`, `lcm-web.log`, `web.log`, `marvin.log`; VxVerify output; VxRail and vCenter versions |
| VxRail node not discovered | `loudmouth.log`; `loudmouthc query` output; ToR VLAN 3939 / MLD config |
| SDDC Manager workflow failed | Task name and ID; `domainmanager.log` / `lcm.log` / `operationsmanager.log` |
| NSX tunnel down | `vmkping ++netstack=vxlan -d -s 1572` and `-s 8970` results; NSX alarms; host `nsx-syslog.log` |
| Supervisor stuck | vCenter `wcpsvc.log`, `eam.log` |

## 3. Recognising a log from its lines

| Looks like | It's |
|---|---|
| `cpuNN:NNNNNN)NMP: nmp_...`, `ScsiDeviceIO`, `LSOM:`, `VMotion`, `Migrate:` | ESXi `vmkernel.log` |
| `In(182) vmkernel: cpuN:...` | ESXi 8.0+ `vmkernel.log` (new format) |
| `[vob.storage...]`, `[esx.problem...]`, `[vob.vsan...]` | ESXi `vobd.log` |
| `Hostd[NNN]: [Originator@6876 sub=...]` or `... hostd[NNN] [Originator@6876 ...]` | ESXi `hostd.log` (8.0 vs 7.0 form) |
| `vpxd[NNN] [Originator@6876 sub=... opID=...]`, `[VpxLRO] -- BEGIN task-` | vCenter `vpxd.log` **[verify]** |
| `[ClusterElection...]`, `UninitializedState` | ESXi `fdm.log` |
| `vmx| I125:` / `In(05) vmx` | VM `vmware.log` |
| `Device naa... state is DISK_UNDER_PERM_ERROR`, `WARNING - ... Latency on VSAN device` | `vsandevicemonitord.log` |
| `microservice.do-...`, `func_...` | VxRail Manager `short.term.log` |
| `"failedSteps":` | vCenter `firstbootStatus.json` |

ESXi 8.0+ severity tokens: `Em Al Cr Er Wa No In Db`. VM log 6.x–7.x: `I125/W115/E105`; 8.0+: `In(05)/Wa(03)/Er(02)`.

## 4. Correlating across components

- **Time** is the universal key — normalise to UTC.
- **opID** links a vCenter task to vpxa/hostd lines on hosts. Grep the root prefix; suffixes are added as the call fans out.
- **Task ID** (`task-12345`) links the UI task to `vpxd.log` BEGIN/FINISH/ERROR lines.
- **Migration ID** links vMotion lines in both hosts' `vmkernel.log` and the VM's `vmware.log`.
- **Device ID** (`naa.xxx`, `t10.xxx`, `eui.xxx`) links storage lines across `vmkernel.log`, `vobd.log`, `vsandevicemonitord.log` and `esxcli` output.
- **vSAN UUIDs** (node, disk, disk group, object) link `esxcli vsan` output to log lines.
- **Datastore UUID** links `Lost access to volume <uuid>` to `esxcli storage filesystem list`.
- **Service tag** identifies a VxRail node in VxRail Manager logs and lockbox credential names.

## 5. High-value search patterns

Run on the host or against an extracted bundle. Patterns are case-insensitive regex.

| Goal | Pattern |
|---|---|
| SCSI failures | `H:0x[1-9a-f]|D:0x[1-9a-f]|Valid sense data` |
| APD / PDL | `APD|PERM LOSS|permanently inaccessible|PDL` |
| Latency spikes | `performance has deteriorated` |
| VMFS heartbeat loss | `Lost access to volume|Successfully restored access|ATS Miscompare` |
| Path changes | `path .* (dead|changing)|redundancy (lost|degraded)` |
| NIC flaps | `NIC Link is (Down|Up)|linkstate` |
| PSOD / panic | `PSOD|Panic|Exception (13|14)|LINT1|NMI|MCE|heartbeat` |
| Duplicate IP | `Duplicate IP` |
| vSAN disk | `permanent error|DISK_UNDER_PERM_ERROR|LogCong|Congestion|IMPENDING FAILURE|devicewithhighlatency` |
| vSAN membership | `CMMDS|partition|unicast` **[verify]** |
| HA | `UninitializedState|GenericFdmFault|Election` |
| vCenter task errors | `-- ERROR task-|vim.fault` |
| Certificates | `certificate|SSLHandshake|expired|Signing certificate is not valid` |
| Disk full | `No space left on device|ramdisk .* is full` |
| VxRail LCM | `ERROR|Exception|refresh token|precheck` in `lcm-web.log` / `short.term.log` |

## 6. Asking for logs: bundles and size limits

Copilot cannot open `.tgz` support bundles, and chat uploads have per-file size limits. Guide the user to:
1. Extract the bundle locally (`tar -xzf <bundle>.tgz`); rotated logs inside are `.gz` (`gunzip` or `zcat`).
2. Cut the window to **±30 minutes around the event** and filter with the patterns in section 5.
3. Upload or paste the trimmed text (rename `.log` to `.txt` if the surface rejects `.log`).
4. Mask hostnames, IPs, usernames and serial numbers if their policy requires — but keep the masking consistent so correlation still works.

The repository ships `tools/Invoke-LogTriage.ps1`, which does steps 1–3 automatically and writes size-limited `.txt` chunks plus a summary.

Bundle commands: ESXi `vm-support`; vCenter `vc-support` / VAMI / Export System Logs; VxRail Manager log bundle (`/mystic/generateLogBundle.py`); SDDC Manager `sos`; NSX Manager UI support bundle.

## 7. Pitfalls when reading logs

- **Timezone mismatches** cause most wrong root causes.
- **Log rotation:** the event may be in `vmkernel.1.gz`, not the live file. Bundles taken days later may have rotated it out entirely.
- **Non-persistent logs:** hosts without persistent scratch (USB/SD boot, older versions) lose logs at reboot — absence of evidence isn't evidence.
- **ESXi 8.0 format change** breaks old regexes.
- **The loudest error is rarely the cause.** One APD produces thousands of downstream lines.
- **Benign noise** (rescan sense codes, smartd pass-through rejections) is not a fault.
- **A green UI is not proof** — confirm vSAN partitions and object health with host CLI.
- **Don't trust "Possible sense data"** — only "Valid sense data".
- **Correlation isn't causation** — a NIC flap at the same second as a PSOD could be either cause or effect; check which came first and whether the backtrace names that driver.
