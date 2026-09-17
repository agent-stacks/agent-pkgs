# Guides

Task-oriented walkthroughs. Where a guide needs a precise rule it
links to [reference/](../reference/index.md) rather than paraphrasing
it, and where a step belongs to `agent-stacks` it links to that repo.

## The workflow

A stack is built in three steps, each consuming what the last
produced:

1. **Create agent-plugin packages.** Pin an upstream skills repository
   and build it into the canonical spec layout —
   [create-agent-plugin.md](create-agent-plugin.md). Public skills
   belong in this repo, under `pkgs/`, where CI and the binary cache
   carry them; private ones belong in a repository of your own.
2. **Create an agent-stack package.** Compose a harness package with
   the agent-plugins from step 1 —
   [create-agent-stack.md](create-agent-stack.md). Stacks are
   typically defined in a repository of your own, over plugins from
   this repo, from yours, or from both.
3. **Use the agent stack.** Run its launcher, which stages the
   plugins into the shape that harness expects —
   [create-agent-stack.md](create-agent-stack.md#3-use-the-stack).

Steps 2 and 3 share a page because a stack is not worth creating
without running it, and what the launcher does is the argument for how
the stack is composed.

| Guide | What it walks through |
| ----- | --------------------- |
| [create-agent-plugin.md](create-agent-plugin.md) | Create an agent-plugin package from an existing skills repository, from import to pull request |
| [create-agent-stack.md](create-agent-stack.md) | Create an agent-stack package from a harness package and agent-plugins, and run it |
