# Item budgets

One stuck item should not take the whole shift. A budget gives an item two limits in working time,
tokens, or both: a soft one, where the agent is told to finish, and a hard one, where it can only
wrap up and move on. The rest of the punch list still gets its turn, and the stuck item comes back
to you with everything it tried.

## Set a budget

Most items need no budget. In the [plan room](plan-room.md#size-it-from-your-own-history), the agent
offers one only for an item with a real chance of getting stuck, says why, and proposes limits from
your past receipts. You can also add a `Budget:` line to any item yourself:

```text
- [ ] **3. Migrate the session store to the new schema.**
  - Budget: soft 30m / 1M tokens, hard 45m / 2M tokens
  - Verify:
    - WHEN the migration runs on the fixture THEN every session survives with its expiry
```

Each limit takes a time (`45m`, `1h 30m`, `90s`), a token count (`500k tokens`, `2.5M tokens`), or
both, and either limit can be left out. `shift.itemBudget` in your rules gives every item without
its own line the same budget.

Time is working time on that item across every session, so a recovered session continues the same
count. Tokens are input plus output, measured from what the host reports. A reading the host does
not report never trips a limit.

## The soft limit: finish

When an item passes its soft limit, the next tool result tells the agent, once, to start finishing:
complete the change in hand, run the item's `Verify:`, write the receipt and tick it. The shift log
records when the notice was given. Nothing is blocked at this point.

## The hard limit: wrap up and move on

When an item passes its hard limit, the next tool call narrows the shift to wrap-up. The agent may
read, `git add` and `git commit`, and write the receipts, the punch list and the inbox. Every other
tool is denied with the reason. A response already being written finishes first.

The agent then commits the work in progress, writes the item's receipt, and closes the item as
stopped:

```text
- [-] **3. Migrate the session store to the new schema.**
  - Stopped: hard 45m reached; spent 47m / 1.8M tokens; work in progress at a1b2c3d
```

A stopped item is never ticked. The shift treats it as closed and goes on to the next item.

## What you see afterwards

- The morning receipt lists the stopped item under decisions for you, with its receipt one click
  away: what was delivered, what was tried, and the commit holding the work in progress.
- Status and Doctor count it as `stopped=N` while the shift runs.
- The next time you open the plan room, it asks for each stopped item whether to keep it, rework it,
  or drop it.
- Archive keeps it live as open work. To try it again as it is, change its box back to `- [ ]`.

---

[The plan room](plan-room.md#the-plan-room) · [Receipts and token usage](receipts.md#receipts-and-token-usage) · [Documentation index](README.md#documentation)
