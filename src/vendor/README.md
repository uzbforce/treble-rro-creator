# Vendor files (optional)

This folder is only used by **advanced** builds that ship vendor HALs
(fingerprint, vibrator, …) with the overlay module.

The contents are ignored by git — they are extracted from your own device or
firmware and are usually proprietary.

## Layout

Put extracted files in the same shape they have on the device, without the
leading `/system`:

```
src/vendor/
├── bin/hw/                   HAL binaries       → /system/vendor/bin/hw/
├── lib64/                    shared libraries  → /system/vendor/lib64/
├── etc/init/                 init .rc files    → /system/vendor/etc/init/
└── etc/vintf/manifest/       VINTF fragments   → /system/vendor/etc/vintf/manifest/
```

`build.sh` copies everything under `src/vendor/` into the module's
`system/vendor/` and adds it only when you choose **Include vendor HALs**.

## Before you start

- Read [docs/device-extraction.md](../../docs/device-extraction.md).
- Keep `HAS_VENDOR_FINGERPRINT_HAL` / `HAS_VENDOR_VIBRATOR_HAL` in
  `config.env` set to `false` until the files are actually in place.
- Start with an overlay-only build and verify it boots before adding HALs.

SELinux rules go in `src/module/sepolicy.rule`, install permissions in
`src/module/customize.sh`, and service startup in `src/module/service.sh`.
