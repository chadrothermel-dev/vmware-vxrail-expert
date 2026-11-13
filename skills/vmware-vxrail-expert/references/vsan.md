# vSAN reference: architecture, states, failures, logs, safe operations

Covers vSAN 5.5/6.x briefly, 7.0, 8.0 (OSA and ESA) and vSAN in VCF 9.x. Facts current as of November 2026. **[OSA]** = disk groups; **[ESA]** = storage pool; **[All]** = both. **[verify]** = practitioner knowledge not confirmed against a current Broadcom document — confirm with `--help` on the host or in the KB.

## Contents
1. Architecture you need to reason about failures
2. Object and component states, repair timer, resync
3. Disk failures and capacity
4. Network partitions and stretched clusters
5. Log files
6. Command toolkit
7. Health checks
8. Maintenance mode, cluster shutdown, power-outage recovery
9. Performance
10. Upgrades, on-disk format, licensing
11. Safe vs dangerous operations
12. VxRail notes
13. KB index

---

## 1. Architecture

- **[OSA] Disk group** = 1 cache device + 1–7 capacity devices. All I/O goes through the cache device, so **losing the cache device takes the whole disk group offline**. With **dedup+compression on, losing any device in the group takes the whole group** (KB 326859). First question on any OSA disk alarm: `esxcli vsan storage list | grep -i dedup`.
- **[ESA]** No disk groups, no cache tier. Every NVMe device is independent; a device failure affects only that device. Log-structured file system, compression and encryption at the top of the stack, RAID-5/6 at RAID-1 performance, adaptive RAID-5 (2+1 on 3–5 hosts, 4+1 on 6+). Requires ESA-certified ReadyNodes (non-NVMe/SAS devices are incompatible — KB 435891).
- **Layers** **[verify]**: CMMDS (cluster membership/directory; master/backup/agent), CLOM (`clomd`, placement and repair decisions, owns the repair timer), DOM (client/owner/component manager), LSOM (per-host local store; ESA uses LSOM2 with zDOM above DOM), PLOG (OSA cache log), RDT (host-to-host transport).
- **Objects** (VM home, VMDK, swap, snapshot delta, stats DB, iSCSI, file share) are made of components plus witnesses. An object is accessible only with **> 50% of votes and at least one full data copy** **[verify]**. FTT=1 RAID-1 needs 3 fault domains; RAID-5 (OSA 3+1) needs 4; RAID-6 (4+2) needs 6.
- **Unicast** has been the mode since 6.6 (agent port 12321). From 6.5d, vCenter pushes the member list to hosts — a stale or older vCenter can cause partitions.
- **Encryption:** data-at-rest and data-in-transit are separate settings. DARE keys stay in host memory until reboot; if the KMS is unreachable at reboot, disk groups stay offline. 7.0 U3+ supports TPM-backed key persistence. KMS port 5696.
- **9.0+:** ESA global deduplication (post-process, limited availability at launch); "vSAN storage clusters" (disaggregated storage-only, formerly vSAN Max); stretched compute clusters can mount stretched storage clusters.
- **On-disk format** (KB 327034): 6.7 U3 = 10 · 7.0 = 11 · 7.0 U1 = 13 · 7.0 U2 = 14 · 7.0 U3 = 15 · 8.0 = 17 · 8.0 U1 = 18 · 8.0 U2 = 19 · 8.0 U3 = 20 · 9.0 = 21 · 9.0 P01 = 22 · 9.1 = 23. Format 1.0 is no longer recognised from 7.0 U1.

## 2. Object and component states, repair timer, resync

**Object health states** (KB 326929 [2108319]) — also the categories in `esxcli vsan debug object health summary get`:

