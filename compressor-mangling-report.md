# Report: models report tool output as "mangled by the compressor"

Status: analysis only, no code changed. Asking maintainers whether fixes are wanted and which direction.

## Summary

Across a user's Claude Code sessions, models repeatedly say things like *"Compressor mangled the output; get line-exact context with grep"*. The phrase is written by the model; Headroom never emits it. In the cases examined, the complaint tracks lossy compression of tool results where the model needs exact text (shell output, source files read via `git show`/`cat`, Read results). The strongest finding is that the **`log` strategy is applied to content that is not a log**, and removes a large fraction of it.

This is **not** explained by the five causes already fixed in `tests/test_garbled_compression_fixes.py`, and it reproduces on a post-fix build (0.41.1-alpha.4).

## Evidence

### 1. Model complaints (local transcripts)

1,542 local transcripts were searched. 95 raw string hits across 70 sessions; 22 compression-related after excluding unrelated "mangled" uses (e.g. MSYS path mangling). Mostly Bash tool results, Claude Code 2.1.273–2.1.304, dated 2026-09-16 to 2026-10-20. Typical sentences:

- "Compressor mangled the output; get line-exact context with grep."
- "Output garbled by compressor around <identifier>; verifying state directly."
- "Output mangled by compressor. Write to scratch files and read with Read tool."
- "Output is mangled by compression; use python to extract ranges."
- Subagent: "the brief files were display-garbled when I read them. I reconstructed the tests and src/... from the readable parts and from my own inference."

Models are adapting: one command piped output through `sed 's/ /·/g'` (spaces to middle dots) specifically to dodge the compressor, and still reported the result as mangled.

Transcripts store the **original** tool result; compression happens on the wire. What the model saw is therefore not recoverable from transcripts. Everything below about routing comes from proxy logs and local reproduction.

### 2. Five hits examined in detail (content sanitized)

| Hit | Tool / content | Production route (proxy log, matched by timestamp + size) | Notes |
|---|---|---|---|
| A | Bash, ~2.4k chars TypeScript source, spaces replaced by `·` | `tool:log:0.35` (≈65% removed) | Source code treated as log |
| B | Bash, ~4.1k chars: 3-line block repeated per item (CLI stderr `WARNING:` + doc URL + `deleted X`) | `tool:log:0.60` (≈40% removed) | The informative lines are the quiet `deleted X` ones |
| C | Bash, ~14.9k chars C# source via `git show \| cat -n` | `tool:code_aware:0.58` (≈42% removed) + a text compressor on a second block | Lossy code compression of a file the model wanted verbatim |
| D | Subagent Read of a 12k-char markdown file with 4 embedded code blocks (13k chars with `cat -n` prefixes) | not available | Stored result byte-identical to file after stripping prefixes. `Read` is excluded by default, so the cause is unexplained (see hypothesis 3) |
| E | Bash, branch status table, model said "contradicts itself" | n/a | Original output already odd (script quirk); likely **not** a compression issue |

Request-to-hit matching is by timestamp and size (~5 concurrent requests per 10 s), so A–C are candidates, not proven.

### 3. Fleet statistics (one proxy revision, ~31 h, image 0.41.1-alpha.4)

Counts per `content_router … (tool:<strategy>:<ratio>)` tag; ratio is retained fraction.

| Strategy | Tags | <0.3 | 0.3–0.5 | 0.5–0.7 | ≥0.7 |
|---|---|---|---|---|---|
| mixed | 1872 | 218 | 12 | 226 | 1416 |
| text | 1645 | 0 | 2 | 217 | 1426 |
| code_aware | 1374 | 0 | 44 | 383 | 947 |
| lossless_log | 431 | 0 | 0 | 35 | 396 |
| lossless_search | 305 | 0 | 0 | 124 | 181 |
| lossless_paths | 196 | 0 | 4 | 5 | 187 |
| **log** | **180** | **98** | 5 | 12 | 65 |
| smart_crusher | 176 | 20 | 15 | 8 | 133 |
| tabular | 155 | 3 | 0 | 128 | 24 |
| search | 118 | 5 | 97 | 11 | 5 |
| config | 86 | 0 | 0 | 1 | 85 |

Skip reasons among 5,168 route-count lines: `ratio_too_high` 2713, `error_protected` 1449, `lossy_unrecoverable_skipped` 535 (`cache_control_protected` 4486 is a separate gate).

Only 7 requests in 31 h had pipeline reduction >50% on inputs >300 tokens: 5 `log` (avg 71.8%, max 97.2%) and 2 `code_aware` (avg 60.4%, max 70.4%).

`text` (the Kompress path) had essentially no aggressive compressions here, so Kompress word-dropping does not explain these hits. Tool names (Read/Bash/Agent) are not logged next to strategies, so the fraction of aggressive `log` uses that hit source or exact-text output is unknown.

### 4. Local reproduction (partial)

