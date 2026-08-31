import std/[os, osproc, json, strutils, strformat, times, tables, algorithm]
import ./types
import ./checksum
import ./signing

## Buduje `recipe.<lang>` w katalogu pakietu (ten sam kontrakt co
## `buildZpk` w zpm/src/zpmpkg/zpk.nim: recipe dostaje ZPM_PACKAGE_STAGE_DIR
## i ma tam zostawić GOTOWE pliki, względem "/") i pakuje wynik do .zpk +
## manifest.json -- output jest bit-w-bit kompatybilny z tym, co produkuje
## `zpm pack`, więc `zpm install <plik>.zpk` działa bez żadnych zmian.
##
## UWAGA (cross-kompilacja): `zpk` samo NIE cross-kompiluje kodu -- ale
## jeśli `zpk.build` ma blok `toolchains { <arch> = "prefiks-" }`,
## ustawia recipe standardowe `CC`/`CXX`/`AR`/`STRIP` (patrz
## `toolchainEnvFor` niżej) -- konkretna, choć wąska pomoc dla typowych
## `make`/`configure`/`cgo`. Dodatkowo, jeśli w PATH jest
## `qemu-<arch>-static`, jego ścieżka trafia do recipe jako
## `$ZPM_QEMU_STATIC` (patrz `findQemuStatic`). Cała reszta (sysroot,
## `--target`, konfiguracja binfmt_misc, języki z własnym mechanizmem
## cross-target jak Rust/Zig) leży po stronie `recipe.<lang>` -- `zpk`
## o tym ostrzega (patrz `warnIfCrossArch` niżej), żeby nie było to
## zaskoczeniem dopiero po nieudanej instalacji na docelowym sprzęcie.

proc hostArch(): string =
  ## Zwraca architekturę hosta w konwencji zpm/zpk (x86_64/aarch64/...),
  ## mapując z nazewnictwa Nim (`hostCPU`: amd64/arm64/...). `hostCPU`
  ## jest stałą kompilacji Nim (nie zależy od środowiska uruchomieniowego).
  case hostCPU
  of "amd64": "x86_64"
  of "arm64": "aarch64"
  of "arm": "armv7"
  of "riscv64": "riscv64"
  of "i386": "i686"
  else: hostCPU

proc qemuArchName(arch: string): string =
  ## Mapuje nazewnictwo architektur zpk/zpm na konwencję nazewnictwa
  ## binarek `qemu-user-static` (`qemu-<nazwa>-static`).
  case arch
  of "x86_64": "x86_64"
  of "aarch64": "aarch64"
  of "armv7": "arm"
  of "riscv64": "riscv64"
  of "i686": "i386"
  else: arch

proc findQemuStatic*(arch: string): string =
  ## Szuka `qemu-<arch>-static` (albo `qemu-<arch>`) w PATH -- zwraca
  ## pełną ścieżkę, albo "" jeśli nie znaleziono. WYEKSPORTOWANE do
  ## testów jednostkowych (mapowanie nazw + wykrywanie w PATH).
  let qname = qemuArchName(arch)
  for candidate in [&"qemu-{qname}-static", &"qemu-{qname}"]:
    let p = findExe(candidate)
    if p.len > 0: return p
  ""

