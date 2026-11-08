# Add to a catalog

Nightshift's catalogs are folders of short Markdown files. Adding an entry means writing one
file. It needs no code, and no other file changes: every listing finds a new file on its own.

| Catalog | One entry is | Shipped folder | Template | A good one to copy |
| --- | --- | --- | --- | --- |
| Shifts | a ready-made night of work | [`compose/shifts/`](../plugins/nightshift/skills/nightshift/references/compose/shifts/) | [`shift-entry.md`](../plugins/nightshift/skills/nightshift/references/templates/shift-entry.md) | [`environment-example-drift.md`](../plugins/nightshift/skills/nightshift/references/compose/shifts/environment-example-drift.md) |
| Evidence kinds | how to show one kind of work to a reviewer | [`evidence/kinds/`](../plugins/nightshift/skills/nightshift/references/evidence/kinds/) | [`evidence-kind.md`](../plugins/nightshift/skills/nightshift/references/templates/evidence-kind.md) | [`ui.md`](../plugins/nightshift/skills/nightshift/references/evidence/kinds/ui.md) |
| Gate stacks | the checks one kind of project runs | [`compose/gates/`](../plugins/nightshift/skills/nightshift/references/compose/gates/) | [`gates-stack.md`](../plugins/nightshift/skills/nightshift/references/templates/gates-stack.md) | [`python.md`](../plugins/nightshift/skills/nightshift/references/compose/gates/python.md) |
| Edge-case packs | situations worth a test | [`plan/edge-cases/`](../plugins/nightshift/skills/nightshift/references/plan/edge-cases/) | [`edge-case-pack.md`](../plugins/nightshift/skills/nightshift/references/templates/edge-case-pack.md) | [`input.md`](../plugins/nightshift/skills/nightshift/references/plan/edge-cases/input.md) |

## Three steps

1. **Copy the template** into the catalog's shipped folder. Name the file for your entry in
   lowercase words joined by hyphens and ending in .md, such as nightly-docs.md.
2. **Fill every section.** Keep each heading and replace the guidance under it with your own
   words. The headings are what an entry needs: Nightshift checks every entry against its
   catalog's template. To check yours, run
   `ns catalog-index --catalog <catalog> --check-draft <your-file>`; it names any section that is
   still missing.
3. **Open a pull request** with that one file. For a shift, reference
   [#21](https://github.com/orwa-mahmoud/nightshift/issues/21). A shift may also add one test,
   `tests/shifts/<your-shift>.bats`, to lock its refusals.

## Only for you

To use an entry without contributing it, keep it on your machine:
`ns catalog-new --catalog <catalog> --key <key>` copies the template into this project's
`.nightshift/catalogs/<catalog>/`, and `--user` puts it in your user folder for every project.
Your entry wins over a shipped one of the same name. [Owner knobs](knobs.md#catalogs) lists every
place an entry can live, and how to use your own template.

## What a reviewer looks for

Every entry is read by a person before it is merged.

- **Shifts:** whether it is finite or open-ended, how it finds the work, when it is done (stated
  as something a check can confirm), what it will never do, and the Verify line. The full rules
  are in the [shift recipe](../plugins/nightshift/skills/nightshift/references/compose/catalog-recipe.md#the-six-things-an-entry-must-declare).
- **Evidence kinds:** a concrete file name, width, command or figure in every line. The
  optional `evidence-check` block only counts files. Rules: the
  [evidence recipe](../plugins/nightshift/skills/nightshift/references/evidence/recipe.md#adding-an-evidence-kind).
- **Gate stacks:** commands you have run on that kind of project, a Detect section naming the
  files that signal it, and one `Match:` line. Rules:
  [adding a stack](../plugins/nightshift/skills/nightshift/references/compose/gates-catalog.md#adding-a-stack).
- **Edge-case packs:** named, concrete cases, and at least one WHEN/THEN line someone could test.
  Rules: [adding a pack](../plugins/nightshift/skills/nightshift/references/plan/edge-cases.md#adding-a-pack).

Narrow beats broad. "Clear Ruff findings in a Django project" can say exactly when it is done;
"improve Python code" cannot.

---

[Choose a contribution](contribution-map.md#choose-your-contribution) · [Documentation index](README.md#documentation)
