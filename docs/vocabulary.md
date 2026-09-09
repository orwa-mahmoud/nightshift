# Vocabulary

The working files and the terms you will see during a shift:

| Term | File / mechanism | Meaning |
|---|---|---|
| **punch list** | `.nightshift/punch-list.md` | approved work and self-reported completion; the Shift contract above Items survives Archive and binds the next cut |
| **state workspace** | `.nightshift/` | the folder that owns run state — punch list, rules, receipts; may sit beside or above the work target |
| **work target** | `.nightshift/work-target` | the folder that receives inspection and verification — a Git repository in repository mode, a persistent non-Git folder in artifact mode |
| **work mode** | `.nightshift/work-mode` | `repository` or `artifact`; legacy repositories can omit it, but a non-Git folder needs Setup to record artifact mode |
| **clock-out gate** | Stop hook + `.shift-armed` | the bound session can't clock out while the armed punch list has open Items |
| **hardhat** | PreToolUse hook | mandatory safety equipment — your forbidden commands, protected dirs, secret patterns, and expected commit identity; denied, not discouraged |
| **process lease** | `.nightshift/.shift-lease` | transient ownership of the active shift process — each watchman recovery advances its generation, admitting the recovered worker and fencing stale processes on the same conversation without locking other tabs |
| **item gate** | project verification commands | checks run at the selected cadence: per item, final, custom, or none; a check that runs must pass |
| **receipt** | `.nightshift/receipts/` | the runtime's records: one file per item, the index, and the morning receipt; live progress, results, verification, output locations, and measured usage and duration where available |
| **archive** | `.nightshift/archive/<YYYY-MM-DD>/` by default; `archive.root` and `archive.layout` move it | filing of shipped items, the journal, handled snags, and copied artifact receipts. Filing is a copy: a live record is retired only when Archive is told it is closed. Missing or empty receipts create no dated receipts folder. |
| **site inspection** | interval commands | the scheduled heavy inspection (coverage, dead code, Sonar) every N items or H hours |
| **walkthrough** | catalog item | an ongoing work loop with a required deadline; some entries can finish early at convergence or verified objective satisfaction |
| **hunt** | Nightshift Hunt | composes catalog work with Guided or Automatic selection and review-first or direct execution |
| **work order** | `.nightshift/work-orders.md` | a prepared job ticket — the item plus its hours, clock not running until the cut |
| **snag log** | `.nightshift/snag-log.md` | findings ledger across runs — cycle 4 never re-reports cycle 1 |
| **product research** | `.nightshift/product-research.md` | dated evidence about the product, users, comparable tools, and unmet needs; conclusions keep their source links |
| **opportunity map** | `.nightshift/opportunity-map.md` | ranked product opportunities with evidence, value, differentiation, effort, reversibility, risk, and an explicit status; its single `building` entry is the resumable current cycle |
| **parking lot** | `.nightshift/parking-lot.md` | decisions for the human — parked with a default chosen, the run continues |
| **park, don't ask** | `toolDeny` question entries | during a shift the host's ask tool is denied with the configured message — the question is parked with a default chosen; an empty native entry allows ask-and-wait instead |
| **quality survey** | Nightshift Quality | the optional debt audit — review findings first or choose a direct run that fixes them |
| **doctor** | `/nightshift:doctor` | read-only diagnosis — facts, warnings, classified next actions; invoking it never repairs |
| **drafting table** | `.nightshift/drafting-table.md` | where items are drawn before they're contracted |
| **issue import** | Nightshift Import issues | copies selected GitHub issues onto the drafting table as quoted source; never searches, never writes back to GitHub; Hunt consumes them only in repository mode |
| **quitting time** | `.nightshift/deadline` | UNIX epoch seconds; past that instant the next stop attempt clocks the shift out and starts nothing new — a whistle, not an axe: it bounds the night without killing work mid-item |
| **red-tag** | stall guard | a stuck run is flagged in the shift log and held open by default; `NIGHTSHIFT_STALL_MAX=N` clocks it out after N stuck attempts instead |
| **stop-work order** | `.nightshift/STOP` | Nightshift Stop — or the platform-native terminal command that creates this file — ends the shift at the agent's next stop attempt; the site rules stay armed until it actually stops |
| **morning whistle** | `NIGHTSHIFT_NOTIFY_CMD` | optional shift-end ping (ntfy / Pushover / `say`) |
| **night watchman** | `plugins/nightshift/runtime/` | one per host and operating-system runtime — after positive death evidence it advances the process lease and resumes its recorded session; host-specific pause and close signals determine when it stands down |

---

[Follow a shift from start to finish](how-it-works.md#how-nightshift-works) · [Documentation index](README.md#documentation)
