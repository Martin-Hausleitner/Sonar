# Sonar Skills Newsletter Repo Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a public GitHub repo `sonar-skills` that acts as a newsletter-style changelog for Sonar-specific Claude Code skills. Subscribers (RSS or GitHub Watch → Releases) get notified whenever a new skill ships. Each skill is a valid Claude Code skill folder that anyone can drop into their own project.

**Why a separate repo and not just a folder in `Sonar/`:**
- Newsletter mechanic needs its own release cadence — Sonar app releases shouldn't drag every skill update along, and skill updates shouldn't pollute the Sonar release tag list.
- Separate watchers: people interested in the *iOS app* are not necessarily the same as people interested in *automation around it*.
- Skills can be installed standalone without cloning the whole Sonar repo.

**Architecture:** GitHub Releases is the newsletter UI (RSS + email-via-Watch are already built into GitHub). Repo is read-only for subscribers; each release = a curated post about one or more new/updated skills. Skills live in `skills/<name>/SKILL.md`, conforming to the Claude Code skill spec so they are directly usable.

**Tech Stack:** Markdown, GitHub Releases, GitHub Actions (lint), `gh` CLI for repo creation.

---

## Repo Layout

```
sonar-skills/
├── README.md                       # landing page, skill index, subscribe instructions
├── CHANGELOG.md                    # human mirror of GitHub Releases
├── skills/
│   ├── release-sidestore/
│   │   └── SKILL.md
│   └── pairing-diagnose/
│       └── SKILL.md
└── .github/
    └── workflows/
        └── lint-skills.yml         # validate SKILL.md frontmatter on PR
```

---

## Newsletter Mechanism

- **Primary**: GitHub Releases. Each release = one newsletter post.
  - RSS feed: `https://github.com/<owner>/sonar-skills/releases.atom`
  - Email: GitHub Watch → Custom → Releases (subscribers opt in)
- **Mirror**: `CHANGELOG.md` updated alongside each release for in-repo browsing.
- **No website, no SSG, no email service** — GitHub Releases is the newsletter UI.

---

## Initial Skill Slate (v0.1.0)

Two skills for the launch release. Picked because both have validated source material in this repo and in auto-memory:

1. **`release-sidestore`** — wraps the validated `make publish` + `apps.json` flow. Source: `Makefile`, `feedback_release_flow.md` memory ("SideStore-source release flow is correct").
2. **`pairing-diagnose`** — diagnoses pairing failures (QR scan-receive, Tailscale IP not surfacing, distance ring flicker). Source: `docs/connection-guide.md`, `docs/pairing.md`, `docs/hardware-connection-verification.md`, `project_open_issues.md` memory.

Deferred to later releases: `audio-latency-probe`, `e2e-relay-runner`.

---

## Tasks

### Task 1: Create the public GitHub repo

- [ ] **Step 1: Confirm repo name and owner with user**
  - Default: `sonar-skills` under personal account (`gh repo view` shows current default).
  - Alternative: a future `sonar` org if/when one exists.

- [ ] **Step 2: Create repo via `gh`**
  ```sh
  gh repo create sonar-skills \
    --public \
    --description "Claude Code skills for Sonar — pairing, audio, release flow. Watch → Releases to subscribe." \
    --license MIT
  ```
  Clone locally to `~/Documents/GitHub/sonar-skills/`.

### Task 2: Scaffold structure

- [ ] **Step 1: Write `README.md`**
  - Section: *What this is* (newsletter-style changelog of Sonar Claude skills, not a plugin marketplace).
  - Section: *Subscribe* — instructions for GitHub Watch → Custom → Releases, and the `releases.atom` RSS URL.
  - Section: *Skill index* — table with name | one-liner | link to `skills/<name>/SKILL.md`.
  - Section: *Install a skill* — copy folder into your project's skills directory; one-line `cp` example.
  - Section: *Related* — link back to the main Sonar repo.

- [ ] **Step 2: Write `CHANGELOG.md`**
  - Single H1 + an `## Unreleased` placeholder. Real entries appear after the first release.

- [ ] **Step 3: Create empty `skills/` directory** with a `.gitkeep` until the first skill lands.

### Task 3: Author skill `release-sidestore`

- [ ] **Step 1: Draft `skills/release-sidestore/SKILL.md`**
  - Frontmatter: `name`, `description` (specific enough that another Claude instance picks it up when the user asks for a release), trigger phrase examples.
  - Body: numbered steps for the publish flow — `make publish`, version bump, `apps.json` update, sanity checks, what success looks like.
  - Cross-reference: link to the relevant Makefile target line and the apps.json file in the Sonar repo.

- [ ] **Step 2: Dry-run the skill against the current Sonar repo**
  - Read the SKILL.md as if I were a fresh Claude in the Sonar repo with no memory.
  - Verify every command and file path exists and works as written. Fix any drift.

### Task 4: Author skill `pairing-diagnose`

- [ ] **Step 1: Draft `skills/pairing-diagnose/SKILL.md`**
  - Frontmatter as above.
  - Body: a decision tree — what to check for QR scan-receive failure, Tailscale IP not surfacing, distance ring flicker. Pull the actual signals/log lines from the code, not generic advice.
  - Reference the open-issues memory items by name so the skill stays anchored to known-current bugs.

- [ ] **Step 2: Verify against current Sonar code**
  - Each diagnostic step must reference a real log string, real file, or real symptom in the current tree. No hallucinated paths.

### Task 5: Lint workflow

- [ ] **Step 1: Write `.github/workflows/lint-skills.yml`**
  - Trigger: PR + push to main.
  - Job: a small shell or Python script that fails the build if any `skills/*/SKILL.md` is missing required frontmatter keys (`name`, `description`).
  - No external dependencies — keep it `grep`/`yq`-based or a 30-line Python file.

### Task 6: First release (v0.1.0)

- [ ] **Step 1: Tag and release**
  ```sh
  git tag v0.1.0
  git push origin v0.1.0
  gh release create v0.1.0 --title "v0.1.0 — first drop" --notes-file release-notes-v0.1.0.md
  ```
- [ ] **Step 2: Write release notes (`release-notes-v0.1.0.md`)**
  - This *is* the first newsletter post. Tone: short, concrete, links to the two skills.
  - Include the subscribe instruction inline so first-time readers know how to get future drops.
- [ ] **Step 3: Mirror notes into `CHANGELOG.md`** under a `## v0.1.0 — YYYY-MM-DD` section.

### Task 7: Cross-link from main Sonar repo

- [ ] **Step 1: Add a *Skills* section to `Sonar/README.md`**
  - One paragraph explaining the sister repo.
  - Link to `sonar-skills` and to the Releases/RSS for subscription.

- [ ] **Step 2: Commit and push to Sonar's claude branch** (or wherever current PRs land — confirm with user before pushing).

---

## Open Decisions (to confirm with user before Task 1)

- **Repo owner**: personal account vs. future `sonar` org. Default: personal.
- **License**: MIT (default), or no license / different one.
- **Versioning**: repo-wide semver vs. per-skill semver. Default: repo-wide for v0.1; revisit if skills evolve at very different rates.
- **First release timing**: ship with two skills as planned, or one to keep the launch tight. Default: two — the newsletter format only makes sense if there's already a small index.

---

## Out of Scope (won't do)

- No plugin-marketplace metadata (`marketplace.json`) — user explicitly chose changelog over marketplace.
- No website / SSG / Substack mirror — GitHub Releases is the newsletter UI.
- No automation that auto-extracts skills from the Sonar repo — manual curation is the value.
- No tracking, analytics, or subscriber list — GitHub handles delivery; we don't see who subscribes, and that's fine.