proc toolchainEnvFor*(toolchains: Table[string, string], arch: string): seq[(string, string)] =
  ## Jeśli `zpk.build` ma blok `toolchains { <arch> = "prefiks-" }` dla
  ## TEJ architektury, zwraca zmienne środowiskowe w konwencji, którą
  ## rozumie zdecydowana większość istniejących systemów budowania (make,
  ## autotools, CMake, `go build` przez cgo, wiele `Makefile`-i pisanych
  ## ręcznie): `CC`, `CXX`, `AR`, `STRIP` ustawione na `<prefiks>gcc` itd.,
  ## plus `ZPM_PACKAGE_CROSS_PREFIX` z samym prefiksem (do własnego użytku
  ## recipe, np. budowanie poleceniem, które nie honoruje CC/CXX).
  ##
  ## UCZCIWIE: to NIE JEST pełne rozwiązanie cross-kompilacji (nie
  ## instaluje toolchaina, nie configure'uje sysroota, nie pomaga
  ## językom z własnym mechanizmem cross-target jak Rust/`cargo` czy
  ## Zig) -- to jedna, wąska, ale realna korzyść: standardowe zmienne
  ## środowiskowe, które configure/make/cgo faktycznie odczytują, więc
  ## `recipe.<lang>` NIE musi samo znać ścieżki do toolchaina, jeśli
  ## operator skonfigurował go raz w `zpk.build`.
  result = @[]
  if not toolchains.hasKey(arch): return
  let prefix = toolchains[arch]
  result.add ("CC", prefix & "gcc")
  result.add ("CXX", prefix & "g++")
  result.add ("AR", prefix & "ar")
  result.add ("STRIP", prefix & "strip")
  result.add ("ZPM_PACKAGE_CROSS_PREFIX", prefix)

proc warnIfCrossArch(arch, recipeFile: string, hasToolchain: bool): string =
  ## Zwraca ścieżkę do `qemu-<arch>-static`, jeśli znaleziona w PATH
  ## (patrz `findQemuStatic`) -- wywołujący (`buildOneArch`) przekazuje
  ## ją dalej do recipe jako `ZPM_QEMU_STATIC`, żeby recipe (np. przy
  ## uruchamianiu cross-skompilowanych binarek testowych albo przez
  ## binfmt_misc) miało do niej dostęp bez zgadywania ścieżki.
  ##
  ## UCZCIWIE: to WCIĄŻ NIE JEST cross-kompilacja -- `zpk` samo nadal
  ## niczego nie kompiluje krzyżowo. To tylko usuwa jedno realne tarcie
  ## (znajdowanie ścieżki do qemu-static), zostawiając całą resztę
  ## (toolchain, `--target`, konfigurację binfmt_misc) po stronie
  ## `recipe.<lang>`.
  let host = hostArch()
  result = ""
  if arch.len > 0 and arch != host:
    result = findQemuStatic(arch)
    if hasToolchain:
      stderr.writeLine(&"[zpk] ℹ budowanie dla '{arch}' na hoście '{host}' -- skonfigurowany toolchain " &
        &"(package.arch + zpk.build toolchains.{arch}): CC/CXX/AR/STRIP ustawione dla recipe. " &
        "To ułatwienie, nie gwarancja -- recipe wciąż musi HONOROWAĆ te zmienne (make/configure/cgo " &
        "zwykle tak, ręczne wywołania kompilatora czasem nie).")
    elif result.len > 0:
      stderr.writeLine(&"[zpk] ⚠ budowanie dla '{arch}' na hoście '{host}' -- zpk NIE cross-kompiluje " &
        &"samo (i brak toolchains.{arch} w zpk.build); upewnij się, że '{recipeFile}' faktycznie " &
        &"produkuje binarki dla architektury '{arch}'. Znaleziono {result} -- dostępne dla recipe jako " &
        "$ZPM_QEMU_STATIC.")
    else:
      stderr.writeLine(&"[zpk] ⚠ budowanie dla '{arch}' na hoście '{host}' -- zpk NIE cross-kompiluje " &
        &"samo (i brak toolchains.{arch} w zpk.build); upewnij się, że '{recipeFile}' faktycznie " &
        &"produkuje binarki dla architektury '{arch}' (toolchain/QEMU/itp. -- nie znaleziono żadnego " &
        "qemu-*-static w PATH), inaczej pakiet nie zadziała po instalacji.")

