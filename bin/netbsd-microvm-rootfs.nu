#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
#
# netbsd-microvm-rootfs.nu — build the immutable rootfs image and the
# writable state disk for bin/netbsd-microvm-prototype.nu from official
# NetBSD 11.0 amd64 sets. Runs on a Linux or BSD build host that has
# bsdtar, makefs (NetBSD makefs; Debian/Ubuntu package "makefs") and sudo
# (sudo keeps the sets' root ownership without an mtree spec).
#
#   nu bin/netbsd-microvm-rootfs.nu --sets-dir DL --out root.img \
#       [--add /path/dd-agent-rs:/opt/datadog/bin/dd-agent-rs:0755] \
#       [--authorized-keys ~/.ssh/id_ed25519.pub] [--hostname smolfire-netbsd]
#   nu bin/netbsd-microvm-rootfs.nu state --out state.img --env-stdin < protected-agent.env
#
# DL must hold base.tar.xz and etc.tar.xz plus the release's sets SHA512
# list (saved as SHA512 or sets-SHA512); every set is checked against it
# before extraction. Secrets never go into the rootfs: the state subcommand
# writes the environment it reads on stdin to /agent.env (mode 0600) on the
# state disk only, and nothing it reads is printed.
#
# Output: one JSON report (schema smolfire.netbsd-microvm-rootfs/v1) on
# stdout.


const TRIM = [
    "./stand", "./usr/mdec", "./usr/games",
    "./usr/share/man", "./usr/share/info", "./usr/share/doc",
    "./usr/share/examples", "./usr/share/locale", "./usr/share/i18n",
    "./usr/share/nls", "./usr/share/dict", "./usr/share/games",
    "./usr/share/zoneinfo", "./usr/share/calendar", "./usr/share/me",
    "./usr/share/mi", "./usr/share/tmac", "./usr/share/groff_font",
    "./usr/share/xml", "./usr/share/wscons", "./usr/share/keymaps",
    "./usr/libexec/postfix", "./usr/share/examples/postfix",
    "./usr/lib/*.a", "./usr/lib/*_p.a", "./usr/lib/*_pic.a",
    "./usr/libdata/lint", "./usr/libdata/ldscripts",
]

# Match the guest's literal environment grammar; never parse shell syntax.
# Errors intentionally omit input lines and values.
def validate-agent-env [text: string]: nothing -> list<string> {
    if $text =~ '\x00' {
        error make {msg: "agent.env must be text without NUL bytes"}
    }
    mut keys = []
    for line in ($text | split row "\n") {
        if $line == "" or ($line | str starts-with "#") { continue }
        if $line !~ '^[A-Za-z_][A-Za-z0-9_]*=' {
            error make {msg: "invalid agent.env assignment"}
        }
        let key = ($line | split row "=" | first)
        if ($key | str starts-with "SMOLFIRE_ENV_") {
            error make {msg: "reserved agent.env key"}
        }
        $keys = ($keys | append $key)
    }
    $keys
}



const SCHEMA = "smolfire.netbsd-microvm-rootfs/v1"
const STATE_SCHEMA = "smolfire.netbsd-microvm-state/v1"
const GUEST = path self ../guest/netbsd-microvm

# Native boundary used by BOTH public entry points. The optional closure on
# build-image is library-only: the CLI never accepts an alternate executor.
# OpenSSL 3 default-provider SHA512; input is streamed via stdin so filenames
# are never interpreted as options. The selected executable/config is a runtime
# admission responsibility; there is no fallback to another digest algorithm.
export def image-sha512 [path: string] {
    let child = (open --raw $path | ^openssl dgst -provider default -propquery 'provider=default' -sha512 -binary | complete)
    if $child.exit_code != 0 { error make {msg: 'SHA512 child failed'} }
    let digest = ($child.stdout | into binary)
    if ($digest | bytes length) != 64 { error make {msg: 'SHA512 child returned invalid length'} }
    $digest | encode hex | str downcase
}

