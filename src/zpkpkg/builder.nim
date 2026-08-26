import std/[os, osproc, json, strutils, strformat, times]
import ./types

## Buduje `recipe.<lang>` w katalogu pakietu (ten sam kontrakt co
## `buildZpk` w zpm/src/zpmpkg/zpk.nim: recipe dostaje ZPM_PACKAGE_STAGE_DIR
## i ma tam zostawić GOTOWE pliki, względem "/") i pakuje wynik do .zpk +
## manifest.json -- output jest bit-w-bit kompatybilny z tym, co produkuje
## `zpm pack`, więc `zpm install <plik>.zpk` działa bez żadnych zmian.

proc sha256sumOf(path: string): string =
  let sha = execProcess("sha256sum", args = @[path], options = {poUsePath})
  if sha.len == 0: return ""
  sha.split(' ')[0].strip()

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

proc buildOneArch*(pkgDir: string, m: ZpkBuildManifest, arch: string, outDir: string,
                    verbose: bool): tuple[ok: bool, path: string, manifest: ZpkManifest] =
  echo &"[zpk] Buduję {m.name} {m.version} ({arch})..."
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
    manifest.files.add ZpkFileEntry(path: rel, sha256: sha256sumOf(path))
  writeFile(stageDir / ManifestFileName, manifestToJson(manifest).pretty())

  createDir(outDir)
  let outPath = outDir / packageFileName(m.name, m.version, arch)
  let tarCode = execCmd(&"tar --numeric-owner --owner=0 --group=0 -C \"{stageDir}\" -acf \"{outPath}\" .")
  if tarCode != 0:
    stderr.writeLine(&"[zpk] ✘ Pakowanie do {outPath} nie powiodło się (kod {tarCode}).")
    return (false, "", ZpkManifest())

  manifest.sha256 = sha256sumOf(outPath)
  writeFile(outPath & ".json", manifestToJson(manifest).pretty())
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
