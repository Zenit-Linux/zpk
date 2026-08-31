(def stage (os/getenv "ZPM_PACKAGE_STAGE_DIR"))

(defn fail [msg]
  (eprint "recipe.janet: " msg)
  (os/exit 1))

(defn run [cmd]
  # `os/shell` zwraca kod wyjścia polecenia (jak C-owe system()) --
  # zero == sukces, tak samo jak `set -e` w dawnym recipe.sh.
  (def code (os/shell cmd))
  (unless (zero? code)
    (fail (string "'" cmd "' zakończone kodem " code))))

(defn ensure-dir [path]
  # `os/mkdir` w Janet nie jest rekurencyjne i zgłasza błąd, jeśli katalog
  # już istnieje -- oba przypadki są tu nieszkodliwe (świeży katalog
  # roboczy z ZPM_PACKAGE_STAGE_DIR może już mieć część drzewa "usr/..."
  # z poprzedniego, przerwanego builda), więc łykamy błąd i jedziemy dalej.
  (try (os/mkdir path) ([_] nil)))

# packaging/recipe.janet leży w <repo>/packaging -- katalog wyżej to
# korzeń repo, niezależnie od tego, skąd faktycznie wywołano `zpk build`.
(def repo-root (string (os/cwd) "/.."))

(def prebuilt (os/getenv "ZPK_PACKAGING_PREBUILT_BIN"))

(def bin-path
  (if (and prebuilt (> (length prebuilt) 0))
    # CI/operator już zbudował binarkę wcześniej w tym samym biegu (np.
    # w tym samym jobie co `nimble buildRelease` przed wywołaniem `zpk
    # build` na sobie samym) -- nie buduj drugi raz, użyj gotowej ścieżki.
    prebuilt
    (do
      (run (string "command -v nimble >/dev/null 2>&1 || "
                   "{ echo \"recipe.janet: brak 'nimble' w PATH -- zainstaluj Nim >= 2.0\" >&2; exit 1; }"))
      (run (string "cd " repo-root " && nimble buildRelease"))
      (string repo-root "/bin/zpk"))))

(unless (os/stat bin-path :mode)
  (fail (string "nie znaleziono zbudowanej binarki: " bin-path)))

(def bin-dir (string stage "/usr/local/bin"))
(ensure-dir stage)
(ensure-dir (string stage "/usr"))
(ensure-dir (string stage "/usr/local"))
(ensure-dir bin-dir)

(def dest (string bin-dir "/zpk"))
(spit dest (slurp bin-path))
(run (string "chmod +x " dest))
