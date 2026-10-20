{
  description = "Nix package set for Agent Plugins and Agent Stacks";

  # The cache the agent CLIs re-exported from llm-agents.nix are built
  # into upstream. Whether a path hits depends on it having been built
  # from inputs identical to ours, which the two nixpkgs revisions
  # currently agree on for a good part of the set; where they do not,
  # Nix treats the miss as a miss and builds. Offered rather than
  # imposed: an untrusted user gets a warning and no substituter, which
  # costs build time and nothing else.
  nixConfig = {
    extra-substituters = [ "https://cache.numtide.com" ];
    extra-trusted-public-keys = [
      "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
    ];
  };

  inputs = {
    # The Flox nixpkgs fork, not upstream. Publishing to a Flox catalog
    # requires a nixpkgs revision the catalog server has a page for, and
    # those pages track this fork — an upstream revision is rejected
    # with "specifies a page or catalog that does not exist in this
    # instance". Building against the nixpkgs we publish against keeps
    # what we build and what the catalog serves identical.
    nixpkgs.url = "github:flox/nixpkgs/unstable";

    # The agent CLIs themselves — claude-code, codex, opencode and the
    # rest — packaged by numtide and updated daily. Its nixpkgs is
    # deliberately not followed to ours: the set pins its own bun to
    # keep the bun-built packages substitutable, and following would
    # take that pin away.
    llm-agents.url = "github:numtide/llm-agents.nix";

    # SkillSpector's own source at a release tag, for pkgs/skillspector,
    # which builds it from the uv.lock upstream ships there. The tag is
    # the package's version. SkillSpector moves by editing the tag here
    # in a reviewed pull request, never with the hourly update. ADR 0020.
    skillspector-src = {
      url = "github:NVIDIA/SkillSpector/v2.12.0";
      flake = false;
    };

    # What pkgs/skillspector is built with: uv2nix turns that uv.lock
    # into a Python package set, pyproject-nix builds that set, and
    # pyproject-build-systems supplies the build backends the sdists
    # in it need. Libraries evaluated, not packages built, so all three
    # follow our nixpkgs as their READMEs recommend. The hourly
    # flake.lock update leaves them alone: they shape the SkillSpector
    # build the audit's score depends on, so they move only in a
    # reviewed pull request. ADR 0020.
    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, llm-agents, skillspector-src, pyproject-nix, uv2nix, pyproject-build-systems }:
    let
      # Every system this set is built, cached and published for.
      # x86_64-darwin is absent: Intel Macs are not a target.
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];

      # The predicate is scoped to the one pname rather than the whole
      # instance, so anything drifting into another package still fails
      # loudly. It governs only packages built through this flake; a
      # consumer's own nixpkgs config is untouched.
      pkgsFor = system: import nixpkgs {
        inherit system;
        config.allowUnfreePredicate = pkg: nixpkgs.lib.getName pkg == "agent-stacks-bin";
      };

      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f (pkgsFor system));

      # llm-agents.nix built against the nixpkgs above rather than the
      # one it pins. Its own `packages.*` are built against upstream
      # nixpkgs, which the catalog has no page for; the shared-nixpkgs
      # overlay is how that flake supports being rebuilt against a
      # consumer's package set.
      #
      # allowUnfree is on for this instance and this instance only.
      # Roughly a seventh of the set is unfree, upstream adds packages
      # daily, and a name list here would be stale within the week. The
      # narrow predicate above still governs everything under pkgs/.
      llmAgentsPkgsFor = system: import nixpkgs {
        inherit system;
        config.allowUnfree = true;
        overlays = [ llm-agents.overlays.shared-nixpkgs ];
      };

      # Attributes llm-agents.nix exposes that are not packages of this
      # set: the nixpkgs builders and fetchers it patches, its setup
      # hooks, the toolchains it builds its own packages with, and two
      # flake output names. Upstream publishes all of these in its own
      # packages output, so there is no upstream list to defer to —
      # this one is ours, and the re-export-is-packages check fails
      # when upstream grows another.
      #
      # Setup hooks are named here regardless of what platforms they
      # run on. formatelf (auto-formatelf-hook) is Linux-only, so
      # `lib.meta.availableOn` hides it from every check run on
      # aarch64-darwin — it still has to be named explicitly, or it
      # slips back onto packages.x86_64-linux and packages.aarch64-linux
      # unnoticed.
      #
      # bun-bin and go-bin do ship runnable binaries. They are excluded
      # by judgement rather than by rule: they are build inputs for
      # that flake, and nixpkgs already has bun and go.
      #
      # default and formatter are flake output names fixed by the flake
      # schema rather than package names upstream chose, which is why
      # excluding them by name cannot rot the way a package denylist
      # would.
      notPackages = [
        "buildNpmPackage"
        "fetchPnpmDeps"
        "flake-inputs"
        "darwinOpenptyHook"
        "unpinCargoMsrvHook"
        "unpinGoModVersionHook"
        "versionCheckHomeHook"
        "formatelf"
        "codesignCheckHook"
        "bun-bin"
        "go-bin"
        "default"
        "formatter"
        "wrapBuddy"
        "site"
      ];

      # Real packages whose packager omitted meta.mainProgram. Empty
      # today. Listing one here keeps it published and silences the
      # re-export-is-packages check for that name alone.
      notPackagesExempt = [ ];

      # Upstream's packages/ also holds builders, setup hooks and the
      # toolchains it builds with. They are derivations, not functions,
      # so no property distinguishes them from packages — they are
      # named in notPackages above and ADR 0015 records why. Broken and
      # foreign-platform packages are dropped the same way that flake
      # drops them from its own packages output: a package that cannot
      # run on aarch64-darwin has no business being an aarch64-darwin
      # job.
      llmAgentsFor = system:
        let
          pkgs = llmAgentsPkgsFor system;
          keep = name: p:
            !(builtins.elem name notPackages)
            && nixpkgs.lib.isDerivation p
            && nixpkgs.lib.meta.availableOn pkgs.stdenv.hostPlatform p
            && !(p.meta.broken or false);

          # Exceptions only; everything else is an agent-tool. meta is
          # stripped before the derivation is built, so overrideAttrs
          # here changes no store path and rebuilds nothing.
          categories = import ./mappings/agent-categories.nix;
          withCategory = name: p:
            let category = categories.${name} or "agent-tool"; in
            if p ? overrideAttrs
            then p.overrideAttrs (old: {
              meta = (old.meta or { }) // { inherit category; };
            })
            else p;
        in
        nixpkgs.lib.mapAttrs withCategory
          (nixpkgs.lib.filterAttrs keep pkgs.llm-agents);

      # Every subdirectory of pkgs/ with a default.nix is a package.
      # `agent-stacks import --out pkgs/<name>` drops packages here; no
      # central list to edit.
      pluginDirs = pkgs:
        let
          entries = builtins.readDir ./pkgs;
          hasPackage = name:
            entries.${name} == "directory"
            && builtins.pathExists (./pkgs + "/${name}/default.nix");
        in
        builtins.filter hasPackage (builtins.attrNames entries);

      mkLib = pkgs: {
        # Every plugin is validated by the agent-stacks CLI from this set.
        # The reference is lazy: pkgs/agent-stacks is not built by
        # buildAgentPlugin, so naming it here does not recurse.
        buildAgentPlugin = pkgs.callPackage ./lib/build-agent-plugin.nix {
          # The bare binary, not the package wrapped with skillspector on
          # its PATH: a plugin build assembles and checks, never audits,
          # and the wrapper would make every plugin depend on SkillSpector.
          defaultAgentStacks = (mkPackages pkgs).agent-stacks.unwrapped;
        };
        mkAgentStack = pkgs.callPackage ./lib/mk-agent-stack.nix {
          # Every stack runs the agent-stacks CLI from this set. Taken from
          # mkPackages rather than callPackage'd a second time, so the
          # stack runs the same binary as `nix run .#agent-stacks`. The
          # bare binary, not the package wrapped with skillspector on its
          # PATH: a stack launches an agent and never audits, and the
          # launcher passes its environment on, so the wrapper would put
          # skillspector on every agent's PATH and its closure in every
          # stack (ADR 0020). The reference is lazy: pkgs/agent-stacks
          # does not build a stack, so forcing it here does not recurse.
          defaultAgentStacks = (mkPackages pkgs).agent-stacks.unwrapped;
        };
      };

      mkPackages = pkgs:
        let
          lib' = mkLib pkgs;
          # SkillSpector's source and the uv2nix inputs are in scope for
          # pkgs/skillspector, which takes them as arguments; nothing
          # else in pkgs/ names them.
          scope = {
            inherit (lib') buildAgentPlugin mkAgentStack;
            inherit skillspector-src pyproject-nix uv2nix pyproject-build-systems;
          } // built;
          built = nixpkgs.lib.genAttrs (pluginDirs pkgs) (name:
            pkgs.newScope scope (./pkgs + "/${name}") { });
        in
        built;

      # What the catalog is fed from: the plugins built here, plus every
      # agent CLI re-exported from llm-agents.nix. Kept separate from
      # mkPackages so that forcing one plugin does not force the whole
      # re-exported set — mkLib reaches into mkPackages for agent-stacks
      # on every plugin build.
      mkAllPackages = pkgs:
        let
          built = mkPackages pkgs;
          llmAgents = llmAgentsFor pkgs.stdenv.hostPlatform.system;
          # This set owns the name: a package written here is what the
          # catalog serves, and the re-export is shadowed. Warned about
          # rather than tolerated silently, because pkgs/ grows by
          # import and upstream grows daily — a collision is how a
          # plugin quietly stops matching what upstream publishes.
          clashes = builtins.attrNames (builtins.intersectAttrs built llmAgents);
        in
        nixpkgs.lib.warnIf (clashes != [ ])
          "agent-pkgs and llm-agents.nix both define ${toString clashes}; the package from pkgs/ wins"
          (llmAgents // built);

      # The gates alone: mkChecks without the packages. `nix flake
      # check` builds everything `checks` names, and a package built
      # there repeats what Hydra does from `packages.*` — on a GitHub
      # runner, for every package, on every push. Evaluation is not
      # given up with it: flake check evaluates every output, packages
      # included, and builds only what `checks` names.
      mkGates = pkgs: removeAttrs (mkChecks pkgs) (builtins.attrNames (mkPackages pkgs));

      mkChecks = pkgs:
        mkPackages pkgs // {
          # The default runtime packages are this repository's choice,
          # so this repository checks they exist; what the search does
          # with them is asserted in agent-stacks (ADR 0017).
          runtime-defaults-resolve =
            let
              missing = builtins.filter
                (a: !(pkgs ? ${a}) || !(nixpkgs.lib.isDerivation pkgs.${a}))
                (import ./lib/runtime-defaults.nix);
            in
            if missing != [ ] then
              throw ("the default runtime packages are not nixpkgs attributes: "
                + builtins.concatStringsSep ", " missing)
            else
              pkgs.runCommand "runtime-defaults-resolve" { } ''
                touch $out
              '';

          # The list handed to assemble-plugin: a declared dependency
          # ahead of the defaults, a token's own package when nothing
          # was declared, its main program when the binary is not its
          # name, and nothing at all for a record naming no runtime.
          runtime-candidates =
            let
              lib' = mkLib pkgs;
              src = pkgs.runCommand "runtime-candidates-src" { } ''
                mkdir -p $out/skills/one/scripts
                printf -- '---\nname: one\ndescription: Does things.\n---\nBody.\n' \
                  > $out/skills/one/SKILL.md
                printf '#!/usr/bin/env python3\nprint(1)\n' > $out/skills/one/scripts/a.py
                printf '#!/usr/bin/env ruby\nputs 1\n' > $out/skills/one/scripts/b.rb
                printf '#!/usr/bin/env nodejs\n1\n' > $out/skills/one/scripts/c.js
                chmod +x $out/skills/one/scripts/*
              '';
              mk = args: lib'.buildAgentPlugin ({
                name = "runtime-candidates";
                inherit src;
                sourceUrl = "https://example.test/runtime-candidates";
                manifest = {
                  "$schema" = "https://agent-plugins.org/schemas/1.1.0/plugin.schema.json";
                  name = "runtime-candidates";
                };
                skills.one = "skills/one";
                requiredRuntimes = [ "nodejs" "python3" "ruby" ];
              } // args);
              pinned = mk { dependencies = [ "python312" ]; };
              named = mk { };
              empty = mk { requiredRuntimes = [ ]; };
              attrs = p: map (c: "${c.tier}:${c.attr}") p.passthru.agentPlugin.runtimeCandidates;
              expect = what: got: want:
                if got == want then "" else throw
                  ("runtime-candidates: ${what}: handed over ${builtins.toJSON got}, want ${builtins.toJSON want}");
              linksInto = plugin: tok: pkg: ''
                target="$(readlink ${plugin}/share/agent-plugins/runtime-candidates/bin/${tok})"
                case "$target" in
                  ${pkg}/*) ;;
                  *) echo "${tok} -> $target, want ${pkg}" >&2; exit 1 ;;
                esac
              '';
            in
            pkgs.runCommand "runtime-candidates" { } ''
              ${expect "pinned" (attrs pinned)
                [ "declared:python312" "default:bash" "default:python3" "default:nodejs"
                  "named:nodejs" "named:python3" "named:ruby" ]}
              ${expect "empty" (attrs empty) [ ]}
              ${linksInto pinned "python3" pkgs.python312}
              ${linksInto named "python3" pkgs.python3}
              ${linksInto named "ruby" pkgs.ruby}
              ${linksInto named "nodejs" pkgs.nodejs}
              touch $out
            '';

          # A source.json records a licence the manifest spells
          # unusually as a string, an SPDX identifier or a
          # lib.licenses attribute name, and the builder treats one
          # this nixpkgs has no licence for as no licence. That is
          # right for a consumer's nixpkgs and wrong here: in this
          # set a string that does not resolve is a mistyped row in
          # the importer's table, an identifier nixpkgs has no
          # licence for, or an attribute a flake.lock update renamed,
          # and the package would ship with no licence and no
          # complaint. Which names exist is a fact about the
          # nixpkgs this flake pins, so the check is this
          # repository's. ADR 0017.
          license-names-resolve =
            let
              built = mkPackages pkgs;
              unresolved = nixpkgs.lib.filterAttrs (_: name: name != null)
                (builtins.mapAttrs (_: p: p.passthru.agentPlugin.unresolvedLicense or null) built);
            in
            if unresolved != { } then
              throw ("these packages record a meta.license that names no lib.licenses licence: "
                + builtins.concatStringsSep ", "
                (nixpkgs.lib.mapAttrsToList (pkg: name: "${pkg} -> ${name}") unresolved))
            else
              pkgs.runCommand "license-names-resolve" { } ''
                touch $out
              '';

          # agent-sandbox-srt (AI-1015) writes srt's whole settings file on
          # each launch: Claude's hosts and every MCP host the staged
          # plugins name, ~/.ssh denied, Claude's state writable, and the
          # caller's options added on top. The dry run prints the file
          # instead of running srt, so the settings are checked here on
          # every system; the sandbox itself is checked by hand (macOS)
          # until a runner can host it.
          agent-sandbox-srt-contract =
            let srt = "${(mkPackages pkgs).agent-sandbox-srt}/bin/agent-sandbox-srt"; in
            pkgs.runCommand "agent-sandbox-srt-contract" { nativeBuildInputs = [ pkgs.jq ]; } ''
              set -u
              export HOME=$PWD/home TMPDIR=$PWD/tmp AGENT_SANDBOX_SRT_DRY_RUN=1
              # Its own, or a macOS build would make /tmp/claude for the build user.
              export CLAUDE_CODE_TMPDIR=$PWD/agent-tmp
              mkdir -p $HOME $TMPDIR plugins/remote plugins/local
              printf '{"mcpServers":{"seo":{"type":"http","url":"https://app.openseo.so/mcp"}}}' > plugins/remote/.mcp.json
              printf '{"mcpServers":{"cli":{"type":"stdio","command":"x"}}}' > plugins/local/.mcp.json
              export CLAUDE_CODE_PLUGIN_DIRS=$PWD/plugins/remote:$PWD/plugins/local:$PWD/plugins/missing

              ${srt} -- claude --version > s.json 2>cmd
              jq -e '.network.allowedDomains | index("api.anthropic.com") and index("platform.claude.com") and index("app.openseo.so")' s.json
              jq -e '.network.allowedDomains | length == 3' s.json
              jq -e '.filesystem.denyRead | index("~/.ssh")' s.json
              jq -e '.filesystem.allowWrite | index("~/.claude") and index("~/.claude.json")' s.json
              jq -e '.network.deniedDomains == [] and .filesystem.denyWrite == []' s.json
              # On Linux srt runs the bwrap the refusal message names, the
              # one already first on srt's PATH.
              if [ "$(uname -s)" = Linux ]; then
                jq -e '.bwrapPath | endswith("/bin/bwrap")' s.json
                grep -qF "$(dirname "$(jq -r .bwrapPath s.json)")" ${pkgs.sandbox-runtime}/bin/srt ||
                  { echo "bwrapPath is not srt's bwrap"; exit 1; }
              fi
              if [ "$(uname -s)" = Darwin ]; then jq -e 'has("bwrapPath") | not' s.json; fi
              # srt does not follow macOS's /tmp -> /private/tmp link.
              if [ "$(uname -s)" = Darwin ]; then jq -e '.filesystem.allowWrite | index("/private/tmp")' s.json; fi
              # srt points TMPDIR here but does not create it on macOS.
              ${srt} -- true >/dev/null 2>&1
              [ -d agent-tmp ] || { echo "agent TMPDIR not created"; exit 1; }
              # "." is writable, so starting at / or ~ would open the whole disk or home.
              for top in / "$HOME"; do
                if (cd "$top" && ${srt} -- true) >/dev/null 2>err; then echo "started from $top"; exit 1; fi
                grep -q 'project folder' err || { echo "no reason for $top"; cat err; exit 1; }
              done
              grep -q -- '--settings .* -- claude --version' cmd

              ${srt} --options '{"allowedDomains":["example.com"],"allowWrite":["/data"],"denyRead":["~/.aws"]}' -- true > o.json 2>/dev/null
              jq -e '.network.allowedDomains | index("example.com") and index("api.anthropic.com")' o.json
              jq -e '(.filesystem.allowWrite | index("/data")) and (.filesystem.denyRead | index("~/.aws"))' o.json

              for bad in '[1]' '{"allowedDomains":"x"}' '{"allowedDomains":[1]}' '{"other":[]}' '{nope'; do
                if ${srt} --options "$bad" -- true >/dev/null 2>err; then echo "accepted $bad"; exit 1; fi
                [ -s err ] || { echo "no reason for $bad"; exit 1; }
              done
              if ${srt} echo no-separator 2>/dev/null; then exit 1; fi
              touch $out
            '';

          # The Sentry check-in the update workflows run, against a
          # stub curl: what it sends, and the cases where it must send
          # nothing. The script lives beside its action rather than in
          # lib/ because only workflows call it.
          sentry-checkin = pkgs.runCommand "sentry-checkin"
            { nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.jq pkgs.gnugrep pkgs.gnused ]; }
            ''
              bash ${./.github/actions/sentry-checkin/test.sh} \
                ${./.github/actions/sentry-checkin/checkin.sh}
              touch $out
            '';

          # The script audit-plugins.yml records each plugin's audit
          # with, against a stub agent-stacks: what it writes, that a
          # run differing only in its timestamp writes nothing, and
          # that a runner fault is never recorded as the plugin's.
          record-plugin-audit = pkgs.runCommand "record-plugin-audit"
            { nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.diffutils pkgs.jq pkgs.gnugrep pkgs.gnused ]; }
            ''
              bash ${./scripts/record-plugin-audit.test.sh} \
                ${./scripts/record-plugin-audit.sh}
              touch $out
            '';

          agent-sandbox-nono-contract =
            let nono = "${(mkPackages pkgs).agent-sandbox-nono}/bin/agent-sandbox-nono"; in
            pkgs.runCommand "agent-sandbox-nono-contract" { nativeBuildInputs = [ pkgs.jq pkgs.nono ]; } ''
              set -u
              export HOME=$PWD/home TMPDIR=$PWD/tmp AGENT_SANDBOX_NONO_DRY_RUN=1
              # Its own, or a macOS build would make /tmp/claude-<uid> for the build user.
              export CLAUDE_CODE_TMPDIR=$PWD/agent-tmp
              t=$CLAUDE_CODE_TMPDIR/claude-$(id -u)
              mkdir -p "$t"
              touch -d '2 days ago' "$t/agent-sandbox-nono.old"
              mkdir -p $HOME $TMPDIR proj plugins/remote plugins/local
              cd proj
              printf '{"mcpServers":{"seo":{"type":"http","url":"https://app.openseo.so/mcp"}}}' > ../plugins/remote/.mcp.json
              printf '{"mcpServers":{"cli":{"type":"stdio","command":"x"}}}' > ../plugins/local/.mcp.json
              export CLAUDE_CODE_PLUGIN_DIRS=$PWD/../plugins/remote:$PWD/../plugins/local:$PWD/../plugins/missing
              ${nono} -- claude --version > p.json 2>cmd
              nono profile validate p.json
              jq -e '.extends == "default" and .workdir.access == "readwrite"' p.json
              jq -e '.filesystem.read | index("/nix/store")' p.json
              jq -e '.filesystem.allow | index("$HOME/.claude")' p.json
              jq -e '.filesystem.allow_file | index("$HOME/.claude.json")' p.json
              # Network stays open until options name hosts.
              jq -e '.network.allow_domain == null and .network.block == false' p.json
              grep -q -- 'run -s --no-diagnostics --allow-cwd --profile .* -- claude --version' cmd
              # Claude's temp folder exists before the sandbox goes up (Landlock
              # drops a grant for a missing path) and is the one granted.
              # Claude adds claude-<uid> to CLAUDE_CODE_TMPDIR; that folder, not its parent.
              [ -d "$t" ] || { echo "temp folder not created"; exit 1; }
              jq -e --arg t "$t" '.filesystem.allow | index($t) and (index($t | sub("/[^/]*$"; "")) | not)' p.json
              [ "$(stat -c %a "$t")" = 700 ] || { echo "temp folder open to others"; exit 1; }
              # Profiles from earlier days are cleared.
              [ ! -e "$t/agent-sandbox-nono.old" ] || { echo "old profile kept"; exit 1; }
              # TMPDIR points at that folder on Linux; a set one is kept on macOS.
              if [ "$(uname -s)" = Linux ]; then
                grep -q -- "TMPDIR=$t " cmd || { echo "TMPDIR not replaced on Linux"; cat cmd; exit 1; }
              elif grep -q 'TMPDIR=' cmd; then echo "replaced a set TMPDIR"; exit 1; fi
              (unset TMPDIR; ${nono} -- true >/dev/null 2>cmd2)
              grep -q -- "TMPDIR=$t " cmd2 || { echo "TMPDIR not set when unset"; cat cmd2; exit 1; }
              # A temp folder that is a link (or not ours) is refused.
              mkdir -p ../other ../planted && ln -s "$PWD/../other" "../planted/claude-$(id -u)"
              if CLAUDE_CODE_TMPDIR=$PWD/../planted ${nono} -- true >/dev/null 2>err; then echo "used a planted temp folder"; exit 1; fi
              grep -q 'not a folder of yours' err || { echo "no reason for planted folder"; cat err; exit 1; }
              ${nono} --options '{"allowedDomains":["example.com"],"allowWrite":["/data"],"denyRead":["~/.aws"]}' -- true > o.json 2>/dev/null
              nono profile validate o.json
              jq -e '.network.allow_domain | index("example.com") and index("api.anthropic.com") and index("platform.claude.com") and index("app.openseo.so")' o.json
              jq -e '.network.allow_domain | length == 4' o.json
              jq -e '(.filesystem.allow | index("/data")) and (.filesystem.deny | index("~/.aws"))' o.json
              for bad in '[1]' '{"allowedDomains":"x"}' '{"allowedDomains":[1]}' '{"other":[]}' '{nope'; do
                if ${nono} --options "$bad" -- true >/dev/null 2>err; then echo "accepted $bad"; exit 1; fi
                [ -s err ] || { echo "no reason for $bad"; exit 1; }
              done
              if ${nono} echo no-separator 2>/dev/null; then exit 1; fi
              # The project folder is writable, so / or ~ would open everything.
              for top in / "$HOME"; do
                if (cd "$top" && ${nono} -- true) >/dev/null 2>err; then echo "started from $top"; exit 1; fi
                grep -q 'project folder' err || { echo "no reason for $top"; cat err; exit 1; }
              done
              touch $out
            '';

          # A plugin built the way a generated source.json calls the
          # builder: src as a pin rather than a derivation, an import
          # record that only reaches passthru, and skills as plain
          # paths. The formals carry no `...`, so this also proves
          # every key a generated file writes is declared.
          source-shape =
            let lib' = mkLib pkgs; in
            lib'.buildAgentPlugin {
              name = "caveman";
              version = "0-unstable-2026-09-07";
              src = {
                owner = "juliusbrussee";
                repo = "caveman";
                rev = "15581d14007fd01fb3f132016741962f34936ca2";
                hash = "sha256-GuCK3oy0DsMOQq7gHjIY/aeaukJcTvelfg+tp7R7Du4=";
              };
              sourceUrl = "https://github.com/juliusbrussee/caveman";
              manifest = {
                "$schema" = "https://agent-plugins.org/schemas/1.1.0/plugin.schema.json";
                name = "caveman";
                description = "Ultra-compressed communication mode";
              };
              skills = { cavecrew = "skills/cavecrew"; };
              # The skill is Markdown only, so import records no
              # interpreters and the package pulls none into its
              # closure. Present because a generated source.json
              # always writes the key.
              requiredRuntimes = [ ];
              meta = {
                description = "Ultra-compressed communication mode";
                homepage = "https://github.com/juliusbrussee/caveman";
              };
              import = {
                input = "juliusbrussee/caveman";
                flags = [ ];
                warnings = [
                  { path = "skills/cavecrew/SKILL.md"; message = "example, not a real deviation"; }
                ];
              };
            };

          # Every convention ADR 0014 records, asserted on real builds:
          # a declared SPDX licence resolves to the lib.licenses value,
          # an unrecognised licence string yields no assertion at all,
          # a licence the call names is that lib.licenses value and a
          # name nixpkgs lacks is no assertion either,
          # maintainers stay empty, and platforms and category are
          # always present.
          meta-conventions =
            let
              lib' = mkLib pkgs;
              src = pkgs.runCommand "meta-src" { } ''
                mkdir -p $out/skills/one
                printf -- '---\nname: one\ndescription: Does things.\n---\nBody.\n' \
                  > $out/skills/one/SKILL.md
              '';
              mk = { name, license ? null, description ? "Short summary", meta ? { } }:
                lib'.buildAgentPlugin {
                  inherit name src meta;
                  sourceUrl = "https://example.test/${name}";
                  manifest = {
                    "$schema" = "https://agent-plugins.org/schemas/1.1.0/plugin.schema.json";
                    inherit name description;
                  } // nixpkgs.lib.optionalAttrs (license != null) { inherit license; };
                  skills.one = "skills/one";
                  requiredRuntimes = [ ];
                };
              mit = mk { name = "mit-plugin"; license = "MIT"; };
              apache = mk { name = "apache-plugin"; license = "Apache-2.0"; };
              unknown = mk { name = "unknown-plugin"; license = "SEE LICENSE IN LICENSE"; };
              # What `agent-stacks import` writes for a manifest saying
              # "Apache 2.0", "mit" or "Public Domain": the manifest
              # as upstream spelled it, and in meta the SPDX
              # identifier, or the lib.licenses name where SPDX has
              # no identifier.
              named = mk { name = "named-plugin"; license = "Apache 2.0"; meta.license = "Apache-2.0"; };
              recased = mk { name = "recased-plugin"; license = "mit"; meta.license = "MIT"; };
              namedNoSpdx = mk { name = "named-pd-plugin"; license = "Public Domain"; meta.license = "publicDomain"; };
              # The lookup is exact. Import is what knows "mit" is MIT.
              wrongCase = mk { name = "wrong-case-plugin"; license = "mit"; };
              # A name that is not a licence is dropped, and the
              # manifest's own licence then stands.
              badName = mk { name = "bad-name-plugin"; license = "MIT"; meta.license = "no-such-licence"; };
              operatorName = mk { name = "operator-plugin"; meta.license = "AND"; };
              # A caller handing over the licence itself is untouched.
              given = mk { name = "given-plugin"; license = "MIT"; meta.license = nixpkgs.lib.licenses.isc; };
              none = mk { name = "none-plugin"; };
              longDesc = mk {
                name = "long-plugin";
                description = "First sentence. Second sentence carries the rest.";
                meta.description = "First sentence";
              };
              yes = p: f: nixpkgs.lib.boolToString (f p.meta);
              stack = lib'.mkAgentStack {
                name = "conventions-stack";
                harness = "claude";
                plugins = [ mit ];
              };
            in
            pkgs.runCommand "meta-conventions" { } ''
              [ "${mit.meta.license.spdxId}" = MIT ]
              [ "${apache.meta.license.spdxId}" = Apache-2.0 ]
              [ "${yes unknown (m: m ? license)}" = false ]
              [ "${named.meta.license.spdxId}" = Apache-2.0 ]
              [ "${yes named (_: named.passthru.agentPlugin.unresolvedLicense == null)}" = true ]
              [ "${recased.meta.license.spdxId}" = MIT ]
              [ "${yes wrongCase (m: m ? license)}" = false ]
              [ "${yes namedNoSpdx (m: m.license == nixpkgs.lib.licenses.publicDomain)}" = true ]
              [ "${badName.meta.license.spdxId}" = MIT ]
              [ "${badName.passthru.agentPlugin.unresolvedLicense}" = no-such-licence ]
              [ "${yes operatorName (m: m ? license)}" = false ]
              [ "${operatorName.passthru.agentPlugin.unresolvedLicense}" = AND ]
              [ "${given.meta.license.spdxId}" = ISC ]
              [ "${yes none (m: m ? license)}" = false ]
              [ "${yes mit (m: m.maintainers == [ ])}" = true ]
              [ "${yes none (m: m.maintainers == [ ])}" = true ]
              [ "${mit.meta.category}" = agent-plugin ]
              [ "${yes mit (m: m.platforms == nixpkgs.lib.platforms.all)}" = true ]
              [ "${mit.meta.homepage}" = https://example.test/mit-plugin ]
              [ "${none.meta.description}" = "Short summary" ]
              [ "${yes none (m: m ? longDescription)}" = false ]
              [ "${longDesc.meta.description}" = "First sentence" ]
              [ "${longDesc.meta.longDescription}" = \
                "First sentence. Second sentence carries the rest." ]
              [ "${stack.meta.category}" = agent-stack ]
              [ "${yes stack (m: m.platforms == nixpkgs.lib.platforms.all)}" = true ]
              [ "${yes stack (m: m.maintainers == [ ])}" = true ]
              [ "${(mkAllPackages pkgs).claude-code.meta.category}" = agent ]
              [ "${(mkAllPackages pkgs).ccusage.meta.category}" = agent-tool ]
              [ "${(mkAllPackages pkgs).agent-stacks.meta.category}" = agent-tool ]
              touch $out
            '';

          # A stack has no audit output or option any more. A call still
          # passing `audit` must fail evaluation with the reason, not
          # build a stack that silently ignores it, and one without it
          # must still build with the launcher as its only output.
          stack-audit-removed =
            let
              lib' = mkLib pkgs;
              call = extra: lib'.mkAgentStack ({
                name = "no-audit-stack";
                harness = "claude";
              } // extra);
              stack = call { };
              refused = builtins.tryEval (call { audit = { }; }).drvPath;
            in
            assert !refused.success;
            assert stack.outputs == [ "out" ];
            pkgs.runCommand "stack-audit-removed" { } ''
              [ -x ${stack}/bin/no-audit-stack ]
              touch $out
            '';

          # The reference tells readers to attach postAssemble with
          # overrideAttrs. This is the check that sentence promises:
          # the hook runs on the assembled tree, and passthru survives
          # the override so downstream composition still works.
          override-hook =
            let
              lib' = mkLib pkgs;
              src = pkgs.runCommand "override-src" { } ''
                mkdir -p $out/skills/one
                printf -- '---\nname: one\ndescription: Does things.\n---\nBody.\n' \
                  > $out/skills/one/SKILL.md
              '';
              base = lib'.buildAgentPlugin {
                name = "overridable";
                inherit src;
                sourceUrl = "https://example.test/overridable";
                manifest = {
                  "$schema" = "https://agent-plugins.org/schemas/1.1.0/plugin.schema.json";
                  name = "overridable";
                };
                skills.one = "skills/one";
                requiredRuntimes = [ ];
              };
              hooked = base.overrideAttrs (old: {
                postAssemble = (old.postAssemble or "") + ''
                  printf 'hooked\n' > "$dest/MARKER"
                '';
              });
              pinned = lib'.buildAgentPlugin {
                name = "caveman";
                src = {
                  owner = "juliusbrussee";
                  repo = "caveman";
                  rev = "15581d14007fd01fb3f132016741962f34936ca2";
                  hash = "sha256-GuCK3oy0DsMOQq7gHjIY/aeaukJcTvelfg+tp7R7Du4=";
                };
                sourceUrl = "https://github.com/juliusbrussee/caveman";
                manifest = {
                  "$schema" = "https://agent-plugins.org/schemas/1.1.0/plugin.schema.json";
                  name = "caveman";
                };
                skills.cavecrew = "skills/cavecrew";
                requiredRuntimes = [ ];
              };
              yes = b: nixpkgs.lib.boolToString b;
            in
            pkgs.runCommand "override-hook" { } ''
              p=${hooked}/share/agent-plugins/overridable
              [ "$(cat $p/MARKER)" = hooked ]
              [ -f $p/plugin.json ]
              [ "${hooked.passthru.agentPlugin.name}" = overridable ]
              [ "${yes (hooked.passthru.agentPlugin.skills == [ "one" ])}" = true ]
              [ "${hooked.meta.category}" = agent-plugin ]
              [ "${yes (base.passthru.agentPlugin.rev == null)}" = true ]
              [ "${yes (base.passthru.agentPlugin.hash == null)}" = true ]
              [ "${pinned.passthru.agentPlugin.rev}" = \
                15581d14007fd01fb3f132016741962f34936ca2 ]
              touch $out
            '';

          # A preserved default.nix block appends to the hooks rather
          # than replacing them, so both have to exist even when no
          # package has set them. Without the empty defaults in
          # build-agent-plugin.nix this fails to evaluate.
          old-hooks-exist = ((mkPackages pkgs).agent-plugin-avoid-ai-writing.overrideAttrs (old: {
            nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.jq ];
            postAssemble = old.postAssemble + ''
              jq --version > /dev/null
            '';
          })).overrideAttrs (_: { pname = "old-hooks-exist"; });

          # Every key agent-stacks import writes is a builder formal (ADR
          # 0016), or the first replay carrying it fails on main.
          call-keys-declared =
            let
              # The file, not the callPackage'd value, which is not a function.
              formals = builtins.functionArgs (import ./lib/build-agent-plugin.nix {
                inherit (pkgs) lib stdenvNoCC;
                inherit pkgs;
              });
              written = [
                "name" "version" "src" "sourceUrl" "manifest" "skills" "requiredRuntimes"
                "dependencies" "pluginRootPaths" "ignoredPaths" "mcpServers" "hooks" "meta" "import"
              ];
              missing = builtins.filter (k: !(formals ? ${k})) written;
            in
            if missing != [ ] then
              throw ("buildAgentPlugin declares no formal for: "
                + builtins.concatStringsSep ", " missing
                + "; agent-stacks import writes these keys into source.json")
            else
              pkgs.runCommand "call-keys-declared" { } ''
                touch $out
              '';

          # notPackages is a hand-maintained judgement against a set
          # that grows daily, so it needs a tripwire rather than a
          # convention. meta.mainProgram is the signal — every package
          # worth publishing has one — but it is used to ask a question,
          # never to filter: a new attribute without one fails this
          # check by name, and a human decides. Nothing is ever dropped
          # from the catalog without someone seeing it. ADR 0015.
          re-export-is-packages =
            let
              scope = (llmAgentsPkgsFor pkgs.stdenv.hostPlatform.system).llm-agents;
              suspect = name:
                let p = scope.${name}; in
                !(builtins.elem name notPackages)
                && !(builtins.elem name notPackagesExempt)
                && nixpkgs.lib.isDerivation p
                && nixpkgs.lib.meta.availableOn pkgs.stdenv.hostPlatform p
                && !(p.meta.broken or false)
                && !(p.meta ? mainProgram);
              unclassified = builtins.filter suspect (builtins.attrNames scope);
            in
            pkgs.runCommand "re-export-is-packages" { } (
              if unclassified == [ ] then "touch $out"
              else ''
                cat >&2 <<'MSG'
                These attributes of llm-agents.nix have no meta.mainProgram and
                are not listed in notPackages in flake.nix:

                  ${builtins.concatStringsSep "\n  " unclassified}

                A missing mainProgram usually means the attribute is a setup
                hook, a builder or a toolchain rather than a package this set
                should publish; add it to notPackages. If it is a real package
                whose packager simply omitted the field, leave it published and
                add it to notPackagesExempt instead.
                MSG
                exit 1
              ''
            );

        };
    in
    {
      packages = forAllSystems mkAllPackages;

      # The gates, not the packages: CI runs `nix flake check` on every
      # pull request and both update workflows run it hourly, and a
      # package belongs to Hydra, which builds packages.* for every
      # system. A package that stops building is Hydra's to report, and
      # an evaluation error is still caught here, because flake check
      # evaluates packages.* whether or not it builds them.
      checks = forAllSystems mkGates;
      lib = forAllSystems mkLib;

      # What Hydra builds. packages.* is published to the agent-stacks
      # catalog; checks.* builds as a gate and is never published. The
      # jobset configuration lives in deltaops doc/hydra-jobsets.md,
      # because Hydra jobsets are configured in its web UI.
      hydraJobs = {
        packages = nixpkgs.lib.genAttrs systems (system:
          mkAllPackages (pkgsFor system));

        # The same gates `checks` exposes. packages.* above already
        # builds every package, so naming them here too would double
        # the jobset for no extra coverage.
        checks = nixpkgs.lib.genAttrs systems (system: mkGates (pkgsFor system));
      };
    };
}
