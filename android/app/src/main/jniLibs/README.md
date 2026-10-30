# jniLibs

Kazumi runs BitTorrent through a bundled `aria2c` process. Android 10+ only
allows executing binaries that live in `nativeLibraryDir`, so the binary has to
be packaged as a shared library.

Place one executable per ABI:

```
jniLibs/
  arm64-v8a/libaria2c.so
  armeabi-v7a/libaria2c.so
  x86_64/libaria2c.so
```

Use `tool/package_aria2_android.sh <aria2c-binary> <abi>` to copy a prebuilt
static binary into the right folder. See `BT_SETUP.md` in the repository root
for how to obtain/build aria2 and how the feature is wired up.

Without these files the BT engine reports "未找到内置 aria2 引擎" on Android;
the rest of the app is unaffected.
