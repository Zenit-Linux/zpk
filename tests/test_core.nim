import std/[unittest, os, osproc, tempfiles, strutils, strformat, json, sequtils]
import ../src/zpkpkg/hcl
import ../src/zpkpkg/types
import ../src/zpkpkg/manifest
import ../src/zpkpkg/builder
import ../src/zpkpkg/checksum
import ../src/zpkpkg/release
import ../src/zpkpkg/signing
import ../src/zpkpkg/deps
import ../src/zpkpkg/versionbump
import ../src/zpkpkg/tutorial

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
    # v0.4: manifest.json mieszka W ŚRODKU archiwum, nie obok niego jako
    # osobny plik `<plik>.zpk.json` -- sprawdzamy to przez listing tar.
    check not fileExists(path & ".json")
    let (tarListing, tarCode) = execCmdEx(&"tar -tf {quoteShell(path)}")
    check tarCode == 0
    check "manifest.json" in tarListing
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

  test "verifyPackage wykrywa niezgodność sha256 (manifest w środku archiwum)":
    # v0.4: manifest.json (z sumą zawartości) mieszka W ŚRODKU .zpk, nie
    # obok niego -- budujemy archiwum ręcznie przez `tar`, z JAWNIE
    # błędną zagregowaną sumą w manifeście, żeby sprawdzić, czy
    # `verifyPackage` odtwarza sumę z rozpakowanej zawartości i wykrywa
    # rozjazd, zamiast ślepo ufać temu, co manifest deklaruje.
    let dir = createTempDir("zpktest", "")
    defer: removeDir(dir)
    let stageDir = dir / "stage"
    createDir(stageDir / "usr" / "local" / "bin")
    writeFile(stageDir / "usr" / "local" / "bin" / "f", "zawartosc")
    let realFileSha = sha256sumOf(stageDir / "usr" / "local" / "bin" / "f")
    let manifestJson = %*{
      "name": "pkg", "version": "0.1.0", "arch": "x86_64",
      "depends_on": newJArray(), "sha256": "0".repeat(64),
      "description": "", "build_recipe": "recipe.janet", "built_at": "",
      "files": [%*{"path": "usr/local/bin/f", "sha256": realFileSha}]
    }
    writeFile(stageDir / "manifest.json", $manifestJson)
    let zpkPath = dir / "pkg.zpk"
    let tarCode = execCmd(&"tar -C {quoteShell(stageDir)} -acf {quoteShell(zpkPath)} .")
    check tarCode == 0
    let (ok, messages) = verifyPackage(zpkPath)
    check ok == false
    check messages.anyIt(it.contains("NIEZGODNOŚĆ"))

  test "verifyPackage OK gdy sha256 się zgadza i brak podpisu":
    # Najbardziej realistyczna droga do poprawnego .zpk to `buildOneArch`
    # samo -- unikamy duplikowania logiki liczenia zagregowanej sumy
    # (contentDigestOf jest prywatne dla builder.nim) w teście.
    let dir = createTempDir("zpktest", "")
    defer: removeDir(dir)
    writeFile(dir / "recipe.sh", "#!/bin/sh\nmkdir -p \"$ZPM_PACKAGE_STAGE_DIR/bin\"\necho hi > \"$ZPM_PACKAGE_STAGE_DIR/bin/f\"\n")
    let m = ZpkBuildManifest(
      name: "ok-pkg", version: "0.1.0", arches: @["x86_64"],
      recipeFile: "recipe.sh", recipeLang: "sh",
      release: ZpkReleaseTarget(), rawPath: dir / "zpk.build"
    )
    let (buildOk, path, _) = buildOneArch(dir, m, "x86_64", dir / "out", verbose = false)
    check buildOk
    let (ok, messages) = verifyPackage(path)
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

# =====================================================================
# Podpisywanie -- test END-TO-END z PRAWDZIWYMI kluczami PEM (RSA i
# Ed25519), generowanymi przez `openssl` W CZASIE TESTU. Wcześniej
# signing.nim nigdy nie zostało uruchomione z realnym kluczem -- dopiero
# ten test ujawnił, że `openssl dgst -sign` NIE działa dla Ed25519
# ("Key type not supported for this operation") i wymaga `pkeyutl
# -rawin` zamiast tego (patrz komentarz na górze signing.nim).
# Testy pomijają się (ok, bez failowania) jeśli `openssl` niedostępne.
# =====================================================================

