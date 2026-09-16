# Re-exported packages that are agents rather than agent tooling.
#
# Exceptions only: every re-exported package not named here reads
# category = "agent-tool". That default is deliberate. Upstream adds
# packages daily, so an agent nobody has listed yet reads "agent-tool"
# — understated, never broken — and this list rots slowly and visibly
# instead of failing. ADR 0014.
#
# The rule: "agent" is a package whose main program is the agent you
# converse with or that autonomously does the work. Anything that
# monitors, proxies, orchestrates, sandboxes, reviews, remembers for,
# or otherwise supports an agent is "agent-tool", as is a general
# developer tool that happens to be packaged here.
{
  amp = "agent";
  antigravity-cli = "agent";
  aperant = "agent";
  autolith = "agent";
  chatgpt = "agent";
  claude-agent-acp = "agent";
  claude-code = "agent";
  claw-code = "agent";
  cline = "agent";
  code = "agent";
  codex = "agent";
  codex-acp = "agent";
  command-code = "agent";
  copilot-cli = "agent";
  crush = "agent";
  cursor-agent = "agent";
  droid = "agent";
  dsh = "agent";
  eca = "agent";
  forgecode = "agent";
  freebuff = "agent";
  fx = "agent";
  gemini-cli = "agent";
  gitclaw = "agent";
  goose-cli = "agent";
  grok = "agent";
  hax = "agent";
  hermes-agent = "agent";
  ironclaw = "agent";
  jcode = "agent";
  jules = "agent";
  junie = "agent";
  kilocode-cli = "agent";
  kimi-code = "agent";
  letta-code = "agent";
  mimo-code = "agent";
  mistral-vibe = "agent";
  muse-code = "agent";
  nanocoder = "agent";
  omo-ai = "agent";
  omp = "agent";
  openclaw = "agent";
  opencode = "agent";
  opencode2 = "agent";
  openfang = "agent";
  pi = "agent";
  picoclaw = "agent";
  prime-agent = "agent";
  qoder-cli = "agent";
  qoder-cli-cn = "agent";
  qwen-code = "agent";
  reasonix = "agent";
  vix = "agent";
  zaly = "agent";
  zcode = "agent";
  zeroclaw = "agent";
}