| State | Meaning | Action |
|---|---|---|
| Healthy | Compliant | None |
| Data move | Rebuild from maintenance/rebalance; compliant | Watch resync |
| **Inaccessible** | More failures than the policy tolerates; VMs using it cannot run | Fix root cause urgently. **Delete nothing** |
| Reduced availability – active rebuild | Failure tolerated, rebuild running | Wait |
| **Reduced availability with no rebuild** | Failure tolerated but vSAN is NOT re-protecting (no resources, or earlier attempt failed) | Check Limits / capacity; resolve quickly |
| Reduced availability with no rebuild – delay timer | Waiting for the 60-minute repair timer | Wait, or repair now if the entity won't return |
| Reduced availability with paused rebuild / policy pending failed | Not enough resources | Add capacity |
| Non-availability related incompliance / reconfig | Not compliant but still meets FTT | Low urgency (KB 401291, 325171) |
| remoteAccessible | Remote datastore view (HCI Mesh client) | Check the server cluster |

"Reduced availability with no rebuild" on every object right after a host loss in a 3-node FTT=1 (or 6-node RAID-6) cluster is **expected** — there is no spare fault domain to rebuild into.

**Component states** **[verify]**: ACTIVE (healthy) · ABSENT (may come back — waits for the repair timer) · DEGRADED (permanent error reported — rebuild starts immediately) · STALE / ACTIVE_STALE (reachable but missed writes; must resync before it counts) · RECONFIGURING.

**Repair timer** (KB 445909, 327031): `/VSAN/ClomRepairDelay`, default **60 minutes**. It applies to ABSENT (host down, network loss, maintenance). A detected permanent device failure rebuilds immediately.
- View: `esxcli system settings advanced list -o /VSAN/ClomRepairDelay`
- Keep it identical on every host. Raise it before long planned maintenance to avoid a rebuild storm.
- "Repair objects immediately" is safe for data but starts a large rebuild that competes with VM I/O and consumes space — wrong choice if the host is about to come back.

**Durability components:** 7.0 U1 delta components protect writes during planned maintenance; 7.0 U2 extends this to unplanned failures — new writes go to a durability component and only the delta resyncs when the original returns. `/VSAN/DeltaComponent` must match on all hosts or maintenance mode fails (KB 440130).

**Resync:** `esxcli vsan debug resync summary get`, `esxcli vsan debug resync list`, `esxcli vsan resync throttle get|set --level=<n>` (0 = no throttle — reset it after use). Heavy resync can degrade VM I/O (KB 327006).

## 3. Disk failures and capacity

**Detection paths:** hard I/O errors (permanent error / PDL), **Dying/Degraded Device Handling (DDH)** — sustained write latency, maximum log congestion, SMART impending failure — and NVMe controller failure.

**Log signatures** (KB 326859, OSA; fragments):
| Log | Signature | Meaning |
|---|---|---|
| vmkernel.log | `failed H:0x0 D:0x2 P:0x0 Valid sense data: 0x3 0x11 0x0` | Medium error (bad block). In the data region → vSAN support case |
| vmkernel.log | `... Valid sense data: 0x4 0x0 0x0` | Hardware error |
| vmkernel.log | `failed H:0x5 D:0x0 P:0x0`; `failed H:0xc ... Invalid sense data: 0x0 0x0 0x0` | Aborts/retries — controller, driver/firmware, backplane, cabling more often than media. **Check the driver/firmware pair before replacing drives** |
| vmkernel.log | `PDL error (0x5/0x25/0x0)`; `Valid sense data: 0x5 0x25 0x0. Act:EVAL` | Permanent device loss |
| vmkernel.log | `Virtual SAN device <uuid> is under permanent error.` | vSAN marked the device failed |
| vmkernel.log | `state: 9 CONTROLLER_STATE_FAILED` | NVMe controller failed |
| vmkernel.log | `LSOM: LSOMThrowCongestionVOB: Throttled: vSAN node <host> maximum LogCong in <uuid> reached.` | [OSA] Log congestion (KB 418349) |
| vmkernel.log | `LSOM: LSOMEventNotify: Throttled: Waiting for open component count to drop to zero on disk` | [OSA] Evacuation stuck |
| vobd.log | `[vob.vsan.lsom.diskerror] vSAN device <id> is under permanent error.` | Permanent error |
| vobd.log | `[esx.problem.vob.vsan.lsom.devicerepair] Device <id> is in offline state and is getting repaired` | Device offline |
| vobd.log | `[vob.vsan.lsom.devicewithhighlatency] ... has high latency. It will be evacuated and unmounted` | DDH latency action |
| vsandevicemonitord.log | `Device naa.<id> state is DISK_UNDER_PERM_ERROR` | Permanent I/O error |
| vsandevicemonitord.log | `WARNING - WRITE Average Latency on VSAN device <naa> has exceeded threshold value` | DDH latency trigger |
| vsandevicemonitord.log | `WARNING - Maximum log congestion on VSAN device <naa>` | DDH log-congestion trigger |
| vsandevicemonitord.log | `WARNING - SMART health status for disk naa.<id> is IMPENDING FAILURE.` | SMART predictive failure |
| vsanmgmt.log | `DG_UNDER_LOG_CONGESTION`, `LSOM telemetry status: EVACUATING,LOG_CONGESTION` | Management daemon view |

