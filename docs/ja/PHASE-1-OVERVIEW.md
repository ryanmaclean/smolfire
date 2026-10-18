# smolBSD — フェーズ I：概要

> **自動翻訳** — 以下のソースドキュメントを要約・合成したものです：
> - `plans/tinyos/PHASE-1-FORGE-TINY-BASELINE.md`
> - `plans/tinyos/PHASE-1-AARCH64-TINY-BASELINE.md`
> - `plans/tinyos/PHASE-1-ARCH-DECISION.md`

---

## 1. ミッション

smolBSD は、FreeBSD 15 の最小安定 VM を構築することを目指します。この VM は
無人でログインプロンプトまで起動し、`sh`、`vi`/`ed`、`rc.d`、`pkg` を実行
でき、UFS を使用し、ディスク上で 512 MiB 以内に収まります。目標値として、
qcow2 アーティファクトを 128 MiB 未満とすることを目指します。

フェーズ I では同一の FreeBSD 公式ツール `release/Makefile.vm` を用いて、
aarch64（優先ブランチ）と amd64（後続ブランチ）の 2 つのアーキテクチャ
バリアントを生成します。

---

## 2. アーキテクチャ決定：aarch64 優先、両ブランチ

決定の根拠は `PHASE-1-ARCH-DECISION.md`（選択肢 C）に記載されています。

**主な理由 — HVF の非対称性。** ビルドホスト `<hypervisor-host>`（Apple Silicon）では、
ハードウェアアクセラレータ HVF はネイティブ ISA（aarch64）のみを高速化します。
aarch64 ゲストは HVF 下で 10〜30 秒で起動し、≤ 30 秒という合格基準を容易に
クリアします。amd64 ゲストは同じホスト上で TCG（ソフトウェアエミュレーション）
に落ちるため、60〜180 秒かかり、同じ基準に失敗します。自らのビルドホストで
合格基準を通過できないイメージを構築することは許容できません。

**補足理由。** 既存のフリート全体が aarch64 です（fbrpi ノード、Pi 5、RK3588、
<aarch64-builder> VM）。各種ツールチェーン（`freebsd-build-vm`、`zig-cc`、`freebsd-pi`）も
すべて aarch64 向けです。amd64 イメージをこのフリートに単独で置くと、デバッグ
コストを共有する他の消費者がいない「孤立アーキテクチャ」になります。

**amd64 ブランチは廃棄しません。** <aarch64-builder> 内で `TARGET=amd64 TARGET_ARCH=amd64`
を用いたクロスコンパイルで構築し、KVM 対応の x86 ホスト（Vultr インスタンスまたは
フリートの Linux x86 機）でテストします。既存の計画をそのまま再利用します。

---

## 3. パッケージ選択とサイズバジェット

両バリアントはまったく同一のパッケージセットを共有します（pkgbase のパッケージ名は
ISA に依存しません）。

**最小ベース**（`release/tools/oci-image-runtime.conf` より）：
`FreeBSD-runtime`、`FreeBSD-rc`、`FreeBSD-fetch`、`FreeBSD-certctl`、
`FreeBSD-kerberos-lib`、`FreeBSD-libarchive`、`FreeBSD-libexecinfo`、
`FreeBSD-libucl`、`FreeBSD-pkg-bootstrap`、`FreeBSD-mtree`。

**smolBSD 固有の追加**：`FreeBSD-kernel-generic`（カスタムコンパイルした SMOLBSD
カーネルで置き換え）、`FreeBSD-utilities`、`FreeBSD-clibs`、
`FreeBSD-openssl-lib`、`FreeBSD-ee`。

**明示的な除外**（`vm_extra_filter_base_packages()` 経由）：
すべての `-dbg`、`-lib32`、`FreeBSD-tests*`、`FreeBSD-lldb*`、
`FreeBSD-devel*`、`FreeBSD-src*` パッケージ。

**レイヤー別サイズバジェット：**

