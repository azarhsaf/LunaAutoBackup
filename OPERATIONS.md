# Operations Runbook

## Daily/weekly checklist
- Confirm latest backup status is PASS.
- Review warnings in summary and logs.
- Confirm schedule health (cron/systemd).
- Weekly: run `verify` and record evidence.

## Backup execution checklist
1. Confirm approved change window.
2. Confirm correct source partition and destination slot.
3. Confirm PED/operator presence if required.
4. Run precheck.
5. Run backup.
6. Archive generated summary report ticket reference.

## Backup verification checklist
- Run `luna_backup_manager.sh verify`.
- Confirm latest archive naming timestamp.
- Confirm no unresolved domain/PED/firmware warnings.

## PED handling note
PED-required environments require attended operations. Scheduler jobs without operator presence may timeout by design.

## Backup HSM custody note
Maintain chain-of-custody and tamper checks before/after each use.

## Domain key custody note
Domain material must remain under dual control; never store secrets in script config/logs.

## Backup media rotation
Rotate USB backup devices per policy, with serial tracking and documented retention mapping.

## Failed backup handling
- Do not retry blindly more than once.
- Run precheck and list commands.
- Escalate with last report and logs.

## Escalation
Escalate to HSM platform lead + security duty officer with incident timestamp, host, source partition, slot, and CKR/error output.

## What not to do in production
- Do not run restore automatically.
- Do not initialize backup HSM without approved ceremony.
- Do not disable timeouts/locking.
- Do not store secrets in files or command args.
