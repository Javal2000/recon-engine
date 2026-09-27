# recon-engine

[![CI](https://github.com/Javal2000/recon-engine/actions/workflows/ci.yml/badge.svg)](https://github.com/Javal2000/recon-engine/actions/workflows/ci.yml)

A reconciliation engine. It checks that two independent records of the same financial activity agree, and explains the breaks when they don't.

When transaction data moves from a system of record into a warehouse, rows get dropped, duplicated, rounded, or land a day late. Reconciliation catches that before it ends up in a statement, a tax slip or a regulatory report.

```bash
git clone https://github.com/Javal2000/recon-engine && cd recon-engine
bin/recon demo
```

The demo needs no API key, no database and no `bundle install`. The engine only uses Ruby's standard library, and the agent layer falls back to an offline rule table when no model is configured. On Windows, run the commands as `ruby bin/recon ...`.

## Design

I built this around one rule: **a model never decides whether two numbers are equal.**

| | Deterministic layer | Agent layer |
|---|---|---|
| Answers | *whether* records match | *why* a break happened |
| Built from | plain Ruby | an LLM in a bounded tool loop |
| Runs | always, first | only on breaks that already exist |
| Output | content-addressed break records | schema-validated JSON |
| Reproducible | byte for byte | no, and it's labelled as such |
| On failure | the run fails | that cluster becomes `UNKNOWN`, the run finishes |

Reconciliation output feeds statements and filings, so it has to be reproducible and auditable, and a probabilistic component can't be either. Explaining a break is a different kind of problem. Whether a 4,300-row gap is a settlement lag or a dropped partition takes investigation, and that's where a model helps.

The model is kept away from the arithmetic in three ways:

1. **Order.** The agent only sees breaks the deterministic layer has already found. It can't create, suppress or resize one.
2. **Tools.** Its four tools read, count and summarise. None of them compares amounts, decides a match or writes anything, and a spec asserts that.
3. **Fingerprint.** The run fingerprint covers inputs, settings and every break, and leaves out agent output. Switching the agent on, off or to another provider can't change it, and a spec checks that too.

## How a run works

```
ledger.csv ─┐
            ├─► profile ─► match ─► check ─► cluster ─► attribute ─┬─► CLI report
warehouse.csv┘                                                     │   JSON report
                                                                   └─► agent
```

**Profile.** One streaming pass per file with `CSV.foreach`. Control totals, row counts and duplicate detection only need counters, so memory grows with the number of distinct keys, not rows.

**Match.** Matching decides identity (these rows are the same transaction), not agreement (these rows say the same thing). Mixing the two up either hides real breaks or reports every late settlement as missing.

| Pass | Strategy | Handles |
|---|---|---|
| 1 | `exact_key` | a shared transaction id |
| 2 | `composite` | account + currency + amount + date, within an amount tolerance and a settlement window |
| 3 | `split` | one deposit arriving as several legs downstream, or several rows rolled up into one |

A row used by one pass is never reconsidered by a later one, and candidates are probed nearest first, so the result doesn't depend on input order. The specs shuffle both files to check this. The split search is capped at 12 candidates and 5 legs, which bounds it at 1,585 subsets per unmatched row; beyond that it reports no split rather than hanging.

**Check.** Five checks produce breaks:

| Check | Catches | Level |
|---|---|---|
| Completeness | ledger rows missing downstream, and warehouse rows with no ledger origin | row |
| Control totals | daily sums per currency that don't tie | aggregate |
| Duplicates | the same business key twice within one file | row |
| Value-level | matched rows whose amount, date or status differ | row |
| Schema drift | a column dropped, added or retyped between the two files | aggregate |

Schema drift is the only one that compares structure rather than values, so it's the only one that can fire when every row reconciles. If a pipeline changes a column's type, it gets flagged on the first run, before any bad values have come through. Column types are inferred from a 50-row sample rather than the first row, to avoid false alarms.

Each break records its type, the affected rows, the dollar amount and a partition. Break ids are a SHA-256 of the break's content (`brk_...`), so the same break always gets the same id and can be deduplicated downstream. Only row-level breaks count toward the headline dollar figure, since a control total that doesn't tie is usually the same missing money counted a second time.

**Cluster.** One skipped partition upstream can produce thousands of missing-row breaks with a single cause. Breaks are grouped by type and a type-specific signature (partition for missing rows, the differing fields for value mismatches), then ranked row-level first, then by dollars, then by count. That way a whole feed arriving a day late still ranks high even though it's worth $0. The agent runs once per cluster, not once per break.

**Attribute.** A day's control total that doesn't tie is almost never a separate problem: it's the rows already reported, seen as a sum. So the engine explains each control-total and row-count break itself, by adding up the effect of every row-level break on that day and currency. A missing row takes its amount away, an orphan adds it, and a late row takes it off one day and puts it on the next. Split deposits that reconciled cleanly count too, since they add rows without raising a break, which is also why the row-count check used to flag them.

On the demo data every aggregate break balances to the cent:

```
18. Control total does not tie -- 11 break(s), -$26,966.60
   EXPLAINED by the row-level breaks on the same days
        -$16,945.25  orphan in warehouse (5)
        -$13,614.95  missing in warehouse (11)
          $3,393.60  extra duplicate copies (4)
            $200.00  changed amounts (4)
```

A cluster only counts as explained when every day in it balances, so errors of +$5 and -$5 on two different days can't cancel each other out. Explained clusters don't go to the agent at all. Whatever is left over would mean the row-level checks missed something, and only that residual is sent to the model. It's zero on every dataset I've generated, across 172 control totals and 136 row counts.

**Investigate.** For each remaining cluster the agent calls tools until it can justify a classification:

| Tool | Returns |
|---|---|
| `fetch_rows(source, filters...)` | raw rows, at most 20 |
| `check_adjacent_periods(account, date, amount)` | row counts on the days either side, which is how a settlement lag shows up |
| `get_schema(source)` | column names and inferred types |
| `summarize_cluster(break_ids)` | count, amount, accounts and date range |

Its reply has to match a hand-written schema. If it doesn't, the specific errors are sent back for one repair attempt.

```json
{
  "classification": "TIMING_DIFFERENCE",
  "confidence": 0.9,
  "evidence": ["warehouse has 1 matching row on 2026-01-06, none on 2026-01-05"],
  "explanation": "...",
  "suggested_action": "..."
}
```

Classifications are `TIMING_DIFFERENCE`, `ROUNDING`, `DUPLICATE_IN_TARGET`, `MISSING_IN_TARGET`, `SCHEMA_DRIFT`, `GENUINE_DISCREPANCY` and `UNKNOWN`. Every finding records the provider, the model, whether it was model-backed, how many tool calls and repairs it took, and whether it degraded.

## Testing the agent

The agent isn't deterministic, so I test it at three levels.

**The loop, against a scripted model.** `spec/support/fake_llm.rb` returns fixed responses, so parsing, tool dispatch, repair and the budgets are tested with no network. The specs cover a malformed reply getting a repair prompt with the exact schema errors, a model that never complies ending as `UNKNOWN`, a provider outage affecting one cluster rather than the run, the step budget, and the final transcript containing every earlier tool result.

**The output, through schema validation.** `Agent::Schema` is the only place model output gets parsed. It tolerates what models commonly send (markdown fences, a missing `action` key) and rejects everything else.

**The model, against a golden set.** The data generator injects known faults and writes a manifest listing each one with the classification it should get. `bin/recon eval` runs the whole pipeline over that data and reports recall per fault type, how well the stated confidence matches the accuracy, how many breaks got a real answer at all, and what the run cost. `spec/eval/golden_set_spec.rb` holds the result to a threshold: 100% for the offline rule table, 80% per fault type for a model.

```bash
bin/recon eval                                                  # the offline rule table, as a baseline
bin/recon eval --provider gemini --model gemini-3.1-flash-lite  # a real model on the same data
```

Results on the default eval set (600 ledger rows, seed 42, 85 scored breaks across 7 fault types):

| | Offline rule table | gemini-3.1-flash-lite |
|---|---:|---:|
| Recall, all 7 fault types | 100% | 100% |
| Calibration error | 0.25 | 0.035 |
| Breaks that got a real answer | 100% | 100% |
| Model calls | none | 54 |
| Tokens | none | 107,264 |
| Time in the model | none | 96 s, plus 165 s waiting on free-tier rate limits |

These runs predate attribution, when the 6 aggregate clusters still went to the model; they're now explained by the engine, so a run makes fewer calls. The row-level clusters, which the recall figures are about, are sent exactly as before. The rule table scores 100% by construction; it's there as the control. Its calibration error of 0.25 comes from always stating 0.75 confidence while always being right. The model is slightly underconfident the same way, right every time at about 0.96.

The first run scored 95%, with orphans at 20%, and the misses pointed at two real problems:

1. **An engine bug.** A duplicated row's surplus copy was reported twice, once by the duplicates check and again as an orphan. That inflated the demo's headline dollar impact by 22%, and it put duplicates into orphan clusters, where the model was marked wrong for calling a mostly-duplicate cluster a duplicate. Fixing it took the model to 96%.
2. **An ambiguous label.** The model's explanations had the facts right ("present in the warehouse, no ledger record") and then picked `MISSING_IN_TARGET`, because the prompt never said which direction that label meant. Clarifying two definitions took orphans from 40% to 100%.

Each figure is a single run. At temperature 0 they should hold, but I haven't repeated them. The eval uses flash-lite because the free tier allows only 20 requests a day for the default `gemini-3.8-flash`, and a full eval takes about 54. Evals are tagged `:eval` and kept out of `rake spec`, since against a hosted provider they cost money.

## Checking it yourself

```bash
bin/recon generate --dir data --seed 42
bin/recon run --ledger data/ledger.csv --warehouse data/warehouse.csv --json out/a.json --quiet
bin/recon run --ledger data/ledger.csv --warehouse data/warehouse.csv --json out/b.json --quiet
bin/recon run --ledger data/ledger.csv --warehouse data/warehouse.csv --json out/c.json --quiet --no-agent
ruby -rjson -e 'ARGV.each { |f| puts JSON.parse(File.read(f))["run"]["deterministic_fingerprint"] }' out/a.json out/b.json out/c.json
```

All three fingerprints match, including the run with the agent switched off.

```bash
bin/recon run --ledger data/ledger.csv --warehouse data/warehouse.csv --json out/d.json --quiet --tolerance-cents 0
```

With no tolerance, the 18 one-cent differences are no longer treated as rounding and get reported as material value differences instead. The fingerprint changes as well, because settings are part of it.

The tolerance and the timing window only decide matches in passes 2 and 3, where there's no shared id. In the demo data the delayed and rounded rows keep their ids, so they match on pass 1 either way and show up as value-level breaks.

## Providers

`--provider offline` is the default. It's a rule table that speaks the same JSON protocol as a model, so the demo and CI run without credentials, and reports mark its findings as not model-backed. Control totals and row counts never reach it, because the engine explains those itself.

```bash
export GEMINI_API_KEY=...     && bin/recon demo --provider gemini      # free tier
export ANTHROPIC_API_KEY=...  && bin/recon demo --provider anthropic
export OPENAI_API_KEY=...     && bin/recon demo --provider openai
ollama pull llama3.1:8b       && bin/recon demo --provider ollama      # local
```

Override the model with `--model` or `RECON_AGENT_MODEL`. `fetch_rows` sends up to 20 raw rows to whichever provider you pick, so with real data use `--provider ollama` or `--no-agent`.

Rate limits are handled the way the provider asks. A 429 waits as long as the server says, from `Retry-After` or Google's `RetryInfo` block, capped at a minute. A daily quota stops calls for the rest of the run instead of retrying, and so do three failed calls in a row; the remaining clusters get `UNKNOWN` straight away and the deterministic report ships regardless. Every finding records the calls, tokens and time it cost, with thinking tokens counted separately, and the report totals them.

## Usage

```bash
bin/recon demo
bin/recon generate --dir data --seed 42 --rows 5000
bin/recon run --ledger data/ledger.csv --warehouse data/warehouse.csv --json out/report.json
bin/recon run --ledger a.csv --warehouse b.csv --no-agent
bin/recon eval --provider gemini
```

| Option | Default | Effect |
|---|---|---|
| `--tolerance-cents N` | 1 | amounts within ±N cents match in passes 2 and 3 |
| `--timing-window-days N` | 1 | settlement lag allowed in passes 2 and 3 |
| `--provider NAME` | `offline` | `offline`, `gemini`, `anthropic`, `openai`, `ollama` |
| `--max-clusters N` | 40 | clusters the agent investigates per run |
| `--json PATH` | | also write the JSON report |
| `--no-agent` | | skip the agent layer |
| `--quiet` | | don't print the text report |

| Exit code | Meaning |
|---|---|
| `0` | reconciled clean |
| `1` | breaks found |
| `2` | the tool failed: bad input, unreadable file, bad config |

Keeping 1 and 2 separate lets a scheduler alert on bad data and page on a broken job.

## Design notes

**Money.** Amounts are parsed with `BigDecimal`, converted once to integer cents and compared as integers. There's no `Float` in the matching or checking code.

**Idempotency.** The fingerprint is a SHA-256 over the input digests, the deterministic settings, the matching outcome and every break id. It leaves out timestamps, durations, hostnames and agent output. `spec/run_spec.rb` checks that reruns match and that the fingerprint changes when an input byte or a setting does. Getting there took integer cents, content-addressed ids and a total order on everything that reaches a report.

**Memory and speed.** Profiling streams. Matching loads both files because it needs random access, so memory grows with both. `rake bench` measures it; one run on a Windows laptop with Ruby 3.3 and the agent off:

| Ledger rows | Total | Rows/s | Heap |
|---:|---:|---:|---:|
| 10,000 | 1.2 s | 16,580 | 15 MB |
| 100,000 | 12.4 s | 16,165 | 115 MB |
| 1,000,000 | 157 s | 12,714 | 1.1 GB |

That's about 1.1 KB of heap per ledger row, counting its warehouse counterpart. Each file is currently parsed twice, once to profile and once to load, and at 1M rows profiling is the slowest phase, so a single pass is the first thing I'd change. For much larger inputs I'd replace pass 2 with an external sort-merge join on `(account, currency, date)`, which keeps memory to one partition at a time.

**Encrypted columns.** Deterministically encrypted or tokenized ids work unchanged, since pass 1 only compares them for equality. Encrypted amounts and dates don't: the tolerance, the timing window, split matching and control totals all need arithmetic. The loader rejects a non-decimal amount anyway.

**Failures.** The agent runs last, so an outage, bad JSON or a failing tool only degrades that cluster's explanation. Malformed input is the opposite: the run stops and names the row and column, because skipping bad rows would produce a clean report over incomplete data. `rescue` clauses only catch the library's own error classes, so real bugs still raise.

**Synthetic data.** All data comes from `lib/recon_engine/generator.rb`. It's seeded, so the same seed gives byte-identical files, and it shuffles the warehouse file so the matcher can't rely on row order.

## What I'd add next

- An on-disk sort-merge join and partition-parallel runs, since reconciliation splits cleanly by date and account.
- A `breaks` table keyed on the break ids, for break ageing ("open for nine days") and schema drift across runs.
- A per-run token budget. Usage is already tracked per finding, and a circuit breaker stops calling a provider that's out of quota; a ceiling on tokens is the missing piece.
- Periodic human review of agent findings, feeding back into the golden set.
- Skipping notifications when a run's fingerprint matches the previous one.

## Development

```bash
bundle install
rake spec             # unit and integration specs, model mocked, no network
COVERAGE=1 rake spec  # the same, failing below 94% line or 77% branch coverage
rake eval             # golden-set evaluation against the configured provider
rake bench            # timing and memory (BENCH_ROWS=10000,100000 by default)
rake demo             # generate and reconcile
bundle exec rubocop
```

CI runs RuboCop once, and on each of Ruby 3.2, 3.3 and 3.4 the coverage-checked specs, the eval and an end-to-end demo. Coverage is currently 95.6% of lines and 79.8% of branches.

```
lib/recon_engine/
├── money.rb          integer cents
├── transaction.rb    immutable row value
├── config.rb         every setting that affects a result
├── sources/          CSV source and streaming profiler
├── matching/         three-pass matcher
├── checks/           the five checks
├── breaks/           break records and clustering
├── agent/            schema, tools, prompt and the loop
├── llm/              provider adapters and the offline stand-in
├── reporting/        CLI and JSON reports
├── generator.rb      synthetic data and fault manifest
├── evaluation.rb     scores the agent against the manifest
└── run.rb            orchestration
```

A new source type needs five methods: `each`, `name`, `schema`, `digest` and `path`. `CsvSource` is only referenced in `Run.call`.

## License

MIT