proc contentDigestInput(files: seq[ZpkFileEntry]): string =
  ## Kanoniczna reprezentacja "zawartości pakietu" do policzenia JEDNEJ,
  ## zagregowanej sumy (`manifest.sha256`) -- POSORTOWANA (wg ścieżki,
  ## niezależnie od kolejności `walkDirRec`, która nie jest gwarantowana)
  ## lista "ścieżka\tsha256\n" wszystkich plików ŁADUNKU (payload), BEZ
  ## samego `manifest.json` (który i tak jeszcze nie istnieje w tym
  ## momencie budowania -- patrz komentarz w `buildOneArch`).
  var sorted = files
  sorted.sort(proc(a, b: ZpkFileEntry): int = cmp(a.path, b.path))
  var parts: seq[string] = @[]
  for f in sorted: parts.add(f.path & "\t" & f.sha256)
  parts.join("\n") & "\n"

proc contentDigestOf(files: seq[ZpkFileEntry]): string =
  ## sha256 wejścia z `contentDigestInput` -- policzone przez zapisanie go
  ## do pliku tymczasowego i przepuszczenie przez tę samą, przenośną
  ## `sha256sumOf` co reszta zpk (zamiast osobnej implementacji sha256 w
  ## czystym Nim -- jeden mechanizm liczenia hashy w całym projekcie).
  let tmp = getTempDir() / &"zpk-digest-{$epochTime().int}-{getCurrentProcessId()}.tmp"
  writeFile(tmp, contentDigestInput(files))
  defer: removeFile(tmp)
  sha256sumOf(tmp)

proc manifestToJson(m: ZpkManifest): JsonNode =
  result = newJObject()
  result["name"] = %m.name
  result["version"] = %m.version
  result["arch"] = %m.arch
  result["depends_on"] = %m.dependsOn
  result["sha256"] = %m.sha256
  result["description"] = %m.description
  result["build_recipe"] = %m.buildRecipe
  result["built_at"] = %m.builtAt
  if m.signature.len > 0:
    result["signature"] = %m.signature
    result["signed_with"] = %m.signedWith
  var filesArr = newJArray()
  for f in m.files:
    var fj = newJObject()
    fj["path"] = %f.path
    fj["sha256"] = %f.sha256
    filesArr.add fj
  result["files"] = filesArr

proc runRecipe(recipeDir, recipeFile, lang, stageDir: string,
                extraEnv: openArray[(string, string)], verbose: bool): int =
  let interp = case lang.toLowerAscii
    of "", "janet": "janet"
    else: lang
  if findExe(interp).len == 0:
    stderr.writeLine(&"[zpk] ✘ Brak interpretera '{interp}' w PATH.")
    return 127
  for (k, v) in extraEnv:
    putEnv(k, v)
  if verbose:
    echo &"[zpk] $ (cwd={recipeDir}) {interp} {recipeFile}"
    for (k, v) in extraEnv:
      echo &"[zpk]   env {k}={v}"
  let p = startProcess(interp, workingDir = recipeDir, args = @[recipeDir / recipeFile],
                        options = {poUsePath, poParentStreams})
  result = p.waitForExit()
  p.close()

proc packageFileName*(name, version, arch: string): string =
  &"{name}-{version}-{arch}.zpk"

proc archFromPackageFileName*(fileName, name, version: string): string =
  ## Odwraca `packageFileName` -- używane przez `zpk schedule-release
  ## --asset=<ścieżka>`, żeby odgadnąć, dla jakiej architektury jest ten
  ## already-zbudowany plik (potrzebne do poprawnego wpisu "bin" w
  ## own-repository.json). Zwraca "" jeśli nazwa nie pasuje do wzorca.
  let prefix = &"{name}-{version}-"
  let suffix = ".zpk"
  if fileName.startsWith(prefix) and fileName.endsWith(suffix) and fileName.len > prefix.len + suffix.len:
    return fileName[prefix.len ..< fileName.len - suffix.len]
  ""

