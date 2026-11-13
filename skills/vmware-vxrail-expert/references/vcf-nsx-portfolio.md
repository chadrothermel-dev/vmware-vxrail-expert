# VCF, NSX, Aria, HCX, SRM, Supervisor, product history and Broadcom changes

Facts current as of November 2026. **[verify]** = practitioner knowledge not confirmed against a current Broadcom document. **[drift]** = likely to change; re-check before quoting. Much of the NSX, Aria, HCX, SRM and Supervisor command detail here is **[verify]** — confirm in the product CLI reference on techdocs.broadcom.com.

## Contents
1. Version and lifecycle timeline
2. Broadcom-era changes: licensing, downloads, support
3. VCF 9.0 / 9.1 architecture and upgrade sequencing
4. SDDC Manager / VCF troubleshooting
5. NSX
6. Aria / VCF Operations
7. HCX
8. SRM / vSphere Replication / VMware Live Recovery
9. Supervisor / VKS
10. Where authoritative information lives
11. Support bundles and opening a Broadcom case
12. Contested facts — present with caution

---

## 1. Version and lifecycle timeline

**Current builds** (KB 316595) **[drift]**:
| Line | Latest | Date | Build |
|---|---|---|---|
| ESX 9.1 | 9.1.1.0100 | 2026-10-12 | 25782009 |
| ESX 9.1 | 9.1 GA | 2026-05-12 | 25370933 |
| ESX 9.0 | 9.0.2.0100 | 2026-07-26 | 25595025 |
| ESX 9.0 | 9.0 GA | 2025-06-17 | 24755229 |
| ESXi 8.0 | 8.0.3 EP6 | 2026-07-29 | 25595708 |
| ESXi 8.0 | 8.0.3 P05 ("U3e", free hypervisor build) | 2025-04-10 | 24674464 |
| ESXi 7.0 | 7.0.3 EP14 (last 7.0 build) | 2025-07-15 | 24784741 |

8.0 U3 was the final 8.x update; later 8.x releases are 8.0.3 patches. The hypervisor is branded **ESX** again from 9.0.

**Lifecycle:**
- **vSphere 7.x: end of general support 2025-10-02** (extended from 2025-04-02). No 7.0 builds since July 2025 — any 7.x host is unpatched against later fixes.
- **vSphere 8.0: end of general support 2027-10-11** (KB 459135). VCF 5.2 same date.
- **VCF/vSphere 9.0** GA 2025-06-17; **9.1** announced 2026-05-05 (ESX build 2026-05-12); **9.1.1** 2026-09.
- 9.x uses a "6+1" model with per-minor support windows. **9.0 end of general support is reported as 2027-09-17 — earlier than 8.0's** — and 9.1 as August 2028. Both come from a single third-party source citing Broadcom KB 314608 **[verify on the Broadcom lifecycle page]**.
- Aria Operations 8.18: end of general support 2027-10-11.

**History** (expert background, not re-verified) **[verify]**:
| Release | GA | Headline changes |
|---|---|---|
| ESX 2.x | 2003 | VMotion, VirtualCenter 1.x |
| VI3: ESX 3.0 / 3.5 | 2006 / 2007 | HA, DRS, VMFS3; ESXi (3i), Storage VMotion |
| vSphere 4.0 / 4.1 | 2009 / 2010 | vDS, FT, host profiles; 4.1 last classic ESX with service console |
| 5.0 / 5.1 / 5.5 | 2011–2013 | ESXi only, VMFS5, VCSA, SSO (5.1), Web Client, vSAN 1.0 (5.5 U1) |
| 6.0 | 2015 | PSC, vVols, cross-vCenter vMotion, multi-vCPU FT |
| 6.5 | 2016 | VCHA, VUM in VCSA, VM encryption, VMFS6; EoGS 2022-10-15 |
| 6.7 | 2018 | Last Windows vCenter, Flash client, external PSC; EoGS 2022-10-15 |
| 7.0 | 2020-04 | Windows vCenter, Flash, external PSC removed; vLCM images; new DRS; vmklinux drivers removed; vCLS (U1); SD/USB boot deprecated (U3) |
| 8.0 | 2022-10 | DPU support, vSAN ESA, baselines deprecated; RDU (U2); Live Patch (U3) |
| 9.0 | 2025-06 | Section 3 |

