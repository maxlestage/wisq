import Foundation

// Archives écrites par GNU tar 1.35 (Ubuntu 24.04), compressées en deflate
// brut puis codées en base64 pour tenir dans un fichier de test. Ne pas
// éditer à la main. Le script qui les refait, à partir des disques de
// VmdkFixtures (`f-fin.vmdk`, `b-stream.vmdk`, `d-2g.vmdk`) :
//
//     # ovf <dossier> <href> : un descripteur de quatre lignes qui nomme <href>
//     ovf a appliance-disk1.vmdk; cp f-fin.vmdk a/appliance-disk1.vmdk
//     tar -C a --format=ustar -cf a-ustar.ova appliance.ovf appliance-disk1.vmdk
//     ovf b "$LONG"; cp b-stream.vmdk "b/$LONG"   # 113 octets, finit en disk1.vmdk
//     tar -C b --format=pax -cf b-pax.ova appliance.ovf "$LONG"
//     tar -C b --format=gnu -cf c-gnu.ova appliance.ovf "$LONG"
//     ovf d gz.vmdk; gzip -cn a/appliance-disk1.vmdk > d/gz.vmdk
//     tar -C d --format=ustar -cf d-gz.ova appliance.ovf gz.vmdk
//     # e : un descripteur sans fichier ni disque
//     tar -C e --format=ustar -cf e-sans-disque.ova appliance.ovf
//     tar -C a --format=ustar -cf f-plain.tar appliance-disk1.vmdk
//     # i : le descripteur de VirtualBox 7, en abrégé — disques déclarés
//     # données d'abord, matériel qui branche le système en premier
//     cp d-2g.vmdk i/donnees.vmdk; cp f-fin.vmdk i/systeme.vmdk
//     tar -C i --format=ustar -cf i-deux-disques.ova appliance.ovf donnees.vmdk systeme.vmdk
//     ovf j absent.vmdk; cp f-fin.vmdk j/appliance-disk1.vmdk
//     tar -C j --format=ustar -cf j-disque-absent.ova appliance.ovf appliance-disk1.vmdk
//     tar -C a --format=ustar -cf k-point.ova ./appliance.ovf ./appliance-disk1.vmdk
//
// Et deux formes que GNU tar n'écrit pas sur un si petit disque, fabriquées
// par un script Python. `g` : `a`, mais la taille du disque n'est que dans
// l'en-tête pax (`size=`), le champ ustar dit 0 — la forme d'un disque de
// plus de 8 Gio, relue par le module `tarfile`. `h` : `c` avec les dates que
// l'ancien format de GNU range là où ustar met son préfixe
// (`--atime-preserve`, tar incrémental) ; `tar tvf` 1.35 y lit toujours
// `appliance.ovf`, et c'est lui qui fait foi : `tarfile`, lui, colle la date
// devant le nom (« 15103650000/appliance.ovf »), c'est-à-dire l'erreur que
// `h` attrape.
//
// puis chaque fichier en deflate brut (zlib, wbits −15, niveau 9) et base64.
enum OvaFixtures {
    /// `a-ustar.ova` — 81920 octets.
    static let a = [
        "7dgLUBN3HgfwALbQtNiqLc5ZlTVYOc6SB4SHSoK1QagMp/L0QPRisoEUkmA2BPABSrHO1ddZqpx6hVpbWlBBi8UHliitaKUU",
        "xQJCsOgVRURADxHCK7cJodKbzt1MW52xfj+ZyT+7+/v/drO///+/AXFCQrxcrJSQbJVWxng4uDRPPt/c0v675fLpYzwPN08P",
        "Ltfdi8tjcHlu9AaD4DIegURKI1bTl6JWqTT/K+7/HX9M+fgmK+IJLamm5CqlgMVjc1kEqZSopHJljIAVFjrf1ZvlK2T6+Cm1",
        "ZLwqgSTocCUlYMVqNAmzORxKEksqxBRbqtDI2Cp1DIceRRzSEsvhsYRMgvAJJmWkmk5KUkKf+fJ4kqCDZseqSZmAJR4Zfq5S",
        "ORXHY2sV0jiW+bhcKmDJ6GAeiyP04YxKYcooooNDSImGvmahecPcxZTiDbobncSUbDiPKUew6VTDycz7JOIEsUSuSaG/L5fv",
        "7eHlaT7H6KRMH87INxYyGb9jP1eARzr/3Xgeps8/nf/ufD4P8/9RCBQFhdvQrQ39YtgN71tnOWZlaV8cCbZ+0M9oMRLLYBL2",
        "TCsGPGacCPPyKSIpiVqeoFGpTQs0c+R5wGO+/oZIwHNz53t4enkzE8T0Gqwx7ZJZMCVqUqwhQ1MSSAGL0tAbioUJGrlCvoqU",
        "sphMJ8IvWUN3IaSW/HRSZnAE4UYvu0TIoteCQ/wIemFWDq/7pvjQWNJyRWKNmJgnpkimk0g0jymVrmBr5WpNojg+ICJ8+PII",
        "AcHis5goIgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAbyzTisFIbmiv+qHs",
        "hacZjFOl8frLnymoc8UKfXHUEtO7Qt99NOlmhz2bkGbcvDsUsIPnP7TilZmhhXVHglqW2fhvzpm9+uJ5e33PFAFlqP1yYqfu",
        "KfsJs8LLpPKiZva9iF3nP59UHNt0sPPvFzNzq6JOyLoK3nL+dnlJf3P3J3Onlflv2jOdfPu24Z2hqNLIKzMOzumezF3T+N5f",
        "no040FTcc6410MvRJ63HI+BmAG/C9KDMWRGnx388syb+wsnoOuFb/kEDaR3v1uzRTvVO7bj1/tlC4ZDdVPab//zKpTqmIqo5",
        "Rx3WxlfWHPY3iiXOVUsPrblSK9i4MPrkSmO9nrP+db/N44xV3+1SO/xxWf6KLX2VDdpWQWxzhpxyKGw4JjEeLopQ+q4yXFt9",
        "6NDiFc4Lstlx2WVpWQeDSxZXjL3Sbz+lq2mzoaJWWb/2ZvOGtp7sUsPkq53Gl402Vr+qHKc4qdY/LBh64aHXfZ2l/Xi4/nUh",
        "err+6y5y9BXaqOJK8lW68CU7FfH19GjQFxtsT9zObZnV4ngySzXX3M035OqicfvOBu7+k2TrwJnzofn1H6SUFKx9ettu7trv",
        "q8NePtouUPdVV9pWNa21d/BccCDDpVr2dfSnIkN+4qSjty7vMx46nBnjurRYW/Gtzdmq6C+6emvOzp3mJBoZDjsLluxLLSqO",
        "XvX8JEPPkeOB4cretKprIRNVjWn37wde4G6XzAjInkEVpJ+pCMu78im5sWPw7a27+NRpXZxn5+W027d36LctS7WzGyekh0Pa",
        "R1U7jwbk6fLr4hpyqcL1TuUL3y9KPtNn1DrOTrnW98UnKqHtM1Nc5g9I89yvv3onpv7BmJ0Q840xpju3vX9r9vE1bdc29TSl",
        "b+x31X7YdImsDDkm3fBm4p4jHd9Rp+6sDJFxIkuVbT+ObufBvu62usLlutTBvrQNqS3Wv7BQdyRNVjp1zT9+6/rbDrdZlvl/",
        "qcE0/y/4curognvWmqquOBCpqDctAe3Ze/Wl1PdXx4z5deccOEHsZc3flsUPurH0qcD3Hswl95QbxsBwVUPK1d7j+5Om6vp6",
        "nZIvnzs8Pjcgx1W1vfqlUYXrTzr978SonsnCxLvlgzEq3Zixf5gW2TjdVLhFA52jFpshg+pu/pY59x3nrL5+f1+WY6ntsxNc",
        "ZOnNrZ/dcFmav+bzE0GRSbdm/bX3WF5RCyeqhOzZmzmxoGl13w3qA98y/y2Z3mHlkw2bduSFFr3WpY3uf26qx8ryRr+ZXvFN",
        "Sfe+uR71/PKTRgf+vRzev5wD97yStPfd6/m18sZ8ybahL8v/vMtD1bq7smRstndae0dmXY71vIxN4+csPv9cfddLg/tHLTat",
        "lEPBEp2ic/ulLKUweahjv06nM3b2Gp9Jj77V+lDn/+hSWuEx+MQxrf/rf2HfdNw+AACAx9Lo33zWuB1PnAzcAsx/CxvcjidO",
        "oCgo3MZce/rd7sHfhKPHxos/84D4G+OnsQwmYc/EPxAAAAAAAAAAAAAAAAAAAAAAAB6p/wA=",
    ].joined()

