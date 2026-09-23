# smolfire

> 旧称「smolBSD」。無関係の NetBSD ベースのプロジェクト
> [NetBSDfr/smolBSD](https://github.com/NetBSDfr/smolBSD) との混同を避けるため改名しました。
> 詳細は [README.md](README.md) の「Name」セクションを参照してください。

組み込みおよびエッジデプロイ向けの最小限のFreeBSDイメージ。
アクターモデルのメールボックスシステムで協調動作します。

## smolfire とは

smolfireは、30秒以内にログインプロンプトまで無人起動する、最小かつ安定した
FreeBSD仮想マシンを構築するプロジェクトです。対象イメージはディスク上で512 MiB
以内に収まり（目標値：qcow2アーティファクト128 MiB未満）、`sh`、`vi`/`ed`、
`rc.d`、`pkg` の実行に必要なパッケージのみを含みます。

ビルドタスク間の協調は、アクターモデルのメールボックスで処理されます。各エージェント
（アーキテクト・ビルダー・レビュアー・リサーチャー）は、共有のmboxスプール
（`var/mail/spool`）から自分宛のタスクを読み取り、TOML本文を持つRFC 822エンベロープを
使ってスレッド内で返信します。コーディネーターは各ティックで返信を収集し、次のタスクを
ディスパッチします。エージェント間で会話履歴を共有する必要はなく、
Just-Enough-Context（JEC）ドロップが必要なすべての状態を運びます。

## フェーズI のターゲット

2つのブランチが並行して動作します。aarch64が主要ブランチです。

### aarch64 — Apple Silicon 上での HVF ネイティブ（`<hypervisor-host>`）

FreeBSD 15.0-RELEASE arm64。Apple Silicon Mac 上でホストされるFreeBSD 15 aarch64 VM
である `<aarch64-builder>` でネイティブビルドします。HVF（Hypervisor.framework）により、
aarch64ゲストはベアメタルに近い速度で動作します。30秒以内のログイン到達という
受け入れ条件はここでのみ達成可能です。TCG経由のamd64エミュレーションは5〜10倍遅くなります。

### amd64 — Vultr 上での KVM

FreeBSD 15.0-RELEASE amd64。aarch64の<aarch64-builder>ホストからクロスコンパイルし、
KVM対応のx86 Vultrインスタンスにデプロイして計時ゲートを実施します。

## ビルド方針

### バージョン管理：jj

すべてのコミットは [jj](https://github.com/martinvonz/jj)（Jujutsu VCS）を使用します。
外部ツールが要求する場合のみ、生のgitを使用します。

```sh
jj log --no-graph -r '@' --limit 5    # 最近の履歴
jj describe -m "your message"         # 作業コピーの説明を更新
jj new                                # 新しい変更を開く
```

### Nushell コーディネーター

`bin/coord-tick.nu` — コーディネーターのメインループ。各ティックで：

1. `var/mail/spool` を読み取り、エージェントの返信を収集する。
2. 判定と受け入れ基準を評価する。
3. 次のタスクエンベロープをスプールに追記する。

`bin/mbox-parse.nu` — mbox + TOML 本文を後続処理用の構造化レコードに
解析するヘルパー。

### メールボックススプール

`var/mail/spool` — 単一のRFC 822 mboxファイル。すべてのメッセージ（コーディネーターの
リクエストとエージェントの返信）がここに格納されます。アドレスは
`<役割>@smolfire.local` の形式に従います。TOML本文が構造化タスクのペイロードを運びます。

役割の例：
- `coordinator@smolfire.local`
- `architect@smolfire.local`
- `builder@smolfire.local`
- `reviewer@smolfire.local`

## クイックスタート

### 前提条件

- Apple Silicon Mac（aarch64/HVF パス用）または Vultr KVM インスタンス（amd64パス用）
- SSH ジャンプ経由でアクセスできるFreeBSD 15.0-RELEASE `<aarch64-builder>` VM：

```sh
ssh -J <hypervisor-host> -p 2222 builder@localhost
```

- コーディネータースクリプト用にローカルで利用可能な Nushell（`nu`）
- 受け入れテスト用の `expect`

### カーネルをビルドする

<aarch64-builder> に SSH 接続して実行：

```sh
make -j4 -C /usr/src buildworld buildkernel KERNCONF=SMOLFIRE-VM
```

aarch64 ネイティブパスではクロスコンパイルフラグは不要です。arm64 ホストからの
amd64 クロスコンパイルの場合：

```sh
make -j4 -C /usr/src buildworld buildkernel \
    KERNCONF=SMOLFIRE-VM \
    TARGET=amd64 \
    TARGET_ARCH=amd64
```

### 受け入れテストを実行する

```sh
expect tests/time-to-ready.exp
```

このテストはVMの起動からログインプロンプトまでの実時間を計測し、
30秒を超えると失敗します。

### コーディネーターを進める

```sh
nu bin/coord-tick.nu
```

## プロジェクト構成

```
bin/
  coord-tick.nu          # コーディネーターアクターループ
  mbox-parse.nu          # mbox+TOMLパーサー
docs/
  superpowers/specs/     # 設計仕様
plans/
  tinyos/                # フェーズ別ビルド計画
tests/
  time-to-ready.exp      # expectスクリプト：起動〜ログイン計時ゲート
var/
  mail/spool             # 共有mbox — 1ファイルにプロジェクトの全状態
```

## 技術的インスピレーション

- **アクターフレームワーク** — エージェントはスプールのみを通じて通信し、
  mboxファイル以外に共有状態を持たない
- **末尾再帰FSM** — コーディネーターは純粋な状態機械：スプールを読む、
  次の状態を計算する、メッセージを追記する、繰り返す
- **SIMD / ベクトル** — 将来のワークロードは、エッジ信号処理タスクで
  aarch64のNEON と amd64の AVX-512 をターゲットにする
- **セキュアエンクレーブ** — 長期目標：対応ハードウェア上のFreeBSD bhyve
  エンクレーブ内で機密ワークロードを実行する
- **\*BSD 基盤** — FreeBSDのベースはクリーンで許容的なライセンスの基盤を
  提供する；クロスアーキテクチャのパッケージツールにはNetBSD pkgsrcを検討中

## ライセンス

プロジェクト固有のコードは Apache-2.0。FreeBSDのベースシステムコンポーネントは
BSD-2-Clause / BSD-3-Clause ライセンスを維持します。GPL、LGPL、AGPL の依存関係は
許可されません。