Quick filter: `egrep -i "perm|offline|unhealthy" /var/log/vobd.log`. SMART: `localcli storage core device smart get -d naa.<id>`. Host health: `localcli vsan health cluster get -t 'Operation health'`.

**DDH behaviour** (KB 326878): unhealthy disks get no new placements; tolerable components are marked absent and repaired after the timer; immediate evacuation only where needed for availability. Health text: "Impending permanent disk failure, data is being evacuated" (yellow) / "...evacuation failed due to insufficient resources" or "...inaccessible objects" (red). Log congestion → remove and re-add the disk group after evacuation. Excessive latency → replace the disk. From 9.0, DDH also monitors OSA cache devices. After a latency unmount, a remount keeps the same vSAN UUID.

**[OSA] Congestion** (KB 326479 [2150260]) is flow control on a 0–255 scale applied as latency at ingress: SSD (write buffer full), Log (cache log space), Mem (heap), Slab (in-flight ops), Comp (component table), IOPS (limit hit). Read per disk group:
```
for ssd in $(localcli vsan storage list | grep "Group UUID" | awk '{print $5}' | sort -u); do
  echo $ssd; vsish -e get /vmkModules/lsom/disks/$ssd/info | grep Congestion; done
```
A worn NVMe cache device shows high congestion, evacuation timeouts and whole-group failure (KB 447568).

**[OSA] Stuck log-congestion evacuation** (KB 418349), in order: (1) MM with Ensure Accessibility; (2) if it stalls, pre-check (KB 394849); (3) **only if the pre-check shows no inaccessible objects**, unmount — single capacity disk `localcli vsan storage diskgroup unmount -d naa.<id>`, whole group `-s naa.<cache id>`; (4) if you get `Failed to get VsanInfo operation lock for diskOpLock`, run `/etc/init.d/vsanmgmtd restart` (management daemon only — data path unaffected) and retry; (5) replace hardware.

**Replacement:**
- Prerequisites: object health clean of inaccessible objects; resync finished. **Never remove or replace a disk while resync is running.**
- [OSA] KBs: 327048 (requirements), 327008 (identify failed disk with dedup), 388453 (slot location).
- [ESA] (KB 419068): controller must be passthrough + hot-plug; Disk Management → Remove Disk with full data migration → pre-check → Remove (CLI `esxcli vsan storagepool remove -d <device>`), insert new, rescan, claim.
- **On VxRail use the VxRail Physical View hardware-replacement workflow** (see section 12).

**Capacity** (KB 326889):
- 7.0 U1+ replaces the old "keep 25–30% slack" rule with **Operations Reserve** (transient work) + **Host Rebuild Reserve** (N+1; ~25% on 4 nodes, 8% on 12, 3% on 32).
- Reactive rebalance starts when any disk reaches 80%.
- Above ~99% full, VMs stun with a pending question and writes fail.
- **Recovery when full:** confirm every capacity device is present first. Then free space without writing: power off VMs gracefully (answer pending questions with Cancel; powering off deletes swap objects), Storage vMotion VMs elsewhere, or delete unneeded VMs. Freed space may not appear in the UI immediately. Do not change the storage policy of many VMs while full — that needs space.

## 4. Network partitions and stretched clusters

