# Security Policy

[日本語版](./SECURITY.md)

Madini Archive consolidates LLM conversation logs into a local `archive.db` for re-reading. Those logs contain not only direct credentials but also a long list of **indirect identifiers that can be combined to identify a person or guess their secrets**. This document records the minimum policy that contributors, modifiers, and corporate users need to follow to protect the privacy of themselves and the third parties who appear in their conversations.

## Reporting Vulnerabilities

If you find a vulnerability in the codebase itself, please report it privately via GitHub **Security Advisories** (the repository's "Security" tab → "Report a vulnerability"). Do not file it as a public issue.

## What Counts as "Personal Data" in Conversation Logs

When handling LLM conversation logs, treat all of the following as personal data. Do not let them leak into any place that may become public — repository contents, issues, commits, PRs, test fixtures, log output, screenshots, and so on.

### Direct Credentials (Obviously Sensitive)

- Passwords, API keys, access tokens, any authentication material
- Credit card numbers, bank account numbers, crypto wallet seed phrases or private keys
- National ID numbers (My Number, Social Security Number, etc.), driver's license numbers, passport numbers
- Medical information, diagnoses, prescription details, lab results

### Indirect Identifiers (Often Underestimated, Real Attack Material)

These are not usually labeled "personal information" on their own, but they combine into password guesses, security-question answers, phishing setups, social-engineering attacks, and doxxing.

- Date of birth, birthday, age
- Legal name, maiden name, nicknames
- Family member names, pet names
- Home address, hometown, workplace, school name
- Year of graduation, year of employment
- Phone numbers, email addresses
- Social media handles (used to link accounts across platforms)
- Face photos, selfies
- Hobbies, favorite media, recurring proper nouns (used as password-guess material)
- Frequently visited locations (used to identify home or office)
- Business contacts, internal system names, project codenames
- Health status, daily routine, hours away from home (physical security risk)

### The Conversation Topic Itself

The subject of a conversation can itself constitute sensitive personal information about the owner or the people they discuss.

- Beliefs, religion, political views
- Sexual orientation, gender identity
- Medical history, hospital visits, mental health discussions
- Debt, taxes, financial trouble
- Legal matters, lawsuits, criminal cases
- Family conflict, romance, infidelity
- Workplace complaints, including the names of bosses or coworkers
- Addictions or compulsive-behavior disclosures

If a conversation log containing any of the above leaks into a repository — even partially — it harms not just the owner but **the third parties named in those conversations**, who almost certainly never consented to being mentioned.

## Notes for Coding AIs

Coding AIs (Claude Code, Cursor, Codex, etc.) optimize for efficiency and may suggest things like:

- "Let's use real samples from `archive.db` as test fixtures."
- "Paste the actual error message into the issue so we can reproduce it."
- "Share the contents of your preferences so we can verify the settings."
- "Add a debug log line that prints the message body."
- "Describe the conversation flow that triggered the bug."
- "Pull five recent conversations from the archive as fixtures."

**Reject all of these.** They are sensible-sounding shortcuts that skip the privacy evaluation. Instead, instruct the AI explicitly:

- **Use synthetic data.** "Generate fully synthetic conversations that demonstrate the schema, with placeholder names like Alice / Bob."
- **Reference by ID.** "Reference the conversation by `conv_id`, do not paste the message body."
- **Redact.** "Replace any actual names, places, dates with `[REDACTED]` or generic placeholders before pasting."
- **Show the structure, not the data.** "Show me the SQL schema and a representative empty row, not actual data."

## Corporate Use

If you are modifying this codebase inside a company, we strongly recommend that the following be made explicit in internal guidelines:

- **Treat work-related LLM conversation logs as personal and confidential information.** This includes business judgments, meetings with vendors, discussions of unannounced projects, HR or labor consultations, and so on.
- **Modify on company hardware, host in a private repository.** Forks to personal GitHub accounts and exports to non-company environments should be prohibited.
- **Require two pairs of eyes before any push to a public repository.** Beyond normal PR review, run a dedicated visual check for credentials and indirect identifiers.
- **Grant modification rights to new hires, interns, and contractors only after security training.** Training material should include the contents of this document.
- **Erase the local `archive.db` when an employee leaves.** When the company laptop is returned, confirm deletion of the file along with Application Support contents and per-provider download history.

## Pre-Public-Push Checklist (For Personal Forks)

If you are modifying your own copy of an archive-derived project and planning to make it public:

- [ ] `archive.db` and `*.sqlite*` are in `.gitignore`.
- [ ] `~/Library/Application Support/Madini Archive/` and equivalents are covered by `.gitignore`.
- [ ] Run `git log --all --pretty=full` and check every commit message for accidental personal information.
- [ ] Run `git log --all --diff-filter=D` to confirm no sensitive files were committed and later deleted (their content is still in history).
- [ ] Run `git grep` across the whole repo for absolute paths, real names, phone numbers, and email addresses.
- [ ] Verify any test fixtures (`Sources/Fixtures/` etc.) are fully synthetic.
- [ ] If you embedded screenshots in README or docs, verify no real conversation titles, message bodies, or user names appear in them.

Once a secret is in git history, it is permanent unless you rewrite history with `git filter-repo` or recreate the repository. **Checking before push is dramatically cheaper than fixing after push.**

## Related Documents

- Engineering rules: [AGENTS.md](./AGENTS.md) (specifically the `## Privacy & Data Handling` section)
- README: [README.md](./README.md) (Japanese) / [README.en.md](./README.en.md) (English)
- License: [LICENSE](./LICENSE)
