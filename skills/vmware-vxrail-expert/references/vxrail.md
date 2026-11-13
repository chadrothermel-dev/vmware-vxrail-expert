# Dell VxRail reference

Facts current as of November 2026. **[verify]** marks items that came from practitioner knowledge or search summaries and were not confirmed against a Dell or Broadcom document. Dell KB numbers are the 9-digit `000xxxxxx` IDs at `dell.com/support/kbdoc/<id>`. Broadcom KBs are at `knowledge.broadcom.com/external/article/<id>`.

## Contents
1. What VxRail adds to vSphere/vSAN
2. VxRail Manager: access, services, logs, log bundle
3. Lifecycle management (LCM)
4. Operations: VMware habit vs VxRail-supported path
5. Hardware health, platform agent, iDRAC
6. Symptom → cause → fix table
7. Support model, Dell-only procedures, escalation
8. VCF on VxRail, VxRail 9.1, Dell Private Cloud
9. Version mapping table
10. KB index

---

## 1. What VxRail adds to vSphere/vSAN

VxRail = PowerEdge nodes + ESXi + vSAN + a Dell control plane: the **VxRail Manager** VM. VxRail Manager owns cluster bring-up, node add/remove, hardware inventory and health (through a host agent that talks to iDRAC), stored credentials (the **lockbox**), its own certificate trust store, and full-stack lifecycle.

**Why this matters for troubleshooting:** vCenter is not the only source of truth. VxRail Manager keeps its own state (Postgres DB, lockbox, trust store, cluster image/baseline). Anything changed behind its back — passwords, certificates, VIBs, firmware, hostnames, IPs, the vLCM image — drifts, and later breaks health monitoring, node expansion, or the next upgrade.

Rule of thumb: if VxRail created or tracks the object (system VMs, system vDS and port groups, management accounts, host membership, hostnames/IPs, certificates VxRail trusts, the cluster image, firmware), use a VxRail plugin workflow, Administration Guide procedure, or SolVe procedure. Workload VMs, storage policies, DRS rules, and custom port groups follow normal vSphere practice.

Architecture facts:
- **VxRail Manager OS:** SLES. On 7.0.2xx–7.0.320 lab inspection showed Docker Swarm services prefixed `func_`; on 8.0.x microservices run on Kubernetes (`kubectl get pods -A`). The exact cut-over release is not established — check both. Tomcat-based `vmware-marvin` service and `runjars` service. Postgres DB named `vxrail`.
- **Node discovery:** `loudmouth` service, IPv6 link-local (fe80::) + IPv6 multicast on the internal management VLAN, default **VLAN 3939**. ToR switches need **MLD snooping with an MLD querier** on that VLAN. Hosts with IPv6 disabled cannot be discovered (Broadcom KB 448710).
- **Host agent:** older nodes run `DellPTAgent`. On **14G and newer from VxRail 7.0.240 there is no DellPTAgent**; it was replaced by the VxRail platform service. Never tell a 7.0.240+/14G+ user to restart DellPTAgent.
- **Lockbox (7.0.010+):** stores the vCenter and ESXi management-account credentials (lockbox `SYSTEM`, credential names `management_account_vc` and `management_account_esxi__<ServiceTag>`) — Dell KB 000157662.
- **Accounts:** VxRail Manager `root` and `mystic` (SSH as `mystic`, then `su`); VxRail management account in vCenter; per-host ESXi management account; `administrator@<sso-domain>`. `mystic` locks after 3 failed logins.
- **vCenter plugin:** HTML5 plugin from 4.7.100; 8.0.210+ uses the vCenter **remote plug-in** model.
- **vCenter models:** VxRail-managed (internal) vCenter — VxRail upgrades it. Customer-managed (external) vCenter — customer upgrades it, **before** VxRail; external DNS only.
- **LCM ports** between VxRail Manager, vCenter and ESXi: 39090, 35252, 35353, 38008 (KB 000200768).
- **Hardware at 9.1.000:** 14G Cascade Lake only (Skylake excluded), 15G Intel/AMD, 16G Intel/AMD, 17G Intel (greenfield, vSAN ESA only).
- **vSAN ESA** is supported on 15G/16G/17G; 8.0.300 allowed mixing 15G and 16G nodes in an ESA cluster.

## 2. VxRail Manager: access, services, logs, log bundle