Confirm a partition from the host CLI, not the UI — the UI can be green while the CLI shows a partition (KB 444984).

1. `esxcli vsan cluster get` on every host: Sub-Cluster Member Count vs expected host count; compare Sub-Cluster UUID and master UUID (two masters = two partitions). Member count 1 = isolated. A rising membership revision = flapping.
2. `esxcli vsan cluster unicastagent list` on every host: must list every **other** node, **never the host itself**.
3. `esxcli vsan network list` (which vmk carries vSAN), then `vmkping -I vmkX -d -s 8972 <peer vSAN IP>` (9000 MTU; `-s 1472` for 1500). Partition from MTU mismatch: KB 391883.
4. pNIC counters: `esxcli network nic stats get -n vmnicX` (errors, drops, CRC).
5. `esxcli vsan health cluster get -t "vSAN cluster partition"`.
6. If lists are complete and vmkping passes, suspect certificate thumbprints or a stale member list pushed by vCenter (restoring vCenter from backup can do this — KB 432331).

**Fixing an incomplete unicast list** (KB 317830 — the KB tells unfamiliar users to open a support case first):
1. On ALL hosts: `esxcfg-advcfg -s 1 /VSAN/IgnoreClusterMemberListUpdates` (stops vCenter overwriting your edits).
2. Gather per host: UUID (`cmmds-tool whoami`), vSAN vmk IP, cert thumbprint (`openssl x509 -in /etc/vmware/ssl/rui.crt -fingerprint -sha1 -noout`).
3. Add missing entries: `esxcli vsan cluster unicastagent add -t node -u <UUID> -U true -a <vSAN IP> -p 12321 -T <thumbprint>`.
4. Verify on all hosts, then **set the option back to 0**.
- **9.1+ enforces SHA-256 thumbprints**: hosts left with `IgnoreClusterMemberListUpdates=1` keep SHA-1 thumbprints and can fully partition (0 TB capacity) after upgrade.
- Empty list + stale CMMDS on one host: `esxcli vsan cluster join -u <sub-cluster UUID from a healthy peer>` (KB 444645).

**Stretched cluster failure matrix** (KB 394978, site mirroring):
| Failure | Result |
|---|---|
| Inter-site link down | Preferred site binds with witness; secondary-site objects inaccessible; HA restarts those VMs in the preferred site |
| One data site down | Surviving site + witness keep objects accessible; HA restarts VMs |
| Witness down | VMs unaffected |
| Data site + witness simultaneously | Quorum lost — both sites inaccessible |
| Data site, then witness minutes later | Before 7.0 U3 everything inaccessible; 7.0 U3+ surviving site stays up (Adaptive Quorum Control) |
| Extra host loss in surviving site | Survives only if secondary FTT is RAID-1/5/6, not None |

- Avoid `locality=none` policies in stretched clusters (replicas straddle sites → maintenance failures, inaccessible objects).
- Recovering after site + witness loss is support-led and best effort through 8.0 U3; VCF 9.0 adds site maintenance mode and "manual site takeover" (limited availability).
- Witness isolation: member count 1 STANDALONE, or 0 in Discovery.

## 5. Log files

Host triage order: **vobd.log** (what changed, when) → **vmkernel.log** at that timestamp (sense/LSOM/NVMe) → **vsandevicemonitord.log** (did DDH act) → **clomd.log** (did CLOM place a rebuild or fail to) → **vsanmgmt.log** (is a disk operation holding a lock).

| Log | Content |
|---|---|
| `vmkernel.log` | Device I/O, `LSOM:` lines, membership, heartbeats |
| `vobd.log` | Disk health, PDL, maintenance transitions |
| `vmkwarning.log` | "performance has deteriorated" |
| `vsandevicemonitord.log` | DDH latency, log congestion, SMART, permanent error |
| `clomd.log`, `clomd-whatif.log` | Placement/repair decisions; what-if simulations |
| `vsanmgmt.log` | Management daemon: disk-group state, health flags, File Services comms |
| `vsansystem.log`, `osfsd.log`, `epd.log`, `vsanvpd.log` | Config pushes, namespace ops, entry persistence, VASA provider **[verify]** |
| `/var/log/vsantraces/` | Binary traces — decoding needs Broadcom support. Ramdisk can fill ("The ramdisk 'vsantraces' is full"); relocate with `esxcli vsan trace set -p <path>` (KB 326990) |
| vCenter `/var/log/vmware/vsan-health/vmware-vsan-health-service.log` | vSAN health service |
| File Services: host `vsanfs.mgmt.log`, `vdfsd-server.log`; vCenter `eam.log` | |

