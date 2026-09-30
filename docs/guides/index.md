# Guides

Task-oriented walkthroughs to create agent-plugins and agent stacks.

## The workflow

A stack is built in three steps:

1. **Create agent-plugin packages.** Pin an upstream skills repository
   and build it into the canonical spec layout —
   [create-agent-plugin.md](create-agent-plugin.md). Many public skill
   examples are in this repo, under `pkgs/`, so you can skip this step
   if you want to use a pre-existing plugin package. Private plugin
   packages should be maintained in your own repository.
2. **Create an agent-stack package.** Compose a harness package with
   the agent-plugins from step 1 —
   [create-agent-stack.md](create-agent-stack.md). Stacks are
   typically defined in a repository of your own, over plugins from
   this repo, from yours, or from both.
3. **Use the agent stack.** Run its launcher, which stages the
   plugins into the shape that harness expects —
   [create-agent-stack.md](create-agent-stack.md#3-use-the-stack).

| Guide | What it walks through |
| ----- | --------------------- |
| [create-agent-plugin.md](create-agent-plugin.md) | Create an agent-plugin package from an existing skills repository |
| [create-agent-stack.md](create-agent-stack.md) | Create and use an agent-stack with harness and agent-plugins packages |
