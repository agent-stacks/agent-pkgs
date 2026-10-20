# The packages every build may link a runtime from when nothing names
# one: between them they ship sh, bash, python, python3, node, npm and
# npx. A list, not a map, and it does not grow (ADR 0023). The flake
# check runtime-defaults-resolve reads it too.
[ "bash" "python3" "nodejs" ]
