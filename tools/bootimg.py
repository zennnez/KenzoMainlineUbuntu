#!/usr/bin/env python3
"""Tiny Android boot image v2 pack/unpack (no external deps). Matches the Lineage 23.2 kenzo header layout.
  bootimg.py unpack IMG [OFFSET] [-o DIR]   -> prints header, writes kernel(.gz)/Image/ramdisk/dtb/cmdline.txt (+ lk2nd.img if hybrid)
                                               OFFSET auto-detected (0, 0x80000, 0x100000) when omitted
  bootimg.py verify IMG                      -> sanity-check an image before flashing (refuses lk2nd-hybrid images)
  bootimg.py pack -o OUT --kernel K --ramdisk R --dtb D --cmdline "..." [--hybrid lk2nd.img]

IMPORTANT (lk2nd): in lk2nd's fastboot, the "boot" partition is the real boot partition MINUS its first 512 KiB
(that part is the virtual "lk2nd" partition). So:
  * `fastboot boot` / `fastboot flash boot`  need a PLAIN Android boot image (pack WITHOUT --hybrid).
  * a --hybrid image (lk2nd + Android image @512K) is only for raw writes of the whole partition (dd / recovery zip).
"""
import argparse, gzip, hashlib, os, struct, sys, zlib

PS_DEFAULT = 2048
def pg(n, ps): return (n + ps - 1) // ps * ps

def pack(a):
    ps = a.pagesize
    k, r, d = (open(p, "rb").read() for p in (a.kernel, a.ramdisk, a.dtb))
    cmd = a.cmdline.encode()
    assert len(cmd) <= 512 + 1024 - 1, "cmdline too long"
    c1, c2 = cmd[:512], cmd[512:]
    sha = hashlib.sha1()
    for blob in (k, r, b""):                      # kernel, ramdisk, second
        sha.update(blob); sha.update(struct.pack("<I", len(blob)))
    sha.update(struct.pack("<I", 0))              # recovery_dtbo size
    sha.update(d); sha.update(struct.pack("<I", len(d)))
    ident = sha.digest() + b"\0" * 12
    hdr = b"ANDROID!"
    hdr += struct.pack("<10I", len(k), a.base + a.kernel_offset, len(r), a.base + a.ramdisk_offset,
                       0, a.second_addr, a.base + a.tags_offset, ps, 2, a.os_version)
    hdr += a.name.encode().ljust(16, b"\0")[:16] + c1.ljust(512, b"\0") + ident + c2.ljust(1024, b"\0")
    hdr += struct.pack("<IQI", 0, 0, 1660)        # recovery_dtbo size/offset, header_size
    hdr += struct.pack("<IQ", len(d), a.base + a.dtb_offset)
    assert len(hdr) == 1660, len(hdr)
    out = hdr.ljust(pg(len(hdr), ps), b"\0")
    for blob in (k, r, d):
        out += blob.ljust(pg(len(blob), ps), b"\0")
    if a.hybrid:
        lk = open(a.hybrid, "rb").read()
        assert len(lk) <= 0x80000, "lk2nd.img larger than 512 KiB"
        out = lk.ljust(0x80000, b"\0") + out
    open(a.out, "wb").write(out)
    print(f"wrote {a.out} ({len(out)} bytes){' [lk2nd hybrid: android image at 0x80000]' if a.hybrid else ''}")

HYBRID_OFFSETS = (0, 0x80000, 0x100000)

def find_offset(d, off=None):
    if off is not None:
        return off
    for o in HYBRID_OFFSETS:
        if d[o:o+8] == b"ANDROID!":
            # offset 0 may itself be the lk2nd image; then the real image follows
            if o == 0 and b"lk2nd" == d[64:576].split(b"\0")[0]:
                continue
            return o
    raise SystemExit("no usable ANDROID! boot image found at 0 / 0x80000 / 0x100000")