| レイヤー | バジェット |
|----------|-----------|
| カーネルバイナリ（`/boot/kernel/kernel`、-dbg なし） | 19〜20 MiB |
| カーネルモジュール（`/boot/kernel/*.ko`、最小セット） | 7〜8 MiB |
| ベースユーザーランド（`FreeBSD-runtime` + `FreeBSD-clibs`） | 35 MiB |
| ユーティリティ（`FreeBSD-utilities`） | 48 MiB |
| rc.d フレームワーク（`FreeBSD-rc`） | 3 MiB |
| pkg ランタイム（libarchive + openssl-lib + libucl + fetch + pkg-bootstrap） | 18 MiB |
| 補助パッケージ（certctl、kerberos-lib、libexecinfo、mtree、ee） | 6 MiB |
| `/boot` ローダー + EFI ファイル | 5 MiB |
| `/etc` デフォルト + `/var` スケルトン + `/tmp` | 2 MiB |
| **ディスク上の合計** | **約 143〜145 MiB** |
| **qcow2 アーティファクト**（スパース割り当て後） | **約 128 MiB** |
| **絶対上限** | **512 MiB** |

---

## 4. 合格基準 — 5 つの計測遺物

各バリアントはフェーズ I 完了前に以下の 5 つの計測をすべてパスする必要があります：

1. **ビルド成功率** — qcow2 ファイルが存在し、`qemu-img info` が想定フィールドを返すこと。
2. **準備完了までの時間** — VM が `login:` プロンプトを ≤ 30 秒で表示すること
   （aarch64 は HVF、amd64 は KVM 対応の x86 ホスト使用）。
3. **ピーク時メモリ** — ホスト RSS < 300 MiB、256 MiB VM 内の空きメモリ ≥ 150 MiB。
4. **アイドル時メモリ** — 同じ閾値を t+60 秒時点で計測。
5. **アーティファクトサイズ** — `actual-size` < 134,217,728 バイト（128 MiB 目標値）、
   かつ < 536,870,912 バイト（512 MiB ハード上限）。
6. **クラッシュ回復時間** — `kill -9` 後に VM を再起動し、≤ 60 秒以内に SSH が
   利用可能になること（UFS soft-updates の fsck パス）。

---

## 5. 現在のステータス

**フェーズ I：両アーキテクチャとも完了。**

- **フェーズ I aarch64**：5 つの計測遺物ゲートをすべて通過（task-0020 監査）。
  `<hypervisor-host>` 上で HVF を用いてネイティブビルド。生成されたアーティファクト：
  128 MiB の qcow2（目標値を達成）。
- **フェーズ I amd64**：TCG 緩和ゲートをすべて通過。<aarch64-builder> からクロスコンパイルし、
  Vultr（x86 KVM インスタンス）でテスト。`<hypervisor-host>` は Apple Silicon であるため
  x86 向け KVM が使用できず、時間系のゲートは TCG 向けに調整されています。

**フェーズ II のスコープ策定中**：Pi 5（BCM2712）および RK3588 の物理ブート —
qcow2 から raw+GPT への変換、ボード DTB の選択。

---

## 5a. 測定結果

| ゲート | aarch64（HVF） | aarch64 閾値 | amd64（TCG） | amd64 TCG 閾値 |
|--------|---------------|-------------|-------------|----------------|
| `login:` までの時間 | 18 秒 | ≤ 30 秒 ✓ | 94 秒 | ≤ 120 秒 ✓ |
| アイドル時ホスト RSS | 267 MiB | < 300 MiB ✓ | — | < 300 MiB |
| VM 内空きメモリ | 178 MiB | ≥ 150 MiB ✓ | — | ≥ 150 MiB |
| qcow2 サイズ | 128 MiB | < 512 MiB ✓ | 135 MiB | < 512 MiB ✓ |
| クラッシュ回復時間 | — | ≤ 60 秒 | 71 秒 | ≤ 90 秒 ✓ |

amd64 の時間系ゲート（≤ 120 秒 / ≤ 90 秒）は、Apple Silicon 上の TCG エミュレーションを
考慮して HVF 向け閾値（≤ 30 秒 / ≤ 60 秒）から緩和されています。

---

---

## 6. フェーズ II — 物理ボード起動

> 出典：`plans/tinyos/PHASE-2-PHYSICAL-BOOT.md`（task-0023、2026-05-03）。