    /// `b-pax.ova` — 143360 octets.
    static let b = [
        "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",
        "vNrvYWMVkbsy31k476eNf6Paa1bd+j9Q7F3/X0aoisR4Bx70Bt26bJj1sHcLuJS9sCTPdex4w4Y/7jtvb5ItlPeYmaXrfWb4",
        "U71m311L/mlnPL2G2IvTjt/cuDSlTX7Vzfaph3atbrYoOkdhn/VVi9yi0cWLXCsntt/Z91bKtm+TYitahydd2VmdYM9v2PT5",
        "dsOOdFjif/o3/W6X37PZ1FTar+TO6Hqjbdf00zc+zGqb16hx887xk06dW3Om8/Dcses29R6Wcj7k9zc/WbL2rCp2s1CxMPO5",
        "FaXpVWdcf43YHjUjM3jwztaV0+YsGbT2tavJI241aRMwZueR7l2CLKUp1/aejv3VqC2elrprOZoTnXoteCll4buncw+aj+Qa",
        "Z9bs2NlnfoD93F++2Nw0Ozjj0uXMopz63aZMa9a1/+4mh6+2qF56z2ZzztVyxdC7j+vlpfn5+Z7ym55fThpx/hyHEwAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAP5r/wI=",
    ].joined()

    /// `c-gnu.ova` — 143360 octets.
    static let c = [
        "7dZ5VFNXHsDxuHTsRHE6Wu1ptRqj1VonGzsIwVoUrfuKIy4TkgekZDMJW7HiVntm1HEsKjq2MHbREXcdtS4Flyn1oNVSiyio",
        "WFdwY6wLgpLMS8DR+kd7Tjvq8fT74ZD3cpffu7m/d9+7OpvNZNRZ9ILSmhwneTTUokB/f+9R9PBRHRAUKNEE+AYGqNV+QWqN",
        "RK3x9fXzk8jUkscgyeHU2WUyid1qdf5Yu5+qf0qFRaSaTbJkwe4wWi3hco1SLZcJFr3VYLTEh8tHjeyrCJZHaKVhfSzJgslq",
        "E2Ric4sjXJ7gdNpCVSqHPkEw6xxKg9kZp7Ta41XiXaQSGtqqNHKtVCYLGy7ECXYxqODQhvU1mgSZ2Cg0wS7EhcuTLAqL1aww",
        "CAqD0TEpSVDEGgWLwmZKcihMVku8wlNkEhwKvWBxKqx6p+B0NJQp9Ak6s03hTZ8iXmcXQ9isSXbF/YhxRn2CUbB7IidqlMlm",
        "Q6Lce2WjIVweJw5DI1dpw1QPDM4z1kix8QhB7xRnQ+v94u3iCdFf7CYG8QSrj+OJMdzzI+qDecv0OptOb3SmiTOp9g8Wb2zv",
        "NR4MKg1T3ZtLrfTJ51+pUqp6DRSneqDRkviE1r8mIOh/595yjSZQHSiRDWT9P/qf/1gXoAS/wvz/6Pr3V/t6zn/w/vfz1fgH",
        "8P5/HAZEDhrdRDw2Ef8kz9aXTW2oa9RwfP5e48YSSZuG05ckP2wrkcp8pI1YT0+bzjLvJidScOjtRpvTavds0KT39oMa6Rv9",
        "I8MNev/gOL06VmrTiTslp6coroFUbxd0TmFkmk0Ilzuc4hfzEJvTaDa+LRjkUmlnWZ9Up9hFZmiILwaVDo+W+YqbI9mIoa8P",
        "H9FHJo9V1Hes36J5Oo1MEBqGpXPqZL11DkHaOTKyt1RqMMQqk412Z5LO1C96dP0gZeEyub/cWxUvWM2C056m1KeZjBaDWO+p",
        "9H2oMkHQGbwVmsCHahziHs1a3ynQr75OZ9DZnILd8wM9xUaDUF/utFpNjgdGID6xgvyD/QL9g+RS7ioAAAAAAAAAAAAAAAAA",
        "wKPWlin4VZsq/k/7mX2nM30AADyV2jEF7P/Y/wEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgCcgs5FEkvrBlUNn9jz3G4lkV56p7OhGs2PfFnPZlpgxnk9z2c2tKRVX",
        "fZQyw8yKa65+CzVRrthXeoxcV/KvQRcmNImakxOaXlToU1b9crij5sjeF6ryn/FpHTJ6j8G46azyRvSSws0vbUkoX1P1t6LM",
        "5YditsddXzuj28GJO+6cvbmiV6c9UbOXdhFmXa75iysmb+yJrmt63myvnnx8wR+bR68u31K9r3JAUMewjOqAfhX9NK27DMoM",
        "id7d6tMexaavd44v0c6IGnQ34+r7xUuTOwRPuXrxwy/XaV3PdlC+9cG/u38Tvz/mbI591CV/S/GGKLdO3+3QuPWTTxwJf2/I",
        "+J2T3MfKVNPe6DPn9+5D3y6xt311Qm7s3NqvSpMrwxPOzjQ62q4r/Uzv3rAp2hLxds136evXD4vt9ma2MjF7T0bWmuE7hu1v",
        "eeKOz8vXy+fU7D9iOfZOxdl3L1Vn59W0P1Xlbudu0ugXpWOXakrjM2+6nnvkeZ/acFxRn/8SfYmY/6lFQTvaLtq23lRWsEhM",
        "/ZVS36zxZRs9ZxFFIcUh1a4ZF8609o5t19bng79VFZ3uOnhJp/S8j4TXjvyzfLU56+SMvoMXh8YXFW6OSe4YmvZd7ecrrNpm",
        "zduFxE3/xOh74bUxH5kWls4dm1xx0lqxOD/+gHg/7L31TtShcXk3//PFnV6dOkfOzXy1T60pbfaCtUM/n3A48MN0n/aaKYWX",
        "3+3hKt956dSfr5dc1abVdU9Y3E9z2p0dOuJg4y/cq8et0s2+daK25Yt1JTcyFq2ekG+umn84y6JNdSllkbcn6rsN9Gbv08Lo",
        "VWWfJK3IbjJr3tKwxN3fuwOvhNnuHi/uOW/iOy1ahcbeSO0/XDgwP/9ox4VvBSacXJuYs/vjroOX7kgt3r4mvWXO9tQzrk1b",
        "J05/b3arS1u9t/fIjeOKQ+fGJF0uyjh6tL/fBdWdlDN/rfvy4IRtdRXnmtXV3rxUsm5i/pS62oxZrqo6n5+bq4jcdfn24sX/",
        "3/w3qz9mNaz/w6We9f91hKpEzHfgEU/SzavHmo95HgFXspeV5TlOnmra9Jdd8+522TJ533lZ/oPOj3tmwIL7a8kv7bx7wGhr",
        "adqp29tWpXTIr73dOfXovg2tlvfLUVjnf9MmtySxdLlj3bTOBUPupOz+Pimmur026VpBXbw1v2nLFzuNPd5lpd+5Pwy9W/XA",
        "w8ZVY72WO7fnrY4908/d+jirY16z5q27x00/W7nxfPdxuZM3bx80NuViyJ9uf7Zy0wVVzA6helnmC2vL02vPO/4RsSdqbmbw",
        "qIL2NbMXrhy56fXryePvtOgQMKngeJ8eQabylBsHzsX8buJOd1v/Gzma090GLH0lZdn753KPGI/n6ue59hYMXhJgrfz7Vzta",
        "ZgdnXLmaWZLTuPfM2a16Ditscex6m7pVDzxsKh1t1465f7teXZWfn++uuu3+7fTxFyt5OQEAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAftJ/AQ==",
    ].joined()