Product renames **[verify]**: NSX-T → NSX (4.0; N-VDS on ESXi removed); NSX-V end of support Jan 2022. vROps → Aria Operations → **VCF Operations**; Log Insight → Aria Operations for Logs → VCF Operations for logs; vRA → Aria Automation → **VCF Automation**; vRSLCM → Aria Suite Lifecycle → VCF Operations fleet management. SRM → **VMware Live Site Recovery** (part of VMware Live Recovery). vSphere with Tanzu → vSphere Supervisor; TKGS → **vSphere Kubernetes Service (VKS)**. Horizon/Workspace ONE → **Omnissa** (divested 2024 — support and KBs live at omnissa.com, not Broadcom).

## 2. Broadcom-era changes

- Acquisition closed late 2023. Perpetual licenses ended (announced 2023-12-11); subscription per-core with a **16-core-per-CPU minimum**.
- **72-core minimum order: sources conflict** (introduced April 2025, reported reversed, partially reversed, still quoted mid-2026, reported withdrawn late 2026). Treat as unresolved — get it in writing from the reseller **[drift]**.
- SKU availability (vSphere Standard/Enterprise Plus end of sale, "vSphere Express", VVF availability) varies by region and rests on third-party trackers **[drift]**. Never quote prices.
- **Free ESXi returned with 8.0 U3e** (April 2025); cannot be managed by vCenter; no free ESX 9.
- **9.x licensing:** a single license file managed in **VCF Operations** (no per-version keys); usage reported every **180 days** (connected, or upload/import in disconnected mode); 90-day evaluation; 1 TiB vSAN per VCF core. vDefend Firewall and Avi remain key-based add-ons. Licensing a vCenter licenses its hosts. Known 9.0 issues: KB 437756, 448518, 438527.
- **9.1 requires a VCF License Server** (deployed via VCF Operations) for VCF and VVF. Issues: KB 440471 (can't license vCenter after upgrade), 424533, 441526 (license server black screen from Docker 172.17.0.0/16 conflict — use 9.1.0.0200+). **There is no keys-only mode in 9.x — even vSphere-only customers deploy VCF Operations.**
- **Downloads are token-based** (master KB 390098): `https://dl.broadcom.com/<token>/PROD/COMP/...`. Tokens are tied to the Site ID entitlement and stop working when it lapses. Triage "patch won't download / pre-check can't see bundles / vLCM 403": (1) token present and current, (2) entitlement active, (3) `dl.broadcom.com` reachable through firewall/proxy (KB 394069, 389871). vLCM still pointing at an old token or `hostupdate.vmware.com` → reset the vLCM DB (KB 390121) — **not on VxRail without Dell**. VMware Tools upgrade 403 via vLCM: KB 415515.
- **Skyline Advisor ended 2024-10-04.** Replacement: **Diagnostics for VMware Cloud Foundation** in VCF Operations (full dataset in 9.0) (KB 375104). Skyline Health Diagnostics appliance continues (KB 319011).
- Support moved to support.broadcom.com; KBs to knowledge.broadcom.com (legacy IDs resolve via `?legacyId=`); docs to techdocs.broadcom.com.

## 3. VCF 9.0 / 9.1 architecture and upgrade sequencing

**9.0:**
- VCF Installer replaces Cloud Builder (and the deployment workbook); also drives 5.x → 9.0 upgrades and import/convert of existing vSphere.
- VCF Operations is the fleet management and licensing plane; SDDC Manager UI deprecated; fleet management appliance deployed. Update sequence: KB 390634.
- Removed/deprecated (from 9.0 Product Support Notes and summaries): vLCM baselines removed; IWA removed; ELM, Host Profiles, Auto Deploy, vCLS, vVols deprecated; Storage DRS I/O balancing and SIOC removed; N-VDS on ESXi removed. Third-party summaries disagree on vSAN OSA status — **OSA is still supported in 9.0** per most sources **[verify against release notes]**.
- HCX 9.0: WAN Optimization deprecated, HCX DR being retired (KB 407101, 429864).

**9.1** (KB 440630):
- The 9.0 Fleet Management Appliance is replaced by **Fleet Lifecycle** and **SDDC Lifecycle** services inside **VCF Management Services** (mandatory for VCF, optional for VVF); the identity broker is consolidated into it. Don't use the 9.0 appliance for upgrades.
- Supported sources: VCF 5.2.x / 9.0.x; vCenter + ESX 8.x / 9.0.x; NSX 4.x; Aria Operations 8.x; Aria Automation 8.x.
- **SDDC Manager-based source:** upgrade VCF Operations first, then LCM workflows to 9.1.
- **Plain vCenter + ESX source:** VCF Installer → VCF Operations → license server → new entitlement → vCenters → ESX hosts.
- With NSX 4.x or Aria Automation present: must use VCF Installer converge/import — independent component upgrades are unsupported.
- **Wrong upgrade order causes most 9.1 upgrade failures** (KB 440282, 440407, 440459, plus licensing KBs). Always ask what the source topology is before recommending steps.
- VCHA blocks convergence to 9.1 — destroy it first (KB 443214).
- 9.1 features: NVMe memory tiering, vSAN global dedup with encryption, vSAN for Recovery, up to 5,000 hosts, hardware-offloaded vMotion encryption, native S3 object storage.

## 4. SDDC Manager / VCF troubleshooting

Logs (KB 397253):
| Log | Content |
|---|---|
| `/var/log/vmware/vcf/commonsvcs/vcf-commonsvcs.log` | Identity, inventory, credential store, tasks, network pools |
| `/var/log/vmware/vcf/domainmanager/domainmanager.log` | Workload domains, clusters, hosts, NSX edge clusters |
| `/var/log/vmware/vcf/lcm/lcm.log` (+ `lcm-debug.log`) | Pre-checks, bundles, downloads, upgrades |
| `/var/log/vmware/vcf/operationsmanager/operationsmanager.log` | Backups, host commission, DNS/NTP, licenses, certificates, password rotation |
| `/var/log/vmware/vcf/sddc-manager-ui-app/sddcManagerServer.log` | UI |

**SoS utility** (KB 385749, 429027): `/opt/vmware/sddc-support/sos` — SSH as `vcf`, then `su -`. Confirmed options: `--sddc-manager-logs`, `--all-logs`, `--health-check`, `--get-vcf-summary`, `--get-vcf-tasks-summary`, `--get-vcf-services-summary`, `--password-health`, and on 9.1 `--vcf-mgmt-svcs-logs --zip`. Output under `/var/log/vmware/vcf/sddc-support/`. Collection fails while a workflow is running. **`--collect-all-logs` does not exist — don't suggest it.**

Failure classes:
- **Depot/token** (section 2). Offline "VCF Download Tool" also fails "Unable to connect to the Depot Server" (KB 429663).
- **Full filesystem:** LCM won't start when `/dev/mapper/data_vg-vmware` is full (KB 401603); SoS fails on `/tmp` (KB 344798).
- **Credential drift:** `lookup_passwords` (as `vcf`) shows what SDDC Manager stores (KB 436398). Login `IDENTITY_INTERNAL_SERVER_ERROR` = stored SSO credential mismatch (KB 327796). Password changed out of band → fix the target, then **Remediate** (not Rotate) **[verify]**. VCF 5.2+ enforces 15-character minimum passwords.
- **NSX password expiry** affects SDDC Manager service accounts; 9.x Fleet Management can still show NSX passwords expired after update (KB 441866).
- **Failed workflows:** fix the cause, then Restart Task **[verify]**. Lock/task-state edits in the SDDC Manager Postgres DBs are **Broadcom-support-only**.
- **Pre-checks:** NTP/DNS drift, expired passwords, vSAN health/HCL DB, partition space, hosts not on the BOM build **[verify]**. VCF enforces its BOM strictly.
- **VCF on VxRail:** VxRail Manager performs host lifecycle when SDDC Manager invokes it; never patch ESXi via vLCM outside the VxRail bundle (see vxrail.md). SDDC Manager log collection on VCF on VxRail: Dell KB 000021269.

## 5. NSX

Most outages reduce to manager cluster health, expired local passwords/certificates, or TEP-to-TEP reachability (MTU/VLAN) dropping Geneve tunnels and BFD.

- **Passwords:** `admin`, `root`, `audit` on Manager and Edge expire after **90 days** by default (KB 326341). Once expired, API and UI logins fail. Check/extend: `get user admin password-expiration`; `set user admin password-expiration 9999`; `clear user audit password-expiration` (KB 338942). Expired root reset: KB 408091.
- **TEP MTU:** minimum 1600, best practice 9000 (KB 440775). Test from ESXi on the `vxlan` netstack with don't-fragment: payload **1572** for 1600 MTU, **8970** for 9000 MTU — test both (KB 379112, 405174). Tunnel-down KBs: 425308 ("Faulty TEP"), 429558, 447403 (>1500-byte VM traffic fails).
- **Cluster health:** `get cluster status` on a manager (or `GET /api/v1/cluster/status`). Losing 2 of 3 managers = read-only/unavailable **[verify]**. Corfu/datastore repair is support-only.
- **Support bundle:** NSX Manager → System → Support Bundle.
- **Licensing (9.x):** vDefend Firewall and Avi are separate keyed add-ons.

**[verify]** — commonly used, not re-checked:
- Manager CLI: `get cluster status verbose`, `get managers`, `get services`, `get certificate cluster`.
- Edge CLI: `get logical-routers`, `vrf <id>`, `get bgp neighbor summary`, `get route`, `get bfd-sessions`, `get high-availability status`.
- ESXi: `nsxcli` → `get logical-switches`, `get firewall <VIF-UUID> ruleset rules`; `nsxdp-cli`; `esxcli network ip interface ipv4 get --netstack=vxlan` (TEP vmks); `vmkping ++netstack=vxlan -d -s 1572 -I vmk10 <remote TEP>`; `esxcli software vib list | grep nsx`.
- Logs: manager `/var/log/syslog`, `/var/log/proton/nsxapi.log`, `/var/log/policy/policy.log`, `/var/log/corfu/`; ESXi `/var/log/nsx-syslog.log`, `/var/log/nsxaVim.log`, `/var/log/dfwpktlogs.log`.
- Failure patterns: transport-node install failure (vLCM image conflict, DNS/NTP, thumbprint, uplink profile); edge BFD down (TEP VLAN/MTU, trunk missing VLAN); certificate expiry (Certificate Analyzer-Resolver script); DFW (applied-to scope, exclusion list, group membership not realised — use **Traceflow**); no NSX backup = no supported recovery of a destroyed manager cluster.

## 6. Aria / VCF Operations

- 9.x: Aria products are VCF Operations components, lifecycle-managed from fleet management (9.0 appliance; 9.1 services). VCF Operations is also the licensing console and hosts **Diagnostics** (Skyline replacement; false-positive findings: legacy KB 87532). Skyline adapter error state: KB 392739.
- 9.1 upgrade: Aria Automation upgrades in place to VCF Automation; Log Insight is replaced by Log Management in VCF Operations (logs migrated); Aria Operations for Networks upgrades only via Fleet LCM.
- Licensing KBs: 437756, 439522, 418555, 438868, 436925, 417618.
- **[verify]** Aria Operations internals: analytics cluster + cloud proxies; admin UI `https://<node>/admin` to take the cluster offline/online and generate bundles; logs under `/storage/log/vcops/log/`. Classic failures: `/storage/db` or `/storage/log` full, cluster stuck "Going online" after unclean shutdown, expired certs/passwords, time skew. Recovery: take offline from admin UI → fix → bring online; don't snapshot nodes while online.
- **[verify]** Aria Automation 8.x: `vracli status`, `kubectl get pods -n prelude`, `vracli log-bundle`. VCF Automation 9.x is re-architected and tooling differs.

## 7. HCX

- **Version currency matters:** 4.11.3 is the supported 4.x line (end of service 2027-10-11). 4.11.0–4.11.2 end of support: Broadcom says 2025-12-24, Microsoft says 2026-02-20 (conflict). For end-of-support deployments Broadcom advises redeploying fresh managers rather than upgrading (KB 443860).
- Logs (KB 372815): Manager `/common/logs/admin/app.log` (main), `web.log`, `/common/logs/appliance-management/appliance-management.log`. IX: `/var/log/vmware/hbrsrv.log` (Bulk/RAV), `/var/log/vmware/mobility-agent.log` (vMotion/cold/RAV cutover). NE: `/var/log/system_events` (tunnel down, NE HA failover).
- Migration failure master KB: 377590. Upgrade prerequisite: `/common` above 45% → open a case first (KB 404381).
- WAN Optimization deprecated; HCX DR retiring (KB 413755); plug-in missing after upgrade (KB 401759). HCX with vSphere 7.0 sites: limited support ended 2026-10-02 (KB 321571).
- **[verify]** `ccli` on the manager (`list`, `go <id>`, `hc`, `ssh`) to reach IX/NE; UDP 4500 between IX/NE peers, TCP 443 between managers; classic causes: tunnel down (UDP 4500, NAT, MTU black hole), stuck at switchover (destination placement, vMotion reachability, EVC), cert trust after vCenter/NSX cert replacement.

## 8. SRM / vSphere Replication / VMware Live Recovery

- SRM logs `/var/log/vmware/srm/` (`vmware-dr-<n>.log`); bundles to `/var/log/vmware/Support/` (8.x: `/opt/vmware/dr/bin/dr-support-linux.sh`).
- vSphere Replication: VRMS logs `/opt/vmware/hms/logs/hms*.log`; VR server `hbrsrv*.log`; 9.0.x bundle `/opt/vmware/hms/bin/generatesupportbundle.sh` (KB 312657).
- 9.x naming: VMware Live Site Recovery, licensed under VMware Live Recovery. 9.1 adds vSAN for Recovery.
- **[verify]** Top failures: site pairing lost after vCenter/SRM cert replacement (Reconfigure in appliance UI, then Reconnect; lsdoctor for Lookup Service); placeholder datastore missing; SRA can't discover devices (SRA/array/SRM interop); RPO violations (bandwidth, change rate, target latency, TCP 31031/44046); full sync after Storage vMotion; replication "Not Active" (host can't reach VR server).
- **vSAN stretched cluster vs SRM:** stretched = synchronous, RPO 0, automatic HA restart, one vCenter — availability, not DR orchestration (no runbook, no test bubble, no protection from logical corruption or vCenter loss). Often combined.

