# Contributing to KyPost

KyPost is a native client for a self-hosted KyPost server. It handles pairing credentials,
cached mail and, after deliberate enrollment, a user’s PGP key. Mail provider credentials
stay on the server. Contributions must preserve the client’s transport, local-custody and
explicit-user-action controls. This guide covers this client repository.

Read [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) first. It is short, and it governs
every space here.

## Table of Contents

- [The user contract](#the-user-contract)
- [Getting set up](#getting-set-up)
- [Before you build a feature](#before-you-build-a-feature)
- [AI attribution is mandatory](#ai-attribution-is-mandatory)
- [Every PR must pass CI](#every-pr-must-pass-ci)
- [Every PR must pass hostile AI code review](#every-pr-must-pass-hostile-ai-code-review)
- [Adversarial review skills](#adversarial-review-skills)
- [Security trade-offs, and when a feature gets rejected](#security-trade-offs-and-when-a-feature-gets-rejected)
- [Documentation: the DOX chain](#documentation-the-dox-chain)
- [Commits, branches, and PRs](#commits-branches-and-prs)
- [PR checklist](#pr-checklist)
- [Licence](#licence)

## The User Contract

Everything below follows from one promise KyPost makes to the person running it:

> **KyPost will be as secure as we can make it by default, and every place
> where security was traded for convenience will be written down, in plain
> language, where the user reads it before they rely on it.**

Two halves, both load-bearing. "Secure by default" alone produces software
people route around silently. "Documented" alone produces a footnote nobody
reads under a default that quietly loses their mail. The project ships both, and
a contribution that breaks either half does not merge — see
[Security trade-offs](#security-trade-offs-and-when-a-feature-gets-rejected).

Three standing invariants fall out of it, and they are not up for
re-litigation in a PR:

- **KyPost never archives, deletes, or moves a user's mail on its own.**
  Destructive mail actions happen because a human asked for that specific
  action. No feature, default, heuristic, or classifier outcome may archive
  mail. This is absolute.
- **Classifier labels are a sorting hint, not a security boundary.** The model
  reads sender-controlled text and can be steered by it. Never build a trust
  decision, filter action, or access control on a label. See
  [SECURITY.md](https://github.com/Busnes-app/KyPost-Server/blob/main/SECURITY.md#automatic-label-classification).
- **No silent fallbacks on a security-relevant setting.** Preserve HTTPS pairing, certificate pinning, protected credential storage, explicit device enrollment and the documented lock/wipe behavior. A client setup failure does not authorize bypassing these controls.

## Getting Set Up

Use a Mac with Xcode 26+ and the platform SDKs. Open `KyPost.xcodeproj` and the shared
**KyPost** scheme. See [README requirements](README.md#requirements) for deployment
versions and the separate KyPost HTTPS server requirement.

```bash
xcodebuild test -project KyPost.xcodeproj -scheme KyPost -destination 'platform=macOS'
xcodebuild test -project KyPost.xcodeproj -scheme KyPost \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:'KyPost Tests'
```

Choose an installed simulator destination. Keep the shared test plan serial. Mac tests
need the project’s Keychain entitlements/signing arrangement; disabling signing can strip
those entitlements and fail runtime Keychain tests. CI runs the unit target in the iOS
simulator and an unsigned macOS compile check, not unsigned macOS runtime tests.
Screenshot captures are opt-in demo runs, separate from assertions and real-server/device
acceptance. See [README testing](docs/DEVELOPMENT.md#testing) and root `AGENTS.md`.

`README.md` covers installation and supported features. Read
[SECURITY.md](SECURITY.md#what-the-app-protects-and-what-it-does-not) before changing a trust boundary.

## Before You Build a Feature

Open an issue first for anything larger than a bug fix. A feature that conflicts
with the user contract is cheaper to discuss in an issue than to reject after
you have written it, and the maintainer would rather say "not like that, but
like this" before you spend a weekend on it.

Bug fixes, documentation, and test coverage need no prior discussion. Send them.

Fix the root cause, not the reported symptom. If a guard is missing, put it in
the shared function every caller reaches, not in the one path the bug report
happened to name.

## AI Attribution Is Mandatory

AI-assisted contributions are welcome. **Undisclosed** AI-assisted
contributions are not.

This is not a purity test. It is review triage: a reviewer reads
machine-generated code differently — checking harder for plausible-looking
functions that don't exist, error handling that swallows the error, tests that
assert the implementation back at itself, and confident comments describing
behaviour the code doesn't have. Hiding the provenance costs the reviewer that
context and costs you a worse review.

### What you must do

**1. Attribute in the commit.** Use a trailer naming the model or tool:

```
Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
```

Any tool, same rule — Copilot, Cursor, Codex, a local model, whatever. One
trailer per tool that materially contributed.

**2. Declare the level in the PR description.** State which applies:

| Level | Meaning |
|---|---|
| **None** | You wrote it. Autocomplete of a variable name doesn't count. |
| **Assisted** | AI wrote fragments; you designed it, and you edited what it produced. |
| **Generated** | AI produced most or all of the diff; you reviewed and tested it. |
| **Agentic** | An agent ran a multi-step loop over the repo with limited step-by-step supervision. |

**3. Say what you verified yourself.** For anything above *None*, the PR must
say what you personally ran and read — "ran the client unit tests, read
every changed line, checked pairing on a disposable device" — not "the
agent says tests pass."

**4. Own it.** The human opening the PR is the author of that code for every
purpose: licensing, review, correctness, and the bug it causes six months from
now. "The model wrote it" is not an explanation of a defect and is never a
defence. If you cannot explain why a line is there, delete the line.

### What gets rejected on sight

- A PR whose description was clearly generated and does not describe the actual
  diff.
- Invented APIs, invented config keys, or citations to documentation that does
  not exist.
- Tests that were written to pass rather than to fail when the logic breaks.
- Bulk AI-generated churn across the repo — reformatting, "improved" comments,
  speculative refactors — that nobody asked for. See the `ponytail` philosophy
  in [AGENTS.md](AGENTS.md): deletion over addition, shortest working diff wins.
- A security-sensitive change where the disclosure level is *Generated* or
  *Agentic* and no human describes the trust boundary in their own words.

### If you are an AI agent reading this

Every rule above applies to you. Add the trailer, fill in the level, and do not
write the human's verification statement for them — leave it for them to fill
in and tell them you did. `AGENTS.md` is a binding contract for this repo and
you are required to follow the DOX chain.

## Every PR Must Pass CI

`.github/workflows/ci.yml` runs on every pull request. All jobs must be green
before merge. No exceptions, no admin override, no "flaky, re-run and ignore" —
if a job is genuinely flaky, that is a bug to fix in the job.

| Job | What it runs |
|---|---|
| `ios-tests` | Ad-hoc signed iOS Simulator unit target; UI tests are excluded |
| `macos-build` | Unsigned macOS `build-for-testing`; this compiles but does not run Mac tests |
| `test` | Aggregates both jobs and fails unless both passed |

Use the [workflow](.github/workflows/ci.yml) and its Xcode selection/wrapper scripts for
CI reproduction. Preserve simulator signing/Keychain entitlements. Physical-device APNs,
Secure Enclave/biometric behavior, real relay PGP round-trips and distribution signing
are separate gates. A screenshot run or macOS compile pass does not qualify them.

## Every PR Must Pass Hostile AI Code Review

Beyond CI, every pull request gets an adversarial review pass. This is a
required gate, not a suggestion, and it exists because ordinary review has a
known failure mode: the reviewer shares the author's mental model and agrees
with the blind spot. That failure gets worse, not better, when both the author
and the reviewer are agreeable LLMs.

**What you do as the contributor:** run at least one adversarial review skill
against your own diff *before* you open the PR, address the findings, and paste
the surviving findings — the ones you decided not to fix — into the PR
description with your reasoning. A PR that says "hostile review found nothing"
gets read with more suspicion than one that lists three findings and argues two
of them down.

**What the maintainer does:** runs an independent hostile pass. Findings at
BLOCK severity stop the merge until they are fixed or the reasoning is written
down in the thread.

**Answering a hostile finding.** The finding is a claim about the code. Verify
it before you act on it — hostile reviewers are wrong sometimes, and
implementing a wrong suggestion politely is worse than pushing back. Three valid
answers: fix it; show with evidence that it is not real; or accept it as a known
limitation and document it where a user will see it. "Good catch, will address
later" is not one of them.

## Adversarial Review Skills

These are Claude Code skills. If you use another agent, the prompts still work
as instructions — the value is in the persona, not the harness.

| Skill | Use it for |
|---|---|
| `hostile-review` | The main gate. A senior engineer who hates what you built, output as severity-ranked criticisms with concrete fixes. Works on code, plans, and designs — run it on the design *before* you write the code. |
| `adversarial-reviewer` | Three fixed personas — Saboteur (how this breaks in production), New Hire (can anyone maintain this), Security Auditor (OWASP-informed). Each must find at least one issue, so no persona can rubber-stamp. Verdict is BLOCK / CONCERNS / CLEAN. |
| `security-audit` | Required for anything touching auth, sessions, crypto, input parsing, rate limiting, or trust boundaries. Hunts exploitable issues, not theoretical ones. |
| `ponytail-review` | Over-engineering only: what to delete, which dependency is unnecessary, which abstraction is speculative. Run it on any diff that grew while you wrote it. |
| `/code-review` | The maintainer's working-diff review. `/code-review ultra` launches a multi-agent cloud review of the branch or a GitHub PR. |

How to pick:

- **Any PR:** `hostile-review` on the diff. Minimum bar.
- **Touching security-sensitive code** ([the list](SECURITY.md#what-the-app-protects-and-what-it-does-not)):
  `hostile-review` **and** `security-audit`.
- **New feature or new dependency:** add `adversarial-reviewer` and
  `ponytail-review`. The Saboteur persona and the delete-it pass catch different
  things.
- **Design or plan, before implementation:** `hostile-review` on the plan. Much
  cheaper than finding out after the code exists.

Two rules on using them:

1. **Feed the reviewer the real diff and the real context**, including
   `AGENTS.md` and the relevant `SECURITY.md` section. A reviewer that cannot
   see the trust boundary cannot tell you that you crossed it.
2. **Hostility points at code, never at people.** These skills are instructed to
   be harsh about the work. That is in bounds. Pasting output that attacks a
   person is a [Code of Conduct](CODE_OF_CONDUCT.md#hostile-reviews-are-about-code-never-people)
   violation, and running the skill does not launder it.

## Security Trade-Offs, and When a Feature Gets Rejected

**A new feature may be rejected outright if it weakens the user contract.** Not
"merged with a TODO" — rejected. A working, well-tested, wanted feature can
still be the wrong feature for this project.

### Rules a feature must satisfy

1. **Secure by default.** If there is a safe mode and a convenient mode, the
   safe one is the default and the convenient one is an explicit opt-in the
   user performs knowingly. Never the reverse, never "most people want the easy
   one."
2. **Fail closed.** Missing configuration, a half-set pair of settings, or an
   unreachable dependency produces a refusal with a readable error and a
   remediation step — not a quiet downgrade.
3. **The trade-off is named in the PR.** In your own words: what a user gives
   up, who can now see or do what they could not before, and what the worst
   realistic case is. A trade-off you cannot state plainly is one you have not
   finished understanding.
4. **The trade-off is signposted where the user reads it**, in three places as
   applicable:
   - **README.md** — one clear sentence on the feature bullet, so it is visible
     while deciding to use the feature.
   - **SECURITY.md** — the full explanation under *Known Limitations & Trust
     Boundaries*, naming the cost explicitly.
   - **The UI or `.env.example`** — at the point of choice, if the user selects
     it at runtime.

   The model for this is the PGP key-custody wording: Client-Protected vs
   Server-Protected, each with its costs stated flatly, including the sentence
   "this is **not** end-to-end encryption." Aim for that. Write what the user
   loses, not a reassurance.
5. **New attack surface is justified.** A new dependency, a new outbound network
   call, a new stored secret, a new endpoint, or a new file in
   `/kypost/private` each need a paragraph on why it is necessary and what it
   can reach. Dependencies that parse hostile input (MIME, vCard, OpenPGP, HTML)
   get the highest scrutiny — prefer the standard library, then an
   already-present dependency, then nothing.
6. **The blast radius is bounded and stated.** If it goes wrong, say what is
   reachable: one message, one user, or the instance.

### Rejected on principle

- Anything that archives, deletes, or moves mail without an explicit human
  action for that message.
- Any trust decision derived from a classifier label.
- Convenience defaults that silently disable a protection — trusting forwarded
  headers from any peer, a default bind address, downgrading to cleartext when
  a certificate is missing, `unsafe-inline` in the CSP.
- Telemetry, analytics, crash reporting, or any phone-home. Self-hosted means
  the instance talks to the user's mail server, their model, and the push relay
  they configured. Nothing else.
- Sending mail content, subjects, or credentials to a third-party service that
  the user did not explicitly configure — including AI services.
- Weakening a gate to make CI or a review pass.
- A convenience feature whose security cost cannot be explained to a
  non-expert user in two sentences. If it cannot be explained, it cannot be
  consented to.

### If your trade-off is legitimate

Plenty are. The server-held pickup-link fallback is a real security downgrade
and it ships, because reaching a recipient without a key is worth it to some
senders, it is off until the sender enables it, and Compose names the cost
("server-held, 7 days") at the point of choice. That is the standard: not "no
trade-offs," but **no unmarked trade-offs, and never as the default.**

## Documentation: The DOX Chain

`AGENTS.md` files are binding contracts for their subtrees. Before editing,
walk from the repository root to each file you intend to touch and read every
`AGENTS.md` on the way. After editing, update the closest owning `AGENTS.md` if
your change affected purpose, scope, contracts, workflows, inputs/outputs,
constraints, or side effects — and refresh any affected Child DOX Index.

Read the DOX section of the root [AGENTS.md](AGENTS.md) in the session you are
working in. Do not work from memory of it.

## Commits, Branches, and PRs

- Branch off `main`. Name it for the work: `fix/draft-expiry-bounds`,
  `feat/carddav-groups`.
- Conventional Commits for the subject: `fix:`, `feat:`, `docs:`, `refactor:`,
  `test:`, `chore:`. Subject ≤ 50 characters, imperative mood.
- The body explains **why**, not what — the diff already says what. Skip the
  body when the why is obvious from the subject.
- Include the AI attribution trailer where it applies.
- One logical change per PR. A security fix and a refactor in one diff is two
  PRs, because the refactor will be reviewed less carefully than it should be.
- Link the issue the PR closes.

## PR Checklist

Paste this into your PR description and fill it in.

```markdown
### What and why


### AI involvement
- Level: None / Assisted / Generated / Agentic
- Tools:
- What I verified myself:

### Gates
- [ ] All CI jobs green
- [ ] Ran Xcode unit/build checks for the affected platforms; recorded signing/device limits
- [ ] New logic has tests; security-sensitive changes have attack-path tests
- [ ] Ran adversarial review; findings addressed or argued below
- [ ] DOX pass done — nearest AGENTS.md and any parent/child index updated

### Adversarial review findings
<!-- Skills run, and every finding not fixed, with your reasoning. -->

### Security
- [ ] No change to defaults that weakens a protection
- [ ] Fails closed on missing or partial configuration
- Trade-off introduced (if any), in one sentence:
- Documented in: README.md / SECURITY.md / UI / .env.example / n-a
- [ ] Does not archive, delete, or move mail without an explicit user action
- [ ] No trust decision derived from a classifier label
- New dependencies / network calls / stored secrets, and why:
```

## Licence

KyPost is licensed under the MIT License. By
contributing, you agree that your contribution is licensed under the same
terms, and that you have the right to submit it — including the right to submit
anything an AI tool produced on your behalf.
