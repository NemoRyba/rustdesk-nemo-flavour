# sciter.dll (x64)

The Sciter engine the Windows client loads at startup (`src/ui.rs` looks for it next to
the exe). Without it the client does not start, and the build only *warns* — which is why
the four-file ZIP that used to be the only shipped artifact was so easy to get wrong.

Committed rather than downloaded at package time on purpose: a packaging step that fetches
a binary off the internet is neither reproducible nor offline-capable, and it means the
bytes that ship are not the bytes anyone reviewed.

    source  https://github.com/c-smile/sciter-sdk/raw/master/bin.win/x64/sciter.dll
    sha256  4d97528e157c55ef1fabe9e37a9697116ab66660d7da6163f90a3a7abf80dd56
    size    8296448
    arch    PE32+ x86-64

Verified byte-identical to the copy the QA lab has been running (`vm/run/sciter.dll`), so
this is the same engine everything was tested against.

Verify before packaging:

    sha256sum -c sciter.dll.sha256

The Linux counterpart is `libsciter-gtk.so` from `bin.lnx/`; the client loads it from
`/usr/share/rustdesk/` (that path is hardcoded and must stay literally `rustdesk`
whatever a package is named). `vm/lib/libsciter-gtk.so` is the lab's copy.

**Licensing is the owner's check, not mine.** Sciter is a third-party redistributable and
I did not manage to fetch an authoritative licence file to vendor alongside it. Read the
terms at https://github.com/c-smile/sciter-sdk (`license.txt` in the SDK root) and confirm
they cover redistributing the binary inside TBFDesk before shipping to a customer site.
Upstream RustDesk ships this same DLL, which is suggestive but is not a legal opinion.