## 9. Supervisor / VKS

- vCenter log `/var/log/vmware/wcp/wcpsvc.log`; correlate with EAM and vpxd logs by agency/VM ID (KB 323407).
- Control plane access: on vCenter `/usr/lib/vmware-wcp/decryptK8Pwd.py` gives the IP and root password; if etcd is down the floating IP isn't assigned — use the node's eth0 IP.
- **Never delete EAM agencies** unless Broadcom support directs it (KB 323407).
- Stuck "Configuring": `vc-identity` 503s (KB 423603). Upgrade stalls "vix error codes = (1, 0)": restart `vmtoolsd` on the control plane VM (KB 454213). `ReconcileFailed` from expired internal certs: KB 447147 (follow exactly / with support). kubectl failures: KB 377525. VKS log collection: KB 345464. Bootstrap `SSL_ERROR_SYSCALL` from NSX Edge TEP MTU mismatch: KB 429885. 9.1.0.100: Supervisor not visible after vCenter upgrade (KB 444446).
- **[verify]** Enablement checklist: DNS/NTP from management network (most common), 5 consecutive free management IPs, workload network routable, MTU, content library sync, storage policy, HA/DRS on, LB health. Supervisors left un-upgraded for about a year hit internal cert expiry.

## 10. Where authoritative information lives