    /// `d-gz.ova` — 10240 octets.
    static let d = [
        "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",
    ].joined()

    /// `e-sans-disque.ova` — 10240 octets.
    static let e = [
        "7dKxTsMwEAZgz32KyHvjs9umFUrShfIAFB4gSi9tRGJHton6+FgIlg4gBpCQ/m85nfzr7gY30zT0jW05d3MnfgclxXr9XpPb",
        "Soa2Qm9MsSFabUkL0sYURmQk/sBriI1Pp3jn4le5797/qXJ/HYdsZh96Zyupc5IZ29adenuu5PPTw3In9/WiPNiZBzdxluI2",
        "VPIS43SnVGgvPDYhP42xy50/q/SLFH9klZZ1+cgd+zSRg6rL+z68HLmNaVfq1OfQeiEAAAAAAAAAAAAAAAAAAAAAAADgZ94A",
    ].joined()

    /// `f-plain.tar` — 81920 octets.
    static let f = [
        "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",
    ].joined()

    /// `g-pax-taille.ova` — 81920 octets.
    static let g = [
        "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",
        "AAAAAAAA/xf/AQ==",
    ].joined()

    /// `h-gnu-dates.ova` — 143360 octets.
    static let h = [
        "7dZ5VFTXHcDxcUlNR7GpRnISjY6D0Rg7GwyLyGIMCsZ9xQpKh5kHTJjNmWELKm4xp1VrDSpaE6hZtOKuVaMYcGmMR42GGERB",
        "xbjiSo0LgsL0zYDV+kdyTlJjPfl+OMx7c5ff3Hd/7753dTabyaiz6AWlNTVB8nioRQFarecoevSo9g8MkGj8fQP81Wq/QLVG",
        "otZo/bQBEpla8jNIcTh1dplMYrdand/X7ofqH6Xx16j93JckXuiDc43k/0xIeLrZJEsV7A6j1RIq1yjVcplg0VsNRktiqHzU",
        "yH6KIHl4mDSkryVVMFltgkxsbnGEypOcTluwSuXQJwlmnUNpMDsTlFZ7okq8i1RCY1uVRh4mlclChgsJgl0MKjjCQvoZTYJM",
        "bBScZBcSQuUpFoXFalYYBIXB6JiQIijijYJFYTOlOBQmqyVR4S4yCQ6FXrA4FVa9U3A6GssU+iSd2abwpE+RqLOLIWzWFLvi",
        "QcQEoz7JKNjdkZM1ylSzIVnu+WWjIVSeIA5DI1eFhageGpx7rBFi4xGC3inORpjni6eLO0R/sZsYxB2sIY47xnD3RTQE85Tp",
        "dTad3ujMEGdSrQ0Sb2zPbzwcVBqiuj+XYdInn3+lSqnqPVCc6oFGS/ITWv8a/8D/nHvKNZoAtbj+Bz7N6/8p8fMuQAl+gfn/",
        "3vWvVfs2vCIfev/7+Wq0/k/5+/8pMSBi0Ohm4rGZ+Cd5tqFsSmNdk8bj8/cbN5VI2jWeviT577YSqcxL2oT19LTxkXk2ORGC",
        "Q2832pxWu3uDJr2/H9RI3+gfEWrQa4MS9Op4qU0n7pSc7qKERlK9XdA5hZEZNiFU7nCKX8xDbE6j2fi2YJBLpT6yvulOsYvM",
        "0BhfDCodHi3zFTdHshFDXx8+oq9MHq9o6NiwRXN3GpkkNA5L59TJ+ugcgtQnIqKPVGowxCtTjXZnis4UFT26YZCyUJlcK/dU",
        "JQpWs+C0Zyj1GSajxSDWuyt9H6lMEnQGT4Um4JEah7hHszZ0CvBrqNMZdDanYHdfoLvYaBAayp1Wq8nx0AjEJ1agNsgvQBso",
        "l3JXAQAAAAAAAAAAAAAAAAAeN2+m4Bdtivg/9Uf2ncb0AQDwVGrPFLD/Y/8HAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACegOwmEkn6+1cPndn13K8kkh2FpvKjG8yO",
        "vZvN5Ztjxrg/zeW3tqRVXvNSygwzKq/XRy3QRNbHv9Jj5NrSfwy6ML5Z5Oy84MzifV7l1S+HOmqO7H6hqugZr7Y9R+8yGDee",
        "Vd6MXrxv00ubkypWV/2lOHvZoZhtCTfWTO92MK7g7tlby3t33hU5a0kXYeaVmj/VxxSOPdF1da9bHdQTj8//fcvoVRWbq/de",
        "HBDYKSSr2j+qMkrTtsug7J7RO9t80qPE9NX2caVh0yMH3cu69l7JktSOQZOvXfrgi7Vh9c92VL71/j+7f524P+Zsnn3UZa2l",
        "ZH2kS6fvdih23cQTR0LfHTJu+wTXsXLV1Df6zv6t69A3i+3er47Pj59T+2VZ6sXQpLMzjA7vtWWf6l3rN0Zbwt+u+TZz3bph",
        "8d3ezFUm5+7Kylk9vGDY/tYn7nq9fKNids3+I5ZjkyrPvnO5OrewpsOpKld7V7MmPykdO1STm555s/65x573KY3H5Q35L9WX",
        "ivmfUhxY4L1w6zpT+Z6FYuqvlvnmjCvf4D4LL+5Z0rO6fvqFM209Y9ux5fmgb1TFp7sOXtw5s/BD4bUjf69YZc45Ob3f4EXB",
        "icX7NsWkdgrO+Lb2s+XWsBYt2/dMmPax0ffCa2M+NC0omzM2tfKktXJRUeIB8X7YfXtS5KHYwlv/+vxu784+EXOyX+1ba8qY",
        "NX/N0M/GHw74INOrg2byvivv9Kiv2H751B9vlF4Ly6jrnrQoSnPalRs84mDTz12rYlfqZt0+Udv6xbrSm1kLV40vMlfNO5xj",
        "CUuvV8oi7sTpuw30ZO+TfdEryz9OWZ7bbObcJSHJO79zBVwNsd07XtJrbtykVm2C42+m9x8uHJhXdLTTgrcCkk6uSc7b+VHX",
        "wUsK0ku2rc5snbct/Uz9xi1x096d1ebyFs/tPXJDbEnwnJiUK8VZR4/297ugupt25s91Xxwcv7Wu8lyLutpbl0vXxhVNrqvN",
        "mllfVef1Y3MVnr+2yF6y6H+b/xYNx5zG9X+4zL3+vwpXlYr5DjjiTrp51VjzMfcj4Gru0vJCx8lTzZv/tN+8t022VN5vbo52",
        "0PnYZwbMf7CW/DLOuwaMtpZlnLqzdWVax6LaOz7pR/eub7MsKk9hnfd1u/zS5LJljrVTffYMuZu287uUmOoOYSnX99QlWoua",
        "t36x89jjXVb4nfvd0HtVDz1s6mus1/Pn9LrdqVfmudsf5XQqbNGybfeEaWcvbjjfPTZ/4qZtg8amXer5hzufrth4QRVTIFQv",
        "zX5hTUVm7XnH38J3Rc7JDhq1p0PNrAUrRm58/UbquLutOvpP2HO8b49AU0XazQPnYn4Tt93lrb2ZpzndbcCSV9KWvncu/4jx",
        "eL5+bv3uPYMX+1sv/vXLgta5QVlXr2WX5jXtM2NWm17D9rU6dqNd3cqHHjYXHd5rxjy4Xa+tLCoqclXdcf162rhLF3k5AQAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB+0L8B",
    ].joined()