proc buildOneArch*(pkgDir: string, m: ZpkBuildManifest, arch: string, outDir: string,
                    verbose: bool): tuple[ok: bool, path: string, manifest: ZpkManifest] =
  echo &"[zpk] Buduję {m.name} {m.version} ({arch})..."
  let toolchainEnv = toolchainEnvFor(m.toolchains, arch)
  let qemuStatic = warnIfCrossArch(arch, m.recipeFile, toolchainEnv.len > 0)
  let stageDir = getTempDir() / &"zpk-build-{m.name}-{arch}-{$epochTime().int}"
  createDir(stageDir)
  defer: removeDir(stageDir)

  var recipeEnv = @[("ZPM_PACKAGE_STAGE_DIR", stageDir), ("ZPM_PACKAGE_NAME", m.name),
                     ("ZPM_PACKAGE_VERSION", m.version), ("ZPM_PACKAGE_ARCH", arch)]
  if qemuStatic.len > 0:
    recipeEnv.add ("ZPM_QEMU_STATIC", qemuStatic)
  recipeEnv.add toolchainEnv

  let code = runRecipe(pkgDir, m.recipeFile, m.recipeLang, stageDir, recipeEnv, verbose)
  if code != 0:
    stderr.writeLine(&"[zpk] ✘ recipe '{m.recipeFile}' nie powiodło się dla {arch} (kod {code}).")
    return (false, "", ZpkManifest())

  var manifest = ZpkManifest(
    name: m.name, version: m.version, arch: arch, dependsOn: m.dependsOn,
    description: m.description, buildRecipe: m.recipeFile, builtAt: nowIso8601()
  )
  for path in walkDirRec(stageDir):
    let rel = path.relativePath(stageDir)
    try:
      manifest.files.add ZpkFileEntry(path: rel, sha256: sha256sumOf(path))
    except ChecksumError as e:
      stderr.writeLine(&"[zpk] ✘ {e.msg}")
      return (false, "", ZpkManifest())

  # v0.4 -- `manifest.sha256` NIE JEST już sumą CAŁEGO archiwum .zpk
  # (to byłoby niemożliwe do policzenia PRZED zapisaniem manifestu do
  # środka: plik nie może w sposób prosty zawierać własnej sumy siebie
  # samego). Zamiast tego jest to JEDNA, zagregowana suma ZAWARTOŚCI
  # pakietu -- sha256 posortowanej listy "ścieżka + sha256" wszystkich
  # plików ładunku (patrz `contentDigestOf`) -- w pełni policzalna PRZED
  # spakowaniem, więc manifest z POPRAWNĄ sumą może wylądować w środku
  # TEGO SAMEGO, jedynego archiwum .zpk zamiast w osobnym pliku obok
  # niego (`<plik>.zpk.json` już nie jest produkowane). Weryfikacja
  # (`verifyPackage`) odtwarza dokładnie tę samą sumę z rozpakowanej
  # zawartości i porównuje z tym, co manifest deklaruje.
  try:
    manifest.sha256 = contentDigestOf(manifest.files)
  except ChecksumError as e:
    stderr.writeLine(&"[zpk] ✘ {e.msg}")
    return (false, "", ZpkManifest())

  # Podpisywanie jest opcjonalne: aktywuje się wyłącznie zmienną
  # środowiskową ZPK_SIGN_KEY (ścieżka do klucza prywatnego PEM). Podpis
  # (jak sha256 wyżej) MUSI dać się policzyć PRZED spakowaniem -- podpisuje
  # więc tę samą kanoniczną reprezentację zawartości (`contentDigestInput`),
  # zapisaną chwilowo do pliku tymczasowego wyłącznie na potrzeby wywołania
  # `openssl` (patrz `signFile`), NIE finalne archiwum .zpk.
  let signKey = getEnv("ZPK_SIGN_KEY")
  if signKey.len > 0:
    let digestTmp = getTempDir() / &"zpk-sign-{$epochTime().int}-{getCurrentProcessId()}.tmp"
    writeFile(digestTmp, contentDigestInput(manifest.files))
    try:
      manifest.signature = signFile(digestTmp, signKey)
      manifest.signedWith = signKey.extractFilename
      echo &"[zpk] ✔ podpisano kluczem {signKey}"
    except SigningError as e:
      stderr.writeLine(&"[zpk] ✘ {e.msg}")
      removeFile(digestTmp)
      return (false, "", ZpkManifest())
    removeFile(digestTmp)

  # Manifest (z JUŻ POPRAWNĄ sumą/podpisem) dopisany do stagingu TERAZ,
  # PRZED jedynym wywołaniem `tar` -- trafia więc do środka archiwum razem
  # z resztą ładunku, w JEDNYM przebiegu (bez przepakowywania).
  writeFile(stageDir / ManifestFileName, manifestToJson(manifest).pretty())

  createDir(outDir)
  let outPath = outDir / packageFileName(m.name, m.version, arch)
  let tarCode = execCmd(&"tar --numeric-owner --owner=0 --group=0 -C {quoteShell(stageDir)} " &
    &"-acf {quoteShell(outPath)} .")
  if tarCode != 0:
    stderr.writeLine(&"[zpk] ✘ Pakowanie do {outPath} nie powiodło się (kod {tarCode}).")
    return (false, "", ZpkManifest())

  echo &"[zpk] ✔ {outPath} (manifest.json w środku archiwum, sha256 zawartości={manifest.sha256})"
  (true, outPath, manifest)

