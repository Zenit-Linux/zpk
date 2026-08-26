import std/[unittest, os, tempfiles, strutils]
import ../src/zpkpkg/hcl
import ../src/zpkpkg/types
import ../src/zpkpkg/manifest
import ../src/zpkpkg/builder

## Testy jednostkowe zpk -- parser zpk.build, budowanie/pakowanie .zpk.

suite "manifest (zpk.build)":
  test "parsuje minimalny zpk.build":
    let dir = createTempDir("zpktest", "")
    defer: removeDir(dir)
    let path = dir / "zpk.build"
    writeFile(path, """
      package {
        name    = "hello"
        version = "1.0.0"
      }
    """)
    let m = loadZpkBuild(path)
    check m.name == "hello"
    check m.version == "1.0.0"
    check m.arches == @["x86_64"]  # domyślne
    check m.recipeFile == "recipe.janet"  # domyślne
    check m.release.repo == "https://github.com/Zenit-Linux/own-repository"  # domyślne

  test "parsuje pełny zpk.build z release{}":
    let dir = createTempDir("zpktest", "")
    defer: removeDir(dir)
    let path = dir / "zpk.build"
    writeFile(path, """
      package {
        name        = "hello"
        version     = "2.0.0"
        arch        = ["x86_64", "aarch64"]
        description = "opis"
        depends_on  = ["glibc"]
      }
      recipe {
        file = "build.sh"
        lang = "sh"
      }
      release {
        branch     = "testing"
        asset_name = "hello-custom"
      }
    """)
    let m = loadZpkBuild(path)
    check m.arches == @["x86_64", "aarch64"]
    check m.dependsOn == @["glibc"]
    check m.recipeFile == "build.sh"
    check m.recipeLang == "sh"
    check m.release.branch == "testing"
    check m.release.assetName == "hello-custom"

  test "brak package{} -> ZpkError":
    let dir = createTempDir("zpktest", "")
    defer: removeDir(dir)
    let path = dir / "zpk.build"
    writeFile(path, "recipe {}\n")
    expect(ZpkError):
      discard loadZpkBuild(path)

  test "brak name/version -> ZpkError":
    let dir = createTempDir("zpktest", "")
    defer: removeDir(dir)
    let path = dir / "zpk.build"
    writeFile(path, "package { name = \"x\" }\n")
    expect(ZpkError):
      discard loadZpkBuild(path)

  test "brak pliku -> ZpkError":
    expect(ZpkError):
      discard loadZpkBuild("/nieistniejaca/sciezka/zpk.build")

suite "builder (budowanie i pakowanie .zpk)":
  test "buildOneArch produkuje .zpk + manifest zgodny z zpm":
    let dir = createTempDir("zpktest", "")
    defer: removeDir(dir)
    writeFile(dir / "recipe.sh", """#!/bin/sh
mkdir -p "$ZPM_PACKAGE_STAGE_DIR/usr/local/bin"
echo '#!/bin/sh' > "$ZPM_PACKAGE_STAGE_DIR/usr/local/bin/test-bin"
echo 'echo hi' >> "$ZPM_PACKAGE_STAGE_DIR/usr/local/bin/test-bin"
chmod +x "$ZPM_PACKAGE_STAGE_DIR/usr/local/bin/test-bin"
""")
    let m = ZpkBuildManifest(
      name: "test-pkg", version: "0.1.0", arches: @["x86_64"],
      description: "test", dependsOn: @[],
      recipeFile: "recipe.sh", recipeLang: "sh",
      release: ZpkReleaseTarget(), rawPath: dir / "zpk.build"
    )
    let outDir = dir / "out"
    let (ok, path, manifest) = buildOneArch(dir, m, "x86_64", outDir, verbose = false)
    check ok
    check fileExists(path)
    check fileExists(path & ".json")
    check manifest.name == "test-pkg"
    check manifest.version == "0.1.0"
    check manifest.arch == "x86_64"
    check manifest.sha256.len == 64  # sha256 hex
    check manifest.files.len >= 1
    var foundBin = false
    for f in manifest.files:
      if "usr/local/bin/test-bin" in f.path:
        foundBin = true
        check f.sha256.len == 64
    check foundBin

  test "recipe zwracający błąd -> buildOneArch zwraca ok=false":
    let dir = createTempDir("zpktest", "")
    defer: removeDir(dir)
    writeFile(dir / "recipe.sh", "#!/bin/sh\nexit 1\n")
    let m = ZpkBuildManifest(
      name: "broken", version: "0.1.0", arches: @["x86_64"],
      recipeFile: "recipe.sh", recipeLang: "sh",
      release: ZpkReleaseTarget(), rawPath: dir / "zpk.build"
    )
    let (ok, _, _) = buildOneArch(dir, m, "x86_64", dir / "out", verbose = false)
    check ok == false
