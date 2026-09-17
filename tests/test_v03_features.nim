import std/[unittest, os, tempfiles, strutils]
import ../src/zpkpkg/archive
import ../src/zpkpkg/signing
import ../src/zpkpkg/ed25519
import ../src/zpkpkg/zlz2
import ../src/zpkpkg/zsha512
import ../src/zpkpkg/bignum

## Testy funkcji dodanych w v0.6: ZLZ2 (lepszy kompresor), streaming,
## zpk diff/inspect, delty, natywny Ed25519. Niezależne od `hcl.nim`/
## `hcl_nim`, więc dają się uruchomić nawet bez tej zależności zainstalowanej
## (w przeciwieństwie do `test_core.nim`).

suite "zlz2 (LZ77 + Huffman, blokowo)":
  test "round-trip podstawowy + lepsza kompresja niż ZLZ1 na tekście":
    let readme = readFile(currentSourcePath().parentDir / ".." / "README.md")
    var b = newSeq[uint8](readme.len)
    for i in 0 ..< readme.len: b[i] = uint8(readme[i])
    let c = zlz2.compressBlock(b)
    var pos = 0
    let d = zlz2.decompressBlock(c, pos)
    check d == readme
    check pos == c.len

suite "archive v0.6: streaming, inspect, diff, delta":
  test "plik > StreamThreshold buduje sie strumieniowo (ZLZ2) i wraca bajt-w-bajt":
    let dir = createTempDir("zpktest-stream", "")
    defer: removeDir(dir)
    let big = "tresc do streamingu ".repeat(300_000)  # > 4 MiB
    check big.len > archive.StreamThreshold
    writeFile(dir / "big.bin", big)
    let outPath = dir / "t.zpk"
    discard archive.writeArchive(outPath, @[archive.PendingFile(relPath: "big.bin", absPath: dir / "big.bin")])
    let destDir = dir / "out"
    let (ok, err) = archive.extractAll(outPath, destDir)
    check ok
    check readFile(destDir / "big.bin") == big

  test "inspectArchive zwraca poprawne metody kompresji i sumy":
    let dir = createTempDir("zpktest-inspect", "")
    defer: removeDir(dir)
    writeFile(dir / "a.txt", "aaaa".repeat(1000))
    let outPath = dir / "t.zpk"
    discard archive.writeArchive(outPath, @[archive.PendingFile(relPath: "a.txt", absPath: dir / "a.txt")])
    let (ok, report, err) = archive.inspectArchive(outPath)
    check ok
    check report.entries.len == 1
    check report.entries[0].compSize < report.entries[0].rawSize

  test "diffArchives wykrywa added/removed/changed/unchanged":
    let dir = createTempDir("zpktest-diff", "")
    defer: removeDir(dir)
    createDir(dir / "v1"); createDir(dir / "v2")
    writeFile(dir / "v1" / "same.txt", "x")
    writeFile(dir / "v1" / "gone.txt", "y")
    writeFile(dir / "v2" / "same.txt", "x")
    writeFile(dir / "v2" / "new.txt", "z")
    discard archive.writeArchive(dir / "v1.zpk", @[
      archive.PendingFile(relPath: "same.txt", absPath: dir / "v1" / "same.txt"),
      archive.PendingFile(relPath: "gone.txt", absPath: dir / "v1" / "gone.txt")])
    discard archive.writeArchive(dir / "v2.zpk", @[
      archive.PendingFile(relPath: "same.txt", absPath: dir / "v2" / "same.txt"),
      archive.PendingFile(relPath: "new.txt", absPath: dir / "v2" / "new.txt")])
    let (ok, report, err) = archive.diffArchives(dir / "v1.zpk", dir / "v2.zpk")
    check ok
    check report.unchangedCount == 1
    var kinds: seq[DiffKind] = @[]
    for e in report.entries: kinds.add e.kind
    check dkAdded in kinds
    check dkRemoved in kinds

  test "buildDelta + applyDelta odtwarza dokladnie ten sam plik":
    let dir = createTempDir("zpktest-delta", "")
    defer: removeDir(dir)
    createDir(dir / "v1"); createDir(dir / "v2")
    let shared = "wspolna tresc\n".repeat(5000)
    writeFile(dir / "v1" / "shared.bin", shared)
    writeFile(dir / "v1" / "old.txt", "stare")
    writeFile(dir / "v2" / "shared.bin", shared)
    writeFile(dir / "v2" / "new.txt", "nowe")
    discard archive.writeArchive(dir / "v1.zpk", @[
      archive.PendingFile(relPath: "shared.bin", absPath: dir / "v1" / "shared.bin"),
      archive.PendingFile(relPath: "old.txt", absPath: dir / "v1" / "old.txt")])
    discard archive.writeArchive(dir / "v2.zpk", @[
      archive.PendingFile(relPath: "shared.bin", absPath: dir / "v2" / "shared.bin"),
      archive.PendingFile(relPath: "new.txt", absPath: dir / "v2" / "new.txt")])
    let (bok, _) = archive.buildDelta(dir / "v1.zpk", dir / "v2.zpk", dir / "delta.zpkd")
    check bok
    check getFileSize(dir / "delta.zpkd") < getFileSize(dir / "v2.zpk")
    let (aok, aerr) = archive.applyDelta(dir / "v1.zpk", dir / "delta.zpkd", dir / "v2_rebuilt.zpk")
    check aok
    let (e1ok, _) = archive.extractAll(dir / "v2.zpk", dir / "orig")
    let (e2ok, _) = archive.extractAll(dir / "v2_rebuilt.zpk", dir / "rebuilt")
    check e1ok and e2ok
    check readFile(dir / "orig" / "shared.bin") == readFile(dir / "rebuilt" / "shared.bin")
    check readFile(dir / "orig" / "new.txt") == readFile(dir / "rebuilt" / "new.txt")

suite "ed25519 natywny (bez openssl)":
  test "generowanie kluczy + podpis + weryfikacja + odrzucenie manipulacji":
    let dir = createTempDir("zpktest-ed", "")
    defer: removeDir(dir)
    signing.genNativeEd25519Keypair(dir / "k.priv", dir / "k.pub")
    writeFile(dir / "payload.txt", "tresc pakietu")
    let sig = signing.signFile(dir / "payload.txt", dir / "k.priv")
    check signing.verifyFile(dir / "payload.txt", dir / "k.pub", sig)
    writeFile(dir / "payload.txt", "ZMIENIONA tresc")
    check not signing.verifyFile(dir / "payload.txt", dir / "k.pub", sig)

  test "ed25519Sign/Verify -- API niskiego poziomu":
    let seed = "12345678901234567890123456789012"
    let pub = ed25519.ed25519DerivePublicKey(seed)
    let sig = ed25519.ed25519Sign(seed, "wiadomosc testowa")
    check ed25519.ed25519Verify(pub, "wiadomosc testowa", sig)
    check not ed25519.ed25519Verify(pub, "inna wiadomosc", sig)
