# Controlled Restore Drill Guide

> This procedure is manual-only and must target non-production partitions.

1. Obtain formal approval, ticket, and dual control sign-off.
2. Confirm target partition is non-production and empty/approved for overwrite.
3. Validate domain compatibility and policy 55 implications.
4. Connect Backup HSM and PED (if required).
5. Run `luna_backup_manager.sh verify` and identify archive to test.
6. In attended LunaCM session, perform restore using approved command syntax for your client version.
7. Validate restored object counts/application-level test keys.
8. Collect evidence: command transcript, timestamps, approvers, outcomes.
9. Remove Backup HSM and re-establish custody seals.