export def image-effect [r: record] {
    match $r.op {
        command => { ^($r.argv.0) ...($r.argv | skip 1) | complete }
        inspect => {
            let kind: any = ($r.path | path type)
            if $kind == null { {type: missing} } else {
                if $kind not-in [file dir] { {type: $kind} } else {
                    let row = (ls --long --directory $r.path | first)
                    {type: $kind, bytes: ($row.size | into int), mode: $row.mode, inode: $row.inode}
                }
            }
        }
        copy => { open --raw $r.source | save $r.target }
        hash => { open --raw $r.path | hash sha256 }
        hash512 => { image-sha512 $r.path }
        read => { open --raw $r.path }
        write => { $r.text | save $r.path }
        workspace => { mktemp -d -p $r.parent 'nbmicrovm-transaction.XXXXXX' }
        mkdir => { mkdir $r.path }
        remove => { rm -r $r.path }
        publish => { mv --force $r.source $r.target }
        _ => { error make {msg: 'unsupported image effect'} }
    }
}

def command [effect: closure, argv: list<string>, stage: string] {
    let child = (do $effect {op: command, argv: $argv, stage: $stage})
    if (($child.exit_code | describe) != 'int') or $child.exit_code != 0 {
        let code = if (($child.exit_code | describe) == 'int') { $child.exit_code | into string } else { 'invalid-status' }
        error make {msg: $'image child failed: ($stage); exit=($code)'}
    }
    $child.stdout
}

def inspect [effect: closure, path: string] { do $effect {op: inspect, path: $path} }

def require-type [effect: closure, path: string, kind: string] {
    let row = (inspect $effect $path)
    if $row.type != $kind { error make {msg: $'expected ($kind) at selected path'} }
    $row
}

# Ordinary exclusive-owner scope: every existing component must be a directory,
# never a symlink. Not a descriptor-relative defense against a privileged race.
def directory-chain [effect: closure, path: string] {
    mut current = '/'
    for part in ($path | path split | skip 1) {
        $current = ($current | path join $part)
        require-type $effect $current dir | ignore
    }
}

export def add-specs [add: string] {
    mut items = []
    for spec in ($add | split row ',' | where {|s| ($s | str trim) != ''}) {
        let parts = ($spec | split row ':')
        if ($parts | length) not-in [2 3] { error make {msg: 'add requires src:dst[:mode]'} }
        if $parts.0 == '' or $parts.0 =~ '[\x00-\x1f\x7f]' { error make {msg: 'add source path contains control characters'} }
        let dst = ($parts.1 | str trim --left --char '/')
        let components = ($dst | split row '/')
        if ($dst == '') or ($components | any {|p| $p in ['' '.' '..']}) or ($dst =~ '[\x00-\x1f\x7f]') {
            error make {msg: 'image policy: add destination must be a confined guest path'}
        }
        let mode = ($parts | get -o 2 | default '0644')
        if $mode !~ '^0?[0-7]{3}$' { error make {msg: 'add mode must be ordinary octal permissions'} }
        $items = ($items | append {src: ($parts.0 | path expand --no-symlink), dst: $dst, mode: $mode})
    }
    if ($items | get dst | uniq | length) != ($items | length) { error make {msg: 'duplicate add destination'} }
    $items
}

# Reject an extracted symlink at every destination ancestor/final component.
# Missing directories are created individually after their parent is checked.
def stage-parent [effect: closure, staging: string, relative: string, privileged: bool] {
    mut current = $staging
    let prefix = if $privileged { [sudo] } else { [] }
    for part in ($relative | split row '/' | drop 1) {
        $current = ($current | path join $part)
        let row = (inspect $effect $current)
        if $row.type == 'missing' { command $effect [...$prefix mkdir $current] 'stage directory creation failed' | ignore
        } else if $row.type != 'dir' { error make {msg: 'image policy: stage destination traverses a non-directory'} }
        require-type $effect $current dir | ignore
    }
    let dst = ($staging | path join $relative)
    let row = (inspect $effect $dst)
    if $row.type not-in [missing file] { error make {msg: 'image policy: stage destination is not a regular file'} }
    $dst
}

