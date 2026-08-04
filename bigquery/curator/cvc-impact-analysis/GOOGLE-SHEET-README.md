CVC RESUBMISSION QUEUE
══════════════════════

Purpose: Track SCVs that need to be resubmitted as flagging candidates.


WHY ARE THESE HERE?
───────────────────
These SCVs were submitted for flagging but the flags weren't applied:

• Version bump → Submitter updated SCV without real changes, blocking the flag
• Grace period expired → 60-day window passed but flag wasn't applied
• Both → Both issues occurred (highest priority)


QUICK WORKFLOW
──────────────
1. Filter the "Actionable - Extract" sheet (by submitter, reason, etc.)
2. Select rows to resubmit (Ctrl/Cmd+click for multiple)
3. CVC Tools → Add Selected to Queue
4. Add notes in the "Resubmission Queue" tab if needed
5. CVC Tools → Export Pending (when ready to submit)
6. CVC Tools → Mark as Submitted (after sending to ClinVar)


KEY COLUMNS
───────────
• Why Resubmission Needed → Prioritize: Both > Version bump > Grace period
• Original Flagging Reason → Verify the reason still applies
• Current Classification → Check if submitter changed their call
• Remove Flag Requested → See if we previously asked to unflag
• ClinVar VCV Link → Click to view current state in ClinVar


STATUS MEANINGS
───────────────
• Pending → Ready to submit
• Submitted → Sent to ClinVar
• Completed → Flag was applied
• Skipped → Decided not to resubmit (add note explaining why)


TIPS
────
• CVC Tools → Highlight Queued SCVs to see what's already queued (turns green)
• Re-extract data periodically to get updates from BigQuery
• Use the Notes column for anything unusual

Questions? Contact the ClinVar data team.
