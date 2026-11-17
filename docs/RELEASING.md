# Releasing

How a maintainer cuts a release of the SL 2 driver: the version, the installers, the tag and the GitHub
release. Contributors don't need this: their pull requests leave the version and the committed installers
alone (AGENTS.md).

A release goes through a pull request like any other change. The PR carries the version bump and the
rebuilt installers, and is tested before it is merged; the tag and the GitHub release are made from the
merge commit afterwards.

## 1. Choose the version

`MAJOR.MINOR.PATCH`: the patch number for fixes only, the minor number when something is added (a tool,
an option, a status field), the major number for a change users must act on.

## 2. Bump it, and close the CHANGELOG section

`VERSION` is the source: the Makefile, `Installer/build-pkg.sh` and `tools/controlpanel/build-app.sh` read
it. These carry a copy and must match:

| File | What |
|---|---|
| `plugin/Device-Info.plist` | `CFBundleShortVersionString`, `CFBundleVersion` (the control panel shows these) |
| `tools/controlpanel/Info.plist` | the same two keys |
| `plugin/SL2Device.m`, `tools/sl2panel.m` | the fallback `SL2_VERSION` |
| `Makefile`, `Installer/build-pkg.sh`, `tools/controlpanel/build-app.sh` | the fallback when `VERSION` can't be read |

```
echo X.Y.Z > VERSION
sed -i '' 's/OLD/X.Y.Z/g' Installer/build-pkg.sh Makefile plugin/Device-Info.plist plugin/SL2Device.m \
    tools/controlpanel/Info.plist tools/controlpanel/build-app.sh tools/sl2panel.m
git grep -n 'OLD' -- ':!CHANGELOG.md' ':!docs'     # nothing should be left
```

In `CHANGELOG.md`, turn `## [Unreleased]` into `## [X.Y.Z] — YYYY-MM-DD`. Commit this on its own
("Version X.Y.Z").

## 3. Build and check the installers

```
make package        # build/RaneSL2-macOS-Universal.pkg and build/Rane-SL2-Installer-Mac-M1-M2-M3-M4.zip
```

`build-pkg.sh` builds everything from source (the release driver, no debug code), fills the version into
the installer's pages, and draws the installer's background. Before committing the result, check it:

```
pkgutil --expand-full build/RaneSL2-macOS-Universal.pkg /tmp/pkgcheck
P=/tmp/pkgcheck/RaneSL2-Core.pkg/Payload
find "$P" -type f                                   # 17 files: driver, SL2Api, kext Info.plist, app (with its firmware script), 3 tools
defaults read "$P/Library/Audio/Plug-Ins/HAL/SL2Device.driver/Contents/Info.plist" CFBundleShortVersionString
defaults read "$P/Applications/SL 2 Control Panel.app/Contents/Info.plist" CFBundleShortVersionString
"$P/usr/local/bin/sl2panel" --version
lipo -archs "$P/Library/Audio/Plug-Ins/HAL/SL2Device.driver/Contents/MacOS/SL2Device"   # x86_64 arm64
strings "$P/Library/Audio/Plug-Ins/HAL/SL2Device.driver/Contents/MacOS/SL2Device" | grep -c 'DBG '   # 0: a release build
grep -h 'subtitle">' /tmp/pkgcheck/Resources/*/Welcome.html                              # X.Y.Z in English and Spanish
unzip -l build/Rane-SL2-Installer-Mac-M1-M2-M3-M4.zip   # the Installer folder and tools/firmware only
```

The zip takes `tools/firmware` from the files git tracks, so no extracted firmware (Rane's) can get into
it. Then copy the results over the committed installers and commit them on their own:

```
cp build/RaneSL2-macOS-Universal.pkg Installer/
cp build/Rane-SL2-Installer-Mac-M1-M2-M3-M4.zip .
```

## 4. Test, and raise the pull request

Test the release on hardware as for any change (AGENTS.md, Testing): at least `make hwtest
ARGS="--loopback"` with the release's driver. The PR description says what was tested and what was not.
Merge it when it is ready.

## 5. Tag the merge commit and publish the release

After the merge, check the merge commit holds what was tested, then tag it. Tags are annotated and
signed, like the commits.

```
git fetch upstream
C=$(gh pr view N -R pepeleedj/Rane-SL2-Macos-ARM-Driver --json mergeCommit -q .mergeCommit.oid)
git diff --stat $C origin/<release branch>          # nothing: the merge holds the tested tree
git tag -s vX.Y.Z $C -m "Release X.Y.Z ..."          # a few lines on what the release brings
git tag -v vX.Y.Z
git push upstream vX.Y.Z
git push origin vX.Y.Z
```

The release's files come from the merge commit, so they are exactly what is committed. Its notes are an
install line, the version's CHANGELOG section and the files' SHA-256:

```
D=$(mktemp -d)
git show $C:Installer/RaneSL2-macOS-Universal.pkg > $D/RaneSL2-macOS-Universal.pkg
git show $C:Rane-SL2-Installer-Mac-M1-M2-M3-M4.zip > $D/Rane-SL2-Installer-Mac-M1-M2-M3-M4.zip
{ echo '**Install:** download `Rane-SL2-Installer-Mac-M1-M2-M3-M4.zip`, unzip it and run `Installer/Instalar-Rane-SL2.command`, or open `RaneSL2-macOS-Universal.pkg` directly. Universal (Apple Silicon and Intel).'
  echo
  git show $C:CHANGELOG.md | awk '/^## \[X\.Y\.Z\]/{f=1;next} /^## \[/{if(f)exit} f'
  echo; echo '**SHA-256**'; echo '```'
  (cd $D && shasum -a 256 RaneSL2-macOS-Universal.pkg Rane-SL2-Installer-Mac-M1-M2-M3-M4.zip)
  echo '```'; } > $D/notes.md
gh release create vX.Y.Z -R pepeleedj/Rane-SL2-Macos-ARM-Driver --verify-tag \
    --title "Rane SL 2 driver X.Y.Z" --notes-file $D/notes.md \
    $D/RaneSL2-macOS-Universal.pkg $D/Rane-SL2-Installer-Mac-M1-M2-M3-M4.zip
```

The README's download links use `releases/latest/download/<file>`, so they serve the new release as soon as
it is published; the file names must stay the same.

## 6. Install it

Install the released package on a Mac with a box (`open Installer/RaneSL2-macOS-Universal.pkg`) and check
that it took: `pkgutil --pkg-info com.pepelee.ranesl2.driver` shows the version, the installed binaries are
the package's, and the log shows `SL2Device X.Y.Z (release) AudioServerPlugIn Initialized` with the box
connected.