## 6. Command toolkit

From the ESXCLI 9.0 reference (mostly valid on 7.x/8.x). `localcli vsan ...` mirrors these when hostd is unhealthy.

| Area | Command |
|---|---|
| Cluster | `esxcli vsan cluster get` · `esxcli vsan cluster unicastagent list` · `esxcli vsan cluster preferredfaultdomain get` |
| Network | `esxcli vsan network list` · `esxcli vsan network security get` (in-transit encryption) |
| Storage [OSA] | `esxcli vsan storage list` · `esxcli vsan storage diskgroup mount|unmount` |
| Storage [ESA] | `esxcli vsan storagepool list|mount|unmount|remove` |
| Objects | `esxcli vsan debug object health summary get` · `esxcli vsan debug object list --health <state>` · `esxcli vsan debug object list --vm-name <name>` |
| Disks | `esxcli vsan debug disk overview` · `esxcli vsan debug disk list` |
| Resync | `esxcli vsan debug resync summary get` · `esxcli vsan resync throttle get` |
| Limits / controllers | `esxcli vsan debug limit get` · `esxcli vsan debug controller list` (driver, firmware, queue depth) |
| What-if | `esxcli vsan debug evacuation precheck -e <entity>` (accurate only when all hosts share version and format) |
| Health | `esxcli vsan health cluster list` · `esxcli vsan health cluster get -t "<test>"` |
| Maintenance | `esxcli system maintenanceMode set -e true -m evacuateAllData|noAction` (`ensureObjectAccessibility` **[verify]**) · `esxcli vsan maintenancemode cancel` |
| Encryption | `esxcli vsan encryption info get` · `esxcli vsan encryption kms list` |
| Identity | `cmmds-tool whoami` |
| Perf | `esxcli vsan perf get` · `vsantop` (6.7 U3+) **[verify]** |

- **RVC** still runs on vCenter (`rvc localhost`) but is deprecated and "will not be available in the next major release" (KB 326527): `vsan.cluster_info .`, `vsan.resync_dashboard .`, `vsan.disks_stats .`, `vsan.vm_object_info .`, `vsan.check_state -re .` (reload orphaned/invalid VMs once objects are accessible).
- Host-side commands reproduce most of what vSAN Health and RVC showed, so vSAN can be fully diagnosed with vCenter down.
- `vdq -q`, `vdq -iH`, `cmmds-tool find`, `objtool`, PowerCLI vSAN cmdlets — widely used but not re-verified **[verify]**.

## 7. Health checks

The in-vCenter page is labelled "Skyline Health" or "vSAN Health" depending on build; the test names from `esxcli vsan health cluster list -w` are the stable identifiers.

| Check | KB | Failure means |
|---|---|---|
| Data – vSAN object health | 326929 [2108319] | See section 2 |
| Physical disk – Operation health | 326969 [2108691] | Disk failed or DDH flagged |
| Network – cluster partition | 317843 / 318839 | Hosts in different partitions |
| Network – unicast agent not configured | 326871 | Missing entries |
| Network – basic unicast connectivity | 441929 | vmknic unreachable |
| Stretched – witness host not found | 326961 | Witness missing/isolated |
| Capacity – storage space | 326889 | Section 3 thresholds |
| Cluster – disk format version | 315550 | Mixed formats |
| Resync throttling | 326963 | Manual throttle left set |
| Encryption – KMS | 326514, 326769 | KMS unreachable / key mismatch |
| Physical disk – memory pool (heaps) | 416696 | LSOM heap pressure |
| Build recommendation | 326877 | Deprecated in 9.x; moved to vLCM |

