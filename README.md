# VMware vExpert & Dell VxRail Troubleshooter — a Copilot skill

A skill for Microsoft Copilot (and GitHub Copilot, and Claude) that works like a senior VMware engineer with vExpert-level depth, who also knows Dell VxRail. It reads your logs, explains what they mean, finds root cause, gives safe fixes, and tells you when you really do need Dell or Broadcom support. When you do, it builds the case package for you.

Content is current as of **November 2026** and covers ESX 3.x through **VCF 9.1** and VxRail 4.x through **9.1.100**.

---

## What it can do

| Area | What you get |
|---|---|
| **Log analysis** | Paste or upload ESXi, vCenter, vSAN, VxRail Manager, SDDC Manager, NSX or VM logs. It names the log, finds the earliest abnormal line, quotes and decodes the lines it relies on, flags benign noise, and checks the hypothesis against a second log. |
| **Decoding** | SCSI `H:/D:/P:` status and sense key/ASC/ASCQ, APD vs PDL, PSOD exceptions and the driver to blame, vSAN object/component states, vMotion failures by percentage, HA agent states, vCenter 503s, firstboot failures. |
| **ESXi** | Storage paths, VMFS heartbeat/ATS, boot media, PSOD and core dumps, host not responding, ramdisk full, networking/MTU, esxtop thresholds, patching and CPU support in ESX 9. |
| **vCenter** | Service failures, disk/partition full, certificates (vCert, fixsts, lsdoctor), SSO and ELM, password resets, backup/restore, upgrades and RDU, HA/FDM, vCLS, DRS, vMotion, vLCM, opID tracing. |
| **vSAN** | OSA vs ESA failure domains, object health states, the 60-minute repair timer, disk failures and DDH, congestion, capacity reserves, partitions and unicast repair, stretched-cluster failure behaviour, cluster shutdown and power-outage recovery, safe vs dangerous operations. |
| **VCF / NSX / others** | SDDC Manager logs and SoS, VCF 9.0/9.1 architecture and upgrade order, NSX password expiry and TEP MTU, Aria/VCF Operations, HCX, SRM/vSphere Replication, Supervisor/VKS. |
| **Dell VxRail** | VxRail Manager services and logs, log bundles, VxVerify, VxRail lifecycle and vLCM mode, the lockbox and trust store, Physical View/iDRAC, node discovery, the VxRail-to-vSphere version map, VCF on VxRail and VxRail 9.1. |
| **Change safety** | Before recommending any change it checks whether VxRail owns the object, and steers you away from VMware procedures that break VxRail (for example patching ESXi with esxcli or upgrading a VxRail-managed vCenter directly). Disruptive steps are marked with their impact, plus validation and rollback. |
| **Escalation** | Tells you plainly when to call support, who to call first (Dell for VxRail, otherwise Broadcom), what severity to pick, and which bundles and facts to collect. |
| **History & Broadcom changes** | Version timeline, end-of-support dates, licensing in 9.x (VCF Operations, license server), token-based downloads, Skyline's replacement, where KBs and docs live now. |

## Limitations — read these

- **It doesn't replace support contracts.** It can take you a long way, but some fixes need Dell- or Broadcom-only procedures or tools (VxRail RASR/reimage, VxRail Manager recovery, database edits, Dell SolVe restricted procedures, vsantrace decoding, stretched-cluster site takeover). The skill tells you when you've hit one of these.
- **It can't see your environment.** It only knows what you paste or upload. Wrong timezone, missing logs or rotated logs lead to wrong answers. Give it the event time with timezone and what changed beforehand.
- **Copilot can't open `.tgz` support bundles**, and chat uploads have per-file size limits. Use [`tools/Invoke-LogTriage.ps1`](tools/Invoke-LogTriage.ps1) to extract, filter and chunk logs first (see below).
- **Some content is unverified.** The reference files mark practitioner knowledge that couldn't be confirmed against a current Broadcom or Dell document with **[verify]** — especially much of the ESXi networking section, many command flags, vCenter log-line formats, and NSX/Aria/HCX/SRM/Supervisor CLI detail. The skill is told to say so when it relies on these. Check flags with `--help` on your system.
- **Dell-gated information is incomplete.** Many VxRail procedures, firmware-per-release tables and multi-hop upgrade paths live behind Dell login (SolVe, release notes, Simple Support Matrix). The skill points you there instead of guessing.
- **Facts drift.** Lifecycle dates, licensing rules, SKUs and builds change. Contested facts are flagged as contested: the 72-core minimum, VCF 9.0/9.1 end-of-support dates, vCLS/DRS behaviour in 9.0, Skylake-SP support in ESX 9, and VxRail 9.1 support for stretched/2-node/satellite clusters. It never quotes prices.
- **AI can be wrong.** Test changes in non-production where you can, take snapshots/backups first, and sanity-check anything destructive.
- **Data handling.** With a work account, Microsoft 365 Copilot applies enterprise data protection, and files you upload in chat are stored in your OneDrive. Follow your organisation's policy for sharing infrastructure logs. The triage script can mask IP addresses (`-MaskIPs`); mask hostnames yourself if required. Never paste passwords, license keys or download tokens.