proc opensslGenKey(dir, alg: string): tuple[priv, pub: string] =
  let priv = dir / (alg & "_priv.pem")
  let pub = dir / (alg & "_pub.pem")
  let genCmd = case alg
    of "rsa": &"openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out {quoteShell(priv)}"
    of "ed25519": &"openssl genpkey -algorithm ed25519 -out {quoteShell(priv)}"
    else: raise newException(ValueError, "nieznany algorytm: " & alg)
  let (genOut, genCode) = execCmdEx(genCmd)
  doAssert genCode == 0, "openssl genpkey nie powiodło się: " & genOut
  let (pubOut, pubCode) = execCmdEx(&"openssl pkey -in {quoteShell(priv)} -pubout -out {quoteShell(pub)}")
  doAssert pubCode == 0, "openssl pkey -pubout nie powiodło się: " & pubOut
  (priv, pub)

suite "signing -- end-to-end z prawdziwymi kluczami openssl (RSA + Ed25519)":
  test "RSA: podpis + weryfikacja poprawnego pliku":
    if not opensslAvailable(): skip()
    let dir = createTempDir("zpktest-sign", "")
    defer: removeDir(dir)
    let (priv, pub) = opensslGenKey(dir, "rsa")
    let filePath = dir / "plik.zpk"
    writeFile(filePath, "zawartosc pakietu do podpisania")
    let sig = signFile(filePath, priv)
    check sig.len > 0
    check verifyFile(filePath, pub, sig)

  test "RSA: zmodyfikowany plik NIE przechodzi weryfikacji":
    if not opensslAvailable(): skip()
    let dir = createTempDir("zpktest-sign", "")
    defer: removeDir(dir)
    let (priv, pub) = opensslGenKey(dir, "rsa")
    let filePath = dir / "plik.zpk"
    writeFile(filePath, "oryginalna zawartosc")
    let sig = signFile(filePath, priv)
    writeFile(filePath, "ZMIENIONA zawartosc")
    check not verifyFile(filePath, pub, sig)

  test "Ed25519: podpis + weryfikacja poprawnego pliku (wymaga pkeyutl -rawin, NIE dgst -sign)":
    if not opensslAvailable(): skip()
    let dir = createTempDir("zpktest-sign", "")
    defer: removeDir(dir)
    let (priv, pub) = opensslGenKey(dir, "ed25519")
    let filePath = dir / "plik.zpk"
    writeFile(filePath, "zawartosc pakietu do podpisania")
    let sig = signFile(filePath, priv)
    check sig.len > 0
    check verifyFile(filePath, pub, sig)

  test "Ed25519: zmodyfikowany plik NIE przechodzi weryfikacji":
    if not opensslAvailable(): skip()
    let dir = createTempDir("zpktest-sign", "")
    defer: removeDir(dir)
    let (priv, pub) = opensslGenKey(dir, "ed25519")
    let filePath = dir / "plik.zpk"
    writeFile(filePath, "oryginalna zawartosc")
    let sig = signFile(filePath, priv)
    writeFile(filePath, "ZMIENIONA zawartosc")
    check not verifyFile(filePath, pub, sig)

  test "podpis Ed25519 zweryfikowany kluczem RSA (zły klucz) -> false, bez wyjątku":
    if not opensslAvailable(): skip()
    let dir = createTempDir("zpktest-sign", "")
    defer: removeDir(dir)
    let (edPriv, _) = opensslGenKey(dir, "ed25519")
    let (_, rsaPub) = opensslGenKey(dir, "rsa")
    let filePath = dir / "plik.zpk"
    writeFile(filePath, "tresc")
    let sig = signFile(filePath, edPriv)
    check not verifyFile(filePath, rsaPub, sig)

  test "builder.verifyPackage: pełny łańcuch build -> sign -> verify (RSA)":
    if not opensslAvailable(): skip()
    let dir = createTempDir("zpktest-sign", "")
    defer: removeDir(dir)
    let (priv, pub) = opensslGenKey(dir, "rsa")
    writeFile(dir / "recipe.sh", "#!/bin/sh\nmkdir -p \"$ZPM_PACKAGE_STAGE_DIR/bin\"\necho hi > \"$ZPM_PACKAGE_STAGE_DIR/bin/f\"\n")
    let m = ZpkBuildManifest(
      name: "signed-pkg", version: "0.1.0", arches: @["x86_64"],
      recipeFile: "recipe.sh", recipeLang: "sh",
      release: ZpkReleaseTarget(), rawPath: dir / "zpk.build"
    )
    putEnv("ZPK_SIGN_KEY", priv)
    defer: delEnv("ZPK_SIGN_KEY")
    let (ok, path, manifest) = buildOneArch(dir, m, "x86_64", dir / "out", verbose = false)
    check ok
    check manifest.signature.len > 0
    # v0.4: podpis mieszka w manifest.json W ŚRODKU archiwum -- nie ma
    # już osobnego `<plik>.zpk.sig` obok niego.
    check not fileExists(path & ".sig")
    let (verifyOk, msgs) = verifyPackage(path, pub)
    check verifyOk
    check msgs.anyIt(it.contains("autentyczność potwierdzona"))

