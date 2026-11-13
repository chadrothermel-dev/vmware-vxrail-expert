# vCenter reference: logs, services, certificates, SSO, upgrades, HA/DRS/vMotion, vLCM

Covers Windows vCenter history briefly and the vCenter Server Appliance (VCSA) 6.5 through 9.x. Facts current as of November 2026. Broadcom KBs as `KB <new ID>` [legacy ID]. **[verify]** = practitioner knowledge not confirmed against a current Broadcom document — much of the command syntax and log-line format detail in this file is in that category, so confirm with `--help` on the appliance or the KB before relying on it.

## Contents
1. Log locations
2. Services, 503 / "no healthy upstream"
3. Disk / partition full
4. Certificates
5. SSO, identity, passwords
6. Database
7. Backup, restore, vCenter HA
8. Upgrade and patch failures
9. vSphere HA (FDM)
10. vCLS
11. DRS, vMotion, Storage vMotion, EVC, FT
12. vSphere Lifecycle Manager
13. Tracing an operation with opID
14. Performance and sizing
15. VxRail notes
16. KB index

---

## 1. Log locations

VCSA: `/var/log/vmware/<service>/` (on the `/storage/log` partition). Windows vCenter 6.x: `C:\ProgramData\VMware\vCenterServer\Logs\<service>`. Canonical index: KB 312194 [1021804]. Logs rotate to numbered files, some gzipped.

| Log | Content |
|---|---|
| `vpxd/vpxd.log` | **Primary log.** Tasks, host sync, vpxa communication, DB errors, vMotion orchestration |
| `vpxd/vpxd-profiler.log` | Per-operation timings and session counters (VOD dashboard `https://<vc>/vod/index.html`) |
| `vpxd/drmdump/` | DRS actions proposed and taken, per cluster |
| `vpxd-svcs/vpxd-svcs.log` | Authorization, tagging; fails when vmdir/STS unhealthy **[verify]** |
| `sso/vmware-identity-sts.log`, `sso/websso.log`, `sso/ssoAdminServer.log` | Logins, tokens, identity-source (LDAP) errors, STS cert errors **[verify]** |
| `vmdird/vmdird-syslog.log` | VMware Directory, ELM replication **[verify]** |
| `vmcad/certificate-manager.log` | certificate-manager runs **[verify]** |
| `vmon/vmon.log` | Service start/stop/crash decisions **[verify]** |
| `rhttpproxy/`, `envoy/` | Reverse proxy; 503 routing |
| `vsphere-ui/logs/vsphere_client_virgo.log` | HTML5 client, plug-in deployment **[verify]** |
| `eam/eam.log` | Agent VM deployment (vCLS pre-8.0 U3, NSX agents, File Services) |
| `vpostgres/postgresql-*.log` | Database |
| `applmgmt/` (`applmgmt.log`, `backup.log`, `software-packages.log`) | VAMI, file backup, patching **[verify]** |
| `vmware-updatemgr/vum-server/vmware-vum-server.log` | vLCM / depot sync / remediation |
| `vlcm/vlcm.log` | Reduced Downtime Upgrade (RDU) |
| `imageservices.log` | vLCM image depot issues |
| `vsan-health/vmware-vsan-health-service.log` | vSAN health |
| `wcp/wcpsvc.log` | Supervisor / Workload Management |
| `/var/log/firstboot/firstbootStatus.json`, `fbInstall.json`, `<script>_stderr.log` | Install/upgrade firstboot failures |
| `/var/log/vmware/upgrade/` | Upgrade pre-check, export/import |
| `/var/core/` | Core dumps (`core.vpxd.*`) — fill `/storage/core` |

**Support bundle** **[verify]**: `vc-support` from the bash shell; vSphere Client → vCenter → Actions → Export System Logs; or VAMI (`:5480`) → Create support bundle.

9.0: the `vmonapi` API is discontinued; EAM and solution-user accounts are deprecated. No authoritative per-service log list for 9.x was found — check `ls /var/log/vmware` on the appliance.

## 2. Services, 503 / "no healthy upstream"

"503 Service Unavailable" and "no healthy upstream" are the same symptom: the reverse proxy has no healthy backend (KB 344201). Check in this order:

1. `service-control --status --all` — are `vmware-vpxd` and `vapi-endpoint` running?
2. `df -h` and `df -i` — **vpxd stops automatically when a filesystem reaches 95%** (KB 318953).
3. Certificates — expired **STS signing certificate** gives "Signing certificate is not valid" or "no healthy upstream" with no warning, sometimes two years after deployment (KB 316619 [76719]). An expired issuing CA of the Machine SSL cert in TRUSTED_ROOTS stops the core service (KB 442815).
4. Restart: `service-control --stop --all && service-control --start --all`.

