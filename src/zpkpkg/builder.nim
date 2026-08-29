import std/[os, osproc, json, strutils, strformat, times]
import ./types
import ./checksum
import ./signing

## Buduje `recipe.<lang>` w katalogu pakietu (ten sam kontrakt co
## `buildZpk` w zpm/src/zpmpkg/zpk.nim: recipe dostaje ZPM_PACKAGE_STAGE_DIR
## i ma tam zostawić GOTOWE pliki, względem "/") i pakuje wynik do .zpk +
## manifest.json -- output jest bit-w-bit kompatybilny z tym, co produkuje
## `zpm pack`, więc `zpm install <plik>.zpk` działa bez żadnych zmian.
##
## UWAGA (cross-kompilacja): `zpk` NIE cross-kompiluje niczego samo --
## dla `--release` po prostu iteruje po `package.arch` i ustawia
## `ZPM_PACKAGE_ARCH` w środowisku recipe. Jeśli architektura docelowa
## różni się od hosta, to CAŁA odpowiedzialność za wyprodukowanie
## poprawnych binarek (toolchain/cross-kompilator/QEMU/itd.) leży po
## stronie `recipe.<lang>` -- `zpk` tylko o tym ostrzega (patrz
## `warnIfCrossArch` niżej), żeby nie było to zaskoczeniem dopiero po
## nieudanej instalacji na docelowym sprzęcie.

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

proc warnIfCrossArch(arch, recipeFile: string) =
  let host = hostArch()
  if arch.len > 0 and arch != host:
    stderr.writeLine(&"[zpk] ⚠ budowanie dla '{arch}' na hoście '{host}' -- zpk NIE cross-kompiluje " &
      &"samo; upewnij się, że '{recipeFile}' faktycznie produkuje binarki dla architektury '{arch}' " &
      "(toolchain/QEMU/itp.), inaczej pakiet nie zadziała po instalacji.")

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
  warnIfCrossArch(arch, m.recipeFile)
  let stageDir = getTempDir() / &"zpk-build-{m.name}-{arch}-{$epochTime().int}"
  createDir(stageDir)
  defer: removeDir(stageDir)

  let code = runRecipe(pkgDir, m.recipeFile, m.recipeLang, stageDir,
                        [("ZPM_PACKAGE_STAGE_DIR", stageDir), ("ZPM_PACKAGE_NAME", m.name),
                         ("ZPM_PACKAGE_VERSION", m.version), ("ZPM_PACKAGE_ARCH", arch)],
                        verbose)
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
  writeFile(stageDir / ManifestFileName, manifestToJson(manifest).pretty())

  createDir(outDir)
  let outPath = outDir / packageFileName(m.name, m.version, arch)
  let tarCode = execCmd(&"tar --numeric-owner --owner=0 --group=0 -C {quoteShell(stageDir)} " &
    &"-acf {quoteShell(outPath)} .")
  if tarCode != 0:
    stderr.writeLine(&"[zpk] ✘ Pakowanie do {outPath} nie powiodło się (kod {tarCode}).")
    return (false, "", ZpkManifest())

  try:
    manifest.sha256 = sha256sumOf(outPath)
  except ChecksumError as e:
    stderr.writeLine(&"[zpk] ✘ {e.msg}")
    return (false, "", ZpkManifest())

  # Podpisywanie jest opcjonalne: aktywuje się wyłącznie zmienną
  # środowiskową ZPK_SIGN_KEY (ścieżka do klucza prywatnego PEM). Bez
  # niej zachowanie jest identyczne jak wcześniej (tylko sha256).
  let signKey = getEnv("ZPK_SIGN_KEY")
  if signKey.len > 0:
    try:
      manifest.signature = signFile(outPath, signKey)
      manifest.signedWith = signKey.extractFilename
      echo &"[zpk] ✔ podpisano kluczem {signKey}"
    except SigningError as e:
      stderr.writeLine(&"[zpk] ✘ {e.msg}")
      return (false, "", ZpkManifest())

  writeFile(outPath & ".json", manifestToJson(manifest).pretty())
  if manifest.signature.len > 0:
    writeFile(outPath & ".sig", manifest.signature)
  echo &"[zpk] ✔ {outPath} (sha256={manifest.sha256})"
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

proc verifyPackage*(zpkPath: string, publicKeyPath: string = ""): tuple[ok: bool, messages: seq[string]] =
  ## `zpk verify <plik.zpk>` -- sprawdza integralność (sha256 archiwum
  ## zgodny z manifestem `<plik>.zpk.json`) oraz, jeśli podano klucz
  ## publiczny (albo ZPK_VERIFY_KEY w środowisku) i pakiet ma podpis
  ## (`<plik>.zpk.sig`), AUTENTYCZNOŚĆ (podpis pasuje do klucza).
  var messages: seq[string] = @[]
  var ok = true
  let manifestPath = zpkPath & ".json"
  if not fileExists(zpkPath):
    return (false, @[&"nie znaleziono {zpkPath}"])
  if not fileExists(manifestPath):
    return (false, @[&"nie znaleziono {manifestPath} (manifest musi leżeć obok pliku .zpk)"])

  let declared = parseJson(readFile(manifestPath)){"sha256"}.getStr("")
  var actual: string
  try:
    actual = sha256sumOf(zpkPath)
  except ChecksumError as e:
    return (false, @[e.msg])
  if declared.len == 0:
    ok = false
    messages.add "manifest nie zawiera sha256"
  elif declared != actual:
    ok = false
    messages.add &"NIEZGODNOŚĆ sha256: manifest={declared} obliczono={actual}"
  else:
    messages.add &"sha256 OK ({actual})"

  let sigPath = zpkPath & ".sig"
  let pubKey = if publicKeyPath.len > 0: publicKeyPath else: getEnv("ZPK_VERIFY_KEY")
  if fileExists(sigPath):
    if pubKey.len == 0:
      messages.add "pakiet ma podpis (.sig), ale nie podano klucza publicznego (--pubkey albo ZPK_VERIFY_KEY) -- pomijam weryfikację podpisu"
    else:
      let sig = readFile(sigPath).strip()
      if verifyFile(zpkPath, pubKey, sig):
        messages.add "podpis OK -- autentyczność potwierdzona"
      else:
        ok = false
        messages.add "podpis NIEPRAWIDŁOWY -- plik mógł zostać zmodyfikowany albo podpisany innym kluczem"
  else:
    messages.add "pakiet nie jest podpisany (brak .sig) -- zweryfikowano tylko integralność (sha256), nie autentyczność"

  (ok, messages)
