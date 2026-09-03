# Deliberately inconsistent environment fixture

`OLD_TUTORIAL.md` represents documentation from an older checkout.
`loaded-package.toml` represents the package currently loaded from another
root. A fresh agent must verify `Base.pathof`, `pkgdir`, package version, and
active project, report the mismatch, and stop before using the unavailable
documented call.