Other causes: LDAP identity source failure (KB 436630), network/MTU upstream (KB 446856). Dell VxRail equivalent: KB 000078068.

**vpxd crash loop** **[verify]**: `vmon.log` shows restarts; the last lines of `vpxd.log` before exit name the cause (`Panic`, `ODBC error`, `Unable to create SSO facade`, `Failed to initialize security`); `/var/core/core.vpxd.*` confirms real crashes. A malformed vCLS retreat-mode advanced setting can stop vpxd (section 10). Classic 6.x/7.x 503 text names the pipe that is down, e.g. `_pipeName =/var/run/vmware/vpxd-webserver-pipe` = vpxd.

`vmon-cli` (`/usr/lib/vmware-vmon/vmon-cli --list`, `--status <svc>`, `--restart <svc>`) — syntax **[verify]**.

## 3. Disk / partition full

- **`/storage/archive` near 100% is by design** (6.7+, archived WAL) — not a fault (KB 318953, 389313).
- `/storage/log` full: check inodes too (`df -i`) (KB 313077 [2143565]). Known consumers: sso/lookupsvc `localhost_access.log` and `catalina.log` (KB 318209), large postgres logs (KB 323922), remote syslog collector files (KB 406045). 8.0 expects `/storage/log` ≥ 50 GB (KB 426783).
- `/storage/seat` 100%: KB 318931 [2119809] gives the top-table query and truncation of `vpx_event_N`, `vpx_event_arg_N`, task tables. Third-party monitoring can flood events (KB 313586). On 8.0 when even psql fails with "No space left on device", follow KB 410118.
- **Grow a disk:** extend the matching VMDK, then `/usr/lib/applmgmt/support/scripts/autogrow.sh` (KB 316602). Root `/` cannot be resized on 7.0+. Autogrow fails if the VM has snapshots. Never shrink.
- 9.1 adds an API to resize vCenter compute and disk with one call plus reboot.
- Triage **[verify]**: `du -sh /storage/log/vmware/* | sort -h | tail`; root usually fills from `audit.log`, mail spool, `/root` uploads, `/tmp`, leftover ISOs. Old `core.*` files in `/storage/core` can be removed after capture.
- Event/task retention: vCenter advanced settings `event.maxAge`, `task.maxAge` (default 30 days) **[verify]**.

## 4. Certificates

**Primary tool: vCert** (KB 385107) — checks and repairs all vCenter certificates including STS and TRUSTED_ROOTS; intended for use at Broadcom support's direction. `checksts.py` is retired (KB 318968). Still documented: `fixsts.sh` (KB 316619 — snapshot **all** vCenters in the SSO domain offline first; run once per domain; Windows line endings cause `bad interpreter: /bin/bash^M`, fix with `sed -i -e 's/\r$//' fixsts.sh`) and `fixcerts` (KB 322249, e.g. `python fixcerts_3_2.py replace --certType sts`).

- vCert "Checking SSL Trust Anchors ... Mismatch" → vCert menu option 4 (KB 412753).
- vCert 6.1.1 can report false extension-thumbprint MISMATCH after 8.0.3 → 9.1 (KB 444233).
- **lsdoctor** fixes Lookup Service trust-anchor mismatch: `python lsdoctor.py -l` (check) then `-t` (fix). Used when SRM or vSAN break after cert replacement ("Failed to extract requested data") — KB 320615, 390691.
- After Machine SSL replacement, stale extension thumbprints break EAM (vCLS/NSX agents), vSAN health, vLCM — update extension thumbprints (vCert/lsdoctor) **[verify]**.
- Default lifetimes **[verify]**: VMCA root 10 years; Machine SSL and solution users 2 years; STS 10 years on fresh 6.5 U2+ deployments (2 years on older lineage); ESXi host certs 5 years.
- VECS inspection **[verify]**: `/usr/lib/vmware-vmafd/bin/vecs-cli store list`, then `vecs-cli entry list --store <store> --text | grep -ie Alias -ie "Not After"`.
- `certificate-manager` (`/usr/lib/vmware-vmca/bin/certificate-manager`) refuses to run cleanly when certs are already expired — the usual reason to use vCert/fixcerts instead **[verify]**.
- Host cert mode: advanced setting `vpxd.certmgmt.mode` = `vmca` (default) | `custom` | `thumbprint`. Host "Renew Certificate" fails for 24 h after a new VMCA root (`vpxd.certmgmt.certs.minutesBefore` = 1440) **[verify]**.
- **On VxRail, after replacing a vCenter certificate, import it into the VxRail Manager trust store** (see vxrail.md).

