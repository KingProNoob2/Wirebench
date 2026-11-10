#!/usr/bin/env python3
"""Fills a macOS .app with exactly the Qt the Wirebench Qt app uses, and makes it run without Homebrew.

macdeployqt does the same job but scans every QML style and plugin Qt has (several minutes, and it copies Imagine, Fluent, Multimedia and
more that this app never loads). This copies the QML modules the app imports, the one platform plugin, and whatever libraries those need,
rewrites their paths to point inside the bundle, and signs each file. Every external command has a time limit.

Usage: bundle-qt.py <App.app> <libWirebenchBridge.dylib>
"""
import os, shutil, subprocess, sys, glob

APP, BRIDGE = sys.argv[1], sys.argv[2]
FW = os.path.join(APP, "Contents", "Frameworks")
EXE = os.path.join(APP, "Contents", "MacOS", "Wirebench-Qt")
QMLDIR = os.path.join(APP, "Contents", "Resources", "qml")
PLUGINS = os.path.join(APP, "Contents", "PlugIns")


def run(*cmd, limit=60, check=True):
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=limit)
    if check and out.returncode != 0:
        sys.exit(f"error: {' '.join(cmd[:3])} failed: {out.stderr.strip()[:300]}")
    return out.stdout


def brew(formula):
    return run("brew", "--prefix", formula).strip()


QTBASE, QTDECL = brew("qtbase"), brew("qtdeclarative")
LIBDIRS = sorted(glob.glob("/opt/homebrew/opt/qt*/lib")) + ["/opt/homebrew/lib"]

os.makedirs(FW, exist_ok=True)
os.makedirs(PLUGINS + "/platforms", exist_ok=True)
os.makedirs(QMLDIR, exist_ok=True)

# 1. What the app loads at run time besides its own binary: the macOS window plugin and the QML modules it imports.
shutil.copy(f"{QTBASE}/share/qt/plugins/platforms/libqcocoa.dylib", PLUGINS + "/platforms/")
shutil.copy(BRIDGE, FW + "/libWirebenchBridge.dylib")

src_qml = f"{QTDECL}/share/qt/qml"
def copy_dir(rel, only=None, skip=()):
    """A QML module directory, without the type-description files that are only for tooling. `only` limits sub-directories."""
    src, dst = os.path.join(src_qml, rel), os.path.join(QMLDIR, rel)
    os.makedirs(dst, exist_ok=True)
    for name in os.listdir(src):
        path = os.path.join(src, name)
        if os.path.isdir(path):
            if only is not None and name not in only:
                continue
            if name in skip or name in ("designer", "tooling"):
                continue
            shutil.copytree(path, os.path.join(dst, name), dirs_exist_ok=True,
                            ignore=shutil.ignore_patterns("*.qmltypes", "designer", "tooling", "*.prl"))
        elif not name.endswith(".qmltypes"):
            shutil.copy(path, dst)

copy_dir("QtQuick", only={"Controls", "Layouts", "Shapes", "Dialogs", "Templates", "Window"})
# Of the Controls styles the app sets "Basic" (main.cpp); the rest are other platforms' looks.
ctl = os.path.join(QMLDIR, "QtQuick", "Controls")
for style in os.listdir(ctl):
    if os.path.isdir(os.path.join(ctl, style)) and style not in ("Basic", "impl"):
        shutil.rmtree(os.path.join(ctl, style))
copy_dir("QtQml", only={"Models", "WorkerScript"})

with open(os.path.join(APP, "Contents", "Resources", "qt.conf"), "w") as conf:
    conf.write("[Paths]\nPlugins = PlugIns\nQml2Imports = Resources/qml\nImports = Resources/qml\n")

# 2. Every library those need, and theirs, copied in and re-pointed.
MAGIC = {b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}

def machos():
    """Every real Mach-O file in the bundle (executable, library, framework binary or plugin), found by its header."""
    for root, _, files in os.walk(APP):
        for name in files:
            path = os.path.join(root, name)
            if os.path.islink(path):
                continue
            with open(path, "rb") as handle:
                if handle.read(4) in MAGIC:
                    yield path