**First-response triage on VxRail Manager:**
1. SSH as `mystic`, then `su -` to root.
2. `systemctl status vmware-marvin` and `systemctl status runjars`.
3. Microservices: 8.0.x+ `kubectl get pods -A` (allow ~10 min after boot); older 7.0.x `docker service ls`.
4. Disk: `df -h`, `du -sh /var/log`, `du -a /var/log/ | sort -n -r | head -n 5`.
5. Read logs (table below), starting with `short.term.log`.

| Log (on VxRail Manager) | What it shows |
|---|---|
| `/var/log/microservice_log/short.term.log` | All microservices. Start here; grep by service, e.g. `microservice.do-storage` |
| `/var/log/microservice_log/dayone.log` | Day-1 bring-up |
| `/var/log/firstboot.log` | Microservice boot at initial configuration |
| `/var/log/vmware/marvin/tomcat/logs/marvin.log` | Node add / expansion |
| `/var/log/vmware/marvin/tomcat/logs/localhost_access_log.txt` | HTTP calls, mostly from the vCenter plugin |
| `/var/log/vmware/marvin/tomcat/logs/DellPTAgentResponse.log` | Host agent responses |
| `/var/log/vmware/loudmouth/loudmouth.log` | Node discovery |
| `/var/log/mystic/web.log` | LCM web-service operations |
| `/var/log/mystic/lcm-web.log` | LCM upgrade workflow |
| `/var/log/mystic/lcm-do.log` | Domain-object activity during LCM |
| `/var/log/mystic/lcm-migration.log` | New VxRail Manager / vCenter deployment during migration-style upgrades |
| `/var/log/mystic/connectors-cluster.log` | Disk replacement, health, shutdown, LED |
| `/var/log/mystic/connectors-esrs.log` | SRS / Secure Connect Gateway |
| `/var/log/mystic/connectors-eservice.log` | Support account, bundle downloads |
| `/var/log/mystic/dc.log` | Log-bundle (data collection) failures |
| `/var/log/messages` | OS, including duplicate IPv6 address detection |

Microservice names seen on Docker-era 7.0.x (prefix `func_`): `api-gateway`, `lockbox`, `lockservice`, `configservice`, `nats`, `wfservice`, `hsm`, `ms-day1-bringup`, `ms-day2`, `nano-service`, `node-service`, `storage-service`, `vlcm`, `vxdoctor-service`, `event-service`, and domain objects `do-cluster`, `do-host`, `do-network`, `do-storage`, `do-vm`, `do-vxrail-system`. Restart one on Swarm: `docker service scale func_<name>=0 && docker service scale func_<name>=1`. Kubernetes pod names on 8.0.x were not captured **[verify]**.

**Log bundle**
- UI: 7.x: cluster → Configure → VxRail → Troubleshooting → Create. 8.x: Configure → VxRail → **Support** → Troubleshooting.
- CLI when vCenter is down (KB 000190671): as root, `/mystic/generateLogBundle.py` with `-v` (VxRail Manager), `-c` (vCenter), `-e --nodes <ServiceTag>` (ESXi), `-i --nodes <ServiceTag>` (iDRAC), `-p --nodes <ServiceTag>` (platform). Flags combine. Output normally `/tmp/mystic/dc/`. On failure read `/var/log/mystic/dc.log`.
- From 7.0.520 / 8.0.300, VxRail Manager Python scripts run with `mcp_python`, not `python`.

**Database:** read-only `SELECT` is acceptable for diagnosis, e.g. `psql -U postgres vxrail -c "SELECT * FROM serviceability.event_code;"`. **Any `UPDATE`/`DELETE` is Dell-support-directed only**, after a VxRail Manager snapshot. Do not recommend clearing `system.operation_status` rows yourself.

**Do not touch:** `/data/store2/vlcm`, `/data/store2/hsm` (LCM staging).

## 3. Lifecycle management (LCM)

This is the single biggest difference from vSAN ReadyNodes.