def permission-text [mode: string] {
    let bits = ['---' '--x' '-w-' '-wx' 'r--' 'r-x' 'rw-' 'rwx']
    $mode | split chars | last 3 | each {|digit| $bits | get ($digit | into int)} | str join
}

def install-file [effect: closure, staging: string, relative: string, src: string, mode: string] {
    let dst = (stage-parent $effect $staging $relative true)
    command $effect [sudo install -o '0' -g '0' -m $mode $src $dst] 'file installation failed' | ignore
    let installed = (require-type $effect $dst file)
    if $installed.mode != (permission-text $mode) { error make {msg: 'installed file mode mismatch'} }
}

def verify-sets [effect: closure, dir: string] {
    mut list_path = ''
    for name in [SHA512 sets-SHA512] {
        let p = ($dir | path join $name)
        if (inspect $effect $p).type == 'file' { $list_path = $p; break }
    }
    if $list_path == '' { error make {msg: 'no SHA512 list in selected sets directory'} }
    let lines = (do $effect {op: read, path: $list_path} | lines)
    mut result = []
    for name in [base.tar.xz etc.tar.xz] {
        let path = ($dir | path join $name)
        let meta = (require-type $effect $path file)
        let want = ($lines | parse 'SHA512 ({name}) = {hex}' | where name == $name)
        if ($want | length) != 1 { error make {msg: 'set requires exactly one SHA512 entry'} }
        let digest = (do $effect {op: hash512, path: $path})
        if ($digest !~ '^[0-9a-f]{128}$') or $digest != ($want.0.hex | str trim | str lowercase) {
            error make {msg: $'SHA512 mismatch for ($name)'}
        }
        $result = ($result | append {set: $name, sha512: $digest, bytes: $meta.bytes})
    }
    $result
}