## 5. SSO, identity, passwords

- External PSC: deprecated 6.7, removed 7.0 (embedded only).
- **ELM is deprecated in 9.0** (kept so existing estates can upgrade; use VCF Operations grouping). **IWA, SSPI, smart card and RSA SecurID are removed in 9.0** — migrate to AD over LDAPS or identity federation before upgrading.
- VCF 9 Identity Broker (VIDB): Embedded or Appliance mode, mutually exclusive; switching needs "Reset SSO" in VCF Operations (KB 413884). Not compatible with ELM (KB 442644). Failures: KB 393161, 443943, 442433 (9.0.2 → 9.1 leaves SSO unavailable), 444003.
- **ELM replication:** `/usr/lib/vmware-vmdir/bin/vdcrepadmin -f showpartnerstatus -h localhost -u administrator` (use `administrator`, not `administrator@vsphere.local`, or you get a false "Host available: No" — KB 316504 [2127057], 410816). Snapshot all ELM nodes offline before changes (KB 369323).
- **Root password reset:** GRUB procedure after snapshot (KB 322247); without reboot when the SSO admin is known (KB 321369); from VAMI (KB 369931). Root expires after 90 days by default on 6.5+; expired root blocks VAMI, SSH, backups, patching **[verify]**. Check with `chage -l root`.
- **administrator@vsphere.local reset:** `/usr/lib/vmware-vmdir/bin/vdcadmintool`, option 3, enter the UPN; it prints a generated password (KB 326186 [2146224]).
- Account lockout **[verify]**: `pam_tally2 --user root --reset` (6.x/7.0), `faillock --user root --reset` (8.0+).
- AD over LDAPS breaks when the pinned DC/CA cert expires: `SSLHandshakeException` / "Error trying to connect to ldap" in the STS logs; re-upload the cert in the identity source **[verify]**.

## 6. Database

VCSA uses embedded vPostgres; most incidents are space (SEAT, WAL, logs), not corruption.
- Access **[verify]**: `/opt/vmware/vpostgres/current/bin/psql -U postgres -d VCDB`.
- Usual large tables: `vpx_event_*`, `vpx_event_arg_*`, `vpx_task*`, `vpx_hist_stat1..4_*` (statistics levels 3–4). Keep stats levels at 1–2 except short troubleshooting windows.
- Corruption signatures (`PANIC: could not locate a valid checkpoint record`, `invalid page in block`) follow hard power-off, APD, or a full `/storage/db`. **Supported fix is restore from file-based backup**; `pg_resetwal` is unsupported **[verify]**.
- 8.0 upgrade "Database in-place upgrade failed": KB 371569.

## 7. Backup, restore, vCenter HA

- **File-based backup from VAMI (`:5480`)** is the supported method: FTP, FTPS, HTTP(S) with WebDAV, SFTP, NFS, SMB (8.0). Target must allow ≥10 simultaneous connections. Manual backup: KB 375278.
- Backup fails if root is expired, a service is stopped, or a patch is in progress **[verify]**.
- Restore = deploy a new appliance of the same build, then import. vCenter rolls back to backup time: hosts added later show disconnected, newer VMs appear orphaned, vDS changes since backup need re-import **[verify]**. **Restoring vCenter can push a stale vSAN member list — see vsan.md section 4.**
- Image-level snapshots of ELM vCenters are only consistent when all nodes are captured powered-off together.
- **vCenter HA:** not supported for VCF-managed vCenters (KB 441793); blocks convergence/upgrade to VCF 9.1 — destroy VCHA first (KB 443214). Still supported on standalone vSphere. RDU on 8.0 U3 removes and re-adds VCHA automatically.

## 8. Upgrade and patch failures

