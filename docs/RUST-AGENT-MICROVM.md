# Running a Rust agent (dd-agent-rs) in the SMOLFIRE microVM

Lab run, 2026-10-10. Host: pop (AMD Ryzen 9 7950X, Linux 6.18.7, QEMU 8.2.2, kvm_amd avic=Y).
Kernel: `smolfire-kernel` artifact from smolfire.yml run 36046130653 (main @ 54e7e0d23f).
No change to the kernel or the MFS root was needed. Everything below is runtime-only.

## Two host-side quirks found

### 1. `-cpu host` panics on Zen 4 + recent KVM (x2APIC LINT1 write)

With the README command line (`-M microvm -accel kvm -cpu host`), the kernel dies in `lapic_setup()`:

```
Fatal trap 9: general protection fault while in kernel mode
rcx: 0000000000000836  rax: 000000000000a400
```

0x836 is the x2APIC LVT LINT1 MSR. The value 0xa400 is NMI delivery with level trigger and active-low set. This KVM raises #GP on that x2APIC write. The GitHub runners (EPYC 7763, older KVM) accept it.
- `-smp 1` and the boot tunable `hw.x2apic_enable=0` do NOT help.
- **Workaround:** hide x2APIC from the guest with `-cpu host,-x2apic`. The guest then uses xAPIC and boots to `SMOLFIRE_READY`.

### 2. Never `mount -uw /`: the embedded MFS root is read-only kernel memory

`mount -uw /` on the md0 root immediately panics the guest:

```
panic: vm_fault_lookup: fault on nofault entry, addr: 0xffffffff80af6000
```

The embedded image lives inside the kernel ELF. Put writable state on tmpfs (`options TMPFS` is in SMOLFIRE) or on a virtio-blk disk instead.

## Recipe: no image rebuild needed

- The agent travels on a read-only UFS2 virtio-blk disk, made with `makefs` on a FreeBSD 15.1 build host. It holds:
  - `bin/dd-agent-rs`: stripped, dynamic PIE.
  - `lib/`: libc.so.7, libthr.so.3, libm.so.5, libsys.so.7, libgcc_s.so.1.
  - `libexec/ld-elf.so.1`.
  - `etc/cert.pem`, `etc/datadog.yaml` (no API key), and `run.sh`.
- The API key travels on a second, raw, 4 KiB virtio-blk disk backed by host tmpfs (/dev/shm, mode 600). Line 1 holds the key. It is never baked into the ELF or the agent disk.

```sh
qemu-system-x86_64 -M microvm -accel kvm -cpu host,-x2apic -smp 1 -m 512M \
  -kernel smolfire-kernel -append "hint.acpi.0.disabled=0 machdep.disable_tsc_calibration=0" \
  -netdev user,id=n0 -device virtio-net-device,netdev=n0 \
  -drive file=agent.ufs,if=none,id=d0,format=raw,readonly=on -device virtio-blk-device,drive=d0 \
  -drive file=/dev/shm/key.img,if=none,id=d1,format=raw,readonly=on -device virtio-blk-device,drive=d1 \
  -display none -nodefaults -serial unix:serial.sock,server=on,wait=off
```

On the console, after SMOLFIRE_READY:

```sh
mount -r /dev/vtbd0 /mnt && sh /mnt/run.sh
```

`run.sh` does the following:
- Mounts tmpfs on `/tmp` (run dir and log) and over `/etc` (for `resolv.conf` pointing at SLIRP 10.0.2.3, and `ssl/cert.pem`).
- Reads the key with `/rescue/rescue dd | /rescue/rescue sed`. Only the rc-linked names are on PATH, so other crunched tools are called as `/rescue/rescue <tool>`.
- Starts the agent through rtld direct exec, because `/libexec/ld-elf.so.1` does not exist on the MFS root:

```sh
LD_LIBRARY_PATH=/mnt/lib SSL_CERT_FILE=/etc/ssl/cert.pem \
  /mnt/libexec/ld-elf.so.1 /mnt/bin/dd-agent-rs run -c /mnt/etc/datadog.yaml &
```

Result: intake answered 202 for series, check_run and host metadata within 1 s of start. The cpu, load, memory, disk, io, network, uptime and file_handle checks run, and dogstatsd listens on udp [::1]:8125.

## Possible follow-ups (not done here)
- An rc hook that mounts `vtbd0` and runs `/mnt/run.sh` if present, so the console step goes away.
- Link `mkdir`, `dd`, `sed` and `tail` in `build-smolfire.sh`, so payload scripts need no `/rescue/rescue` prefix.
- A static (`crt-static`) dd-agent-rs build would drop the rtld and libs (2.8 MB).
