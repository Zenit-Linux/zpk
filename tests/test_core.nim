import std/[unittest, os, tempfiles, strutils, json, sequtils]
import ../src/zpkpkg/hcl
import ../src/zpkpkg/types
import ../src/zpkpkg/manifest
import ../src/zpkpkg/builder
import ../src/zpkpkg/checksum
import ../src/zpkpkg/release

## Testy jednostkowe zpk -- parser zpk.build, budowanie/pakowanie .zpk,
## przenośne sumy sha256, scalanie wpisów own-repository.json.

suite "hcl (parser niskopoziomowy)":
  test "obsługuje liczby ujemne i zmiennoprzecinkowe":
    let root = parseHcl("""
      x {
        a = -5
        b = 3.14
        c = -2.5
      }
    """)
    let blk = root.findBlock("x")
    check blk.getInt("a") == -5
    check blk.getFloat("b") == 3.14
    check blk.getFloat("c") == -2.5

  test "lista z przecinkiem WEWNĄTRZ cudzysłowu nie rozjeżdża się":
    let root = parseHcl("""
      x {
        a = ["foo,bar", "baz"]
      }
    """)
    let blk = root.findBlock("x")
    check blk.getList("a") == @["foo,bar", "baz"]

  test "findAllBlocks widzi wszystkie wystąpienia, findBlock tylko pierwsze":
    let root = parseHcl("""
      package {
        name = "a"
      }
      package {
        name = "b"
      }
    """)
    check root.findAllBlocks("package").len == 2
    check root.findBlock("package").getStr("name") == "a"

  test "niedomknięty string -> HclParseError z numerem linii":
    expect(HclParseError):
      discard parseHcl("x { a = \"niedomkniety }")

  test "nierozpoznana wartość -> HclParseError":
    expect(HclParseError):
      discard parseHcl("x { a = cos_dziwnego }")

suite "manifest (zpk.build) -- walidacja":
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
    writeFile(path, "recipe {\n  lang = \"sh\"\n}\n")
    expect(ZpkError):
      discard loadZpkBuild(path)

  test "brak name/version -> ZpkError":
    let dir = createTempDir("zpktest", "")
    defer: removeDir(dir)
    let path = dir / "zpk.build"
    writeFile(path, "package {\n  name = \"x\"\n}\n")
    expect(ZpkError):
      discard loadZpkBuild(path)

  test "brak pliku -> ZpkError":
    expect(ZpkError):
      discard loadZpkBuild("/nieistniejaca/sciezka/zpk.build")

  test "niepoprawny semver -> ZpkError":
    let dir = createTempDir("zpktest", "")
    defer: removeDir(dir)
    let path = dir / "zpk.build"
    writeFile(path, "package {\n  name = \"x\"\n  version = \"nie-semver\"\n}\n")
    expect(ZpkError):
      discard loadZpkBuild(path)

  test "nazwa z niedozwolonym znakiem -> ZpkError":
    let dir = createTempDir("zpktest", "")
    defer: removeDir(dir)
    let path = dir / "zpk.build"
    writeFile(path, "package {\n  name = \"zla nazwa!\"\n  version = \"1.0.0\"\n}\n")
    expect(ZpkError):
      discard loadZpkBuild(path)

  test "zduplikowana architektura -> ZpkError":
    let dir = createTempDir("zpktest", "")
    defer: removeDir(dir)
    let path = dir / "zpk.build"
    writeFile(path, """
      package {
        name    = "x"
        version = "1.0.0"
        arch    = ["x86_64", "x86_64"]
      }
    """)
    expect(ZpkError):
      discard loadZpkBuild(path)

  test "dwa bloki package{} -> ZpkError":
    let dir = createTempDir("zpktest", "")
    defer: removeDir(dir)
    let path = dir / "zpk.build"
    writeFile(path, """
      package {
        name    = "a"
        version = "1.0.0"
      }
      package {
        name    = "b"
        version = "1.0.0"
      }
    """)
    expect(ZpkError):
      discard loadZpkBuild(path)

  test "validateZpkBuildFull zgłasza brakujący plik recipe":
    let dir = createTempDir("zpktest", "")
    defer: removeDir(dir)
    let path = dir / "zpk.build"
    writeFile(path, "package {\n  name = \"x\"\n  version = \"1.0.0\"\n}\n")
    let m = loadZpkBuild(path)
    let warnings = validateZpkBuildFull(m, dir)
    check warnings.anyIt(it.contains("recipe.janet"))

