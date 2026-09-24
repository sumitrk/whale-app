# Call OpenRouter directly for AI Actions

Supersedes [0001](0001-bundle-pi-as-the-local-agent-runtime.md).

Whale sends each AI Action to OpenRouter as a single chat completion from Swift (`OpenRouterClient`), instead of routing it through a bundled Pi subprocess. In practice Pi was running with every agent capability turned off (no tools, extensions, skills, or sessions), so it was doing the job of one HTTP request. In exchange it added a 73 MB binary downloaded at build time, a subprocess to supervise, an extra executable to sign with JIT entitlements, and a build step that fails on machines where the binary cannot run.

When AI Actions need multi-turn Agent Runs with Tools, the plan is to write that loop in Swift using OpenRouter's OpenAI-compatible tool-calling API, rather than bring back a separate runtime.