VCF 9.0: Skyline Advisor content moved into **VCF Operations → Diagnostics Findings** (KB 375104).

## 8. Maintenance mode, cluster shutdown, power-outage recovery

**Modes:** Ensure accessibility (default; leaves some objects at reduced redundancy) · Full data migration (keeps compliance; fails without a spare fault domain — "insufficient nodes or disks in the cluster", KB 326857) · No data migration (**at FTT=1 a second failure while the host is out can lose data** — KB 315526).

"Stuck at X%" entering MM: check `debug resync summary get`, `debug object health summary get`, and `debug evacuation precheck` before cancelling. Common causes: resync running, inaccessible objects, too few fault domains, durability-component timeout (~60 min, KB 367172), `/VSAN/DeltaComponent` mismatch, `locality=none` policies.

**Full-cluster shutdown:** use the vCenter **Shutdown Cluster wizard** (7.0 U3+). Manual fallback (KB 322144 [70650], 6.7 U3–8.x, not with a shared witness):
1. Health green; disable HA; power off workloads; 7.0 U1+ enable vCLS retreat mode; power off vCenter if on the cluster.
2. ALL hosts: `esxcfg-advcfg -s 1 /VSAN/IgnoreClusterMemberListUpdates`.
3. **ONE** non-witness host, **once**: `python /usr/lib/vmware/vsan/bin/reboot_helper.py prepare`. Running it twice overwrites the network backup and `recover` then fails.
4. All hosts MM "No Action", shut down.
5. Restart: power on, exit MM on all; ONE host `reboot_helper.py recover`; all hosts set the option back to 0; start vCenter, disable retreat mode, re-enable HA.
- **On VxRail, use the VxRail Shutdown Cluster workflow** instead (see vxrail.md).

**After an unclean total power outage** (sequence inferred from KBs 446425, 403869):
1. Power on all hosts and the witness. **Start no rebuilds, deletes or disk-group changes.**
2. `esxcli vsan cluster get` on each host until the member count is complete. If partitioned, fix the unicast lists — don't re-create the cluster.
3. With DARE, restore KMS/NKP reachability first and avoid further reboots (KB 400069).
4. `esxcli vsan debug object health summary get`; wait for stale components to resync.
5. Then reload invalid VMs (`vsan.check_state -re .` or re-register).
6. Inaccessible objects that are not swap objects → Broadcom support, not deletion.

**vCenter down:** the vSAN data path does not depend on vCenter. The risk is vCenter coming back (or being restored) and pushing a stale member list — set `IgnoreClusterMemberListUpdates=1` first if vCenter state is suspect, and revert afterwards.

## 9. Performance

- Latency attribution: VM latency high but backend low → client/network side. Backend high with OSA disk-group congestion > 0 → devices or destaging. Backend high, zero congestion, active resync → resync or network. pNIC drops/CRC → cabling, optics, switch.
- vSAN throttles ingress deliberately, so congestion or a manual resync throttle shows as guest latency with idle-looking devices — easy to misread as a network fault.
- Tools: vSAN Performance Service views (VM, backend, disk group, host network), `esxcli vsan perf diagnostic get`, `vsish -e get /net/pNics/vmnicX/stats`, iPerf (KB 326526), `nc` (KB 310395). Disk latency expectations: KB 424485. Congestion diagnostic message: KB 326673.
- OSA congestion guidance does not transfer to ESA (no cache tier).

## 10. Upgrades, on-disk format, licensing

- Order **[verify]**: vCenter → hosts (rolling, Ensure Accessibility, wait for resync between hosts) → on-disk format. On VxRail the VxRail bundle handles the order.
- Format upgrades after 3.0 are metadata-only. Hosts write only at their own format, so mixed formats unbalance capacity and can partition — finish the format upgrade once all hosts are upgraded. Read KB 326888 first.
- **No in-place OSA → ESA conversion**: build ESA capacity and Storage vMotion workloads (KB 436377) **[verify]**.
- VCF upgrade pre-check fails on a vSAN disk failure (KB 403267).
- **Licensing (Broadcom):** VCF includes 1 TiB vSAN per licensed core (16-core minimum per CPU); additional capacity is a TiB add-on counted on **raw** physical capacity. VVF entitlement differs (KB 313548) **[verify]**. In 9.x, a missing add-on license can break backups and operations (KB 442448) — include entitlement in the checklist.