# =====================================================================
# deps -- weryfikacja depends_on (best-effort przez `zpm` albo fallback
# na `findExe`). Izolujemy PATH tak, żeby test był deterministyczny
# niezależnie od tego, czy `zpm` jest faktycznie zainstalowane w
# środowisku, w którym uruchamiane są testy.
# =====================================================================

proc isolatedBinDir(scripts: openArray[tuple[name, content: string]]): string =
  ## Tworzy katalog zawierający WYŁĄCZNIE podane skrypty (jako
  ## wykonywalne pliki) -- używane do budowania deterministycznego,
  ## izolowanego PATH w testach (`zpm` obecne/nieobecne wg woli testu,
  ## niezależnie od realnego środowiska CI).
  result = createTempDir("zpktest-bin", "")
  for (name, content) in scripts:
    let p = result / name
    writeFile(p, content)
    setFilePermissions(p, {fpUserExec, fpUserRead, fpUserWrite,
                            fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

suite "deps -- weryfikacja depends_on (best-effort)":
  test "zpm dostępne, zależność ZAINSTALOWANA -> dsInstalled":
    let fakeZpm = "#!/bin/sh\necho 'foo bar glibc baz'\nexit 0\n"
    let binDir = isolatedBinDir([("zpm", fakeZpm)])
    defer: removeDir(binDir)
    let originalPath = getEnv("PATH")
    putEnv("PATH", binDir)
    defer: putEnv("PATH", originalPath)

    let results = checkDependencies(@["glibc"])
    check results.len == 1
    check results[0].status == dsInstalled

  test "zpm dostępne, zależność BRAKUJE -> dsMissing":
    let fakeZpm = "#!/bin/sh\necho 'foo bar baz'\nexit 0\n"
    let binDir = isolatedBinDir([("zpm", fakeZpm)])
    defer: removeDir(binDir)
    let originalPath = getEnv("PATH")
    putEnv("PATH", binDir)
    defer: putEnv("PATH", originalPath)

    let results = checkDependencies(@["nieistniejaca-zaleznosc"])
    check results.len == 1
    check results[0].status == dsMissing

  test "zpm zwraca błąd -> dsUnknown (nie fałszywe 'BRAK')":
    let fakeZpm = "#!/bin/sh\nexit 1\n"
    let binDir = isolatedBinDir([("zpm", fakeZpm)])
    defer: removeDir(binDir)
    let originalPath = getEnv("PATH")
    putEnv("PATH", binDir)
    defer: putEnv("PATH", originalPath)

    let results = checkDependencies(@["cokolwiek"])
    check results.len == 1
    check results[0].status == dsUnknown

  test "brak zpm w ogóle -> fallback na findExe (binarka o tej samej nazwie)":
    let binDir = isolatedBinDir([("faktyczna-binarka", "#!/bin/sh\nexit 0\n")])
    defer: removeDir(binDir)
    let originalPath = getEnv("PATH")
    putEnv("PATH", binDir)
    defer: putEnv("PATH", originalPath)

    let results = checkDependencies(@["faktyczna-binarka", "nieistniejaca-binarka"])
    check results.len == 2
    check results[0] == ("faktyczna-binarka", dsInstalled)
    check results[1] == ("nieistniejaca-binarka", dsMissing)

  test "pusta lista depends_on -> pusty wynik, bez wywoływania czegokolwiek":
    check checkDependencies(@[]).len == 0

# =====================================================================
# versionbump -- `zpk bump-version`
# =====================================================================

suite "versionbump":
  test "bumpedVersion: patch/minor/major":
    check bumpedVersion("1.2.3", bkPatch) == "1.2.4"
    check bumpedVersion("1.2.3", bkMinor) == "1.3.0"
    check bumpedVersion("1.2.3", bkMajor) == "2.0.0"

  test "bumpedVersion: odrzuca sufiks -prerelease przy podniesieniu":
    check bumpedVersion("1.2.3-rc1", bkPatch) == "1.2.4"
    check bumpedVersion("1.2.3-rc1", bkMajor) == "2.0.0"

  test "bumpVersionInFile: podmienia WYŁĄCZNIE version, zachowuje komentarze/formatowanie":
    let dir = createTempDir("zpktest-bump", "")
    defer: removeDir(dir)
    let path = dir / "zpk.build"
    writeFile(path, """# komentarz na górze
package {
  name    = "hello"  # komentarz przy nazwie
  version = "1.0.0"
  arch    = ["x86_64"]
}
""")
    let (ok, oldV, newV, _) = bumpVersionInFile(path, "1.1.0")
    check ok
    check oldV == "1.0.0"
    check newV == "1.1.0"
    let content = readFile(path)
    check "# komentarz na górze" in content
    check "# komentarz przy nazwie" in content
    check "version = \"1.1.0\"" in content
    check "name    = \"hello\"" in content
    # Plik musi nadal parsować się poprawnie po podmianie.
    let m = loadZpkBuild(path)
    check m.version == "1.1.0"
    check m.name == "hello"

  test "bumpVersionInFile: brak pliku -> ok=false":
    let (ok, _, _, message) = bumpVersionInFile("/nieistniejaca/sciezka/zpk.build", "1.0.0")
    check not ok
    check message.len > 0

# =====================================================================
# release -- integracja END-TO-END: PRAWDZIWY `git` (lokalne bare repo,
# bez sieci), `gh` całkowicie zamockowany albo świadomie nieobecny.
# Wcześniej testowana była WYŁĄCZNIE czysta logika JSON
# (upsertIntoOwnRepository) -- nigdy cały przepływ
# klon -> branch -> commit -> (upload assetu) -> push -> PR.
# =====================================================================

proc copyRealGitInto(dir: string) =
  let realGit = findExe("git")
  doAssert realGit.len > 0, "testy integracyjne release.nim wymagają 'git' w PATH"
  copyFile(realGit, dir / "git")
  setFilePermissions(dir / "git", {fpUserExec, fpUserRead, fpUserWrite,
                                     fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

proc makeIsolatedGitPath(fakeGh: string = ""): string =
  ## Buduje katalog z PATH zawierającym WYŁĄCZNIE skopiowany binarny
  ## `git` (opcjonalnie + fake `gh`) -- gwarantuje deterministyczną
  ## (nie)obecność `gh` w testach, niezależnie od tego, czy środowisko
  ## CI ma prawdziwe `gh` zainstalowane W TYM SAMYM katalogu co `git`
  ## (częste na GH Actions runnerach, oba w /usr/bin) -- zwykłe
  ## "prepend fakebin do PATH" by wtedy NADAL znajdowało prawdziwe gh;
  ## kopiowanie samego binarnego git do osobnego, w pełni izolowanego
  ## katalogu (bez oryginalnego katalogu w PATH w ogóle) eliminuje to
  ## ryzyko. Zweryfikowane ręcznie przed napisaniem tego testu (patrz
  ## historia zmian) -- lokalny `git clone`/`checkout -b`/`commit`/`push`
  ## do bare repo działają poprawnie nawet z PATH ograniczonym do
  ## jednego katalogu z samym skopiowanym binarnym git.
  result = createTempDir("zpktest-isolated-path", "")
  copyRealGitInto(result)
  if fakeGh.len > 0:
    let ghPath = result / "gh"
    writeFile(ghPath, fakeGh)
    setFilePermissions(ghPath, {fpUserExec, fpUserRead, fpUserWrite,
                                  fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

const fakeGhSuccessScript = """#!/bin/sh
case "$1 $2" in
  "release create") exit 0 ;;
  "release upload") exit 0 ;;
  "release view")
    for a in "$@"; do
      if [ "$a" = "--json" ]; then
        echo "hello-1.0.0-x86_64.zpk"
        exit 0
      fi
    done
    exit 1
    ;;
  "pr create") echo "https://example.test/owner/repo/pull/1"; exit 0 ;;
  *) exit 1 ;;
esac
"""

proc makeTestManifest(bareRepo, pkgDir: string): ZpkBuildManifest =
  ZpkBuildManifest(
    name: "hello", version: "1.0.0", arches: @["x86_64"],
    description: "opis testowy", dependsOn: @[],
    recipeFile: "recipe.sh", recipeLang: "sh",
    release: ZpkReleaseTarget(
      repo: bareRepo, repoFile: "repo/own-repository.json",
      branch: "", assetName: "hello", releaseRepoUrl: "https://github.com/test/test"
    ),
    rawPath: pkgDir / "zpk.build"
  )

suite "release -- integracja end-to-end (prawdziwy git + zamockowany/nieobecny gh)":
  test "pełny sukces: klon -> branch -> commit -> upload assetu -> push -> PR (gh zamockowany)":
    let bareRepo = createTempDir("zpktest-bare", "")
    defer: removeDir(bareRepo)
    discard execCmdEx(&"git init --bare -q {quoteShell(bareRepo)}")

    let pkgDir = createTempDir("zpktest-pkg", "")
    defer: removeDir(pkgDir)
    let assetPath = pkgDir / "hello-1.0.0-x86_64.zpk"
    writeFile(assetPath, "fake .zpk content")

    let isolatedDir = makeIsolatedGitPath(fakeGhSuccessScript)
    defer: removeDir(isolatedDir)
    let originalPath = getEnv("PATH")
    putEnv("PATH", isolatedDir)
    defer: putEnv("PATH", originalPath)

    let m = makeTestManifest(bareRepo, pkgDir)
    let workDir = createTempDir("zpktest-clone", "")

    let (ok, message) = scheduleRelease(m, @[("x86_64", assetPath)], verbose = false,
                                          pkgDir = pkgDir, workDir = workDir)
    check ok
    check message.contains("Pull request utworzony")
    check not dirExists(workDir)  # posprzątane po sukcesie

    # Zweryfikuj TREŚĆ tego, co faktycznie trafiło do zdalnego repo --
    # nie tylko że polecenia się "wykonały", ale że dane są poprawne.
    let verifyClone = createTempDir("zpktest-verify", "")
    defer: removeDir(verifyClone)
    let (_, cloneCode) = execCmdEx(
      &"git clone -q --branch zpk-release-hello-1.0.0 {quoteShell(bareRepo)} {quoteShell(verifyClone)}")
    check cloneCode == 0
    let pushedJsonPath = verifyClone / "repo" / "own-repository.json"
    check fileExists(pushedJsonPath)
    let pushedJson = parseJson(readFile(pushedJsonPath))
    check pushedJson["tools"][0]["name"].getStr == "hello"
    check pushedJson["tools"][0]["bin"].getStr.contains("hello-1.0.0-x86_64.zpk")

  test "--dry-run: JSON zmieniony lokalnie, katalog zachowany, NIC nie wypchnięte":
    let bareRepo = createTempDir("zpktest-bare", "")
    defer: removeDir(bareRepo)
    discard execCmdEx(&"git init --bare -q {quoteShell(bareRepo)}")

    let pkgDir = createTempDir("zpktest-pkg", "")
    defer: removeDir(pkgDir)
    let assetPath = pkgDir / "hello-1.0.0-x86_64.zpk"
    writeFile(assetPath, "fake .zpk content")

    let m = makeTestManifest(bareRepo, pkgDir)
    let workDir = createTempDir("zpktest-clone", "")
    defer: (if dirExists(workDir): removeDir(workDir))

    let (ok, message) = scheduleRelease(m, @[("x86_64", assetPath)], verbose = false,
                                          pkgDir = pkgDir, workDir = workDir, dryRun = true)
    check ok
    check message.contains("dry-run")
    check dirExists(workDir)
    check fileExists(workDir / "repo" / "own-repository.json")

    let (branchesOut, _) = execCmdEx(&"git ls-remote {quoteShell(bareRepo)}")
    check "zpk-release" notin branchesOut

  test "'gh' niedostępne: commit lokalny zachowany, jasna instrukcja, BEZ push":
    let bareRepo = createTempDir("zpktest-bare", "")
    defer: removeDir(bareRepo)
    discard execCmdEx(&"git init --bare -q {quoteShell(bareRepo)}")

    let pkgDir = createTempDir("zpktest-pkg", "")
    defer: removeDir(pkgDir)
    let assetPath = pkgDir / "hello-1.0.0-x86_64.zpk"
    writeFile(assetPath, "fake .zpk content")

    let isolatedDir = makeIsolatedGitPath()  # BEZ fake gh -> 'gh' naprawdę nieosiągalne
    defer: removeDir(isolatedDir)
    let originalPath = getEnv("PATH")
    putEnv("PATH", isolatedDir)
    defer: putEnv("PATH", originalPath)

    let m = makeTestManifest(bareRepo, pkgDir)
    let workDir = createTempDir("zpktest-clone", "")

    let (ok, message) = scheduleRelease(m, @[("x86_64", assetPath)], verbose = false,
                                          pkgDir = pkgDir, workDir = workDir)
    check ok
    check message.contains("gh")
    check message.contains("nie jest zainstalowane")
    check dirExists(workDir)  # zachowany -- operator musi dokończyć ręcznie

    let (logOut, logCode) = execCmdEx("git log --oneline -1", workingDir = workDir)
    check logCode == 0
    check "hello: dodaj" in logOut

    let (branchesOut, _) = execCmdEx(&"git ls-remote {quoteShell(bareRepo)}")
    check "zpk-release" notin branchesOut

    removeDir(workDir)  # scheduleRelease celowo go tu NIE usuwa -- sprzątamy ręcznie

  test "'gh' zawsze zwraca błąd ('release create' i 'upload' zawodzą) -> ostrzeżenie, ale PR i tak powstaje":
    let bareRepo = createTempDir("zpktest-bare", "")
    defer: removeDir(bareRepo)
    discard execCmdEx(&"git init --bare -q {quoteShell(bareRepo)}")

    let pkgDir = createTempDir("zpktest-pkg", "")
    defer: removeDir(pkgDir)
    let assetPath = pkgDir / "hello-1.0.0-x86_64.zpk"
    writeFile(assetPath, "fake .zpk content")

    const fakeGhAllFail = """#!/bin/sh
case "$1 $2" in
  "release create") exit 1 ;;
  "release upload") exit 1 ;;
  "pr create") echo "https://example.test/owner/repo/pull/2"; exit 0 ;;
  *) exit 1 ;;
esac
"""
    let isolatedDir = makeIsolatedGitPath(fakeGhAllFail)
    defer: removeDir(isolatedDir)
    let originalPath = getEnv("PATH")
    putEnv("PATH", isolatedDir)
    defer: putEnv("PATH", originalPath)

    let m = makeTestManifest(bareRepo, pkgDir)
    let workDir = createTempDir("zpktest-clone", "")

    let (ok, message) = scheduleRelease(m, @[("x86_64", assetPath)], verbose = false,
                                          pkgDir = pkgDir, workDir = workDir)
    check ok  # PR i tak powstaje -- upload assetu to osobny krok
    check message.contains("Pull request utworzony")
    check message.contains("nie udało się utworzyć ANI wgrać assetu")

# =====================================================================
# tutorial-release -- interaktywny kreator, testowany przez podanie
# odpowiedzi jako plik `input` i przechwycenie `output` (patrz
# tutorial.nim -- input/output są teraz parametrami, nie globalnym
# stdin/stdout, właśnie żeby to umożliwić).
# =====================================================================

proc runTutorialWithAnswers(answers: seq[string], pkgDirOverride = ""): string =
  let answersDir = createTempDir("zpktest-tutorial", "")
  defer: removeDir(answersDir)
  let inputPath = answersDir / "input.txt"
  let outputPath = answersDir / "output.txt"
  writeFile(inputPath, answers.join("\n") & "\n")
  let inputFile = open(inputPath, fmRead)
  let outputFile = open(outputPath, fmWrite)
  runTutorialRelease(input = inputFile, output = outputFile, pkgDirOverride = pkgDirOverride)
  inputFile.close()
  outputFile.close()
  readFile(outputPath)

suite "tutorial-release -- interaktywny kreator":
  test "rezygnacja z publikacji (odpowiedź 'nie' na potwierdzenie PR) -> bez wywołania git/gh":
    let pkgDir = createTempDir("zpktest-tut-pkg", "")
    defer: removeDir(pkgDir)
    writeFile(pkgDir / "zpk.build", """
package {
  name    = "tut-hello"
  version = "1.0.0"
}
recipe {
  file = "recipe.sh"
  lang = "sh"
}
""")
    writeFile(pkgDir / "recipe.sh",
      "#!/bin/sh\nmkdir -p \"$ZPM_PACKAGE_STAGE_DIR/bin\"\necho hi > \"$ZPM_PACKAGE_STAGE_DIR/bin/f\"\n")

    # Odpowiedzi po kolei: pkg_dir (puste = użyj pkgDirOverride),
    # ask_build_first (tak), ask_branch (puste), ask_confirm_pr (nie).
    let output = runTutorialWithAnswers(@["", "tak", "", "nie"], pkgDirOverride = pkgDir)
    check "tut-hello" in output
    check fileExists(pkgDir / "out" / "tut-hello-1.0.0-x86_64.zpk")  # build i tak się wykonał
    check not ("Pull request" in output)

  test "brak zpk.build w podanym katalogu -> czytelny komunikat błędu, bez wyjątku":
    let emptyDir = createTempDir("zpktest-tut-empty", "")
    defer: removeDir(emptyDir)
    let output = runTutorialWithAnswers(@[""], pkgDirOverride = emptyDir)
    check "✘" in output

  test "pełny przepływ z publikacją (gh zamockowany) -> PR utworzony":
    let bareRepo = createTempDir("zpktest-tut-bare", "")
    defer: removeDir(bareRepo)
    discard execCmdEx(&"git init --bare -q {quoteShell(bareRepo)}")

    let pkgDir = createTempDir("zpktest-tut-pkg2", "")
    defer: removeDir(pkgDir)
    writeFile(pkgDir / "zpk.build", &"""
package {{
  name    = "tut-hello2"
  version = "1.0.0"
}}
recipe {{
  file = "recipe.sh"
  lang = "sh"
}}
release {{
  repo              = "{bareRepo}"
  repo_file         = "repo/own-repository.json"
  release_repo_url  = "https://github.com/test/test"
  asset_name        = "tut-hello2"
}}
""")
    writeFile(pkgDir / "recipe.sh",
      "#!/bin/sh\nmkdir -p \"$ZPM_PACKAGE_STAGE_DIR/bin\"\necho hi > \"$ZPM_PACKAGE_STAGE_DIR/bin/f\"\n")

    const fakeGh = """#!/bin/sh
case "$1 $2" in
  "release create") exit 0 ;;
  "release upload") exit 0 ;;
  "release view")
    for a in "$@"; do
      if [ "$a" = "--json" ]; then
        echo "tut-hello2-1.0.0-x86_64.zpk"
        exit 0
      fi
    done
    exit 1
    ;;
  "pr create") echo "https://example.test/owner/repo/pull/3"; exit 0 ;;
  *) exit 1 ;;
esac
"""
    # UWAGA: w przeciwieństwie do testów w suite "release" wyżej, TEN test
    # faktycznie BUDUJE pakiet (recipe.sh przez `sh`) zanim dojdzie do
    # publikacji -- w pełni izolowany PATH (sam skopiowany git) by nie
    # zawierał `sh`/`mkdir` i build by się wysypał. Zamiast tego
    # PRZEDROSTKUJEMY prawdziwy PATH katalogiem z samym fake `gh` --
    # gwarantuje to użycie naszego fake (sprawdzany pierwszy), a reszta
    # narzędzi (sh, mkdir, git) nadal rozwiązuje się normalnie.
    let fakeBinDir = createTempDir("zpktest-tut-fakebin", "")
    defer: removeDir(fakeBinDir)
    writeFile(fakeBinDir / "gh", fakeGh)
    setFilePermissions(fakeBinDir / "gh", {fpUserExec, fpUserRead, fpUserWrite,
                                             fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})
    let originalPath = getEnv("PATH")
    putEnv("PATH", fakeBinDir & ":" & originalPath)
    defer: putEnv("PATH", originalPath)

    let output = runTutorialWithAnswers(@["", "tak", "", "tak"], pkgDirOverride = pkgDir)
    check "Pull request utworzony" in output