suite "checksum (przenośne sha256)":
  test "sha256sumOf liczy poprawną sumę znanego pliku":
    let dir = createTempDir("zpktest", "")
    defer: removeDir(dir)
    let path = dir / "plik.txt"
    writeFile(path, "hello world\n")
    # sha256 dla "hello world\n" jest znane i stabilne.
    check sha256sumOf(path) == "a948904f2f0f479b8f8197694b30184b0d2ed1c1cd2a1ec0fb85d299a192a447"

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

  test "packageFileName / archFromPackageFileName są odwrotnościami":
    let fname = packageFileName("hello-world", "1.2.3", "aarch64")
    check fname == "hello-world-1.2.3-aarch64.zpk"
    check archFromPackageFileName(fname, "hello-world", "1.2.3") == "aarch64"
    check archFromPackageFileName("cos-innego.zpk", "hello-world", "1.2.3") == ""

  test "verifyPackage wykrywa niezgodność sha256":
    let dir = createTempDir("zpktest", "")
    defer: removeDir(dir)
    let zpkPath = dir / "pkg.zpk"
    writeFile(zpkPath, "zawartosc")
    writeFile(zpkPath & ".json", $(%*{"sha256": "0".repeat(64)}))
    let (ok, messages) = verifyPackage(zpkPath)
    check ok == false
    check messages.anyIt(it.contains("NIEZGODNOŚĆ"))

  test "verifyPackage OK gdy sha256 się zgadza i brak podpisu":
    let dir = createTempDir("zpktest", "")
    defer: removeDir(dir)
    let zpkPath = dir / "pkg.zpk"
    writeFile(zpkPath, "zawartosc")
    let realSha = sha256sumOf(zpkPath)
    writeFile(zpkPath & ".json", $(%*{"sha256": realSha}))
    let (ok, messages) = verifyPackage(zpkPath)
    check ok
    check messages.anyIt(it.contains("nie jest podpisany"))

suite "release (scalanie own-repository.json)":
  test "dodaje nowy wpis z pojedynczą architekturą (bin=string)":
    let dir = createTempDir("zpktest", "")
    defer: removeDir(dir)
    let repoPath = dir / "own-repository.json"
    check upsertIntoOwnRepository(repoPath, "hello", "opis", @[], "",
      @[("x86_64", "https://example.test/hello-x86_64.zpk")])
    let root = parseJson(readFile(repoPath))
    check root["tools"][0]["name"].getStr == "hello"
    check root["tools"][0]["bin"].getStr == "https://example.test/hello-x86_64.zpk"

  test "wiele architektur -> bin=obiekt {arch: url}":
    let dir = createTempDir("zpktest", "")
    defer: removeDir(dir)
    let repoPath = dir / "own-repository.json"
    check upsertIntoOwnRepository(repoPath, "hello", "opis", @[], "",
      @[("x86_64", "https://example.test/hello-x86_64.zpk"),
        ("aarch64", "https://example.test/hello-aarch64.zpk")])
    let root = parseJson(readFile(repoPath))
    check root["tools"][0]["bin"]["x86_64"].getStr == "https://example.test/hello-x86_64.zpk"
    check root["tools"][0]["bin"]["aarch64"].getStr == "https://example.test/hello-aarch64.zpk"

  test "branch niepusty -> wpis pod 'branches', top-level nietknięty":
    let dir = createTempDir("zpktest", "")
    defer: removeDir(dir)
    let repoPath = dir / "own-repository.json"
    discard upsertIntoOwnRepository(repoPath, "hello", "opis", @[], "",
      @[("x86_64", "https://example.test/stable.zpk")])
    discard upsertIntoOwnRepository(repoPath, "hello", "opis", @[], "testing",
      @[("x86_64", "https://example.test/testing.zpk")])
    let root = parseJson(readFile(repoPath))
    check root["tools"][0]["bin"].getStr == "https://example.test/stable.zpk"
    check root["tools"][0]["branches"]["testing"]["bin"].getStr == "https://example.test/testing.zpk"

  test "aktualizacja istniejącego wpisu top-level nadpisuje bin":
    let dir = createTempDir("zpktest", "")
    defer: removeDir(dir)
    let repoPath = dir / "own-repository.json"
    discard upsertIntoOwnRepository(repoPath, "hello", "v1", @[], "",
      @[("x86_64", "https://example.test/v1.zpk")])
    discard upsertIntoOwnRepository(repoPath, "hello", "v2", @[], "",
      @[("x86_64", "https://example.test/v2.zpk")])
    let root = parseJson(readFile(repoPath))
    check root["tools"].len == 1
    check root["tools"][0]["info"].getStr == "v2"
    check root["tools"][0]["bin"].getStr == "https://example.test/v2.zpk"