proc buildAll*(pkgDir: string, m: ZpkBuildManifest, outDir: string,
               verbose: bool, onlyArch: string = ""): tuple[ok: bool, built: seq[tuple[arch, path: string]]] =
  ## `--release`: buduje dla WSZYSTKICH architektur z `package.arch`;
  ## `onlyArch` niepusty (z `--arch=X` w CLI): buduje tylko jedną,
  ## przydatne przy szybkiej iteracji lokalnej.
  var built: seq[tuple[arch, path: string]] = @[]
  let arches = if onlyArch.len > 0: @[onlyArch] else: m.arches
  for arch in arches:
    let (ok, path, _) = buildOneArch(pkgDir, m, arch, outDir, verbose)
    if not ok:
      return (false, built)
    built.add (arch, path)
  (true, built)

proc extractManifestFromArchive(zpkPath: string): tuple[ok: bool, manifest: JsonNode, err: string] =
  ## `manifest.json` mieszka TERAZ w środku archiwum (patrz `buildOneArch`),
  ## nie obok niego -- wyciąga go przez `tar -xOf` (wypisuje zawartość
  ## pojedynczego pliku archiwum na stdout, bez rozpakowywania reszty).
  let (output, code) = execCmdEx(&"tar -xOf {quoteShell(zpkPath)} {quoteShell(ManifestFileName)}")
  if code != 0 or output.strip().len == 0:
    return (false, newJNull(), &"nie udało się odczytać '{ManifestFileName}' z wnętrza {zpkPath} " &
      &"(kod {code}) -- czy to na pewno poprawne archiwum .zpk?")
  try:
    (true, parseJson(output), "")
  except CatchableError as e:
    (false, newJNull(), &"'{ManifestFileName}' wewnątrz {zpkPath} nie jest poprawnym JSON-em: {e.msg}")