- A VxRail release is one Dell-validated composite bundle: ESXi + vSAN + VxRail Manager + VxRail VIBs + BIOS/iDRAC/NIC/HBA/drive firmware (+ VxRail-managed vCenter). VxRail Manager applies it.
- **Never** patch ESXi with `esxcli software`, VUM/vLCM baselines, or Broadcom depots; never update firmware with iDRAC, DSU or OME; never upgrade a VxRail-managed vCenter on its own. Out-of-band changes cause pre-check/compliance failures and take the cluster out of Dell's validated state.
- **Customer-managed vCenter** is the one component the customer upgrades separately, and it goes **before** VxRail. Exception: **VxRail 7.0.320 — upgrade VxRail first** (driver conflict). Check the interop matrix, **Dell KB 000157682**.
- Factory-only releases cannot be upgrade targets: 8.0.010, 8.0.120, 8.0.230, 8.0.240, 7.0.210, 7.0.360, 7.0.380, 7.0.405, 7.0.420, 7.0.453, 7.0.460.
- Multi-hop upgrade paths live in the release notes / Simple Support Matrix (elabnavigator.dell.com) behind Dell login — tell the user to confirm the path there **[verify]**.

**VxVerify** (KB 000021527) — run before every upgrade and as a general health check:
- Download fresh every time (the internal minion expires after 21 days). Copy to VxRail Manager, extract, run `vxverify.sh` as root.
- VxVerify 3.x for VxRail 7.0.010+ (Python 3.6); VxVerify 4.x for 8.0.210+ (Python 3.11). Wrong pairing → "magic number" errors.
- Supply vCenter root + SSO admin to enable vCenter tests. Each warning row cites a Dell KB — follow that KB.
- Auto-fix options exist for iSM/iDRAC issues (KB 000205179).

**vLCM mode on VxRail**
- Introduced 7.0.240; optional; **cannot be disabled once enabled**. Default at deployment from 8.0.300. **Required before any 9.x upgrade.** Not supported on 13G.
- VxRail Manager drives the vLCM APIs. **Do not edit the cluster image in the vCenter Lifecycle Manager UI.** Do not follow generic Broadcom vLCM repair KBs unless a Dell procedure says so.
- Add drivers/agents (GPU, HBA, PowerFlex SDC, PPDM) as **vLCM-compatible offline depot ZIPs through VxRail "Add Components"**, not `esxcli software vib install` (standalone VIBs are removed at the next upgrade).
- Do not add solution depots (NSX, Veeam, Rubrik, NetApp, PPDM management) — blocked in Add Components from 8.0.320.
- Keep `lcmProperties.upgrade.advanced.mode.on=false` (advanced mode can strip third-party VIBs).
- A VUM/vLCM DB reset removes VxRail depots and needs Dell Engineering Escalation approval.
- Disable non-required Broadcom online depots (`dl.broadcom.com`) before a VxRail upgrade to avoid depot-sync timeouts; persistent `504 Gateway Time-out` → Dell.
- 2-node/ROBO with vLCM: the witness must also be single-image; manual witness upgrade is unsupported.
- Known enablement failures: base image NON_COMPLIANT on clusters born on 4.5.x (KB 000190895); `nsx-lcp-bundle` compliance (KB 000190928); external vCenter 8.0 U3 (KB 000225089).

**Upgrade preparation (KB 000200768)**
- Rolling reboot of every node a few days before (vSAN health clean → MM "Ensure accessibility" → reboot → exit MM → wait for resync).
- Remove vMotion blockers (mounted ISOs, host-pinned VMs).
- Have credentials ready: VxRail Manager mystic + root, vCenter administrator, vCenter root (if VxRail-managed), ESXi root, iDRAC. Avoid shell-breaking special characters in `administrator@vsphere.local`.
- Out-of-family upgrades with VxRail-managed vCenter need a free temporary IP on the same subnet.
- To 8.0.x: 14G nodes with TPM 1.2 fail pre-check (KB 000204703); decouple SmartFabric Services before 7.0.450+ (KB 000218470); upgrade SRS to Secure Connect Gateway 5.x before 7.0.350+ (KB 000196945).
- Upgrades can re-enable IGMP/MLD snooping on the vDS and break Microsoft NLB (KB 000196307).
- 8.0.330+: **VxRail Update Passphrase** (cluster → Configure → Updates → Settings) avoids sharing live credentials with Dell RPS.
- After upgrade: apply license keys (60-day eval otherwise), reconfigure file-based backup (`mcp_python ... vxm_backup_restore.py -c`, KB 000260789), re-add AD identity source after out-of-family upgrades.

**9.x licensing gate:** all nodes must hold VCF or VVF **subscription** before updating; perpetual licenses do not entitle 9.x; **downgrade is not possible** (KB 000310965). VCF Operations must be deployed to assign vSphere 9 licenses (KB 000318010).

