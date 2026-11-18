# Build patches

Local patches for pinned upstream sources. The image build applies each patch;
a source bump that stops a patch applying fails the build instead of silently
dropping it.

Name files `<source>-<purpose>.patch`.

| Patch | Target | Applied in |
| --- | --- | --- |
| `apollo-rumble.patch` | `apollo-git` `PKGBUILD` | `apollo-builder` |
| `obs-vkcapture-device-proc-fallback.patch` | `src/vklayer.c` | `vkcapture-builder` |

The Apollo patch is inserted into the AUR `prepare()` after the submodule
checkout; the Dockerfile checks the recipe anchor. The capture patch is checked
with `git apply --check` before it is applied.