def deps(path):
    return [line.split()[0] for line in run("otool", "-L", path).splitlines()[1:] if line.strip()]

def rpaths(path):
    out, found = run("otool", "-l", path).splitlines(), []
    for i, line in enumerate(out):
        if "cmd LC_RPATH" in line:
            text = out[i + 2].strip()                    # "path /some/dir (offset 12)": a path may hold spaces
            found.append(text[len("path "):text.rindex(" (offset")])
    return found

def resolve(dep):
    """Where a library really is on this machine, or None for the operating system's own."""
    if dep.startswith(("/usr/lib", "/System", "/Library/Apple")) or dep.startswith("@loader_path") or dep.startswith("@executable_path"):
        return None
    if dep.startswith("@rpath/"):
        name = dep[len("@rpath/"):]
        for directory in LIBDIRS:
            if os.path.exists(os.path.join(directory, name)):
                return os.path.join(directory, name)
        return None
    return dep if os.path.exists(dep) and dep.startswith(("/opt/homebrew", "/usr/local")) else None

def bundle_copy(real):
    """Copies a framework or a plain library into the bundle; returns the @rpath name it now has."""
    if ".framework/" in real:
        fw_root = real[: real.index(".framework/") + len(".framework")]
        name = os.path.basename(fw_root)
        dest = os.path.join(FW, name)
        if not os.path.exists(dest):
            shutil.copytree(fw_root, dest, symlinks=True, ignore=shutil.ignore_patterns("Headers", "*.prl", "Modules"))
        return "@rpath/" + os.path.join(name, real[len(fw_root) + 1:])
    name = os.path.basename(real)
    dest = os.path.join(FW, name)
    if not os.path.exists(dest):
        shutil.copy(os.path.realpath(real), dest)
    return "@rpath/" + name

done = set()
queue = list(machos())
while queue:
    path = queue.pop()
    if path in done:
        continue
    done.add(path)
    changes = []
    for dep in deps(path):
        real = resolve(dep)
        if real is None:
            continue
        new = bundle_copy(real)
        if new != dep:
            changes += ["-change", dep, new]
    if path.startswith(FW + os.sep):
        changes += ["-id", "@rpath/" + os.path.relpath(path, FW)]
    # Look for libraries inside the bundle only: drop every search path but the one into the bundle.
    wanted = "@executable_path/../Frameworks" if path == EXE else "@loader_path/" + os.path.relpath(FW, os.path.dirname(path))
    have = rpaths(path)
    for rp in have:
        if rp != wanted:
            changes += ["-delete_rpath", rp]
    if wanted not in have:
        changes += ["-add_rpath", wanted]
    result = subprocess.run(["install_name_tool", *changes, path], capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        sys.exit(f"error: install_name_tool on {path}: {result.stderr.strip()[:300]}")
    for new_file in machos():
        if new_file not in done:
            queue.append(new_file)

# 3. A modified file's signature is void, and a library without a valid one will not load on Apple silicon: sign each, then the bundle.
for path in sorted(set(machos())):
    run("codesign", "--force", "--sign", "-", path, limit=30, check=False)
for fw in glob.glob(FW + "/*.framework"):
    run("codesign", "--force", "--sign", "-", fw, limit=30, check=False)
run("codesign", "--force", "--sign", "-", APP, limit=60)
# 4. Nothing may still point at this machine.
outside = []
for path in machos():
    for dep in deps(path):
        if not dep.startswith(("/usr/lib", "/System", "/Library/Apple", "@rpath/", "@loader_path", "@executable_path")):
            outside.append(f"{os.path.relpath(path, APP)}: {dep}")
        elif dep.startswith("@rpath/") and not os.path.exists(os.path.join(FW, dep[len("@rpath/"):])):
            outside.append(f"{os.path.relpath(path, APP)}: {dep} (not in the bundle)")
    for rp in rpaths(path):
        if not rp.startswith("@"):
            outside.append(f"{os.path.relpath(path, APP)}: rpath {rp}")
if outside:
    sys.exit("error: the bundle still refers to things outside itself:\n  " + "\n  ".join(outside[:15]))
print(f"bundled {len(done)} binaries, none refer outside the bundle")