Built `headroom._core` with `maturin develop` and ran `ContentRouter` on synthetic payloads shaped like A–D (placeholder names).

| Payload | Routed to | Content changed in this container? |
|---|---|---|
| Space-to-`·` source | LOG | No |
| Repeated `WARNING:` blocks + `deleted X` lines | LOG | No |
| `cat -n` C# | TABULAR | No |
| `cat -n` markdown with code blocks | TABULAR | No |
| Raw C# / raw markdown | MIXED | No |

Routing for the first two matches production. The `cat -n` C# case does **not**: production used `code_aware`, this container used TABULAR. This container fell back to pure-Python content detection ("Native content detection requires ONNX Runtime 1.24+"), so the native detector's behaviour on line-numbered text is unverified. Output equalled input in every case here, so what each strategy drops was not observed.

## Hypotheses (ranked by support)

1. **Content-type misdetection routes non-log text to `log`.** Words like `error`/`WARNING` inside code (`catch (error)`, `console.log(error)`) or CLI stderr banners appear to push whole results to `log`. The log compressor keeps lines that look important (error-like) and drops the rest, so quiet lines carrying the real result are the ones lost. Supported by A and B in production logs.
2. **Exact-text tool results are compressed lossily at all.** `code_aware` removed 42% of a source file read verbatim (C). Models then burn effort re-reading via other tools, often through workarounds that defeat the savings.
3. **Line-number prefixes (`cat -n`) may change detection.** In pure-Python detection they flip source code and markdown to TABULAR (csv, tab-delimited, 2 columns, confidence ≈0.86). Unconfirmed against the native detector. Note that `Read` is in `DEFAULT_EXCLUDE_TOOLS` (`headroom/config.py:222`), so a Claude Code Read result should not be compressed at all by default; hit D (a subagent's Read) is therefore **unexplained**. Possible reasons: the tool-name lookup fails for subagent or SDK-driven requests, the exclusion is overridden in the deployment, or the garbling did not come from this router. Bash is not excluded, which fits A–C.
4. **The model cannot distinguish "words/lines removed" from "content corrupt".** Even when a retrieval marker exists, models report "garbled" and reconstruct from inference (D), which is a correctness risk beyond wasted tokens.

Not supported: the five causes already fixed (prose banner typed as JSON, Kompress short-text floor, SmartCrusher CSV string spliced into prose, `ensure_ascii` escapes, "items" marker wording). None of A–E matches them.

## Limitations

- Hits A–C are matched to requests by timestamp and size only.
- Sessions from 2026-09-16 to 2026-10-18 (about half the hits) predate the logged revision and cannot be analysed this way.
- Whether a retrieval marker was visible to the model in each case is unchecked; marker text is not logged.
- No evidence that a negation or critical word was dropped in any case; hit E, which looked like a contradiction, appears to be a script quirk.
- All payloads in this report are reconstructed or sanitized; no customer source is included.

## Proposed fixes (not started)

1. **Detection:** do not route to `log` when the input is mostly source code or has code-like syntax/indentation; ignore `cat -n`/`nl` line-number prefixes in detection.
2. **Exact-text guard:** skip lossy strategies (`log`, `code_aware`) for tool results from file-reading commands (`cat`, `git show`, Read), or require a visible retrieval marker when lines are removed.
3. **Floor on `log`:** a minimum retained fraction (e.g. 0.5) for inputs under a few hundred lines. Today more than half of `log` uses (98 of 180) remove over 70%.
4. **Observability:** log the tool name next to strategy and ratio, so aggressive compressions can be audited per tool type.

## Questions for maintainers

1. Is `log` on code-shaped content a known/accepted tradeoff, or a bug?
2. `Read` is excluded by default, `Bash` is not. Is excluding `Bash` wholesale acceptable, or is there a way to exclude only file-reading shell commands (`cat`, `git show`, `sed -n`)? Also: can the exclusion silently fail for subagent requests (hit D)?
3. Does the native detector treat `cat -n` output differently from the pure-Python detector?
4. Would you accept PRs for fixes 1–2 (with tests) and fix 4 (logging)? Fix 3 changes compression behaviour and may need your call on the threshold.

## Appendix: reproduction

Requires the Rust core (`maturin develop --release -m crates/headroom-py/Cargo.toml`).

```python
from headroom.transforms.content_router import ContentRouter, ContentRouterConfig

W = ("WARNING: Warning! If you have soft-delete protection enabled on this key vault, "
     "this secret will be moved to the soft deleted state. You will not be able to create "
     "a secret with the same name within this key vault until the secret has been purged "
     "from the soft-deleted state. Please see the following documentation for additional guidance.\n"
     "https://learn.microsoft.com/azure/key-vault/general/soft-delete-overview\n")
warn = "".join(W + f"deleted secret Secret{c}\n" for c in "ABCDEFGH") + W + "deleted certificate Cert\n"

res = ContentRouter(ContentRouterConfig()).compress(warn)
print(res.strategy_used)   # LOG
```
