import std/[unittest, os, tempfiles, strutils]
import ../src/zpkpkg/archive
import ../src/zpkpkg/zsha256
import ../src/zpkpkg/zlz

## Testy formatu ZPKA v2 (archive.nim) + zsha256 + zlz, w IZOLACJI od
## reszty `zpk` (bez `hcl.nim`/`hclnim`) -- dzięki temu dają się uruchomić
## nawet bez `nimble install` zależności parsera HCL. Pełne testy
## integracyjne (buildOneArch/verifyPackage na tym samym formacie) są w
## `tests/test_core.nim`, suite "builder" + "archive (natywny format ZPKA)".

suite "zsha256 (sha256 w czystym Nim, bez procesów potomnych)":
  test "wektory testowe NIST/znane":
    check sha256Hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    check sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    check sha256Hex("a".repeat(1_000_000)) ==
      "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"

  test "sha256HexOfFile zgodne z sha256Hex":
    let dir = createTempDir("zpktest-sha", "")
    defer: removeDir(dir)
    let content = "przykladowa zawartosc\n".repeat(500)
    writeFile(dir / "f.bin", content)
    check sha256HexOfFile(dir / "f.bin") == sha256Hex(content)

suite "zlz (kompresor LZ77 w czystym Nim, format ZLZ1)":
  test "round-trip: pusty, krótki, powtarzalny":
    for sample in ["", "a", "ab", "abcd", "abcdefgh".repeat(2000)]:
      check zlz.decompress(zlz.compress(sample), sample.len) == sample

  test "kompresja realnie zmniejsza rozmiar danych powtarzalnych":
    let data = "x".repeat(10_000)
    check zlz.compress(data).len < data.len div 10

  test "dane nieściśliwe wciąż dają się poprawnie zdekompresować":
    var s = ""
    for i in 0 ..< 5000: s.add char((i * 37 + 11) mod 256)
    check zlz.decompress(zlz.compress(s), s.len) == s

suite "archive (natywny format ZPKA -- zastępuje tar)":
  test "writeArchive/listMembers/extractAll: pełna zgodność bajt-w-bajt":
    let dir = createTempDir("zpktest-archive", "")
    defer: removeDir(dir)
    let stageDir = dir / "stage"
    createDir(stageDir / "usr" / "bin")
    createDir(stageDir / "etc")
    writeFile(stageDir / "usr" / "bin" / "prog", "#!/bin/sh\necho hi\n".repeat(50))
    writeFile(stageDir / "etc" / "config", "klucz=wartosc\n".repeat(200))
    writeFile(stageDir / "manifest.json", """{"name":"t"}""")

    var toPack: seq[archive.PendingFile] = @[]
    for p in walkDirRec(stageDir):
      toPack.add archive.PendingFile(relPath: p.relativePath(stageDir), absPath: p)
    let outPath = dir / "test.zpk"
    let entries = archive.writeArchive(outPath, toPack)
    check entries.len == toPack.len
    check archive.isZpkaFile(outPath)

    let (listOk, members, _) = archive.listMembers(outPath)
    check listOk
    check members.len == toPack.len
    check "manifest.json" in members

    let destDir = dir / "extracted"
    let (extractOk, extractErr) = archive.extractAll(outPath, destDir)
    check extractOk
    for p in walkDirRec(stageDir):
      let rel = p.relativePath(stageDir)
      check readFile(p) == readFile(destDir / rel)

  test "extractMember czyta tylko jeden człon":
    let dir = createTempDir("zpktest-archive2", "")
    defer: removeDir(dir)
    writeFile(dir / "manifest.json", """{"ok":true}""")
    writeFile(dir / "payload.bin", "cokolwiek".repeat(1000))
    var toPack: seq[archive.PendingFile] = @[
      archive.PendingFile(relPath: "manifest.json", absPath: dir / "manifest.json"),
      archive.PendingFile(relPath: "payload.bin", absPath: dir / "payload.bin"),
    ]
    let outPath = dir / "t.zpk"
    discard archive.writeArchive(outPath, toPack)
    let (ok, content, err) = archive.extractMember(outPath, "manifest.json")
    check ok
    check content == """{"ok":true}"""

  test "extractSelected odmawia rozpakowania plików spoza allowlisty":
    let dir = createTempDir("zpktest-archive3", "")
    defer: removeDir(dir)
    writeFile(dir / "a.txt", "A")
    writeFile(dir / "b.txt", "B")
    var toPack: seq[archive.PendingFile] = @[
      archive.PendingFile(relPath: "a.txt", absPath: dir / "a.txt"),
      archive.PendingFile(relPath: "b.txt", absPath: dir / "b.txt"),
    ]
    let outPath = dir / "t2.zpk"
    discard archive.writeArchive(outPath, toPack)
    let dest = dir / "out"
    let (ok, err) = archive.extractSelected(outPath, dest, @["a.txt"])
    check ok
    check fileExists(dest / "a.txt")
    check not fileExists(dest / "b.txt")

  test "uszkodzone dane są wykrywane przy ekstrakcji (sha256 z TOC)":
    let dir = createTempDir("zpktest-archive4", "")
    defer: removeDir(dir)
    writeFile(dir / "f.txt", "zawartosc do uszkodzenia".repeat(20))
    var toPack: seq[archive.PendingFile] = @[
      archive.PendingFile(relPath: "f.txt", absPath: dir / "f.txt"),
    ]
    let outPath = dir / "t3.zpk"
    discard archive.writeArchive(outPath, toPack)
    var bytes = readFile(outPath)
    bytes[bytes.len div 3] = char((int(bytes[bytes.len div 3]) + 1) mod 256)
    writeFile(outPath, bytes)
    let (ok, err) = archive.extractAll(outPath, dir / "out4")
    check not ok

  test "isZpkaFile odrzuca pliki spoza formatu":
    let dir = createTempDir("zpktest-archive5", "")
    defer: removeDir(dir)
    writeFile(dir / "nie-to.zpk", "to nie jest archiwum ZPKA, tylko zwykly tekst")
    check archive.isZpkaFile(dir / "nie-to.zpk") == false
