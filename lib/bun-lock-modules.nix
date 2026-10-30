# bunLockModules — the node_modules a bun.lock pins, built without
# bun: one fetchurl per package by the lock's sha512, unpacked at the
# lock's hoisted paths, bins linked as Bun links them (ADR 0026).
#
# A lock this cannot lay out fails the build, never evaluation.
{ lib, stdenv, fetchurl, runCommand }:

{ # A plugin's source.json; name, src and dir come from it.
  source ? null
, name ? (lib.importJSON source).name
  # The unpacked tree holding the lock, read at evaluation.
, src ? null
  # The directory in src holding bun.lock.
, dir ? "."
}:

let
  plugin = lib.importJSON source;
  lockPath = if source == null then "${dir}/bun.lock" else plugin.pluginRootPaths."bun.lock" or null;
  srcTree = if source == null then src else builtins.fetchTarball {
    url = "https://github.com/${plugin.src.owner}/${plugin.src.repo}/archive/${plugin.src.rev}.tar.gz";
    sha256 = plugin.src.hash;
  };
  lockFile = "${srcTree}/${lockPath}";

  meta = {
    description = "Dependencies of the ${name} plugin's MCP server";
    platforms = lib.platforms.all;
    # ADR 0014.
    category = "agent-tool";
  } // lib.optionalAttrs (source != null) {
    homepage = plugin.sourceUrl or "https://github.com/${plugin.src.owner}/${plugin.src.repo}";
  };

  # JSON with trailing commas, checked here because fromJSON's error
  # cannot be caught.
  lexed = builtins.split
    "(\"([^\"\\\\[:cntrl:]]|\\\\([\"\\\\/bfnrt]|u[0-9a-fA-F]{4}))*\"|-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][-+]?[0-9]+)?|true|false|null|[][{}:,])"
    (builtins.readFile lockFile);
  tokens = map builtins.head (builtins.filter builtins.isList lexed);
  kind = t: if lib.hasPrefix "\"" t then "s" else if builtins.elem t [ "{" "}" "[" "]" "," ":" ] then t else "v";
  close = st: { stack = builtins.tail st.stack; want = "after"; };
  step = st: t:
    let k = kind t; top = if st.stack == [ ] then null else builtins.head st.stack; in
    if st == null then null
    else if st.want == "after" then
      if k == "," && top != null then st // { want = if top == "}" then "key" else "item"; }
      else if k == top then close st else null
    else if st.want == ":" then (if k == ":" then st // { want = "value"; } else null)
    else if st.want == "key" then (if k == "s" then st // { want = ":"; } else if k == "}" then close st else null)
    else if k == "{" then { stack = [ "}" ] ++ st.stack; want = "key"; }
    else if k == "[" then { stack = [ "]" ] ++ st.stack; want = "item"; }
    else if k == "s" || k == "v" then st // { want = "after"; }
    else if st.want == "item" && k == "]" then close st else null;
  isJSON = lib.all (g: builtins.isList g || builtins.match "[[:space:]]*" g != null) lexed
    && lib.foldl' step { stack = [ ]; want = "value"; } tokens == { stack = [ ]; want = "after"; };
  lock = builtins.fromJSON (lib.concatStrings (lib.zipListsWith
    (t: next: if t == "," && builtins.elem next [ "}" "]" ] then "" else t)
    tokens (builtins.tail tokens ++ [ "" ])));

  # "a/@s/b" is node_modules/a/node_modules/@s/b.
  names = segs:
    if segs == [ ] then [ ]
    else if lib.hasPrefix "@" (builtins.head segs) && builtins.length segs > 1
    then [ "${builtins.head segs}/${builtins.elemAt segs 1}" ] ++ names (lib.drop 2 segs)
    else [ (builtins.head segs) ] ++ names (builtins.tail segs);

  host = stdenv.hostPlatform;
  os = if host.isDarwin then "darwin" else if host.isLinux then "linux" else host.parsed.kernel.name;
  cpu = if host.isAarch64 then "arm64" else if host.isx86_64 then "x64" else host.parsed.cpu.name;
  # npm's os/cpu rule, which Bun follows.
  allows = value: spec:
    let l = lib.toList spec; neg = builtins.filter (lib.hasPrefix "!") l; in
    l == [ "any" ] || !builtins.elem "!${value}" neg
      && (neg == l || builtins.elem value l);

  entry = key: value:
    let
      ident = builtins.match "(@?[^@]+)@([^@/]+)" (builtins.head value);
      pkgName = builtins.head ident;
      at = builtins.elemAt ident 1;
      info = builtins.elemAt value 2;
      hash = builtins.elemAt value 3;
      installs = names (lib.splitString "/" key);
      install = lib.last installs;
      path = "node_modules/" + lib.concatStringsSep "/node_modules/" installs;
      spec = s: builtins.isString s || builtins.isList s && lib.all builtins.isString s;
      problem =
        if !(builtins.isList value && builtins.length value == 4 && builtins.elemAt value 1 == ""
          && builtins.isString (builtins.head value) && builtins.isAttrs info && ident != null
          && builtins.isString hash && builtins.match "sha512-[A-Za-z0-9+/]{86}==" hash != null)
        then "${key} is not a registry.npmjs.org package"
        else if lib.any (n: builtins.match "(@[^/]+/)?[^/@]+" n == null) installs
          || lib.any (s: s == "." || s == "..") (lib.splitString "/" key)
        then "${key} is not a node_modules path"
        else if !spec (info.os or [ ]) || !spec (info.cpu or [ ])
        then "${key} has an os or cpu that is not a string or list"
        else null;
      bins =
        if builtins.isString (info.bin or null) then { ${baseNameOf pkgName} = info.bin; }
        else if builtins.isAttrs (info.bin or null) then info.bin
        else { };
    in
    if problem != null then { inherit problem; } else {
      inherit problem path;
      wanted = allows os (info.os or [ ]) && allows cpu (info.cpu or [ ]);
      binDir = lib.removeSuffix install path + ".bin";
      tarball = fetchurl {
        name = "npm-" + lib.strings.sanitizeDerivationName "${baseNameOf pkgName}-${at}.tgz";
        url = "https://registry.npmjs.org/${pkgName}/-/${baseNameOf pkgName}-${at}.tgz";
        inherit hash;
      };
      bin = lib.mapAttrsToList (cmd: file: { inherit cmd file install; }) bins;
    };

  all = lib.mapAttrsToList entry (if isJSON && builtins.isAttrs (lock.packages or null) then lock.packages else { });
  problems =
    if lockPath == null then [ "source.json ships no bun.lock" ]
    else if !builtins.pathExists lockFile then [ "${lockPath} is missing" ]
    else if !isJSON then [ "${lockPath} is not JSON with trailing commas" ]
    else if !builtins.isAttrs (lock.packages or null) then [ "${lockPath} has no packages" ]
    else builtins.filter (p: p != null) (map (e: e.problem) all);

  # Parents first, so a nested package unpacks inside its parent; a
  # package skipped for its platform takes its nested ones with it.
  sorted = lib.sort (a: b: a.path < b.path) all;
  skipped = map (e: e.path) (builtins.filter (e: !e.wanted) sorted);
  entries = builtins.filter
    (e: e.wanted && !lib.any (p: lib.hasPrefix "${p}/" e.path) skipped) sorted;

  q = lib.escapeShellArg;

  unpack = e: ''
    if [ ! -e "$out"/${q e.path} ]; then
      mkdir -p "$out"/${q e.path}
      tar -xzf ${e.tarball} -C "$out"/${q e.path} --strip-components=1 --no-same-owner --no-same-permissions
    fi
  '';

  # Into the .bin beside the package, relative, as Bun links them; the
  # first package to claim a name keeps it.
  link = e: lib.concatMapStrings (b:
    let
      segs = builtins.filter (s: s != "." && s != "") (lib.splitString "/" b.file);
      rel = lib.concatStringsSep "/" segs;
      linkPath = "${e.binDir}/${b.cmd}";
    in
    if !builtins.isString b.file || lib.hasPrefix "/" b.file || segs == [ ] || builtins.elem ".." segs
      || builtins.elem b.cmd [ "" "." ".." ] || lib.hasInfix "/" b.cmd || lib.hasInfix "\\" b.cmd
    then ''
      echo ${q "bunLockModules: ${name}: skipping ${e.path}'s bin ${b.cmd}"}
    '' else ''
      if [ -e "$out"/${q linkPath} ] || [ -L "$out"/${q linkPath} ]; then
        echo ${q "bunLockModules: ${name}: ${linkPath} is taken; skipping ${e.path}'s ${b.cmd}"}
      elif [ ! -f "$out"/${q "${e.path}/${rel}"} ]; then
        echo ${q "bunLockModules: ${name}: ${e.path} has no ${rel}; skipping bin ${b.cmd}"}
      else
        mkdir -p "$out"/${q e.binDir}
        chmod +x "$out"/${q "${e.path}/${rel}"}
        ln -s ${q "../${b.install}/${rel}"} "$out"/${q linkPath}
      fi
    '') e.bin;
in
runCommand "${name}-node-modules" { inherit meta; } (if problems != [ ] then ''
  echo ${q "bunLockModules: ${name}: ${lib.concatStringsSep "; " problems}"} >&2
  exit 1
'' else ''
  mkdir -p "$out"
  ${lib.concatMapStrings unpack entries}
  ${lib.concatMapStrings link entries}
'')
