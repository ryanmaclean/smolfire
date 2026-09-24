# SPDX-License-Identifier: Apache-2.0
# no-new-python-test.nu — guards the Nushell-only script policy declared in
# AGENTS.md and .github/copilot-instructions.md: fails if any tracked *.py
# file exists outside an explicit, reasoned allow-list.
#
# Motivation: on 2026-09-23 the Copilot coding agent added
# bin/netbsd-microvm-prototype.py + tests/netbsd-microvm-prototype-test.py
# (commit 624fb15) despite this repo's "new scripts are Nushell" convention.
# Both were ported to .nu (bin/netbsd-microvm-prototype.nu,
# tests/netbsd-microvm-prototype-test.nu) and the .py originals + their
# __pycache__ artifacts were removed. This test exists so a future agent (or
# human) adding a new Python file gets caught in CI instead of silently
# landing on main.
#
# Wired into tests/run-all.sh via the `tests/*-test.nu` glob, and therefore
# into CI (.github/workflows/ci.yml runs `sh tests/run-all.sh`).

# Allow-list: path (repo-root-relative) -> reason. Every entry must carry a
# reason comment explaining why it predates/is exempt from the policy.
def allow-list []: nothing -> record {
    {
        # Owner's own file (Ryan MacLean), added May 2026 — predates the
        # Nushell-only policy and is explicitly grandfathered in rather than
        # ported, per the owner's own instruction.
        "bin/fix-freebsd-vm.py": "owner's own file (May 2026), grandfathered — not ported",
    }
}

def repo-root []: nothing -> string {
    $env.FILE_PWD | path dirname
}

# Returns repo-root-relative paths of every tracked *.py file, using jj when
# this checkout is jj-colocated and falling back to git ls-files otherwise
# (e.g. a plain git clone in CI without a jj binary).
def tracked-py-files [root: string]: nothing -> list<string> {
    if (($root | path join ".jj") | path exists) and ((which jj | length) > 0) {
        (jj -R $root file list | lines | where {|f| $f | str ends-with ".py" })
    } else if (which git | length) > 0 {
        let out = (do { ^git -C $root ls-files } | complete)
        if $out.exit_code != 0 {
            error make {msg: $"git ls-files failed: ($out.stderr)"}
        }
        ($out.stdout | lines | where {|f| $f | str ends-with ".py" })
    } else {
        error make {msg: "neither jj nor git available to list tracked files"}
    }
}

print "test: no tracked *.py files outside the allow-list"
do {
    let root = (repo-root)
    let allowed = (allow-list | columns)
    let found = (tracked-py-files $root)
    let offenders = ($found | where {|f| not ($f in $allowed) })

    if ($offenders | length) > 0 {
        let listing = ($offenders | each {|f| $"  - ($f)" } | str join "\n")
        error make {msg: $"tracked Python files found outside the allow-list \(AGENTS.md: new scripts must be Nushell\):\n($listing)"}
    }
}

print "no-new-python-test: ok"