**LCM failure signatures**
| Signature | Meaning / fix |
|---|---|
| Failed upgrade leaves two VxRail Manager VMs | Migration-style upgrade deployed a new VxM; old one lost its IP. **Dell support action** |
| "Error extracting upgrade bundle" | Bundle corrupt or space problem; re-download, check space **[verify]** |
| VIB dependency errors (e.g. `DEL_bootbank_dcism` requires esx-version) | Third-party or stale VIB conflict; identify the VIB, follow the Dell KB VxVerify cites |
| `MetadataDownloadError Could Not Download from Depot` | KB 000069309 |
| vCenter upgrade fails exporting data from source VM | KB 000372265 (VDDK cleanup, retry from plugin) |
| "invalid refresh token" in `lcm-web.log` (8.0.330+ internet download) | Re-login to the Dell support account (KB 000354303) |
| VCF: SDDC Manager cannot download VxRail bundles | Dell moved to OAuth; download manually; partner bundle metadata URL needs the Broadcom download token (Broadcom KB 404731) |

## 4. Operations: VMware habit vs VxRail-supported path

| Task | Generic VMware habit to avoid | VxRail-supported path | Who |
|---|---|---|---|
| Patch ESXi / firmware | `esxcli software`, vLCM baseline/image edits, iDRAC/DSU firmware | VxRail composite bundle via plugin (or SDDC Manager in VCF) | Customer |
| Upgrade VxRail-managed vCenter | VAMI / installer | Comes with the VxRail bundle | Customer |
| Add a driver/agent VIB | `esxcli software vib install` | vLCM offline depot ZIP via VxRail "Add Components" | Customer |
| Add a node | Add host in vCenter | VxRail plugin add-node (loudmouth discovery); check Dell node-addition compatibility first | Customer |
| Remove a node | Remove from inventory | VxRail plugin node-removal workflow **[verify]** | Customer |
| Replace a drive | Raw vSAN disk remove/add | VxRail Physical View hardware-replacement workflow **[verify]** | Customer (CRU) |
| Change management-account password | Change in vCenter/ESXi only | Administration Guide procedure so the lockbox stays in sync; repair reference KB 000157662 | Customer |
| VxRail Manager root/mystic password | — | KB 000200881; 8.0.380+ also via public API/Ansible/PowerShell | Customer |
| Lost VxRail Manager root | — | Boot-menu reset (KB 000064579) | Customer |
| ESXi root lost/locked | Host profile freely | KB 000287775 (careful — wrong use removes management accounts); lockout KB 000071365. Lost **witness** root → Dell redeploys witness | Customer / Dell |
| Replace/renew vCenter certificate | Replace and walk away | Then import the new cert into the VxRail Manager trust store (`cert_util.py`) and `service runjars restart` (KB 000201187) | Customer |
| VxRail Manager certificate | — | Plugin (KB 000020625); if expired and plugin won't load, `cert_util.py -r` first | Customer |
| Expired CAs in VxRail trust store | — | Delete in plugin "All Trust Store Certificates", re-import (KB 000216783); snapshot VxM first | Customer |
| Shut down cluster | Manually MM each host | VxRail Shutdown Cluster workflow with pre-checks (KB 000228081; 2-node KB 000190707) | Customer |
| Rename ESXi host | Broadcom vSAN rename KB | Broadcom KB 327019 itself says engage Dell VxRail support | Dell-assisted |
| Change VLAN / IPs | Edit vmk / port group | Administration Guide sections; other re-IP procedures in SolVe | Mixed |
| Rename datacenter/cluster/vDS/port groups | Rename in vCenter | Check the Administration Guide for your release first **[verify]** | Check docs |
| Reimage / factory reset node | Install ESXi from Dell ISO | RASR or Node Image Management — SolVe restricted procedure | **Dell/partner** |
| Back up VxRail Manager | Image-level VM backup only | `/mystic/vxm_backup_restore/vxm_backup_restore.py` (`-b`, `-l`, `-c`) via `mcp_python` on 7.0.520+/8.0.300+; run `-h` for restore syntax | Customer (restore usually with Dell) |
| Recover/redeploy VxRail Manager | Deploy OVA | Recovery script per KB 000189568 | Dell-led |
| VUM/vLCM DB reset | Broadcom reset KB | Needs Dell Engineering Escalation approval | **Dell** |

## 5. Hardware health, platform agent, iDRAC