def parse(d, o):
    assert d[o:o+8] == b"ANDROID!", "no ANDROID! magic at offset %#x" % o
    h = d[o:o+4096]
    ks, ka, rs, ra, ss, sa, ta, ps, hv, osv = struct.unpack("<10I", h[8:48])
    cmd = (h[64:576].split(b"\0")[0] + h[608:1632].split(b"\0")[0]).decode()
    rdo = dts = dta = 0
    if hv >= 1: rdo, = struct.unpack("<I", h[1632:1636])
    if hv >= 2: dts, dta = struct.unpack("<IQ", h[1648:1660])
    return dict(ks=ks, ka=ka, rs=rs, ra=ra, ss=ss, ta=ta, ps=ps, hv=hv, osv=osv, cmd=cmd, rdo=rdo, dts=dts, dta=dta)

def parts(d, o, H):
    ps = H["ps"]; p = o + ps; out = {}
    for name, sz in (("kernel", H["ks"]), ("ramdisk", H["rs"])):
        out[name] = d[p:p+sz]; p += pg(sz, ps)
    p += pg(H["ss"], ps) + (pg(H["rdo"], ps) if H["hv"] >= 1 else 0)
    if H["hv"] >= 2: out["dtb"] = d[p:p+H["dts"]]
    return out

def unpack(a):
    d = open(a.img, "rb").read(); o = find_offset(d, a.offset)
    H = parse(d, o)
    print(f"image offset {o:#x}{' (lk2nd hybrid)' if o else ''}\nheader v{H['hv']} page {H['ps']} os {H['osv']:#x}\n"
          f"kernel {H['ks']} @ {H['ka']:#x}\nramdisk {H['rs']} @ {H['ra']:#x}\ntags @ {H['ta']:#x}\ncmdline: {H['cmd']}")
    if H["hv"] >= 2: print(f"dtb {H['dts']} @ {H['dta']:#x}")
    os.makedirs(a.outdir, exist_ok=True)
    P = parts(d, o, H)
    for name, blob in P.items():
        open(f"{a.outdir}/{name}", "wb").write(blob)
    k = P["kernel"]
    if k[:2] == b"\x1f\x8b":
        open(f"{a.outdir}/Image.gz", "wb").write(k)
        img = gzip.decompress(k); open(f"{a.outdir}/Image", "wb").write(img)
        print(f"kernel: gzip, Image {len(img)} bytes, arm64 magic {'OK' if img[56:60] == b'ARMd' else 'MISSING'}")
    else:
        open(f"{a.outdir}/Image", "wb").write(k)
        print(f"kernel: raw, arm64 magic {'OK' if k[56:60] == b'ARMd' else 'MISSING'}")
    open(f"{a.outdir}/cmdline.txt", "w").write(H["cmd"] + "\n")
    if o:
        lk = d[:o].rstrip(b"\0")        # keeps trailing SEANDROIDENFORCE footer, drops zero padding
        open(f"{a.outdir}/lk2nd.img", "wb").write(lk)
        print(f"lk2nd: {len(lk)} bytes -> {a.outdir}/lk2nd.img")
    # plain (non-hybrid) copy of the Android image, ready for `fastboot boot` / `fastboot flash boot` under lk2nd
    end = o + H["ps"] + sum(pg(x, H["ps"]) for x in (H["ks"], H["rs"], H["ss"], H["rdo"], H["dts"]))
    open(f"{a.outdir}/android-only.img", "wb").write(d[o:end])
    print(f"android-only.img: {end - o} bytes (use this for `fastboot boot|flash boot` under lk2nd)")

