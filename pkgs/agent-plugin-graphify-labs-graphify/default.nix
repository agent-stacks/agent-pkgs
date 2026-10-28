# agent-plugin-graphify-labs-graphify — graphify's Claude Code skill.
#
# Written by hand: upstream ships the skill as graphify/skill.md, package
# data `graphify install` copies to ~/.claude/skills/graphify/SKILL.md, so
# `agent-stacks import` finds no SKILL.md and writes nothing (agent-pkgs
# ADR 0027, "A plugin import cannot read is written by hand").
# The hourly replay does not reach this package; bump `version` and
# `hash` together for a new upstream release.
{
  buildAgentPlugin,
  fetchFromGitHub,
  runCommand,
}:

let
  version = "0.9.97";

  upstream = fetchFromGitHub {
    owner = "Graphify-Labs";
    repo = "graphify";
    tag = "v${version}";
    hash = "sha256-MCzEVYnC5L/lsLEq0Orqn64AP+xVk3S7jf1p1K+ESyA=";
  };

  # The skill as `graphify install` lays it out for Claude Code: skill.md
  # as SKILL.md, with the claude bundle's references/ beside it.
  src = runCommand "graphify-skill-${version}" { } ''
    mkdir -p $out/skills/graphify
    cp ${upstream}/graphify/skill.md $out/skills/graphify/SKILL.md
    cp -r ${upstream}/graphify/skills/claude/references $out/skills/graphify/references
  '';
in
buildAgentPlugin {
  name = "graphify-labs-graphify";
  inherit version src;
  sourceUrl = "https://github.com/Graphify-Labs/graphify";
  manifest = {
    "$schema" = "https://agent-plugins.org/schemas/1.1.0/plugin.schema.json";
    name = "graphify-labs-graphify";
    inherit version;
    description = "Turn any folder of code, docs, papers, images, or videos into a queryable knowledge graph";
    homepage = "https://graphify.com";
    repository = "https://github.com/Graphify-Labs/graphify";
    license = "Apache-2.0";
  };
  skills.graphify = "skills/graphify";
  # The skill ships no scripts. Its steps import the user's graphify,
  # found through the graphify CLI on PATH, else python3; the CLI is a
  # separate package (ADR 0011).
  requiredRuntimes = [ ];
}