- **Supported paths:** 9.0 from 8.0 only — **no direct 7.0 → 9.0** (vSphere 9 FAQ). 6.5/6.7 → 7.0; 6.7/7.0 → 8.0 **[verify]**. The target build must be released after the source build. Confirm in the Broadcom Product Interoperability Matrix.
- **9.0 blockers:** baseline-managed clusters (convert to vLCM images), IWA identity sources, Windows vCenter (Migration Assistant removed), external PSC, VCHA in VCF.
- **RDU (Reduced Downtime Upgrade):** introduced 8.0 U2; 8.0 U3 added ELM/VCHA and automatic switchover; recommended method in 9.x; switchover downtime minutes (KB 313288 [92659]). Log `/var/log/vmware/vlcm/vlcm.log`. KBs: needs the full installer ISO, not the patch ISO (452801); fails with a proxy configured (433349, 418332); fails with disconnected hosts (406490); `vsphere-ui` account failure at switchover 8.0 U3 → 9.0 (396777); ELM pre-check 8 → 9 (446672); DNS at target deploy (446307); 401 at pre-check (424471); stuck "A vCenter upgrade is already running" (454467); VCF RDU preparation timeout (419090); 9.0 → 9.1 (442134).
- **9.1:** vCenter quick patch; RDU from online depot; RDU moves the vCenter VM to hardware version 17.
- **Stage 2 / firstboot:** read `/var/log/firstboot/firstbootStatus.json` (names the failed step, e.g. `vpxd_firstboot`), then that script's `_stderr.log` (KB 324989). Examples: `vmafd-firstboot.py` on 8 → 9 (KB 421523); `vpostgres-firstboot.py` 8.0 U3h → 9.0.1, fix is retry (KB 423649); updatemgr extension (386345); HVC 7 → 8 (386547); content library role (392535); pre-check internal error (413489).
- **Rollback:** the source appliance is untouched until switchover — power off the new one, power on the old one.
- **Stage 1** logs live on the workstation running the installer (`%TEMP%\vcsaUiInstaller`) **[verify]**. Typical causes: forward/reverse DNS mismatch, temp IP unreachable, expired source root password, time skew, datastore space.
- **Patching** **[verify]**: VAMI → Update, or `software-packages stage --iso`, `software-packages install --staged`. Logs `applmgmt/software-packages.log`, `PatchRunner.log`. An interrupted patch leaves the appliance non-operational — supported recovery is revert to the pre-patch snapshot/backup. **Take a snapshot before patching.**
- **On VxRail with a VxRail-managed vCenter, never upgrade or patch vCenter on its own** — it comes in the VxRail bundle. A customer-managed vCenter is upgraded **before** VxRail (see vxrail.md).

## 9. vSphere HA (FDM)

Host log `/var/run/log/fdm.log`; VIB push failures in `fdm-installer.log`.