    /// `i-deux-disques.ova` — 471040 octets.
    static let i = [
        "7dsNmFRloQfwBSptCistfa6ZjkvJNWNnZ1kWRHYVWBXkksoqdMWPO+ychYmdmXVmdgG/ILN8ytJblFz1hpk3Eyw/orDEpOSm",
        "Xc0oTVHR0PL7AypTBJW97+zOIvAoqUk9PP1+PP85M+e87znvxzln5vBAqqOjPZPKtUY1+a62qh2jNmior+9ZBtsuh9UNHVqV",
        "HFbXMKy2dujw2mRVbbKurqGhKl5b9XfQWSylCqEphXy+tL1yf237TmrUobOz7fGuqFDM5HON1cma2upDm2Kj9h8yJL7iC62F",
        "TCle7CzE26N4Np9ecWVYpqN4axQ/tXNwNLsjXyhF8cmZQqkz1T4mPzs+PD4yFC3G05niqZ1hWcznSrF4WXrFotb2VGHForAx",
        "n8utWFQuNTg1LV9IfyKeTWWKPYdIlVYsKmSi9vi0QjglZ0TllcU5xdKKK7NRPMrFOwpRNhMVauJDhoQ2Hp7ritrzHVE8nLkj",
        "t+pBPPRpZHsqN72xOsoNOb6lZ0Wu2Fg9o1TqGJlIFMO+s6liTTpbaqvJF6Ynwh4SUWV3iWSl+Miw9s1WKaSK6devM2talE3M",
        "KrZmsolkIrwO6S2RqEuMHT/xlElRMd9ZaI1Gt7fnW1Ol0JuWqFTK5KY3p0qpvgN0Fd/6ASoz1RJGNMq+1r6n5Wdv3vesWbNq",
        "unorhNWbu5xNtc7I5KLqpjCvoyZFbVEhCjePYlPPNI86ItPeOx2Z0Mi28CEMTPnjjEIUhrI881FUrOnKpmdWJ16vSt2WVYo9",
        "bY22qDIqsfVRRzVnijNbotbyeFV2OT7Xlm/6t0yxFM+3xUvhNKr0o3xezizGO4tROp7J9WzpSLXOTE2PRiV66vRWL++wpwmt",
        "qbA5U5rTWF2XrB9eP2JoQ/2I3saVdzQ+tDc0K7yrdLLc+EnlRm/R8bZ8IZzVWw9qdlaqENW05rOJTK4UFdpSoSeJYkfUmmnL",
        "9M57MVHub82MUrZ9ULFUiFLZoztKmWzmtCi9edxeo5XJ2voRw4Y3vFYT616jiXU7tImjEttMzKitTr/NU57q+wKq3nL2Rm+e",
        "s8oJt9UMVfY0LlVIlxu61ez37aFSJj6jUiheiE7tzIQbSJQrFeOh0/HU9o5R3k1oZt+H8LF8aY8cm+roOVRyc92xxxw/KrHV",
        "tm2qjM+Fb5jQv/HNTclKyS1WbVO47x5w3JyOqGlopfhWK7epUOnmsZ2pXCmcBJsPse36vk4ltuzVdrtYDHeGseEGXsi3t0eF",
        "2jfcyaFvuJMtndN6ujR63Njx23S1b9P2hqeudjvj8wY6OjqdLkTF4tG5Y8LpkSs19e1u2/WvMz49V/72R2Vcvljqa1xTolwh",
        "UbkcK/W2KvD6Q1r/V4e00tS+sX/tlm81Tsnhb+/oJd/86NW9xdFLvrnRG7YTjF7dmxu91nQhn02+4UuyYUeMwLA3OAKjEq9/",
        "u968rfdLIfyoS/T9qmuKVbHjbfmbrOof8PyXrO99v83zX7Ku3vPf38OE5omT+4XlgJ5Ph/W8zqts61dZfrCvcP+qqg9V3u5Z",
        "2Tivf2VFLD7QFbvzGRTveZBojorhYb+jlC+Un8difU/TydjY8c2NbQ11bW3DUkNjHT1fCz2rKmKt4ad/qefe31idzefy7ZnS",
        "jExrSyhZjKpjsUHxw2eXQp14unKAsNfYpCnx+uTB9UNr6+Mtx4ye1HJ4vDo9pG5670Neuc5x4cmst1nhN2h8TKoYxQY1N4+J",
        "xdLpaX0PpeOmTO5tZLwxXl1f3bNpepTPRqXCnJrWOe2ZXDps79mYbEhus31GlEr3bEs2bLOlGL6c8r31Gob2bkulwxdsVCj3",
        "sbw6k45615fy+fbiFo3Y/JA4vNqVAAAAAAAAAAAAwI61Z8jeIfuGVIccEPLxkJqQupCGkJEhTSFjQo4IOSrkkyGTQiaHnBBy",
        "csi0kPL/If10SC6kENIVclrIWSFnh3w+5Ish54d8NeTCkItDFoZ8K+SKkMUhV4d8P2RpyA0hN4XcHHJLyG0hvwq5M+SekPtD",
        "fhfy+5DHQp4KWRvy55AXQjaGbArp36+q6l0hsZDdQnbvZ/4BAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACgbF5/YwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAEBV1V79qqo+HLJfyKCQwSEHhSRChoYMDzkk5NCQsSFHhkwIOTqkJWRKyNSQU0JaQ6aH",
        "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",
        "5bnxwdf4gvhC1dZlq2LxgTF/gQAAO4X/Bw==",
    ].joined()