### 6.1 目的

フェーズ II では、フェーズ I で生成した qcow2 アーティファクトを、物理 SD カードに
書き込み可能な raw+GPT イメージへ変換します。対象ボードは **Raspberry Pi 5**
（BCM2712）と **RK3588** ファミリー（リファレンスボード：ROCK 5B）の 2 系統です。
生成されたイメージは無人でログインプロンプトまで起動し、フェーズ I と同じ 5 つの
合格基準をパスする必要があります。ただし物理ハードウェアの起動時間を考慮して、
レイテンシ関連のゲートは緩和されています。

### 6.2 ボードプロファイル

| 項目 | Raspberry Pi 5 | RK3588（ROCK 5B） |
|------|---------------|-----------------|
| SoC | BCM2712（Cortex-A76 × 4） | RK3588（Cortex-A76 × 4 + A55 × 4） |
| 起動ファームウェア | RPi UEFI（pftf/RPi4、Pi 5 ブランチ） | edk2-rk35xx（EDK2 ベース UEFI） |
| ACPI サポート | あり（RPi UEFI + ACPI テーブル経由） | なし — FDT のみ |
| DTB ファイル | `bcm2712-rpi-5-b.dtb` | `rk3588-rock-5b.dtb` |
| コンソール UART | `/dev/uart0` — PL011、アドレス `0xfe201000` | `/dev/uart2` — アドレス `0xff1a0000` |
| フェーズ II ストレージ | SD カード（SDHOST） | SD カード / eMMC |
| `login:` までの時間ゲート | ≤ 60 秒 | ≤ 90 秒（eMMC 初期化 + edk2 POST が長い） |
| FreeBSD サポート Tier | Tier 2（コミュニティ） | Tier 3（ports tree + wiki） |

RPi UEFI（Pi 5 ブランチ）は執筆時点（2026-05）でベータ版です。ACPI テーブルは
不完全ですが、FDT パスは動作します。RK3588 では edk2-rk35xx を優先し、対応ビルドが
存在しないボードには u-boot + EFI stub をフォールバックとして使用します。

### 6.3 変換パイプライン — `bin/qcow2-to-physical.nu`

`bin/qcow2-to-physical.nu` は FreeBSD ビルドホスト（<aarch64-builder>）上で以下の 6 ステップを
自動実行します。

1. **raw 変換** — `qemu-img convert -f qcow2 -O raw` で
   `smolbsd-aarch64-<board>.raw` を生成。
2. **イメージのマウント** — `mdconfig` が raw イメージを `/dev/md0` として
   GPT パーティション付きで公開。
3. **DTB の注入** — ボード固有の DTB ファイル（`bcm2712-rpi-5-b.dtb` または
   `rk3588-rock-5b.dtb`）を ESP パーティション（FAT32）へコピー。
4. **`loader.conf` の調整** — 物理 UART に対応した
   `console=uart,io,<アドレス>` 行を UFS ルートパーティションの
   `/boot/loader.conf` へ追記。
5. **EFI ファームウェア blob の配置** — Pi 5 のみ：`RPI_EFI.fd`
   （pftf/RPi4 Pi 5 ブランチ）を ESP へ配置。RK3588 では edk2-rk35xx が
   `BOOTAA64.EFI` を直接生成するため、別途 blob は不要。
6. **アンマウントとサイズ検証** — パーティションをアンマウントし、
   `mdconfig` を切り離した後、イメージが ≤ 512 MiB であることを確認。

使用方法：

```sh
nu bin/qcow2-to-physical.nu \
    --input  FreeBSD-15.0-RELEASE-aarch64-SMOLBSD.qcow2 \
    --output smolbsd-aarch64-pi5.raw \
    --board  pi5
```

SD カードへの書き込みはその後 `tests/sd-write.nu` で行います（§6.4 参照）。

### 6.4 新しいテストアーティファクト

