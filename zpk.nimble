version       = "0.2.0"
author        = "Zenit Linux Developers"
description   = "zpk -- oficjalny builder pakietow .zpk dla zpm (Zenit Linux)"
license       = "GPL-3.0"
srcDir        = "src"
bin           = @["zpk"]
binDir        = "bin"

requires "nim >= 2.0.0"

requires "hcl_nim >= 0.1.0"

task test, "Uruchamia testy jednostkowe":
  exec "nim c -d:ssl -r --out:bin/test_core tests/test_core.nim"

task buildRelease, "Buduje zoptymalizowana binarke release":
  exec "nim c -d:release -d:ssl --opt:speed -o:bin/zpk src/zpk.nim"
