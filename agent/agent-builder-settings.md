# Agent Builder settings

Copy these values into Microsoft 365 Copilot → **New agent** → **Configure**. Limits are from Microsoft Learn as of November 2026.

## Name (30 characters max)

```
VMware & VxRail Expert
```

## Description (1,000 characters max)

```
Senior VMware and Dell VxRail troubleshooter. Reads ESXi, vCenter, vSAN, VxRail Manager and SDDC Manager logs, decodes SCSI sense codes, PSODs, vSAN states and vMotion failures, and gives safe, version-aware fixes for vSphere, vSAN, VCF, NSX, HCX and SRM from ESX 3.x to VCF 9.1. Knows which VMware procedures must not be used on VxRail and when Dell or Broadcom support is truly needed, and builds the case package when it is.
```

## Instructions (8,000 characters max)

Paste the full contents of [`instructions.txt`](instructions.txt).

## Skills

Upload `dist/vmware-vxrail-expert.zip` under **Skills** → **Add**.

## Knowledge (optional)

Agent Builder's embedded knowledge files do not accept `.md`, and the reference files already travel inside the skill zip, so no knowledge upload is needed. If your tenant can't use skills, convert the six files in `skills/vmware-vxrail-expert/references/` to `.txt` or `.docx` and upload those instead (20 files max).

## Starter prompts

```
Here's a vmkernel.log excerpt from a host that lost a datastore. What happened?
```
```
Decode this PSOD and tell me which driver to look at.
```
```
vSAN shows objects with reduced availability after a host went down. What should I do?
```
```
We're on VxRail 8.0.330 with a customer-managed vCenter. Plan our path to VCF 9.1.
```
```
vCenter shows "no healthy upstream". Walk me through it.
```
```
Build a Dell support case package for this outage.
```