---

## Install

The same skill folder works across hosts. Pick one.

### Option 1 — Microsoft 365 Copilot Chat (personal skill, quickest)

1. Download [`dist/vmware-vxrail-expert.zip`](dist/vmware-vxrail-expert.zip).
2. In Microsoft 365 Copilot Chat: **Agents** → **More agents** → drop-down next to **Add** → **Upload skill**.
3. Upload the zip. Copilot can pick the skill automatically when it's relevant, or you can select it.

If you don't see **Upload skill**, your admin hasn't enabled skills for your tenant — use Option 2 or ask them.

### Option 2 — Agent Builder agent (shareable inside your tenant)

Needs a Microsoft 365 Copilot license, or pay-as-you-go enabled for Copilot Studio.

1. Microsoft 365 Copilot → **New agent** → **Skip to configure**.
2. Fill in the name, description and starter prompts from [`agent/agent-builder-settings.md`](agent/agent-builder-settings.md).
3. Paste [`agent/instructions.txt`](agent/instructions.txt) into **Instructions** (5.7K of the 8,000-character limit).
4. **Skills** → **Add** → upload `dist/vmware-vxrail-expert.zip`.
5. Test on the **Try it** tab, then **Create** and **Share**.

Agents can't be shared across tenants, so anyone outside your organisation rebuilds it from this repo.

### Option 3 — Copilot Studio

Agent → **Build** → **Skills** → **Add skill** → **Upload a skill** → upload the zip. Paste `agent/instructions.txt` as the agent instructions. Turn on code interpreter if users will upload log files (it lifts the 30,000-characters-per-file limit; the 15 MB per-file limit still applies).

### Option 4 — GitHub Copilot (VS Code agent mode, Copilot CLI, coding agent)

Copy the skill folder into a repository or your profile:

```powershell
# Project skill
Copy-Item -Recurse .\skills\vmware-vxrail-expert <your-repo>\.github\skills\
# Personal skill
Copy-Item -Recurse .\skills\vmware-vxrail-expert $HOME\.copilot\skills\
```

### Option 5 — Claude

Copy `skills/vmware-vxrail-expert` to `~/.claude/skills/` (Claude Code). For claude.ai, zip the `vmware-vxrail-expert` folder itself (the `dist` zip has `SKILL.md` at the root, which is the layout Copilot needs).

---

## Preparing logs for Copilot

[`tools/Invoke-LogTriage.ps1`](tools/Invoke-LogTriage.ps1) extracts a support bundle (`vm-support`, `vc-support`, VxRail, SoS — `.tgz`, `.tar`, `.zip`, or a folder), unpacks nested bundles and rotated `.gz` logs, keeps only lines matching known VMware/VxRail failure signatures (plus a little context), optionally within a time window, and writes `triage-NNN.txt` chunks under 25,000 characters each with a `summary.csv`. Everything runs locally.

```powershell
# Everything within ±30 minutes of 2:05 pm local time
.\tools\Invoke-LogTriage.ps1 -Path .\esx-host01.tgz -EventTime '2026-11-10 14:05'
```

```powershell
# Only vCenter and certificate signatures, with IP addresses masked
.\tools\Invoke-LogTriage.ps1 -Path .\vc-support.tgz -Category vcenter,certificates -MaskIPs
```

Then upload `triage-001.txt` to Copilot and say when it happened and what changed before it. Categories: `storage, psod, network, host, vsan, ha, vcenter, certificates, space, vxrail, vcf, nsx`. Add `-IncludeGenericErrors` to also keep every generic error/warning line (much more output). Works in PowerShell 7+ and Windows PowerShell 5.1; needs `tar` (built into Windows 10/11, macOS, Linux).

