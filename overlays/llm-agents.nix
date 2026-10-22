# Applies overrides/ to the llm-agents set. Compose it after
# llm-agents.nix's shared-nixpkgs overlay. ADR 0024.
#
# A name upstream no longer has is skipped, so it can't break
# evaluation; the overrides-name-packages check fails on it instead.
let
  overrides = import ../overrides;
in
final: prev: {
  llm-agents = prev.llm-agents // builtins.mapAttrs
    (name: f:
      let p = prev.llm-agents.${name}; in
      final.lib.throwIfNot (p ? overrideAttrs)
        "overrides/default.nix names ${name}, which has no overrideAttrs"
        (p.overrideAttrs f))
    (builtins.intersectAttrs prev.llm-agents overrides);
}
