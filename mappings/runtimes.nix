# Runtime name-mapping table: interpreter names as they appear in
# skills (shebangs, mcp.json commands) mapped to nixpkgs attribute
# names. Consumed by the substitution pass in buildAgentPlugin.
#
# A detected name that is neither here nor in the plugin's `runtimes`
# argument fails the build with a message pointing at this file.
# Per-plugin version pins go through `runtimes`
# (e.g. `runtimes.python3 = python312;`), never through this table.
#
# Keep the table lean. Every mapped runtime a plugin's files mention
# becomes a build input of that plugin, so map names skills actually
# use in the wild.
{
  bash = "bash";
  sh = "bash";
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