# Existing report schemas remain; transaction is additive status, not a Genoa
# deployment receipt or a durability acknowledgement. No fsync/boot claim.
export def build-image [request: record, --effect: closure] {
    let effect = if $effect == null { {|r| image-effect $r} } else { $effect }
    mut stage = 'validate'
    mut workspace: any = null
    mut published = false
    mut publishing = false
    mut cleanup = 'not_attempted'
    mut report: any = null
    let outcome = try {
        if $request.kind not-in [root state] { error make {msg: 'invalid image kind'} }
        if $request.out == '' or $request.out =~ '[\x00-\x1f\x7f]' { error make {msg: 'output path contains control characters'} }
        if $request.sets_dir =~ '[\x00-\x1f\x7f]' or $request.authorized_keys =~ '[\x00-\x1f\x7f]' { error make {msg: 'input path contains control characters'} }
        let out = ($request.out | path expand --no-symlink)
        let parent = ($out | path dirname)
        if $out == '/' or ($out | path basename) in ['' '.' '..'] { error make {msg: 'invalid output path'} }
        directory-chain $effect $parent
        let initial = (inspect $effect $out)
        if $initial.type not-in [missing file] { error make {msg: 'output must be absent or a regular file'} }
        let initial_digest = if $initial.type == 'file' { do $effect {op: hash, path: $out} } else { null }
        if $initial_digest != null and $initial_digest !~ '^[0-9a-f]{64}$' { error make {msg: 'invalid existing output digest'} }
        let items = (add-specs $request.add)
        for item in $items { require-type $effect $item.src file | ignore }
        let env_keys = (validate-agent-env $request.text)
        if $request.size_mb < 1 or $request.size_mb > 65536 { error make {msg: 'state size outside 1..65536 MiB'} }
        if $request.free_pct < 0 or $request.free_pct > 99 { error make {msg: 'free percentage outside 0..99'} }
        if $request.authorized_keys != '' { require-type $effect $request.authorized_keys file | ignore }
        let sets = if $request.kind == 'root' { verify-sets $effect $request.sets_dir } else { [] }
        $stage = 'workspace'
        $workspace = (do $effect {op: workspace, parent: $parent})
        if (($workspace | path dirname) != $parent) or not (($workspace | path basename) | str starts-with 'nbmicrovm-transaction.') {
            error make {msg: 'workspace acquisition returned unexpected path'}
        }
        command $effect [chmod '0700' $workspace] 'private workspace chmod failed' | ignore
        let private_meta = (require-type $effect $workspace dir)
        if $private_meta.mode != 'rwx------' { error make {msg: 'workspace permission verification failed'} }
        let staging = ($workspace | path join 'tree')
        let candidate = ($workspace | path join 'candidate.img')
        do $effect {op: mkdir, path: $staging}
        require-type $effect $staging dir | ignore
        mut added = []
        mut ca_count = 0
        mut tree_kb = 0
        if $request.kind == 'state' {
            $stage = 'state-environment'
            if $request.env_stdin {
                let envf = ($staging | path join 'agent.env')
                do $effect {op: write, path: $envf, text: $request.text}
                command $effect [chmod '0600' $envf] 'environment chmod failed' | ignore
                if (require-type $effect $envf file).mode != 'rw-------' { error make {msg: 'environment permission verification failed'} }
            }
        } else {
            $stage = 'snapshot-sets'
            let snapshots = ($workspace | path join sets)
            do $effect {op: mkdir, path: $snapshots}
            for set in $sets {
                let selected = ($snapshots | path join $set.set)
                do $effect {op: copy, source: ($request.sets_dir | path join $set.set), target: $selected}
                if (do $effect {op: hash512, path: $selected}) != $set.sha512 { error make {msg: 'set snapshot digest mismatch'} }
            }
            $stage = 'extract'
            let excludes = if $request.full { [] } else { $TRIM | each {|p| ['--exclude' $p]} | flatten }
            command $effect [sudo bsdtar -xpf ($snapshots | path join 'base.tar.xz') -C $staging ...$excludes] 'base extraction failed' | ignore
            command $effect [sudo bsdtar -xpf ($snapshots | path join 'etc.tar.xz') -C $staging] 'etc extraction failed' | ignore
            $stage = 'configure'
            for entry in [[etc/rc '0555'] [etc/rc.shutdown '0555'] [etc/ttys '0644']] {
                install-file $effect $staging $entry.0 ($request.guest | path join $entry.0) $entry.1
            }
            for entry in [[myname $request.hostname] [fstab '']] {
                let input = ($workspace | path join $entry.0)
                do $effect {op: write, path: $input, text: $entry.1}
                install-file $effect $staging $'etc/($entry.0)' $input '0644'
            }
            for d in [state kern proc opt/datadog/bin] {
                stage-parent $effect $staging $'($d)/.directory-check' true | ignore
            }
            let resolv = (stage-parent $effect $staging etc/resolv.conf true)
            command $effect [sudo rm -f $resolv] 'resolv.conf removal failed' | ignore
            command $effect [sudo ln -s /var/run/resolv.conf $resolv] 'resolv.conf link failed' | ignore
            let certdir = ($staging | path join usr/share/certs/mozilla/server)
            # The selected release sets are trusted. Do not traverse a symlinked
            # cert ancestry; filenames/data are read only from the owned tree.
            if (inspect $effect $certdir).type != 'missing' {
                directory-chain $effect $certdir
                let pems: list<string> = (ls ($certdir | path join '*.pem' | into glob) | get name | sort)
                mut bundle = ''
                for p in $pems { require-type $effect $p file | ignore; $bundle = ($bundle + (do $effect {op: read, path: $p}) + "\n") }
                let input = ($workspace | path join 'ca.pem')
                do $effect {op: write, path: $input, text: $bundle}
                install-file $effect $staging etc/openssl/cert.pem $input '0644'
                install-file $effect $staging etc/openssl/certs/ca-certificates.crt $input '0644'
                $ca_count = ($pems | length)
            }
            if $request.authorized_keys != '' {
                let sshfile = (stage-parent $effect $staging root/.ssh/authorized_keys true)
                command $effect [sudo chmod '0700' ($sshfile | path dirname)] 'SSH directory chmod failed' | ignore
                if (require-type $effect ($sshfile | path dirname) dir).mode != 'rwx------' { error make {msg: 'SSH directory permission verification failed'} }
                install-file $effect $staging root/.ssh/authorized_keys $request.authorized_keys '0600'
            }
            for item in $items {
                install-file $effect $staging $item.dst $item.src $item.mode
                $added = ($added | append {src: $item.src, dst: $'/($item.dst)', mode: $item.mode, bytes: (require-type $effect $item.src file).bytes})
            }
            let usage = (command $effect [sudo du -sk $staging] 'tree size command failed' | str trim | split row "\t" | first)
            if $usage !~ '^\d+$' { error make {msg: 'invalid tree size response'} }
            $tree_kb = ($usage | into int)
        }
        $stage = 'makefs'
        let prefix = if $request.kind == 'root' { [sudo] } else { [] }
        let size_args = if $request.kind == 'state' { [-s $'($request.size_mb)m'] } else { [-b $'($request.free_pct)%' -f $'($request.free_pct)%'] }
        command $effect [...$prefix makefs -t ffs -B le -o version=2 -o minfree=0 ...$size_args $candidate $staging] 'makefs failed' | ignore
        $stage = 'verify-candidate'
        if $request.kind == 'root' {
            let uid = (command $effect [id -u] 'uid lookup failed' | str trim)
            let gid = (command $effect [id -g] 'gid lookup failed' | str trim)
            if $uid !~ '^\d+$' or $gid !~ '^\d+$' { error make {msg: 'invalid uid/gid response'} }
            command $effect [sudo chown $'($uid):($gid)' $candidate] 'image chown failed' | ignore
        }
        command $effect [...$prefix chmod '0600' $candidate] 'image chmod failed' | ignore
        let image = (require-type $effect $candidate file)
        if $image.bytes <= 0 or $image.mode != 'rw-------' { error make {msg: 'image size/permissions invalid'} }
        if $request.kind == 'state' and $image.bytes != ($request.size_mb * 1048576) { error make {msg: 'state image size mismatch'} }
        let digest = (do $effect {op: hash, path: $candidate})
        if $digest !~ '^[0-9a-f]{64}$' { error make {msg: 'invalid candidate digest'} }
        # Cleanup before commit when requested. Its failure preserves old output
        # and the private candidate. State staging may contain secret text.
        $stage = 'cleanup'
        if not $request.keep_staging {
            if $request.kind == 'root' { command $effect [sudo rm -rf $staging] 'staging cleanup failed' | ignore } else { do $effect {op: remove, path: $staging} }
            if (inspect $effect $staging).type != 'missing' { error make {msg: 'staging remains after cleanup'} }
            $cleanup = 'tree_removed'
        } else { $cleanup = 'tree_retained_by_request' }
        $stage = 'publish'
        # Caller owns output parent and excludes concurrent writers/mounts.
        # Recheck shape; candidate is in a sibling private directory on that FS.
        directory-chain $effect $parent
        let before_commit = (inspect $effect $out)
        if $before_commit.type != $initial.type { error make {msg: 'output changed before commit'} }
        if $initial.type == 'file' {
            if $before_commit.inode != $initial.inode or $before_commit.bytes != $initial.bytes or (do $effect {op: hash, path: $out}) != $initial_digest { error make {msg: 'output identity/content changed before commit'} }
        }
        $publishing = true
        do $effect {op: publish, source: $candidate, target: $out}
        $published = true
        $stage = 'readback'
        let installed = (require-type $effect $out file)
        if $installed.bytes != $image.bytes or $installed.mode != 'rw-------' or (do $effect {op: hash, path: $out}) != $digest {
            error make {msg: 'published image readback mismatch'}
        }
        let transaction = {published: true, durable: false, workspace: $workspace, cleanup: $cleanup}
        $report = if $request.kind == 'state' {
            {schema: $STATE_SCHEMA, image: {path: $out, bytes: $image.bytes, sha256: $digest}, size_mb: $request.size_mb, fs: 'ffs-wapbl', env_keys: $env_keys, state_device_hint: ld1a, transaction: $transaction}
        } else {
            {schema: $SCHEMA, netbsd_sets: $sets, trimmed: (not $request.full), tree_kb: $tree_kb, ca_certs: $ca_count, hostname: $request.hostname, added: $added, staging: (if $request.keep_staging { $staging } else { null }), image: {path: $out, bytes: $image.bytes, sha256: $digest}, fs: 'ffs-v2', root_device_hint: ld0a, transaction: $transaction}
        }
        {ok: true}
    } catch {|e|
        let message = ($e | get -o msg | default '')
        {ok: false, detail: (if (($message | str starts-with 'image child failed: ') or ($message | str starts-with 'image policy: ')) { $message } else { 'operation failed; see retained private workspace' })}
    }
    if $outcome.ok { $report } else {
        # Never serialize caught native stderr/input values. Latest mutation
        # state is assembled OUTSIDE catch, including ambiguous commit failure.
        {schema: (if $request.kind == 'state' { $STATE_SCHEMA } else { $SCHEMA }), error: $'image build failed at ($stage)', failed_stage: $stage, detail: $outcome.detail, transaction: {published: (if $published { true } else if $publishing { null } else { false }), durable: false, workspace: $workspace, cleanup: $cleanup, retained: ($workspace != null)}}
    }
}