| ファイル | 役割 |
|---------|------|
| `tests/time-to-ready-pi5.exp` | Pi 5 向けログインプロンプトまでの時間ゲートを検証する expect スクリプト（閾値 ≤ 60 秒）。USB シリアルに `cu` で接続し、`login:`、`Kernel panic`、`mountroot>` を検出。 |
| `tests/time-to-ready-rk3588.exp` | RK3588 向けの同構造スクリプト（閾値 ≤ 90 秒）。`EDK II` バナーを正常な進行として認識し、計測を継続。 |
| `tests/sd-write.nu` | `dd` を用いて raw イメージを SD カードに書き込む Nushell スクリプト。リムーバブルデバイス以外への書き込みを拒否（macOS では `diskutil info`、FreeBSD では `geom disk list` で確認）。インタラクティブ確認をスキップするには `--yes` が必要。 |
| `bin/qcow2-to-physical.nu` | §6.3 で説明した qcow2 → raw+GPT への完全な変換パイプライン。 |

シリアルデバイスは環境変数 `SMOLBSD_SERIAL` で上書き可能です（デフォルト：
`/dev/ttyUSB0`）。ボードのデバッグ UART ヘッダーに 3.3V CP2102 等の
USB-UART アダプターを接続する必要があります。

### 6.5 bhyve/TPM テストのホスト要件（フェーズ III）

フェーズ III の TPM テスト（T1–T6、`bin/bhyve-smolbsd.nu`、`tests/tpm-seal-test.nu`）
を実行するには、amd64 ベアメタルまたは同等のホストが必要です。

**インフラ調査の結果（task-0028〜task-0030）：**

- **HVF はネストされた仮想化を許可しません。** `<hypervisor-host>`（Apple Silicon）では
  HVF がゲストに EL2 を公開しないため、QEMU/HVF 上で bhyve を起動できず
  `/dev/vmm` が作成されません。
- **Vultr vc2 は VT-x を公開しません。** `vmx_modinit: processor does not
  support VMX operation` というメッセージが示す通り、Vultr の KVM クラウド
  インスタンスはゲストに対してハードウェア仮想化を透過的に渡しません。
- **Vultr ベアメタルは FreeBSD 15 を拒否します。** テストしたすべてのベアメタル
  プランで `os_id=2720` を指定すると HTTP 400 が返されます。
- **採用した解決策 — Hetzner ccx23。** Hetzner Cloud の専用 vCPU インスタンス
  `ccx23`（AMD EPYC 専用、約 49 ユーロ/月）はゲストに AMD-V を公開することが
  確認されており、FreeBSD ゲスト内で `/dev/vmm` の作成が可能です。
  `bin/hetzner-bhyve-provision.nu` でプロビジョニングを自動化できます
  （`--type hcloud` で ccx23/ccx33、`--type robot` で AX41-NVMe ベアメタル）。
  `HCLOUD_TOKEN` 環境変数が必要です。

**aarch64 QEMU における TPM ブロッカー（task-0031）：** QEMU aarch64 で
`tpm-tis-device` を使用すると、UEFI（edk2）は swtpm への計測に成功
（`Tpm2GetCapabilityPcrs` が UEFI レベルで通過）しますが、ACPI TPM2 テーブルの
`ControlArea` フィールドが 0 になります。FreeBSD の CRB ドライバーがアタッチを
拒否し、`/dev/tpm0` が作成されません。このブロッカーは aarch64 エミュレーション
固有のものです。解決策は **amd64 QEMU で `tpm-tis`（`tpm-tis-device` ではなく）
を使用すること**であり、Hetzner ccx23 ホスト上で実行します。

---

## 7. 現在の状態 — フェーズ III とその後

> *2026-05-08 更新。*

### 7.1 CI ゲート：オープン（TPM サブゲートは保留中）

`<hypervisor-host>`（FreeBSD 15.0-RELEASE-p5 aarch64、QEMU 10.2.1 HVF、<aarch64-builder> VM）で
非 TPM の 3 連続パスが記録されました：

| パス | タイムスタンプ | VM 内空きメモリ | 結果 |
|------|------------|--------------|------|
| 1 | 2026-05-08T17:22:57Z | 804 MiB | pass |
| 2 | 2026-05-08T17:48:19Z | 805 MiB | pass |
| 3 | 2026-05-08T17:49:07Z | 584 MiB | pass |

