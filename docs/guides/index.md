# Guides

Task-oriented walkthroughs to create agent-plugins and agent stacks.

New here? Start with
[create-agent-stack.md](create-agent-stack.md). It builds and runs a
stack from plugins already packaged in this repo, so there is nothing
to import first. If you use Flox,
[create-agent-stack-with-flox.md](create-agent-stack-with-flox.md)
makes the same kind of stack with `flox install` and FloxHub, with no
flake to write.

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
   this repo, from yours, or from both. With the Flox CLI, the stack
   is a Flox environment on FloxHub instead —
   [create-agent-stack-with-flox.md](create-agent-stack-with-flox.md).
3. **Use the agent stack.** Run its launcher, which stages the
   plugins into the shape that harness expects —
   [create-agent-stack.md](create-agent-stack.md#4-run-it), or
   [create-agent-stack-with-flox.md](create-agent-stack-with-flox.md#6-run-it-from-floxhub)
   for a stack on FloxHub.

| Guide | What it walks through |
| ----- | --------------------- |
| [create-agent-plugin.md](create-agent-plugin.md) | Create an agent-plugin package from an existing skills repository |
| [create-agent-stack.md](create-agent-stack.md) | Create and use an agent-stack with harness and agent-plugins packages |
| [create-agent-stack-with-flox.md](create-agent-stack-with-flox.md) | Create an agent stack with the Flox CLI, push it to FloxHub, and run it from there |