- Physical View health comes from the host agent talking to iDRAC. When Physical View is blank or says "server type is not supported": cold-reset iDRAC and restart the host agent. Dell calls this a **temporary fix**; an upgrade is often the permanent fix.
  - Old PTAgent nodes: `/scratch/dell/DellPTAgent/bin/ipmitool_static mc reset cold` (tool path varies by release: also `/opt/dell/DellPTAgent/tools/` or `/opt/vxrail/tools/`), then `/etc/init.d/DellPTAgent restart` (KB 000023663).
  - Platform service, older releases: `/etc/init.d/vxrail-pservice restart`. **8.0.300+:** `esxcli daemon control restart -s platformsvc` (KB 000195061).
- Node not responding to esxcli → Physical View missing: KB 000224344. Node missing on Hosts tab: KB 000204722. Blank Physical View on vCenter 8.x: Broadcom KB 394580.
- Dial-home event codes look like `MYSTIC######` / `VXR######` (e.g. MYSTIC010011 = host power supply, KB 000040077). Full catalog: DB table `serviceability.event_code`.
- Health monitoring can be suppressed; re-enable in the plugin (Health Monitoring → Enable).
- iDRAC tools (standard iDRAC practice, not from a VxRail document **[verify]**): `racadm getsel`, `racadm lclog view`, `racadm getsysinfo`, `racadm jobqueue view`, `racadm racreset`, TSR via iDRAC → Maintenance → SupportAssist. Clearing the iDRAC job queue during LCM should be done with Dell guidance.
- **vSAN/Skyline "controller firmware not on HCL" warnings on VxRail:** Dell validates firmware per VxRail release, and the VxRail support matrix governs. Before acting, confirm the installed firmware matches the VxRail release manifest; do not "fix" it by flashing firmware out of band **[verify]**.

## 6. Symptom → cause → fix

| Symptom | Likely cause | Fix |
|---|---|---|
| Plugin: "The provided vCenter credentials are not valid" | vCenter cert/CA rotated and VxM trust store stale; or management-account password drifted from lockbox | Import vCenter cert into VxM + `service runjars restart` (KB 000201187); verify lockbox creds (KB 000157662) |
| "Failed to find a matching root CA certificate/CRL set that could verify vCenter certificate" | Incomplete chain in vCenter trusted roots | Put the full chain in place, re-import (KB 000196953). If VxVerify `vc_trust` still fails → Dell |
| VxRail plugin missing after VxM cert update | — | Broadcom KB 442677 |
| Cannot log in to VxRail-managed vCenter, expired certs | STS/machine certs expired | KB 000082108; vCert, then re-import to VxM |
| `short.term.log`: "Failed to login by session cookie!" + SSL hostname mismatch | VxM ↔ vCenter cert/hostname mismatch | Fix cert/hostname, `cert_util.py` |
| Physical View blank / "server type is not supported" | Host agent ↔ iDRAC communication | Section 5 |
| New node not discovered | MLD snooping without querier, VLAN 3939 not trunked, IPv6 disabled/filtered | Fix ToR; on VxM `service vmware-loudmouth restart`, check `/usr/lib/vmware-loudmouth/bin/loudmouthc query` (one fe80 address per host) — KB 000214834, Broadcom KB 448710 |
| Expansion fails: "No en_US resource bundle for ExpansionValidation with key <host>" in marvin.log | Misleading message masking a disk/disk-group validation failure | Check the new node's disks |
| `mystic` locked | 3 failed logins | Reset from root console (KB 000200881) |
| VxM file backup stopped after upgrade | Cron still calls `python` | `mcp_python /mystic/vxm_backup_restore/vxm_backup_restore.py -c` (KB 000260789) |
| Internet LCM download fails (8.0.330+) | Invalid refresh token | Re-login support account (KB 000354303) |
| Cluster shutdown fails to power off hosts | Cluster from 4.7 with changed hostnames/IPs | KB 000190965 |
| Cluster shutdown "pre-checks failed" | — | KB 000054970 |
| Microsoft NLB breaks after upgrade | vDS multicast snooping re-enabled | KB 000196307 |
| Hosts on 60-day eval after 7 → 8 | No vSphere 8 keys applied | Apply keys from the Broadcom portal |
| RASR "Script 15_setup_node.sh execution error" | Missing `vxadmin` account or network attached during RASR | KB 000050335 (Dell-led) |
| VxRail Manager `/` or `/var/log` full | Log growth | Find with `du`; get the Dell cleanup KB before deleting anything **[verify]** |

