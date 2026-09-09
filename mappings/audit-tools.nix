# Default audit tools a stack's audit script puts on PATH.
#
# `flox-agent audit` probes PATH for the tools it knows: skill-tools,
# skill-validator, claudelint, agnix, cclint, skillcheck, skillspector.
# Whatever is present is used; whatever is missing is skipped, so an
# empty list still produces a working audit.
#
# Entries land here as these tools are packaged into agent-pkgs.
# Until then a stack audits with whatever the consumer already has,
# and `audit.tools` lets a stack pin its own set.
{ pkgs }:

[ ]
