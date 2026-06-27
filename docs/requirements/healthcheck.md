# Source Document Health Check

Purpose: detect changes in Microsoft Learn source documents used by RNFleetManager requirements, and trigger review/notification when drift is found.

## Scope

This health check tracks:

- document metadata changes (updated date, git commit, version ID)
- requirement-impacting content changes
- newly added or removed constraints

## Tracked sources

| Alias | URL | Current checkpoint |
|---|---|---|
| create-remote-networks | https://learn.microsoft.com/en-us/entra/global-secure-access/how-to-create-remote-networks | 2026-06-19T15:15:55.951-07:00 |
| manage-device-links | https://learn.microsoft.com/en-us/entra/global-secure-access/how-to-manage-remote-network-device-links | 2026-06-19T15:15:55.951-07:00 |
| reference-configurations | https://learn.microsoft.com/en-us/entra/global-secure-access/reference-remote-network-configurations | 2026-06-19T15:15:55.951-07:00 |
| configure-cpe | https://learn.microsoft.com/en-us/entra/global-secure-access/how-to-configure-customer-premises-equipment | 2026-06-19T15:15:55.951-07:00 |

## Baseline metadata (at checkpoint)

| Alias | ms.date | updated_at | document_version_independent_id | git_commit_id |
|---|---|---|---|---|
| create-remote-networks | 2026-04-15 | 2026-06-15 | eb82f9e3-6a80-a989-9c77-8c146382f037 | d2b1d2db3c2666465f000b2eab8c11bae1830820 |
| manage-device-links | 2026-03-23 | 2026-06-15 | 22ff5837-17dd-d3f8-8338-0f8d407a3d7d | d2b1d2db3c2666465f000b2eab8c11bae1830820 |
| reference-configurations | 2026-03-13 | 2026-04-22 | 202872e3-3ec2-7227-b2b1-0e9071773b19 | a11629565e0ba12b8cd63c63566446b9150cab69 |
| configure-cpe | 2026-03-25 | 2026-03-25 | 5a318e5b-af36-c848-3a91-170acd992f98 | e40ec8d20d439303a0aac501fb8ade6761cf6763 |

## Check procedure

1. Fetch each source document.
2. Compare metadata fields against baseline:
   - `ms.date`
   - `updated_at`
   - `document_version_independent_id`
   - `git_commit_id`
3. If metadata changed, compare requirement-bearing sections:
   - prerequisites and protocol requirements
   - IKE/IPSec defaults and custom limits
   - ASN/BGP constraints
   - traffic profile enforcement behavior
4. Classify result:
   - **No change**: no metadata drift and no semantic diff
   - **Doc change, no requirement impact**: metadata/content changed, requirements unchanged
   - **Requirement impact**: any AR-* requirement needs update
5. If requirement impact is detected:
   - update `appliance-requirements-gsa-remote-network.md`
   - update this file baseline table
   - create change note in commit message

## Notification rules

Notify immediately when any of the following occurs:

- protocol support requirements changed (IPSec/IKEv2/BGP/crypto)
- valid/invalid ASN or BGP ranges changed
- default or custom IKE/IPSec combinations changed
- traffic forwarding enforcement behavior changed
- source page marked with newer `git_commit_id`

## Notification payload template

```text
[RNFleetManager] Source Doc Drift Detected
Checkpoint: <old checkpoint>
Detected: <new timestamp>
Source: <alias + URL>
Type: <metadata-only | requirement-impact>
Changed fields: <list>
Impacted requirements: <AR-IDs or none>
Action: <review required | docs updated>
```

## Suggested cadence

- Daily automated metadata check
- Weekly semantic review
- Immediate manual check after known Microsoft Entra GSA release notes