**Timezones:** the time window treats log timestamps as UTC, which is right for ESXi and vCenter. VxRail Manager, SDDC Manager and appliance logs may be in local time — widen `-WindowMinutes` by your UTC offset or skip `-EventTime` for those.

---

## Repository layout

```
skills/vmware-vxrail-expert/
  SKILL.md                    Persona, VxRail gate, log workflow, safety, accuracy, escalation
  references/
    log-triage.md             Method, symptom → which log, correlation, search patterns
    esxi.md                   Logs, SCSI decoding, APD/PDL, PSOD, networking, esxtop, patching
    vcenter.md                Services, certificates, SSO, upgrades/RDU, HA, vCLS, vMotion, vLCM
    vsan.md                   States, repair timer, disks, partitions, stretched, safe vs dangerous
    vxrail.md                 VxRail Manager, LCM, operations table, Dell boundaries, version map
    vcf-nsx-portfolio.md      History, Broadcom changes, VCF 9.x, NSX, Aria, HCX, SRM, Supervisor
agent/
  instructions.txt            Agent Builder / Copilot Studio instructions (< 8,000 chars)
  agent-builder-settings.md   Name, description, starter prompts
tools/
  Invoke-LogTriage.ps1        Local bundle extraction and log filtering
  Build-SkillPackage.ps1      Builds dist/vmware-vxrail-expert.zip
  Test-SkillPackage.ps1       Checks Copilot / Agent Skills limits
dist/
  vmware-vxrail-expert.zip    Ready-to-upload skill package
```

## Updating the skill

1. Edit files under `skills/vmware-vxrail-expert/` (keep `SKILL.md` under 20,000 characters and save as UTF-8 without BOM).
2. Rebuild and validate:
   ```powershell
   pwsh .\tools\Build-SkillPackage.ps1
   ```
3. Re-upload the zip wherever you installed it.

## Test scenarios

Use these after installing to confirm the skill behaves as intended.

| # | Prompt | Expected behaviour |
|---|---|---|
| 1 | "What does this mean? `NMP: nmp_ThrottleLogForDevice: Cmd 0x12 to dev "naa.600..." Failed: H:0x0 D:0x2 P:0x0 Valid sense data: 0x5 0x24 0x0`" | Decodes it as ILLEGAL REQUEST / invalid field in CDB on an INQUIRY, says it's normally benign rescan noise, and asks what symptom prompted the question instead of declaring a fault. |
| 2 | "We're on VxRail 8.0.330. How do I patch ESXi to the latest 8.0.3 build with esxcli?" | Declines the esxcli route, explains that VxRail patches ESXi only through the VxRail bundle (out-of-band patches break LCM and Dell's validated state), and points to the VxRail release that carries the build, VxVerify, and the customer-managed vCenter ordering rule. |
| 3 | "A host in our 4-node vSAN cluster went down 20 minutes ago. Objects show reduced availability. Should I click Repair objects immediately?" | Explains the 60-minute repair timer and that absent components wait for it; asks whether the host is coming back; advises against forcing repair if it is, and against any delete/recreate while objects are degraded; gives host-CLI checks (`esxcli vsan debug object health summary get`, `esxcli vsan cluster get`). |
| 4 | "vCenter 8 shows 'no healthy upstream' this morning." | Checks services, disk space (vpxd stops at 95%) and the STS certificate in that order, with commands and KB references, and recommends a snapshot before certificate repair. |
| 5 | "Build a support case for a Sev 1 outage on our VxRail cluster." | Says Dell is the first call for VxRail, justifies the severity, and lists the case package: timeline in UTC, versions, VxRail Manager log bundle, iDRAC TSR, VxVerify output, vm-support, vCenter logs. |

## Sources

Built from research of Broadcom TechDocs and Knowledge Base articles, Dell VxRail documentation and KBs, Microsoft Learn and GitHub Docs (for the Copilot formats), and well-known practitioner sources (yellow-bricks.com, williamlam.com, virten.net, cormachogan.com, davidring.ie). KB numbers are cited inline in the reference files so you can check them.

## Disclaimer

Not affiliated with or endorsed by Broadcom, VMware, Dell Technologies or Microsoft. All product names are trademarks of their owners. Provided as-is; you're responsible for changes made to your environment.
