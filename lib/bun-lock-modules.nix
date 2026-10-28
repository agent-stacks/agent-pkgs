# bunLockModules — the node_modules a bun.lock pins, built without
# bun: one fetchurl per package by the lock's sha512, unpacked at the
# lock's hoisted paths, bins linked as Bun links them (ADR 0026).
{ lib, fetchurl, runCommand }:

{ name
  # The unpacked source holding the lock; read at evaluation, so it
  # must be a path, such as what builtins.fetchTarball returns.
, src
  # The directory in src that holds package.json and bun.lock.
, dir ? "."
}:

let
  text = builtins.readFile "${src}/${dir}/bun.lock";
  # bun.lock is JSON with trailing commas.
  lock = builtins.fromJSON (lib.concatMapStrings
    (p: if builtins.isList p then builtins.head p else p)
    (builtins.split ",([[:space:]]*[]}])" text));

  # "a/@s/b" is node_modules/a/node_modules/@s/b.
  names = key:
    let
      segs = lib.splitString "/" key;
      go = acc: rest:
        if rest == [ ] then acc
        else if lib.hasPrefix "@" (builtins.head rest)
        then go (acc ++ [ "${builtins.head rest}/${builtins.elemAt rest 1}" ]) (lib.drop 2 rest)
        else go (acc ++ [ (builtins.head rest) ]) (builtins.tail rest);
    in
    go [ ] segs;

  entry = key: value:
    let
      ident = builtins.head value;
      at = lib.last (lib.splitString "@" ident);
      pkgName = lib.removeSuffix "@${at}" ident;
      meta = builtins.elemAt value 2;
      bad = "bunLockModules: ${name}: ${key}";
    in
    assert builtins.length value == 4 && builtins.elemAt value 1 == ""
      || throw "${bad} is not a registry.npmjs.org package";
    assert !(meta ? os || meta ? cpu) || throw "${bad} is limited to some platforms";
    rec {
      inherit pkgName;
      path = "node_modules/" + lib.concatStringsSep "/node_modules/" (names key);
      tarball = fetchurl {
        name = "npm-" + lib.strings.sanitizeDerivationName "${lib.last (lib.splitString "/" pkgName)}-${at}.tgz";
        url = "https://registry.npmjs.org/${pkgName}/-/${lib.last (lib.splitString "/" pkgName)}-${at}.tgz";
        hash = builtins.elemAt value 3;
      };
      bin =
        if builtins.isString (meta.bin or null) then { ${lib.last (lib.splitString "/" pkgName)} = meta.bin; }
        else meta.bin or { };
    };

  # Parents first, so a nested package unpacks inside its parent.
  entries = lib.sort (a: b: a.path < b.path) (lib.mapAttrsToList entry lock.packages);

  unpack = e: ''
    if [ ! -e "$out/${e.path}" ]; then
      mkdir -p "$out/${e.path}"
      tar -xzf ${e.tarball} -C "$out/${e.path}" --strip-components=1 --no-same-owner --no-same-permissions
    fi
  '';

  # Into the .bin beside the package, relative, as Bun links them.
  link = e: lib.concatStrings (lib.mapAttrsToList (cmd: file:
    let
      binDir = "${lib.removeSuffix e.pkgName e.path}.bin";
      rel = lib.removePrefix "./" file;
    in ''
      mkdir -p "$out/${binDir}"
      chmod +x "$out/${e.path}/${rel}"
      ln -s "../${e.pkgName}/${rel}" "$out/${binDir}/${cmd}"
    '') e.bin);
in
runCommand "${name}-node-modules" { } ''
  mkdir -p "$out"
  ${lib.concatMapStrings unpack entries}
  ${lib.concatMapStrings link entries}
''