export def image-request [kind: string, out: string] {
    {kind: $kind, out: $out, add: '', text: '', env_stdin: false, size_mb: 64, free_pct: 10, authorized_keys: '', sets_dir: '', guest: $GUEST, full: false, hostname: smolfire-netbsd, keep_staging: false}
}

def print-result [result: record] {
    $result | to json --indent 2 | print
    if 'error' in $result { exit 1 }
}

def main [--sets-dir: string, --out: string, --add: string = '', --authorized-keys: string, --hostname: string = 'smolfire-netbsd', --free-pct: int = 10, --full, --keep-staging] {
    if $out == null or $sets_dir == null { error make {msg: '--out and --sets-dir are required'} }
    verify-sets {|r| image-effect $r} ($sets_dir | path expand --no-symlink) | ignore
    let req = (image-request root $out | merge {sets_dir: ($sets_dir | path expand --no-symlink), add: $add, authorized_keys: (if $authorized_keys == null { '' } else { $authorized_keys | path expand --no-symlink }), hostname: $hostname, free_pct: $free_pct, full: $full, keep_staging: $keep_staging})
    print-result (build-image $req)
}

def 'main state' [--out: string, --size-mb: int = 64, --env-stdin] {
    let text = if $env_stdin {
        # Script invocation inherits OS stdin; it does not supply main's $in.
        let child = (^cat | complete)
        if $child.exit_code != 0 { error make {msg: 'state environment stdin read failed'} }
        $child.stdout | into string
    } else { '' }
    if $out == null { error make {msg: '--out is required'} }
    # Retain pre-effect grammar diagnostics used by the existing full suite.
    validate-agent-env $text | ignore
    print-result (build-image (image-request state $out | merge {size_mb: $size_mb, env_stdin: $env_stdin, text: $text}))
}
