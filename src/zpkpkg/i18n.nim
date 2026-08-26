import std/[os, tables, strutils]

## Bardzo prosty i18n: tabela klucz -> {lokal: tekst}. Nie ma tu żadnej
## magii (bez formatów .po/.mo) -- to jest świadomie proste, bo cały
## interaktywny tekst (`zpk tutorial-release`) mieści się w jednym pliku
## i realistycznie nie potrzebuje pełnego frameworka i18n.
##
## Wybór języka: `ZPK_LANG=pl|en` w środowisku, inaczej `LANG`/`LC_ALL`
## systemu (jeśli zaczyna się od "pl"), inaczej domyślnie "en".

const translations = {
  "welcome": {
    "en": "Welcome to zpk's interactive release wizard.",
    "pl": "Witaj w interaktywnym kreatorze wydawania pakietów zpk."
  }.toTable,
  "ask_pkg_dir": {
    "en": "Path to the package directory (containing zpk.build)",
    "pl": "Ścieżka do katalogu pakietu (zawierającego zpk.build)"
  }.toTable,
  "ask_build_first": {
    "en": "Build the package now before releasing? [Y/n]",
    "pl": "Zbudować pakiet teraz, przed wydaniem? [T/n]"
  }.toTable,
  "ask_branch": {
    "en": "Target branch in own-repository.json (empty = default/top-level)",
    "pl": "Docelowy branch w own-repository.json (pusty = domyślny/top-level)"
  }.toTable,
  "ask_confirm_pr": {
    "en": "Create a pull request against the own-repository now? [y/N]",
    "pl": "Utworzyć teraz pull request do repozytorium own-repository? [t/N]"
  }.toTable,
  "building": {
    "en": "Building package...",
    "pl": "Buduję pakiet..."
  }.toTable,
  "build_failed": {
    "en": "Build failed -- fix the errors above and run `zpk tutorial-release` again.",
    "pl": "Budowanie się nie powiodło -- popraw błędy powyżej i uruchom `zpk tutorial-release` ponownie."
  }.toTable,
  "pr_created": {
    "en": "Pull request created successfully.",
    "pl": "Pull request utworzony pomyślnie."
  }.toTable,
  "pr_skipped": {
    "en": "Skipped -- nothing was published. Run `zpk schedule-release` manually when ready.",
    "pl": "Pominięto -- nic nie zostało opublikowane. Uruchom `zpk schedule-release` ręcznie, gdy będziesz gotowy."
  }.toTable,
  "gh_missing": {
    "en": "'gh' (GitHub CLI) not found in PATH -- cannot create a pull request automatically.",
    "pl": "'gh' (GitHub CLI) nie znaleziono w PATH -- nie mogę automatycznie utworzyć pull requesta."
  }.toTable,
  "goodbye": {
    "en": "Done. Thanks for publishing to the Zenit Linux ecosystem!",
    "pl": "Gotowe. Dzięki za publikację w ekosystemie Zenit Linux!"
  }.toTable,
}.toTable

proc detectLang*(): string =
  let envLang = getEnv("ZPK_LANG")
  if envLang.len > 0: return envLang
  let sysLang = getEnv("LANG", getEnv("LC_ALL", ""))
  if sysLang.toLowerAscii.startsWith("pl"): return "pl"
  "en"

proc t*(key: string, lang: string = ""): string =
  let l = if lang.len > 0: lang else: detectLang()
  if key notin translations:
    return key
  let entry = translations[key]
  if l in entry: return entry[l]
  entry.getOrDefault("en", key)