| State / error | Cause | Fix |
|---|---|---|
| Uninitialized | Agent present but not Primary/Secondary; storage access loss can cause it | Reconfigure for vSphere HA; look for `UninitializedState` / `GenericFdmFault` (KB 415249) |
| Agent Unreachable | Network to primary, watchdog, cert not matching vCenter PNID, port 8182 blocked | Reconfigure for HA (restarting agents/vCenter doesn't fix it) (KB 315379, 417885, 398888) |
| "Cannot install the vCenter Server agent service" / DependencyError | VIB push failed | KB 409955, 318929; read-only storage KB 391599 |
| "Cannot find vSphere HA master agent" | Missing `fdm.conf` | KB 440248 |
| Insufficient resources to satisfy failover level | Admission control math | Remove stray reservations, check disconnected/maintenance hosts, review policy |

Fix ladder **[verify]**: Reconfigure for vSphere HA → management network / 8182 / DNS → `/etc/init.d/vmware-fdm restart` → disable/re-enable HA on the cluster.

Concepts **[verify]**:
- One primary + secondaries; election ~15 s.
- Host **failed** (no network heartbeat, no datastore heartbeat, no ping → restart VMs) vs **isolated** (can't reach isolation address → isolation response) vs **partitioned** (alive, separate primary — datastore heartbeats prevent false restarts).
- 2 heartbeat datastores per host. vSAN clusters heartbeat over the vSAN network; the vSAN datastore can't be a heartbeat datastore.
- Admission control: cluster resource percentage (default 6.5+), slot policy (one big reservation skews everything), dedicated failover hosts.
- VMCP handles PDL/APD (see esxi.md).
- Recommended isolation response for vSAN (including stretched): Power off and restart VMs.

## 10. vCLS

- 7.0 U1–8.0: vCLS agent VMs (deployed by EAM) are required for DRS. "vSphere DRS functionality was impacted due to unhealthy state vSphere Cluster Services" usually = EAM thumbprint mismatch, EVC/CPU mismatch, or no eligible datastore **[verify]**. VxRail: Dell KB 000222526.
- 8.0 U3: embedded vCLS (2 VMs in host memory, no datastore, no EAM) **[verify]**.
- **9.0 deprecates vCLS**; retreat mode recommended; the 9.0 Product Support Notes say deactivating vCLS does not affect DRS or HA. A Japanese-language KB (392441) says DRS does not work without vCLS for "9.0 and earlier" — **this conflict is unresolved; on 7.0 U1–8.x assume DRS needs healthy vCLS.**
- **Retreat mode** (KB 316514 [91890]): advanced setting `config.vcls.clusters.domain-c<number>.enabled` = `False` (the domain ID is in the cluster URL); newer builds: Cluster → Configure → vSphere Cluster Services → Edit vCLS Mode. **The setting can't be deleted once added, and a malformed name (e.g. a UUID) can stop vpxd from starting** (KB 392441, 320005). After upgrading to 8.0 U3, GUI retreat mode may fail (KB 401767).

## 11. DRS, vMotion, Storage vMotion, EVC, FT

**vMotion stages** (KB 321009): request → destination validation → migration spec → source validation → destination VM created → memory pre-copy over vMotion vmknics → switchover → complete. Stage 6 problems: MTU mismatch (`vmkping -I vmk<#> -d -s 8972 <dest>`), vMotion TCP/IP stack, SAN zoning differences, VT disabled, NFS mounted differently.

| Fails at | Cause | KB |
|---|---|---|
| 10% hang, "Operation timed out" | Validation / connectivity | 321009 |
| 14% | Latency Sensitivity = High (community: duplicate vMotion IPs, orphaned `.vswp`) | 308424 |
| 20% | "Failed waiting for data", connection error | 328814, 419079, 420320 |
| 21% | MTU mismatch (bulk transfer uses max MTU) | 437735 |
| 20–21% | VMFS-6 specific | 338283 |
| 22% | Cross-cluster Storage vMotion — management subnet mismatch (NFC uses management network) | 440845 |
| 9–28% | "Error bad003F" | 341291 |
| 63% | "exceeded the maximum switchover time of 100 seconds" (`fsr.maxSwitchoverSeconds`) | 310514 |
| 68% | KB exists (Japanese) | 434539 |

Other percentages people quote (65–67%, 82–90%) are field heuristics, not KB-backed. Log-walk method: KB 379192.

**Tracing one vMotion** **[verify]**: vCenter `vpxd.log` (find the task, capture opID and migration ID) → source and destination `hostd.log`/`vpxa.log` (grep opID) → both `vmkernel.log` (grep migration ID; `Migrate:`, `VMotion` lines) → the VM's `vmware.log` on both sides (usually has the explicit error).

**Requirements** **[verify]**: vMotion vmk on both hosts, TCP 8000 (vMotion) and 902 (NFC), same port groups, compatible CPUs (EVC), ≤150 ms RTT for long-distance.

**EVC** **[verify]**: errors "The target host does not support the virtual machine's current hardware requirements" / CPUID mismatch. Raising EVC needs a VM power-cycle (not a guest reboot). Partial microcode patching creates mixed CPU feature sets.

**DRS:** faults under Cluster → Monitor → vSphere DRS → Faults (no compatible host, affinity rules, pinned by passthrough/vGPU/ISO/FT). 9.0 removed Storage DRS I/O load balancing and SIOC.

**Host won't enter maintenance mode** **[verify]**: DRS not fully automated, pinned VMs (local storage, passthrough, vGPU, connected ISO, must-affinity rules, FT), HA admission control, vSAN evacuation mode / too few fault domains, vCLS (pre-8.0 U3), agent VMs.

**FT** **[verify]**: dedicated FT logging network (10 GbE), HA enabled, max 8 vCPU per VM, no snapshots.

## 12. vSphere Lifecycle Manager

- **Baselines are removed in vCenter 9.0** — clusters must use vLCM images. Auto Deploy and Host Profiles are deprecated (replacement: vSphere Configuration Profiles).
- Logs: vCenter `vmware-vum-server.log` (depot sync, orchestration), `imageservices.log`; host `/var/run/log/lifecycle.log` (staging/remediation), `esxupdate.log`.
- Failure KBs: depot sync failure after upgrade — cleanup script (344109); offline bundle import (legacy 78688); "Two baseimages share the same releaseID" — clear patch store (444320); "A depot is inaccessible or has invalid contents" in 9.1 (445052); "The specified solution cannot be found in depots" (446554, 411089); staging `[Errno 17] File exists` (453548); "Connection reset by peer" ~60% with third-party depots (390155); 8.0 U3+ hosts need TCP 9087 to vCenter (398817); remediation failure (392118).
- Token-based Broadcom depots since 2025 (KB 390098); stale token → reset vLCM DB (KB 390121).
- **On VxRail:** do not edit the cluster image in vCenter, do not reset the vLCM/VUM DB without Dell approval, and disable non-required Broadcom online depots before a VxRail upgrade (see vxrail.md).

## 13. Tracing an operation with opID

The opID is the cross-component correlation token. Format details **[verify]**:
- vpxd.log line: `<UTC timestamp> <level> vpxd[<thread>] [Originator@6876 sub=<subsystem> opID=<opID>] <message>`.
- Tasks: `[VpxLRO] -- BEGIN task-12345 -- vm-678 -- vim.VirtualMachine.powerOn -- ...` and `-- FINISH task-12345`; failures show `-- ERROR task-12345 -- ... vim.fault.<Name>` with a fault dump.
- opIDs gain suffixes as they fan out to sub-operations and hosts — grep the root prefix.
- On hosts: `grep <opID> /var/log/vpxa.log /var/log/hostd.log`.
- Always convert the UI task time to UTC before searching; use `zgrep` for rotated logs.
- `vpxd-profiler.log` session stats identify which API client is hammering the PropertyCollector.
- Raise log level temporarily (vCenter → Configure → General → Logging settings) and set it back — verbose/trivia fills `/storage/log`.

## 14. Performance and sizing

- Most "vCenter is slow" cases: undersized deployment, a chatty API client, stats level/rollup load, or appliance disk latency **[verify]**.
- Tools: `vimtop` on the appliance (per-service CPU/memory/disk latency), `vpxd-profiler.log`, postgres log "checkpoints are occurring too frequently".
- Java out-of-memory (`java.lang.OutOfMemoryError`) in vsphere-ui/sps/eam logs → `cloudvm-ram-size -l` to see heap allocations **[verify]**.
- Deployment sizes and maximums change by release — check configmax.broadcom.com.
- 9.1 adds resize and capacity-monitoring APIs.

## 15. VxRail notes

- VxRail-managed vCenter: upgraded only through the VxRail bundle. Customer-managed vCenter: upgrade **before** VxRail, within the Dell interop matrix (Dell KB 000157682).
- Replacing/renewing vCenter certificates → re-import into the VxRail Manager trust store and `service runjars restart` (Dell KB 000201187).
- Changing the VxRail management account password must go through the VxRail procedure so the lockbox stays in sync (Dell KB 000157662).
- 503 on a VxRail-managed vCenter: Dell KB 000078068. Expired certs on VxRail-managed vCenter: Dell KB 000082108.

## 16. KB index

312194 [1021804] vCenter log files · 319957 6.x log files · 344201 no healthy upstream · 316619 [76719] STS signing cert / fixsts · 442815 expired CA in TRUSTED_ROOTS · 318953 95% full stops vpxd · 313077 [2143565] /storage/log · 318209, 323922, 406045 log growth · 426783 log partition size · 318931 [2119809] /storage/seat · 313586 event floods · 410118 seat full on 8.0 · 316602 increase disk · 385107 vCert · 318968 checksts retired · 322249 fixcerts · 412753 trust anchors · 444233 vCert false mismatch · 320615, 390691 lsdoctor · 316504 [2127057] vdcrepadmin · 410816 false Host available · 369323 replication alarm · 413884, 442644, 393161, 443943, 442433, 444003 Identity Broker · 322247 root reset (GRUB) · 321369 root reset without reboot · 369931 root reset VAMI · 326186 [2146224] SSO admin reset · 371569 DB upgrade failure · 375278 manual backup · 441793 VCHA not supported in VCF · 443214 VCHA blocks 9.1 · 313288 [92659] RDU · 324989 firstboot triage · 421523, 423649 8 → 9 firstboot · 452801, 433349, 406490, 396777, 446672, 446307, 424471, 454467, 419090, 442134 RDU failures · 415249, 315379, 417885, 398888, 409955, 318929, 391599, 440248 vSphere HA · 316514 [91890] vCLS retreat mode · 392441, 320005, 401767 vCLS pitfalls · 321009 vMotion · 308424, 328814, 437735, 338283, 440845, 341291, 310514, 434539 vMotion by % · 379192 vMotion log walk · 344109, 444320, 445052, 446554, 453548, 390155, 398817, 392118 vLCM.
