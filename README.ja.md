# smolfire

[![CI](https://github.com/ryanmaclean/smolfire/actions/workflows/ci.yml/badge.svg)](https://github.com/ryanmaclean/smolfire/actions/workflows/ci.yml)

## 概要

smolfireは、最小限のFreeBSD 15 VM（aarch64を主要対象、amd64を副対象）と、
mbox+TOMLメールスプールを介してビルド・レビュー・運用タスクをエージェントへ
ディスパッチするNushell製のコーディネーター有限状態機械（FSM）を組み合わせた
プロジェクトです。目標は、HVF/KVMホスト上で30秒以内に無人でログインプロンプトまで
起動する小さなqcow2アーティファクトを、会話履歴を共有せずコーディネーターだけで
エンドツーエンドに構築することです。

## ステータス

2026年7月24日時点：

| 系統 | 起動ゲート | イメージサイズ | 備考 |
|---|---|---|---|
| amd64 | KVM上でログインまで9秒 — **PASS** | **66.6 MiB raw、圧縮ダウンロード26.6 MiB**（512 MiB以下のゲート **PASS**） | ホステッドパイプラインでエンドツーエンドにビルド済み。[リリース](https://github.com/ryanmaclean/smolfire/releases)を参照 |
| aarch64 | ARMハードウェアが必要（`docs/BHYVE-GATE-AMD64.md`参照） | 同じパイプラインでクロスビルド済み、サイズゲートのみ | 以前のネイティブビルド基準値：HVF上で11秒、ダイエット前1.41 GiB |
| **SMOLFIRE**（microVM） | **Firecracker上でシェルまで511 ms**（QEMU microvmでは569 ms）、TCPネットワークゲート＋ホストping **PASS** | **37 MiB — PVH ELF 1個がOS全体**（カーネル＋静的な`/rescue` MFS rootfs） | microVM向けの最小イメージ |

検証済みの調査結果とイメージ削減計画は [`docs/UR-BSD-VERIFY.md`](docs/UR-BSD-VERIFY.md)、
初期ベースラインの報告は [`docs/PHASE-1-RESULTS.md`](docs/PHASE-1-RESULTS.md)を参照してください。

## クイックスタート

**すべての環境で必要なもの：** [Nushell](https://www.nushell.sh) **0.115.1**。
CIが[`.github/nu-version`](.github/nu-version)で固定しているバージョンです
（`pkg install nushell` / `brew install nushell` / GitHubリリースのバイナリ）。
0.112.2では`bin/coord-tick.nu`の`str lowercase`で失敗し、0.111以前では`get -o`で失敗します。

利用できる環境に応じて、次の3通りの始め方があります。

1. **FreeBSDホストがない場合：** [ホステッドビルドパイプライン](.github/workflows/build-image-hosted.yml)を
   Actionsタブから実行します。標準のGitHub runner上でqcow2をビルドし、ワークフローアーティファクトとして
   アップロードします（`docs/BUILDING.md`の「パイプラインでのビルド」を参照）。ゲートを通過したビルドは
   手動の`Release smolfire Image`ワークフローで公開できます。[リリース](https://github.com/ryanmaclean/smolfire/releases)で
   ビルド済みイメージを確認してください。
2. **FreeBSD 15ホストがある場合：** 以下の**ビルド**を参照してネイティブにビルドします。
3. **qcow2をすでに持っている場合：** 起動します。

   ```sh
   qemu-system-x86_64 -M q35 -accel kvm -cpu host -m 512M \
     -drive file=smolfire.qcow2,format=qcow2,if=virtio \
     -nic user,model=virtio-net-pci -nographic
   # （macOSでは-accel hvf。その他の環境で低速なTCGを使う場合は-accel/-cpuを削除）
   ```

   `root` / パスワード`smolfire`でログインします。**開発用イメージ専用：**
   `PermitRootLogin yes`とパスワード認証が有効です。初回ログイン時にパスワードを変更し、
   QEMUのユーザーモードネットワークの外部に決して公開しないでください。

## リポジトリ構成

| パス | 内容 |
|---|---|
| `bin/` | コーディネーターFSM（`coord-*.nu`、`sh bin/coord-run.sh`で実行）、イメージビルド（`build-smolfire-vm.nu`）、運用ツール（`harvest.sh`、`qemu-smolfire-vm.nu`、bhyveツール） |
| `sys/`、`release/tools/` | SMOLFIREカーネル設定とリリースイメージ設定 |
| `tests/` | Nuのユニット／統合テストと`expect`起動ゲート（`sh tests/run-all.sh`） |
| `docs/` | `BUILDING.md`（最初に読む文書）、`UR-BSD.md`／`UR-BSD-VERIFY.md`（サイズ削減作業）、`BHYVE-GATE-AMD64.md` |
| `plans/`、`.planning/` | フェーズ計画の記録（履歴） |
| `var/` | 実行時のスプール／状態。コミットしないでください（`CLAUDE.md` §9参照） |

## ビルド

完全なパイプラインは[`docs/BUILDING.md`](docs/BUILDING.md)にあります。`/usr/src`を
`releng/15.0`でチェックアウトしたFreeBSD 15 aarch64ホストから実行するワンライナーは次のとおりです。

```sh
sudo nu bin/build-smolfire-vm.nu
```

このコマンドはセットアップ、`buildworld`、`buildkernel KERNCONF=SMOLFIRE-VM`、
カーネルオブジェクトのクリーンアップ、`make cloudware-release`（リリースイメージの生成）を実行します。
出力は`/var/tmp/smolfire-build.log`に記録されます。
`--check`は読み取り専用の事前チェック、`--skip-buildworld`は長時間のビルド後の再開、
`--arch amd64`はクロスコンパイルに使用します。

## ハーベストと受け入れゲート

`bin/harvest.sh`はリモートビルドホスト（aarch64はジャンプホスト経由の`<aarch64-builder>`、
amd64はVultr）からqcow2アーティファクトを`var/artifacts/`へ取得し、サイズおよび起動ゲートを実行して、
`var/artifacts/harvest-report.txt`へ結果を書き込みます。

```sh
sh bin/harvest.sh
```

ゲートは次のとおりです。

- サイズが512 MiB以下（qcow2に対する`wc -c`）
- `expect tests/time-to-ready-arm64.exp` / `tests/time-to-ready.exp`による起動

イメージの肥大化を調査するには、rootfsをマウントし、ディレクトリ、ファイル、pkgbaseパッケージを
サイズ順に上位から出力します。

```sh
bin/analyze-image.sh path/to/FreeBSD-15-aarch64-smolfire.qcow2
```

Linux（qemu-nbd）とFreeBSD（mdconfig）で動作します。イメージの隣に`.size-report.txt`を作成し、
使用量が512 MiBを超える場合は非ゼロで終了します。

## コーディネーター

Nushellコーディネーターの詳細は[`CLAUDE.md`](CLAUDE.md)に記載されています。ループを実行するには：

```sh
sh bin/coord-run.sh
```

手動で1ティック進めるには：

```sh
nu bin/coord-tick.nu
```

環境変数による上書き（すべて任意）：

| 変数 | デフォルト | 用途 |
|---|---|---|
| `ROOT` | `.` | リポジトリルート |
| `INTERVAL` | `60` | 通常のティック間隔（秒） |
| `HALT_INTERVAL` | `10` | 停止中のスリープ時間（秒） |
| `STATE_FILE` | `var/run/coord-state.toml` | 永続化されるFSM状態 |
| `SPOOL` | `var/mail/spool` | mboxスプールのパス |

FSMの状態は`idle -> dispatching -> waiting -> harvesting -> halted`です。
`dispatching`では、`claude` CLIが`PATH`上にあれば対象エージェントを自動起動します（Phase IIの接続）。
そうでなければ、リクエストをキューに入れ、外部エージェントがスプールへ返信するのを待ちます。
グローバル緊急停止は`touch var/mail/HALT`、タスク単位の停止は`var/mail/HALT.<task_id>`です。

## テスト

```sh
sh tests/run-all.sh
```

すべての`tests/*-test.nu`スイートを実行します。ハードウェア依存のスイート（TPM）は、
ハードウェアまたはイメージがない場合に失敗ではなく`SKIP`を報告するため、新規クローン直後でも
基本的にグリーンになります。個別のスイートは`nu tests/<file>.nu`で直接実行できます。

## ライセンス

プロジェクトコードはApache-2.0です（[`LICENSE`](LICENSE)参照）。FreeBSDベースのコンポーネントは
元のBSD-2-Clause／BSD-3-Clauseライセンスを維持します。GPL／LGPL／AGPL依存関係はありません。