| Need | Location |
|---|---|
| Cases, downloads, tokens, entitlements | support.broadcom.com |
| KBs | knowledge.broadcom.com/external/article/<id> · legacy IDs `?legacyId=<old>` |
| Product docs, release notes | techdocs.broadcom.com **[verify URL]** |
| Interoperability / upgrade paths | interopmatrix.broadcom.com |
| Hardware compatibility (formerly HCL) | compatibilityguide.broadcom.com **[verify URL]** |
| Configuration maximums | configmax.broadcom.com **[verify URL]** |
| Ports | ports.broadcom.com **[verify URL]** |
| Lifecycle dates | Broadcom product lifecycle page (login) |
| ESX builds | KB 316595 |
| VCF upgrade order | KB 390634 (9.0), KB 440630 (9.1) |
| Horizon / Workspace ONE | omnissa.com |
| Dell VxRail | dell.com/support (KBs, SolVe Online) — see vxrail.md |

Practitioner references: williamlam.com, virten.net (build history, sense decoder), yellow-bricks.com, davidring.ie (VCF on VxRail), esxi-patches.v-front.de.

## 11. Support bundles and opening a Broadcom case

**Severity** (KB 429027): **Sev 1** production down / total loss of service — customer contact available 24x7. **Sev 2** production badly degraded, still running. **Sev 3** non-critical, system operational. **Sev 4** questions/documentation.

