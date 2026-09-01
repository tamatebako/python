# Relocation probe — CPython 3.13.15 + 3.12.14 on macos-arm64

The evidence behind the zero patch inventory (`patches/README.md`). Both
pinned lines were built from the factory-pinned tarballs, installed into a
prefix, the installed tree was **moved** (the compiled-in prefix ceased to
exist), and the relocated interpreter was verified — with and without
`PYTHONHOME`.

**Verdict: relocatable as-is. No patch needed.** `sys.prefix`,
`sys.base_prefix`, every `sys.path` entry and sysconfig's stdlib paths all
resolve to the relocated prefix; `ssl` and `json` import and work; no
runtime path references the compiled-in prefix.

## Environment

- Host: macOS 14.1.1 (23B81), arm64 (Apple M-class), Darwin 23.1.0
- Compiler: Apple clang 15.0.0 (`/usr/bin/cc`, Xcode at
  /Applications/Xcode.app)
- OpenSSL for `_ssl`: Homebrew `openssl@3` at
  `/opt/homebrew/opt/openssl@3` (OpenSSL 3.6.3, 9 Jun 2026). The `_ssl`
  extension dynamically links the absolute brew paths
  (`otool -L` below): relocating the python tree does not relocate
  OpenSSL. That is a runtime-factory concern (vendoring/static link), not
  a source-factory patch.
- Tarballs: the factory pins (`versions.yml`), sha256-verified and
  cross-checked (README § versions.yml header).

## Commands (per version, verbatim)

```sh
V=3.13.15   # and 3.12.14
ROOT=$PWD/build/probe/$V
tar -xf .cache/tarballs/Python-$V.tar.xz -C $ROOT
mv $ROOT/Python-$V $ROOT/src
cd $ROOT/src
CC=/usr/bin/cc ./configure --prefix=$ROOT/installed-a \
  --with-openssl=/opt/homebrew/opt/openssl@3
make -j6
make install

# relocate: a REAL move — the compiled-in prefix no longer exists
mv $ROOT/installed-a $ROOT/installed-b

# the acceptance leg, with PYTHONHOME
PYTHONHOME=$ROOT/installed-b $ROOT/installed-b/bin/python3 \
  -c "import sys, json, ssl; print(sys.prefix)"

# and without PYTHONHOME (getpath.py resolves from the executable path)
$ROOT/installed-b/bin/python3 \
  -c "import sys, json, ssl; print(sys.prefix)"
```

(The scripted form lives at `build/probe/build-probe.sh` +
`build/probe/relocate-test.sh`; `build/` is gitignored scratch. Build time:
2m31s per version at `-j6`, the two versions built in parallel.)

## Results — 3.13.15 (2026-09-01T05:53:03Z)

```
-- mv .../3.13.15/installed-a .../3.13.15/installed-b
compiled-in prefix now invalid: absent

-- with PYTHONHOME:
$ PYTHONHOME=.../installed-b .../installed-b/bin/python3 -c "import sys, json, ssl; print(sys.prefix)"
/Users/mulgogi/src/tamatebako/python/build/probe/3.13.15/installed-b
exit=0

-- without PYTHONHOME (getpath.py resolves from the executable path):
$ .../installed-b/bin/python3 -c "import sys, json, ssl; print(sys.prefix)"
/Users/mulgogi/src/tamatebako/python/build/probe/3.13.15/installed-b
exit=0

-- sys.path / prefix detail (no PYTHONHOME):
sys.prefix      = .../installed-b
sys.base_prefix = .../installed-b
sys.exec_prefix = .../installed-b
sys.path        = .../installed-b/lib/python313.zip
sys.path        = .../installed-b/lib/python3.13
sys.path        = .../installed-b/lib/python3.13/lib-dynload
sys.path        = .../installed-b/lib/python3.13/site-packages
stdlib          = .../installed-b/lib/python3.13
platstdlib      = .../installed-b/lib/python3.13

-- compiled-in prefix leak check:
LEAK-FREE: no runtime path references .../installed-a

-- ssl / json smoke:
OpenSSL 3.6.3 9 Jun 2026
{"ok": true}
{ "probe": 1 }   (python3 -m json.tool)

-- _ssl extension linkage (otool -L):
_ssl.cpython-313-darwin.so:
	/opt/homebrew/opt/openssl@3/lib/libssl.3.dylib (compatibility version 3.0.0, current version 3.0.0)
	/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib (compatibility version 3.0.0, current version 3.0.0)
	/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1336.0.0)

-- pip present (ensurepip ran at install):
pip 26.2.1 from .../installed-b/lib/python3.13/site-packages/pip (python 3.13)
```

## Results — 3.12.14 (2026-09-01T05:53:32Z)

Identical shape; the transcript:

```
-- mv .../3.12.14/installed-a .../3.12.14/installed-b
compiled-in prefix now invalid: absent

-- with PYTHONHOME:
.../installed-b/bin/python3 -c "..." → /Users/mulgogi/src/tamatebako/python/build/probe/3.12.14/installed-b
exit=0

-- without PYTHONHOME:
→ /Users/mulgogi/src/tamatebako/python/build/probe/3.12.14/installed-b
exit=0

sys.prefix / sys.base_prefix / sys.exec_prefix = .../installed-b
sys.path = .../installed-b/lib/python312.zip, .../lib/python3.12,
           .../lib/python3.12/lib-dynload, .../lib/python3.12/site-packages

-- compiled-in prefix leak check:
LEAK-FREE: no runtime path references .../installed-a

-- ssl / json smoke:
OpenSSL 3.6.3 9 Jun 2026
{"ok": true}

-- _ssl linkage:
_ssl.cpython-312-darwin.so → /opt/homebrew/opt/openssl@3/lib/{libssl,libcrypto}.3.dylib, /usr/lib/libSystem.B.dylib

-- pip:
pip 25.0.1 (.../installed-b/lib/python3.12/site-packages, python 3.12)
```

## Notes and scope

- The mechanism: since 3.11 the path config is computed by the frozen
  `Modules/getpath.py` at startup — from `PYTHONHOME` when set, else by
  walking up from the real executable path looking for landmarks
  (`lib/python<X.Y>/os.py`). A moved prefix resolves correctly either way;
  the compiled-in `--prefix` is only a fallback when landmarks are absent.
- `sysconfig.get_config_var("prefix")`-style *static* config still records
  the build-time prefix (it is data generated at configure time); nothing
  in the runtime path resolution reads it. Recorded here so a future
  surprise audit knows it is expected.
- Scope: macos-arm64 only, per the work item. linux-gnu/musl and windows
  legs are runtime-factory CI material (TODO.python/02); windows was
  flagged in the brief as the place a getpath quirk could still force a
  patch — if one reproduces there, it lands in `patches/` per
  `patches/README.md`, reviewed, never speculative.