## 11. Safe vs dangerous operations

**Rule from Broadcom's own KBs: do not delete, recreate, wipe or force anything while any object is inaccessible or resync is running.**

| Generally safe | Dangerous (data loss or outage) |
|---|---|
| All `get` / `list` / `debug ... get|list`; `health cluster list/get`; `vmkping`; `vsish -e get` | Deleting/recreating a disk group or removing a storage-pool device while objects are inaccessible, reduced-availability or resyncing |
| `/etc/init.d/vsanmgmtd restart` (KB 418349) | `esxcli vsan cluster leave` on a host holding the last good copy of anything |
| MM with Ensure Accessibility after a clean pre-check | MM with No data migration when FTT=0 or already-degraded objects exist |
| Remount after a DDH latency unmount | `unicastagent remove/clear`, `vsan network remove/clear` without the ignore-updates guard and a recorded good list |
| `/VSAN/ClomRepairDelay` changed consistently on all hosts | Cluster-wide policy change when free space is below the operations threshold |
| Resync throttle (reset to 0 afterwards) | Any `-f/--force` flag (`storagepool remove -f`, `diskgroup rebuild --force`, `network remove -f`) |
| | Rebooting encrypted hosts while the KMS is unreachable (keys only in memory) |
| | `reboot_helper.py prepare` twice, or on more than one host |
| | `objtool delete`, `vsan.purge_inaccessible_vswp_objects` on anything but confirmed swap objects, `partedUtil` on a device not yet evacuated **[verify]** |
| | Bug-specific advanced settings (e.g. `/VSAN/zDOMSnapshotMode`, KB 317859) applied as general tuning |

- "Purge inaccessible VM swap objects" removes only swap objects; anything still inaccessible afterwards → Broadcom support (KB 326929).
- Find FTT=0 / force-provisioned objects before maintenance: `esxcli vsan debug object list --health <state>` and the policy column.

## 12. VxRail notes

- Drive replacement, disk add and node add/remove go through the **VxRail plugin** (Physical View / hardware replacement), not raw vSAN disk management **[verify workflow names for your release]**.
- VxRail sets vSAN up during bring-up; vSAN firmware/driver "not on HCL" warnings are judged against the **VxRail release manifest**, not fixed by flashing out of band.
- Dell VxRail KBs: 000019587 (vSAN object health on VxRail), 000186364 (object inaccessible after disk failure; don't replace a disk during resync), 000209262 (vSAN physical disk troubleshooting guide).
- Use the VxRail Shutdown Cluster workflow, not `reboot_helper.py`.

## 13. KB index

326859 OSA disk troubleshooting · 326878 DDH · 418349 log congestion · 326479 [2150260] congestion · 327050 congestion alarm · 327048, 327008, 388453 replacement · 419068 ESA device replacement · 447568 worn NVMe cache · 435891 non-NVMe in ESA · 326889 capacity / full datastore · 326929 [2108319] object health · 445909, 327031 repair timer · 327006 resync impact · 440130 DeltaComponent · 367172 MM timeout · 326954 network troubleshooting · 317830 unicast list repair · 444645 rejoin · 432331 partition after vCenter restore · 391883 partition from MTU · 394978 stretched failure matrix · 315526 MM from host · 326857 full data migration fails · 322144 [70650] manual cluster shutdown · 390160, 410326 reboot_helper problems · 455801 shutdown with shared witness · 446425, 403869 after power outage · 400069 DARE keys unavailable · 453198, 326769 encryption/KMS · 326990 vsantraces ramdisk full · 326527 RVC · 327034 on-disk formats · 326888 partition during format upgrade · 403267 VCF pre-check on disk failure · 313548, 411654, 442448 licensing · 375104 Diagnostics for VCF · 317859 zDOM snapshot PSOD (bug-specific).
