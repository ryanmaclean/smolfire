Both images built, gated, and verified end-to-end by CI on stock GitHub runners (PR #100; findings ledger: docs/UR-BSD-VERIFY.md, 2026-09-24 sections). Full-image builds now take ~35 min (was ~3.5 h).

## smolfire-amd64-0.5.0.qcow2 (25.0 MiB download, 62.6 MiB raw)
Diet round 3 + build-knob trims (was 66.6 MiB in 0.3.0, 223 MiB in 0.1.0). Gates on this exact image: KVM boot 9s to login, LDDCHECK zero orphaned libraries, size gate PASS.
- Boot: `qemu-system-x86_64 -M q35 -accel kvm -cpu host -m 512M -drive file=smolfire-amd64-0.5.0.qcow2,format=qcow2,if=virtio -nic user,model=virtio-net-pci -nographic`

## smolfire-aarch64-0.5.0.qcow2 (24.9 MiB download, 63.1 MiB raw)
**The first aarch64 image the pipeline has ever produced** — and its first boot anywhere passed the new same-ISA TCG soft-gate: 31s to login on a hosted ubuntu-24.04-arm runner with no hardware acceleration (entropy via Armv8 RNDR). Built just before the round-3 cut landed; the cut rides the next aarch64 run.
- Boot (any aarch64 host, or Apple Silicon with `-accel hvf -cpu host`): `qemu-system-aarch64 -machine virt -cpu max -m 512M -drive if=pflash,format=raw,readonly=on,file=<AAVMF/EDK2 code fd> -drive file=smolfire-aarch64-0.5.0.qcow2,format=qcow2,if=virtio -nic user,model=virtio-net-pci -nographic`

Login: root / smolfire — **dev images**: change the password on first login; never expose beyond QEMU user-mode networking.

Kernel-only SMOLFIRE microVM (one-ELF, 511 ms): unchanged since 0.4.0 — use smolfire-kernel-0.4.0.gz from that release.

Verify: `sha256sum -c SHA256SUMS-0.5.0`
