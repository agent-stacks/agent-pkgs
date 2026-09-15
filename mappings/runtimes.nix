# Runtime name-mapping table: interpreter names as they appear in
# skills (shebangs, mcp.json commands) mapped to nixpkgs attribute
# names. Consumed by the substitution pass in buildAgentPlugin.
#
# A detected name that is neither here nor in the plugin's `runtimes`
# argument fails the build with a message pointing at this file.
# Per-plugin version pins go through `runtimes`
# (e.g. `runtimes.python3 = python312;`), never through this table.
#
# Keep the table lean. The builder consults it only for the tokens a
# package records in `requiredRuntimes` (a hand-written call with no
# such record gets the whole table instead), so map names skills
# actually use in the wild rather than every name that might appear.
#
# A row arrives with a package that exercises it, in the same pull
# request, and never on its own. A row nothing uses cannot be shown to
# work and cannot be shown to be wrong. That standing rule is also why
# this table stays in agent-pkgs rather than moving into flox-agent
# alongside the scanner: a row and the package that exercises it must
# land together, in one review, and splitting the table across
# repositories would turn adding a row into a release plus a version
# bump instead of one pull request.
#
# No name has yet turned up that could not be mapped at all. A sweep of
# 44 packages — everything on main plus every repository the pending
# migrations name — found one unmapped name, `bun`, mapped below with
# the three Anthropic plugins that call it (AI-726), and nothing
# unmappable. The overlay mechanism proposed for skills we do not
# control is therefore unbuilt, deliberately: it answers a problem that
# has not appeared. Revisit it when a skill names something nixpkgs has
# no attribute for.
{
  bash = "bash";
  sh = "bash";
  bun = "bun";
  node = "nodejs";
  nodejs = "nodejs";
  python = "python3";
  python3 = "python3";

  # Launchers, not interpreters. Each resolves what it runs from the
  # network, so mapping the name makes the closure complete for the
  # launcher and not for what it launches (AI-565).
  npx = "nodejs";
  uv = "uv";
}
