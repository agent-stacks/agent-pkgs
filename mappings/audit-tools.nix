# Default audit tools: what a stack's audit script puts on PATH.
#
# The stack audit is a security audit by NVIDIA SkillSpector alone:
# `agent-stacks audit` runs `skillspector` from PATH and scores each
# plugin from its findings. So the default is that one package, built
# here from pkgs/skillspector, and a stack's audit carries it in its
# closure instead of depending on a copy the consumer installed.
#
# `audit.tools` in a mkAgentStack call replaces this list, for a stack
# that wants a different SkillSpector, or other tools, on that PATH.
{ pkgs, skillspector }:

[ skillspector ]
