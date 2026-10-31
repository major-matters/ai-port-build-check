# Security

The AEO Citation Tracker is read-only and bring-your-own-keys. Its threat surface is small by design.

- **No live probing.** It sends queries to four fixed, hardcoded provider endpoints (Anthropic, Perplexity, OpenAI, Google) and reads the answers. It does not fetch the cited URLs or connect to anything else.
- **Keys stay local.** API keys are read from files (`.anthropic-api-key`, `.perplexity-api-key`, ...) or environment variables and are never written to the database, logs, or output. Error strings are redacted so a key in a request URL (Gemini) cannot leak.
- **No injection surface.** All SQL uses parameterized queries; queries you supply are sent only as prompt text to the LLM APIs.
- **Nothing secret is committed.** Key files and the local `aeo.db` are gitignored.

This is a v0 research tool. Open an issue for anything that looks like a key leak or an SSRF path.