def verify(a):
    d = open(a.img, "rb").read()
    ok = True
    def bad(m):
        nonlocal ok; ok = False; print("FAIL:", m)
    if d[:8] != b"ANDROID!": bad("no ANDROID! magic at offset 0"); sys.exit(1)
    H = parse(d, 0)
    if H["cmd"].strip() == "lk2nd":
        bad("offset 0 is the lk2nd image (hybrid). `fastboot boot` / `fastboot flash boot` under lk2nd need a PLAIN Android\n"
            "      boot image. Flashing this puts a 2nd lk2nd image where lk2nd expects Linux -> lk2nd drops to fastboot.\n"
            "      Use out/boot.img, or slice: dd if=IMG of=plain.img bs=512K skip=1")
        sys.exit(1)
    P = parts(d, 0, H)
    k = P["kernel"]
    try: img = gzip.decompress(k) if k[:2] == b"\x1f\x8b" else k
    except Exception as e: bad(f"kernel gzip: {e}"); img = b""
    if img[56:60] != b"ARMd": bad("kernel is not an arm64 Image (no ARMd magic)")
    else: print(f"ok   kernel arm64 Image, {len(img)/2**20:.1f} MiB, image_size {struct.unpack('<Q', img[16:24])[0]/2**20:.1f} MiB")
    rd = P["ramdisk"]
    if rd[:4] in (b"\x04\x22\x4d\x18", b"\x02\x21\x4c\x18"):
        print("note ramdisk is LZ4 (Android-style); content not checked")
    else:
        try:
            raw = gzip.decompress(rd) if rd[:2] == b"\x1f\x8b" else rd
            if raw[:6] != b"070701": bad("ramdisk is not a newc cpio archive")
            elif b"init\0" not in raw: bad("no init entry found in ramdisk")
            else: print("ok   ramdisk newc cpio with init,", len(raw), "bytes unpacked")
        except Exception as e: bad(f"ramdisk: {e}")
    dtb = P.get("dtb", b"")
    if dtb[:4] != b"\xd0\x0d\xfe\xed": bad("no FDT magic in dtb section")
    elif b"xiaomi,kenzo" not in dtb: bad("dtb is not xiaomi,kenzo")
    else: print("ok   dtb xiaomi,kenzo,", len(dtb), "bytes")
    if "lk2nd" in H["cmd"].split(): bad("cmdline contains bare 'lk2nd'")
    print("cmdline:", H["cmd"])
    print("RESULT:", "OK" if ok else "PROBLEMS FOUND"); sys.exit(0 if ok else 1)

if __name__ == "__main__":
    ap = argparse.ArgumentParser(); sp = ap.add_subparsers(dest="cmd", required=True)
    u = sp.add_parser("unpack"); u.add_argument("img"); u.add_argument("offset", nargs="?", type=lambda x: int(x, 0), default=None)
    u.add_argument("-o", "--outdir", default="unpacked")
    v = sp.add_parser("verify"); v.add_argument("img")
    p = sp.add_parser("pack")
    p.add_argument("-o", "--out", required=True)
    for n in ("kernel", "ramdisk", "dtb", "cmdline"): p.add_argument("--" + n, required=True)
    p.add_argument("--hybrid"); p.add_argument("--name", default="")
    p.add_argument("--pagesize", type=int, default=PS_DEFAULT)
    # values taken from the working Lineage 23.2 kenzo boot.img
    p.add_argument("--base", type=lambda x: int(x, 0), default=0x80000000)
    p.add_argument("--kernel-offset", dest="kernel_offset", type=lambda x: int(x, 0), default=0x8000)
    p.add_argument("--ramdisk-offset", dest="ramdisk_offset", type=lambda x: int(x, 0), default=0x1000000)
    p.add_argument("--second-addr", dest="second_addr", type=lambda x: int(x, 0), default=0)  # Lineage header has 0
    p.add_argument("--tags-offset", dest="tags_offset", type=lambda x: int(x, 0), default=0x100)
    p.add_argument("--dtb-offset", dest="dtb_offset", type=lambda x: int(x, 0), default=0x1f00000)
    p.add_argument("--os-version", dest="os_version", type=lambda x: int(x, 0), default=0x200001a8)
    a = ap.parse_args(); {"unpack": unpack, "pack": pack, "verify": verify}[a.cmd](a)