**Before opening:** confirm the Site ID is linked to your portal account with an active contract; search the KB; check the interop matrix; collect logs **as close to the event as possible** (logs rotate quickly). Bundles over 5 GB go via Broadcom SFTP (KB 140731). Case FAQ: KB 144456; change severity: KB 140745.

**Bundles:**
| Product | How |
|---|---|
| ESXi | `vm-support`, or vSphere Client → Export System Logs (KB 326299) |
| vCenter | `vc-support`, VAMI, or Export System Logs |
| NSX | NSX Manager → System → Support Bundle |
| VCF / SDDC Manager | `/opt/vmware/sddc-support/sos --all-logs` (9.1: add `--vcf-mgmt-svcs-logs --zip`) |
| vSphere Replication | `/opt/vmware/hms/bin/generatesupportbundle.sh` (9.0.x) or VAMI |
| SRM | Appliance UI; lands in `/var/log/vmware/Support/` |
| HCX | Manager UI "Generate tech bundle" — both sites **[verify path]** |
| Supervisor / VKS | Workload Management → Export Logs; KB 345464 |
| VxRail | VxRail Manager log bundle + iDRAC TSR (vxrail.md) |

**Case package to assemble:** entitlement/Site ID and support tier; one-paragraph problem statement with exact error text; UTC timeline including last known-good and recent changes; scope and business impact (justifies severity); versions (VCF BOM, vCenter/ESX builds, NSX, VCF Operations, HCX/SRM, VxRail code level); bundles from every component in the failure path; what was tried and which KBs were ruled out; failed task/workflow ID for VCF.

**VCF on VxRail and other OEM-supported estates:** open with the OEM (Dell) first; Dell engages Broadcom as needed **[verify for BYO subscriptions]**.

## 12. Contested facts — present with caution

- 72-core minimum (section 2).
- HCX 4.11.0–4.11.2 end-of-support date (Broadcom vs Microsoft).
- VCF 9.1 GA day (announced 2026-05-05; ESX build 2026-05-12).
- 9.0 removed/deprecated list — third-party summaries conflict on vSAN OSA; check official release notes.
- 9.0 and 9.1 end-of-general-support dates (single third-party source).
- vSphere 8 Standard/Enterprise Plus end of sale and "vSphere Express" (single tracker).
- vCLS/DRS dependency in 9.0 (see vcenter.md section 10).
- Skylake-SP support in ESX 9 (KB 428874 update).