    /// `j-disque-absent.ova` — 81920 octets.
    static let j = [
        "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",
    ].joined()

    /// `k-point.ova` — 81920 octets.
    static let k = [
        "7dgLUFNXGgfwALbQtNiqLc5alWuwsqwlDwgPlQRrQagMq/J0QXRjcgMpeWBuCOADlGKd1tdaqqy6hbpuaUEFLRYfWKK0opVS",
        "FAsIwaJbFBEBXUQIr+xNCJXudLYzbXXG+v9lJie59zvfvbnfOecmYXNECQlymUgpJtkqrZTxMHBpnny+uaX9b8vl0/t4Hm6e",
        "HlyuuxeXx+Dy3PhubgyCy3gEEimNSE2filql0vy/uJ/b/5jy8U1WyAktqaZkKqWAxWNzWQSpFKskMmWsgBUeNt/Vm+UrZPr4",
        "K7WkXJVAEnS4khKw4jSahNkcDiWOIxUiii1RaKRslTqWQ48hDmmJ5fBYQiZB+ISQUlJNJyUpoc98mZwk6KDZcWpSKmD9MPhc",
        "JTIqnsfWKiTxLPN+mUTAktLBPBZH6MMZlcKU0Y8ODiXFGvqcheY35i6mFG/Q3egkpmTDeUw5QkyHGk5m3iYWJYjEMk0K/Xm5",
        "fG8PL0/zMUYnZfpwRj6xkMn4HWNzfqoEj3D+u/E8TK9/PP/d6Zpg/j8KQX7BETZ0a0M/GHbD29ZZ9llZ2hdHgq0f9DNajMQy",
        "mIQ904oBjxknwrx8+pGUWC1L0KjUpgWaOXI/4DFff8NPwHNz53t4enkzE0T0GqwxbZJaMMVqUqQhw1ISSAGL0tBvFAsTNDKF",
        "bBUpYTGZToR/sobuQkgs+emkzJBIwo1edonQRa+FhPoT9MKsHF73TfFhcaTljEQaETFPRJFMJz+/eUyJZAVbK1NrEkXywMiI",
        "4dMjBASLz2KiiAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAv7FMKwYjuaG9",
        "6vuyF55mME6VyvWXP1VQ54oV+uLoJaZnhb77aNLNDns2Icm4eXcocAcvYGjFKzPDCuuOBLcsswnYnDN79cXz9vqeKQLKUPvF",
        "xE7dU/YTZkWUSWRFzex7kbvOfzapOK7pYOffLmbmVkWfkHYVvOX8zfKS/ubuj+dOKwvYtGc6+fZtw7tD0aVRV2YcnNM9mbum",
        "8f2/PBt5oKm451xrkJejT1qPR+DNQN6E6cGZsyJPj/9oZo38wsmYOuFbAcEDaR3v1ezRTvVO7bj1wdlC4ZDdVPab//jSpTq2",
        "Iro5Rx3exlfWHA4wisTOVUsPrblSK9i4MObkSmO9nrP+df/N44xV3+5SO/xxWf6KLX2VDdpWQVxzhoxyKGw4JjYeLopU+q4y",
        "XFt96NDiFc4Lstnx2WVpWQdDShZXjL3Sbz+lq2mzoaJWWb/2ZvOGtp7sUsPkq53Gl402Vr+qHKc4qdbfLxh64aHXfZ2l/Wi4",
        "/nWherr+6y5y9BXa6OJK8lW68CU7FfJ6ejToiw22J27ntsxqcTyZpZpr7uYbenXRuH1ng3b/Sbx14Mz5sPz6D1NKCtY+vW03",
        "d+131eEvH20XqPuqK22rmtbaO3guOJDhUi39KuYTP0N+4qSjty7vMx46nBnrurRYW/GNzdmqmM+7emvOzp3m5DcyHHYWLNmX",
        "WlQcs+r5SYaeI8eDIpS9aVXXQieqGtPu3w+6wN0unhGYPYMqSD9TEZ535RNyY8fg21t38anTunjPzstpt2/v0G9blmpnN05I",
        "D4e0f1XtPBqYp8uvi2/IpQrXO5Uv/KAo+UyfUes4O+Va3+cfq4S2z0xxmT8gyXO//uqd2PoHY3ZC7NfG2O7c9v6t2cfXtF3b",
        "1NOUvrHfVfvPpktkZegxyYY3E/cc6fiWOnVnZaiUE1WqbPthdDsP9nW31RUu16UO9qVtSG2x/oWFuiNustKpa/7+W9ffdrjN",
        "ssz/Sw2m+X/Bl1NHF9yz1lR1xYEoRb1pCWjP3qsvpb67OmbMrzvmwAliL2v+tix+8I2lTwW9/2AuuafcMAZFqBpSrvYe3580",
        "VdfX65R8+dzh8bmBOa6q7dUvjSpcf9Lp/yRG90wWJt4tH4xV6caM/cO0qMbppsItGugctdgMGVR387fMue84Z/X1+/uyHEtt",
        "n53gIk1vbv30hsvS/DWfnQiOSro166+9x/KKWjjRJWTP3syJBU2r+25QH/qWBWzJ9A4vn2zYtCMvrOi1Lm1M/3NTPVaWN/rP",
        "9JI3Jd37+nr088tPGh3493J4/3YO2vNK0t73rufXyhrzxduGvij/8y4PVevuypKx2d5p7R2ZdTnW8zI2jZ+z+Pxz9V0vDe4f",
        "tdi0Ug4FS3SKzu2XspTC5KGO/TqdztjZa3wmPeZW60Od/6NLaYXb4BPHtP6v/4V903H5AAAAHkujv/NZ43I8cTJwCTD/LWxw",
        "OZ44QX7BETbm2tPPdg9+E44eGy/+xA3iHcaPYxlMwp6JPxAAAAAAAAAAAAAAAAAAAAAAAB6p/wI=",
    ].joined()
}