## 7. Support model, Dell-only procedures, escalation

- **Dell is the first call for VxRail systems** — hardware and VxRail software, and in practice the VMware stack running on VxRail ("Dell-engineered and Dell-supported"). Exact routing for bring-your-own Broadcom subscriptions was not confirmed **[verify]**.
- History: Dell ended its VMware distribution agreement in early 2024 after the Broadcom acquisition; Dell later signed a new resale agreement. Customers apply their own license keys from the Broadcom portal. Dell's strategic VCF path is now **Dell Private Cloud**; Dell says it continues to support VxRail; no end-of-sale announcement was found.
- **Dell RPS** (Remote Proactive Services) runs upgrades with customers. SR type "Operating Environment Upgrade" schedules RPS; use "Product Problem" for trouble with a self-run upgrade.
- **Dell-only / Dell-directed:** RASR and node reset/reimage; VxRail Manager recovery/redeploy; VxRail DB edits; VUM/vLCM DB reset; witness redeploy; ESXi hostname change; VxVerify `vc_trust` failures with no usable root cert; cleanup after a failed migration-style upgrade; anything marked restricted in SolVe.
- **SolVe Online** holds the official step-by-step procedures. When a procedure lives in SolVe, tell the user to pull it from SolVe rather than improvising steps.
- **Support end dates:** VxRail 4.5/4.7 ended 2022-09-30. VxRail 7.x ended with vSphere 7 on 2025-10-02 (7.0.550 is the last 7.x). 13G hardware ended standard support 2023-05-31; 7.0.411 is the last recommended release for 13G.

Collect before opening a Dell SR: VxRail Manager log bundle (VxM + vCenter + ESXi + iDRAC + platform), latest VxVerify output, iDRAC TSR for affected nodes, VxRail and vCenter versions, the exact error text and time (with timezone), and what changed recently.

## 8. VCF on VxRail, VxRail 9.1, Dell Private Cloud

- **VxRail 9.1.000 with VCF 9.1 went GA 2026-06-16; 9.1.100 (ESXi 9.1.1.0, VCF 9.1.1) followed around 2026-10-29.** No VxRail 9.0.x release was found — Dell's matrix goes from 8.0.390 to 9.1.000 **[verify]**.
- VxRail Manager still exists in 9.1 (new version scheme, VxRail Manager 01.01.00.00), and VxRail LCM remains integrated.
- 9.1 upgrade prerequisites: VCF 5.2.2+ and VxRail 8.0.361+; vLCM mode; VCF/VVF subscription; VCF Operations. In-place upgrade, no repave. Customer-managed vCenter must be 9.1 first.
- At 9.1.000, **stretched cluster, 2-node, dynamic-node and satellite-node** deployments had no supported upgrade path. Whether 9.1.100 added one was not confirmed — check the 9.1.100 release notes **[verify]**. Until then, keep those topologies on 8.0.3xx.
- 9.1.000 limits: standard vSAN clusters only, IPv4 only.
- In VCF 9.1, VxRail and Dell vSAN Ready Nodes can coexist in one VCF instance; each workload domain must be homogeneous; the management domain must be VxRail if VxRail is present; third-party ReadyNodes are not supported. VxRail clusters keep VxRail LCM.
- VCF on VxRail: SDDC Manager orchestrates; the VxRail plugin Updates tab is disabled. VUM → vLCM transition per Broadcom procedure (KB 000357056), then Dell `enable_vlcm.sh` on each VxRail Manager; no mixing VUM and vLCM clusters in one workload domain. Prep guide: KB 000200812. 5.2.x → 9.1 reference: KB 000478885 **[verify]**.
- 8.x continues: VCF 5.2.3 on VxRail 8.0.380 (May 2026); 8.0.390 (July 2026, ESXi 8.0 U3j).
- **Dell Private Cloud** 1.4 on Dell Automation Platform 2.0 (2026-06-02) supports VCF 9.1 on disaggregated PowerEdge + external storage. It is not VxRail.

## 9. Version mapping table

Release numbers map to vSphere majors; the middle digit encodes the update level (8.0.0xx = GA, 8.0.1xx = U1, 8.0.2xx = U2, 8.0.3xx = U3). Source: Dell KB 000157682 (2026-11-02).