proc verifyPackage*(zpkPath: string, publicKeyPath: string = ""): tuple[ok: bool, messages: seq[string]] =
  ## `zpk verify <plik.zpk>` -- v0.4: manifest (z sumą zawartości i,
  ## opcjonalnie, podpisem) mieszka W ŚRODKU archiwum, nie w osobnych
  ## plikach `<plik>.zpk.json`/`<plik>.zpk.sig` obok niego (patrz
  ## `buildOneArch`). Weryfikacja: (1) wyciąga manifest z archiwum,
  ## (2) rozpakowuje CAŁE archiwum do katalogu tymczasowego, (3) liczy
  ## sha256 KAŻDEGO pliku ładunku od nowa i porównuje z tym, co manifest
  ## deklaruje per-plik ORAZ z zagregowaną sumą `manifest.sha256`
  ## (integralność) -- (4) jeśli manifest niesie podpis, weryfikuje go
  ## względem tej samej kanonicznej reprezentacji zawartości, którą
  ## podpisało `zpk build --sign-key=...` (autentyczność).
  var messages: seq[string] = @[]
  var ok = true
  if not fileExists(zpkPath):
    return (false, @[&"nie znaleziono {zpkPath}"])

  let (gotManifest, manifestJson, manifestErr) = extractManifestFromArchive(zpkPath)
  if not gotManifest:
    return (false, @[manifestErr])

  let declaredSha256 = manifestJson{"sha256"}.getStr("")
  var declaredFiles: seq[ZpkFileEntry] = @[]
  if manifestJson.hasKey("files") and manifestJson["files"].kind == JArray:
    for it in manifestJson["files"]:
      declaredFiles.add ZpkFileEntry(path: it{"path"}.getStr(""), sha256: it{"sha256"}.getStr(""))

  let extractDir = getTempDir() / &"zpk-verify-{$epochTime().int}-{getCurrentProcessId()}"
  createDir(extractDir)
  defer: removeDir(extractDir)
  let extractCode = execCmd(&"tar -C {quoteShell(extractDir)} -xf {quoteShell(zpkPath)}")
  if extractCode != 0:
    return (false, @[&"nie udało się rozpakować {zpkPath} do weryfikacji (kod {extractCode})"])

  var recomputed: seq[ZpkFileEntry] = @[]
  var mismatch = false
  for entry in declaredFiles:
    let full = extractDir / entry.path
    if not fileExists(full):
      ok = false
      mismatch = true
      messages.add &"BRAK pliku zadeklarowanego w manifeście: {entry.path}"
      continue
    try:
      let actual = sha256sumOf(full)
      recomputed.add ZpkFileEntry(path: entry.path, sha256: actual)
      if actual != entry.sha256:
        ok = false
        mismatch = true
        messages.add &"NIEZGODNOŚĆ sha256 pliku '{entry.path}': manifest={entry.sha256} obliczono={actual}"
    except ChecksumError as e:
      return (false, @[e.msg])

  if not mismatch:
    if declaredSha256.len == 0:
      ok = false
      messages.add "manifest nie zawiera zagregowanej sumy sha256"
    else:
      var actualAggregate: string
      try:
        actualAggregate = contentDigestOf(recomputed)
      except ChecksumError as e:
        return (false, @[e.msg])
      if actualAggregate != declaredSha256:
        ok = false
        messages.add &"NIEZGODNOŚĆ zagregowanej sha256: manifest={declaredSha256} obliczono={actualAggregate}"
      else:
        messages.add &"sha256 OK ({actualAggregate}, {declaredFiles.len} plików)"

  let declaredSig = manifestJson{"signature"}.getStr("")
  let pubKey = if publicKeyPath.len > 0: publicKeyPath else: getEnv("ZPK_VERIFY_KEY")
  if declaredSig.len > 0:
    if pubKey.len == 0:
      messages.add "pakiet ma podpis (manifest.signature), ale nie podano klucza publicznego " &
        "(--pubkey albo ZPK_VERIFY_KEY) -- pomijam weryfikację podpisu"
    elif mismatch:
      messages.add "pomijam weryfikację podpisu -- zawartość już nie zgadza się z manifestem"
    else:
      let digestTmp = getTempDir() / &"zpk-verify-sign-{$epochTime().int}-{getCurrentProcessId()}.tmp"
      writeFile(digestTmp, contentDigestInput(recomputed))
      let sigOk = verifyFile(digestTmp, pubKey, declaredSig)
      removeFile(digestTmp)
      if sigOk:
        messages.add "podpis OK -- autentyczność potwierdzona"
      else:
        ok = false
        messages.add "podpis NIEPRAWIDŁOWY -- plik mógł zostać zmodyfikowany albo podpisany innym kluczem"
  else:
    messages.add "pakiet nie jest podpisany (brak manifest.signature) -- zweryfikowano tylko integralność (sha256), nie autentyczność"

  (ok, messages)