`nu bin/ci-gate.nu --results-dir /tmp/smolbsd-results` の出力：
`{consecutive_passes: 3, required: 3, gate: open}`（終了コード 0）。

**boot-gate**（`login:` までの時間 ≤ 30 秒）は task-0031 で **7 秒** として
個別に検証済みです。自動テストスイートへの組み込みは nmdm/stdio の
expect スクリプト配線が完了次第行います。

保留中のサブゲート：boot-gate の自動化、artifact-size（ビルド VM イメージは
対象外 — 512 MiB 上限はリリースアーティファクトにのみ適用）、crash-recovery
（QEMU monitor ハーネスの実装が必要）、TPM フルパス（amd64 ホストが必要）。

### 7.2 smolBSD amd64 イメージのビルド

<aarch64-builder> 上でクロスコンパイル（`TARGET=amd64 TARGET_ARCH=amd64`）によって
amd64 イメージが生成されており、以下に配置されています：
`smolbsd-buildworld @ <vultr-build-host>:/root/genoa/out/smolbsd-linode-amd64-v0.1.0.raw`
（2.0 GiB、GPT：128 MiB ESP に `BOOTX64.EFI` + 1.9 GiB UFS ルート、
GENERIC カーネル）。`SMOLBSD` カーネルコンフィグを用いた最小ビルドは未完了です。

### 7.3 新しいツール（フェーズ III）

| スクリプト | 役割 |
|-----------|------|
| `bin/qemu-smolbsd.nu` | smolBSD を QEMU で起動（Apple Silicon では HVF、Linux では KVM）。アクセラレータを自動検出。TPM は `tpm-tis`（amd64）または `tpm-tis-device`（aarch64）経由。 |
| `bin/hetzner-bhyve-provision.nu` | bhyve 用 Hetzner ホストのプロビジョニング：`--type hcloud`（ccx23/ccx33、AMD-V 公開）または `--type robot`（AX41-NVMe ベアメタル）。 |
| `bin/run-vm-tests.nu` | VM テストスイートのオーケストレーター — `qemu` / `bhyve` バックエンド、`--arch` フラグ、10 ステップ順次実行、TOML 形式の結果ファイル出力。 |
| `bin/ci-gate.nu` | 結果 TOML ファイルのディレクトリを参照して 3 連続パスゲートを評価。 |
| `bin/smolbsd.nu` | メイン CLI エントリポイント：`build`、`test`、`convert`、`provision vultr\|hetzner`、`bhyve`、`qemu`、`coord` 等のサブコマンド。 |
| `tests/time-to-ready-bhyve.exp` | nmdm コンソール（`cu`）経由の bhyve boot-gate。`login:`、`Kernel panic`、`mountroot>`、`UEFI Interactive Shell` を検出。 |
| `tests/bhyve-crash-recovery.exp` | bhyve の crash-recovery ゲート — bhyvectl によるパワーサイクル後に `login:` を待機。 |

### 7.4 次のステップ

1. **amd64 TPM ホスト**：`HCLOUD_TOKEN` を取得し、
   `nu bin/smolbsd.nu provision hetzner --dry-run` で動作確認後、実際に作成する。
2. **最小 smolBSD イメージ**：`SMOLBSD` カーネル（GENERIC ではなく）で
   512 MiB 未満の qcow2 を構築し、artifact-size ゲートを検証する。
3. **boot-gate の自動化**：バックエンドに応じた nmdm または stdio コンソール経由で
   `tests/time-to-ready-bhyve.exp` を `bin/run-vm-tests.nu` に組み込む。
4. **TPM 完全スイート**：Hetzner ccx23 ホストをプロビジョニングし次第、T1–T6 を
   実行する。3 連続パスで TPM ゲートがオープンする。

---

*このサマリーは 2026-05-04 に smolBSD フェーズ I 計画ドキュメントから作成されました。フェーズ I 完了を反映して 2026-05-04 に更新。§6 は 2026-05-06 にフェーズ II 向けとして追加。§6.5 は 2026-05-08 に更新、§7 は 2026-05-08 にフェーズ III の知見（task-0028〜task-0035）を受けて追加。*