| VxRail | ESXi (build) | Customer-managed vCenter min | Notes |
|---|---|---|---|
| 9.1.100 | 9.1.1.0 (25714478) | 9.1.0.0 | VCF 9.1.1 |
| 9.1.000 | 9.1.0.0 (25370933) | 9.1.0.0 | GA 2026-06-16 |
| 8.0.390 | 8.0 U3j (25429389) | 8.0 U3 or 9.1 | July 2026 |
| 8.0.380 | 8.0 U3i (25205845) | 8.0 U3 or 9.1 | VCF 5.2.3 |
| 8.0.370 | 8.0 U3h (25067014) | 8.0 U3 or 9.1 | |
| 8.0.360 / 8.0.361 | 8.0 U3g (24859861) | 8.0 U3 or 9.1 | 8.0.361 = minimum for 9.1 upgrade |
| 8.0.330 / 8.0.331 | 8.0 U3e (24674464) | 8.0 U3 or 9.1 | Update Passphrase |
| 8.0.320 – 8.0.322 | 8.0 U3c / U3d | 8.0 U3 or 9.1 | |
| 8.0.300 – 8.0.311 | 8.0 U3 / U3b | 8.0 U3 or 9.1 | vLCM default at deploy; `mcp_python` |
| 8.0.200 – 8.0.240 | 8.0 U2 – U2d | 8.0 U2 | 8.0.210+ remote plugin, VxVerify 4.x; 8.0.230/240 factory-only |
| 8.0.100 – 8.0.120 | 8.0 U1a / U1c | 8.0 U1 | 8.0.120 factory-only |
| 8.0.000 – 8.0.020 | 8.0 GA / 8.0b | 8.0 GA | 8.0.010 factory-only |
| 7.0.5xx | 7.0 U3q – U3v | 7.0 U3 or 8.0 GA | 7.0.550 last 7.x; 7.0.520+ `mcp_python` |
| 7.0.4xx | 7.0 U3i – U3p | 7.0 U3 or 8.0 GA | 7.0.411 last for 13G |
| 7.0.3xx | 7.0 U3 – U3e | 7.0 U3 or 8.0 GA | 7.0.320: VxRail before vCenter |
| 7.0.2xx | 7.0 U2a – U2c | 7.0 U2 or 8.0 GA | 7.0.240 adds vLCM mode |
| 7.0.0xx – 7.0.1xx | 7.0 GA – U1d | 7.0 GA/U1 or 8.0 GA | 7.0.010 adds lockbox |
| 4.7.x / 4.5.x | vSphere 6.7 / 6.5 | — | Support ended 2022-09-30 |

## 10. KB index (Dell unless noted)

000157682 vCenter interop matrix · 000189279 plugin matrix · 000021527 VxVerify · 000205179 VxVerify iSM/iDRAC fix · 000196953 vc_trust · 000200768 upgrade customer prep · 000020129 upgrade info · 000197544 RPS prep guides · 000190671 log bundle · 000157662 management account / lockbox · 000200881 service VM passwords · 000064579 VxM root reset · 000287775 ESXi root via host profile · 000071365 ESXi root lockout · 000158231 password rules · 000020625 VxM certificate · 000216783 trust store expiring · 000201187 vCenter creds not valid · 000082108 vCenter expired certs · 000214449 stale certs after 4.x → 7 · 000224993 enable vLCM · 000278934 vLCM best practices · 000190895 / 000190928 / 000225089 vLCM enablement failures · 000357056 VCF VUM → vLCM · 000496253 register third-party components (VCF) · 000023663 iDRAC reset / PTAgent · 000195061 server type not supported · 000224344 / 000204722 Physical View / host missing · 000214834 host discovery · 000228081 cluster shutdown · 000190707 2-node shutdown · 000190965 / 000054970 shutdown failures · 000021829 node MM reboot · 000260789 file-based backup · 000189568 VxM recovery · 000050335 RASR failure · 000215869 13G last release · 000310965 9.x licensing · 000318010 VCF Operations licensing · 000354303 invalid refresh token · 000069309 depot metadata error · 000372265 vCenter upgrade export failure · 000204703 TPM 1.2 · 000218470 SmartFabric decouple · 000196945 Secure Connect Gateway · 000196307 vDS multicast · 000200812 VCF on VxRail upgrade prep. Broadcom: 404731, 323978, 448710, 394580, 389212, 442677, 327019, 390098.
