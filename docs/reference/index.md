# Reference

Precise contracts for agent-pkgs' interfaces.

| Doc | What it covers |
| -------------------------------------------- | -------------- |
| [import-contract.md](import-contract.md) | The import→builder contract: the generated file shape, skill selection, output layout, passthru schema |
| [build-agent-plugin.md](build-agent-plugin.md) | Every `buildAgentPlugin` argument, the runtime substitution pass, the extension point |
| [mk-agent-stack.md](mk-agent-stack.md) | The `mkAgentStack` public API: harness forms, outputs, what fails to evaluate |

The `flox-agent` commands these contracts meet — `import`,
`check-plugin`, `launch` — are documented in the flox-agent repo under
`docs/reference/`. These pages link there instead of describing them a
second time.
