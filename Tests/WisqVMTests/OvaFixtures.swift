import Foundation

// Archives écrites par GNU tar 1.35 (Ubuntu 24.04), compressées en deflate
// brut puis codées en base64 pour tenir dans un fichier de test. Ne pas
// éditer à la main. Pour les refaire, à partir de `appliance.ovf` (un
// descripteur de quatre lignes), de `f-fin.vmdk` et de `b-stream.vmdk` de
// VmdkFixtures :
//
//     cp f-fin.vmdk appliance-disk1.vmdk
//     tar --format=ustar -cf a-ustar.ova appliance.ovf appliance-disk1.vmdk
//     cp b-stream.vmdk "$LONG"   # un nom de 113 octets, qui finit en disk1.vmdk
//     tar --format=pax -cf b-pax.ova appliance.ovf "$LONG"
//     tar --format=gnu -cf c-gnu.ova appliance.ovf "$LONG"
//     gzip -kn appliance-disk1.vmdk && mv appliance-disk1.vmdk.gz gz.vmdk
//     tar --format=ustar -cf d-gz.ova appliance.ovf gz.vmdk
//     tar --format=ustar -cf e-sans-disque.ova appliance.ovf
//     tar --format=ustar -cf f-plain.tar appliance-disk1.vmdk
//
// Et deux formes que GNU tar n'écrit pas sur un si petit disque, fabriquées
// par un script Python. `g` : la taille du disque n'est que dans l'en-tête
// pax (`size=`), le champ ustar dit 0 — la forme d'un disque de plus de
// 8 Gio, relue par le module `tarfile`. `h` : `c` avec les dates que l'ancien
// format de GNU range là où ustar met son préfixe (`--atime-preserve`, tar
// incrémental) ; `tar tvf` 1.35 y lit toujours `appliance.ovf`, et c'est lui
// qui fait foi : `tarfile`, lui, colle la date devant le nom
// (« 15103650000/appliance.ovf »), c'est-à-dire l'erreur que `h` attrape.
//
// puis chaque fichier en deflate brut (zlib, wbits −15, niveau 9) et base64.
enum OvaFixtures {
    /// `a-ustar.ova` — 81920 octets.
    static let a = [
        "7dgLUFNXGgfwALbQtNiqLc5alWuwsqwlDwkPlQRrQagMq/J0QXRjcgMp5GFuCOCDKMU6W19rqbLqFuq6pQUVtFh8YInSFV0p",
        "RbGAEGx0iyIioIsI4ZW9gVDpTmd3pq3OWP+/zOQk957z3Zv7nfPdJCKVKlEmUohJtlIrZTwaXJoXnz/U0v675fLpfTzPWV58",
        "b2++F8+TweXN8uB6Mwgu4zFIojQiNX0qaqVS87/6/b/9TyhfvxR5IqEl1ZRMqRCweGwuiyAVYqVEpogTsCLCF7j7sPyETN8A",
        "hZZMVKpIgu6uoASseI1GNYfDocTxpFxEsSVyjZStVMdx6FnEIa19OTyWkEkQvqGklFTTQUlK6LtAlkgSdKc58WpSKmCJRqaf",
        "u0RGJfDYWrkkgTW0XyYRsKR0Zx6LI/TljAphiehPdw4jxRr6nIVDb4aGWEK8RQ+jg1iCDcexxAi1HGo42NA2sUglEss0qfTn",
        "5fJ9PL29ho4xOijTlzPyiYVMxq/YjyXgsa7/WTxPy+sfrn8PvpcH1v/jEOwfEmlHt3b0g+EwvG29dZ+NtX15pLPtw3Fmq5G+",
        "DCbhyLRhwBPGhRgqn/4kJVbLVBql2lKgmSP3Ax7zzbf8BfTtmO/p5e3DVInoGqyxbJJaMcVqUqQhw1NVpIBFaeg38kUqjUwu",
        "W01KWEymCxGQoqGHEBJrfDooMzSKmEWXXSJs8RuhYQEEXZgVw3Xf0j88nrSekUgjIuaLKJLp4u8/nymRrGRrZWpNkigxKCpy",
        "+PQIAcHis5hIIgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADALyzThsFIaWir",
        "+q7spWcZjNOliYYrn8mp88VyQ3HMUsuz3NB1LPlWuyObkGTcujcYtJMXOLjytZnhhXVHQ5qX2wVuyZmz5tIFR0P3FAFlqv1y",
        "Yof+GccJsyPLJLKiJvb9qN0XPp9UHG881PHnS5m5VTEnpZ0F77h+vaKkr6nrk3nTygI3751OvnvH9N5gTGn01RmH5nZN5q5t",
        "/OAPz0cdNBZ3n28J9nb21XV7Bt0K4k2YHpI5O+rM+I9n1iRePBVbJ3wnMKRf1/5+zV7tVJ+09tsfnisUDjpMZb/913+4VcdV",
        "xDTlqCNa+YqaI4Fmkdi1atnhtVdrBZsWxZ5aZa43cDa8GbBlnLnqm91qp98uz1+5tbeyQdsiiG/KkFFOhQ3HxeYjRVEKv9Wm",
        "62sOH16y0nVhNjshu0yXdSi0ZEnF2Kt9jlM6jVtMFbWK+nW3mja2dmeXmiZf6zC/araz+VnpOM1Js/1u4eBLjzzv663tx8P5",
        "rwsz0Plff4ljqNDGFFeSr9OJL9klT6ynZ4Oh2GR/8k5u8+xm51NZynlDw/zCri0et/9c8J7fibf1n70Qnl//UWpJwbpnt+/h",
        "rvu2OuLVY20CdW91pX2VcZ2jk9fCgxlu1dJ/xn7qb8pPmnTs9pX95sNHMuPclxVrK762O1cV+0VnT825edNc/Eemw66CpfvT",
        "iopjV784ydR99ERwpKJHV3U9bKKyUffgQfBF7g7xjKDsGVRB+tmKiLyrn5Kb2gfe3babT53RJ3h1XNHdubPTsH15moPDOCE9",
        "HXR/r9p1LChPn1+X0JBLFW5wKV/0YVHK2V6z1nlO6vXeLz5RCu2fm+K2oF+S53Hj9btx9Q/n7IS4r8xxXbltfduyT6xtvb65",
        "25i+qc9d+zfjZbIy7Lhk49tJe4+2f0OdvrsqTMqJLlW0fj+7XQd6u1rrClfo0wZ6dRvTmm1/YqLuio02enXNX37p/NsPt1nW",
        "9X+5wbL+L/px6uiEe9Vasi4/GC2vt5SAtux9hlLq22tjxvy8Y/afJPaxFmzP4ofcXPZM8AcP15JH6k1zcKSyIfVaz4kDyVP1",
        "vT0uKVfOHxmfG5TjrtxR/cqoxPUln/l3Ukz3ZGHSvfKBOKV+zNjfTItunG5J3OL+jlHFZtCkvJe/de4D57lrbjzYn+Vcav/8",
        "BDdpelPLZzfdluWv/fxkSHTy7dl/7DmeV9TMiSkhu/dlTiwwrum9SX3kVxa4NdMnonyyafPOvPCiNzq1sX0vTPVcVd4YMNM7",
        "0Zh8/6sbMS+uOGV24t/P4f3LNXjva8n73r+RXytrzBdvH/yy/Pe7PZUteypLxmb76NraM+tybOdnbB4/d8mFF+o7Xxk4MKrY",
        "tFBOBUv18o4dl7MUwpTB9gN6vd7c0WN+Lj32dssjXf+jU2mD2+BTx1L/N/zEsem4fAAAAE+k0d/5bHE5njoZuARY/1Z2uBxP",
        "nWD/kEi7odzTzw4PfxOOnhsv/8gN4k+MH/ZlMAlHJv5AAAAAAAAAAAAAAAAAAAAAAAB4rP4D",
    ].joined()

    /// `b-pax.ova` — 143360 octets.
    static let b = [
        "7dYJWJR1HsDxUWttx3BbLXtK03E0zdy5hxlABspQMNfbxBWPHWZeYHKuZoYrVDzKnl11XUNF14K1Qze8ddU8ArXNetQ0KkRB",
        "xfLCTNnyQFCYfWfAIru2Q/dx+3544H35H7955/29///7U6oGmzPiBLNV8HhVZrfbbjM7LYLSlZYk+dmoRQa9PngUXX9Ua3Ra",
        "iSZUa9AbjXqDJlSi1miNBq1EliG5CVK9PrNHvBTJL5NOLXP4bA7BpDGGa8XbHmY0Kg3aUJ0h3KA3SMVe89d7w7QGY2hDr+Xb",
        "50pwC7hBS/4HrX+92Hfd+tepjRKZ+mauf4/L5fuucd/Xf4uKjM5w2GVp4u5vczlNco1SLZcJTovLanMmm+RPDO+rCJNHR0kj",
        "+zjTBLvLLcjE4U6vSZ7i87kjVCqvJUVwmL1Kq8OXpHR5klXiU6QSGseqNPIoqUwWOVRIEjxiUMEbFdnXZhdk4qCIFI+QZJJ/",
        "8fgprDbveI0yzWEdLw/226wmeZI4WCNXRUWqmoQIRIwRBw8TxM3H5YwK/hOcEgjRT5wmBgkEa4gTiDE08FENwYJtFrPbbLH5",
        "MsXvq9aHhRoNwc9oGlQaqbr2jaP+r3cyZdP3f6pT4XQ5FNZgNp5KFRSJNsGpcNtTvQq7y5msCDTZBa/CIjh9CpfFJ/i8jW0K",
        "S4rZ4VYEF5Mi2ewRQ7hdqR5FMOL3rX+d9rr3v06t5/1/c2i0apnb7Esx3aDcByMm2SwpNsHTZI1Lv7Hu0OnDxTP1t9QdOq0u",
        "1KjV67+57vhiLu/0H/T434S0f+f616u1gfOvrn+tmFbe/zdD/5gBI1qIxxbij+SOhrbJjX3NGo93XxvcXCK5p/H0fslXx0qk",
        "shBpM9bTraaLLFg+xQhei8fm9rk8gQJNeq0e1Egf6xdjslr0YUkWdaLUbRZrMF+gKamR1OIRzD5heKZbMMm9PvEfxyC3uDfb",
        "nhascqm0i6xPhk+cIrM2xheDSofGy7Ri2SUbNvjRocP6yOSJioaJDcVfYNLwFKHxssw+s6y32StIu8TE9JZKrdZEZZrN40s1",
        "2+PiRzRcpMwkk+vlwa5kweUQfJ5MpSXTbnMGSppAp/a6zhSx2gl2aAzX9XjF6s/VMMmga+gzW81un+AJfMFAs80qNLT7XC67",
        "t8kVaDV6oz5MJ+5hct5AAAAAAAAAAAAAAAAAAIAbrh234Bdtsvg75UfOncrtAwDgltSeW0D9R/0HAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD+B3KaSSQZL5zdd2zH",
        "Xb+SSLYV2ssPrHV439ngKN+QMDLw11F+cWN65bkQpcz6TOVn9XHzNLH1iQ/2HL6q9J8DTo1tETszPyKreFdIefUDJm/N/jfv",
        "rSq6PaRt+IgdVtu648oL8Qt3rb9/Q0rFiqq/Fucs2ZewOen8ymnd947bcuX4xaWPdN4RO2NRV2H6pzV/rk8oHHW424peFzuo",
        "Jxya+4dW8csrNlS/c7q/sVNkdnVoXGWcpm3XATnh8dvbvNqzxP7e1jGlUdNiB1zNPvd8yaK0jmGTzn3y4turourv6Kh88oV/",
        "9Xg/eXfC8XzPE2f0zpI1sX6zpfu+0asnHN5vem7QmK1P+Q+Wq6Y81mfmb/37PlzoaffQ2ILEWbXvlqWdNqUcf8bmbbeq7HWL",
        "f826eGf00zUfZa1ePSSx++N5yvF5O7JzVwzdMmR368NXQh44XzGzZvd+58GJlcefPVOdV1jT4WiVv72/RbOflI5tqknNjz1e",
        "f9cNz/vkxuPShvyXWkrF/E8uNm5pN3/Tanv5zvli6s+WaXPHlK8NnEUXh5eEV9dPO3WsbfDatm28O+xDVfHH3QYu7JxV+JLw",
        "8P5/VCx35B6Z1nfggojk4l3rE9I6RWR+VPvGUldUy1btw5OmvmLTnnp45Ev2eWWzRqVVHnFVLihK3iM+D29emhi7b3ThxX+/",
        "deWRzl1iZuU81KfWnjlj7srBb4z9wPBiVkgHzaRdnz7bs75i65mjfzpfei4qs65HyoI4zcf+vIhhe5u/5V8+epl5xqXDta3v",
        "qyu9kD1/+dgiR9WcD3KdURn1SlnM5XGW7r8PZu/VXfHLyl9JXZrXYvrsRZHjt3/uN5yNdF89VNJr9riJd7aJSLyQ0W+osGdO",
        "0YFO8540pBxZOT5/+8vdBi7aklGyeUVW6/zNGcfq120cN/W5GW3ObAw+3sPXji6JmJWQ+mlx9oED/XSnVFfSj/2l7u29YzfV",
        "VZ5oWVd78UzpqnFFk+pqs6fXV9WF/NhcRResKvKULPh589+y4ZjbuP4/KAus//eiVaVivg37A0l3LB/lOBjYAs7mLS4v9B45",
        "etttP+0zr26WLZb3nZ2rH3By9O395365lnSZJ/39R7jKMo9e3rQsvWNR7eUuGQfeWdNmSVy+wjXn/XsKSseXLfGumtJl56Ar",
        "6ds/T02o7hCV+tnOumRX0W2t7+s86lDX13Qnfjf4alWTzaa+xvVZwaxelzr1yjpx6eXcToUtW7XtkTT1+Om1J3uMLpiwfvOA",
        "UemfhP/x8uuvrTulStgiVC/OuXdlRVbtSe/fo3fEzsoJe2Jnh5oZ814bvu7R82ljrtzZMfSpnYf69DTaK9Iv7DmR8JtxW/3t",
        "9BfyNR9377/owfTFz58o2G87VGCZXf/mzoELQ12n//bultZ5Ydlnz+WU5jfv/cyMNr2G7Lrz4Pl76pY12WxOe9utHPnl43pu",
        "WVFRkb/qsv/XU8d8cpqXEwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAP5r/wE=",
    ].joined()

    /// `c-gnu.ova` — 143360 octets.
    static let c = [
        "7dZ5VFNXHsDxuHTsRHE6WulptRqD1VonCcEQEFmsRcEqLrjgiMqE5AEp2UzCVlTcas+MOo5FRccWxi464q6j1qXgMrUetVpq",
        "EQUV64orY10QEDIvAav1j/acdmyP0++HQ+7L/d37y3vv3vve1dlsJqPOoheU1tQEyePhK9JqNJ5S9GjpqxFjan8/rSYgQKNV",
        "+0t81X5+mgCJzFfyM0hxOHV2mUxit1qd39fuh+JPqOCwdLNJlirYHUarJUSuVvrKZYJFbzUYLYkh8pEj+isC5WGh0uB+llTB",
        "ZLUJMrG5xREiT3I6bUEqlUOfJJh1DqXB7ExQWu2JKnEWqYTGtiq1PFQqkwVHCwmCXUwqOEKD+xtNgkxsFJRkFxJC5Lr7009h",
        "MDqS1cpUsyFZ7okbDSHyBLGxWq4KDVY9lMKdMVxsPFzQO8VzDvV88XRxpxggdhOTuJM15HHniHb/VEMyT51eZ9Ppjc4M8Xp9",
        "NYH+AVrPbzycVBqsun/FoVLJ/zGlSqnqM8hqSRxktCT/Qutf7R/w7bGnXq3W+molskGs/8d/+RaFxWpWGDwLcEKKoIg3ChaF",
        "zZTiUJjEWaFwV5kEh0IvWJwKq94pOB2NdQp9ks5sU3junyJRZxdT2KwpdsWDjAlGfZJRsD+0tCX4FY7/965/ja+f+/g77/+e",
        "fmot7/+fxcDwqFHNxLKZ+Cd5uqFuSmOsSWP57P3GTSWSdo2HL0i+21YilXlJm7CenjQ+Ms/2KVxw6O1Gm9Nqd2/QpPf3g2rp",
        "awPCQwx6TWCC3jdeatOJezCnuyqhkVRvF3ROYUSGTQiRO5ziF/MQm9NoNr4pGORSqY+sX7pT7CIzNOYXk0qjY2R+4rZLNnzo",
        "q9HD+8nk8YqGjg2bP3enEUlC42npnDpZX51DkPqEh/eVSg2GeGWq0e5M0ZkiY0Y1nKQsRCbXyD2hRMFqFpz2DKU+w2S0GMS4",
        "O+j3SDBJ0Bk8AbX2kYhD3P1ZGzppezbEdAadzSnY3RforjYahIZ6p9Vqcjx0Bn5qTYAmsKf4DJNLmVUAAAAAAAAAAAAAAAAA",
        "gMfNm1vwqzZF/J/6I/tO4/YBAPBEas8tYP/H/g8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAPwCsptIJOnvXjt8dvczv5FIdhaYyo5tMDv2bTaXbY4d7f40l93eklZx",
        "3UspM8youFEfuUAdUR//Uo8Ra0v+FXVxfLOI2XlBmUX7vcqqXgxxVB/d81xl4VNebXuN2m0wbjynvBWzeP+mFzYnla+u/FtR",
        "9rLDsdsSbq6Z3u1Q3Pbac7eX9+m8O2LWki7CzKvVf6mPLRhzsuvq3rc7+E48Mf+PLWNWlW+u2ndpYECn4Kwq/8iKSHXbLlHZ",
        "vWJ2tfmoR7Hpix3jSkKnR0Tdy7r+TvGS1I6Bk69ffu+ztaH1T3dUvvHuv7t/mXgg9lyefeQVjaV4fYRLp+92eOy6iSePhrw9",
        "ZNyOCa7jZaqpr/Wb/XvX4a8W271fHp8fP6fm89LUSyFJ52YYHd5rSz/Wu9ZvjLGEvVn9dea6dcPiu72eq0zO3Z2Vszp6+7AD",
        "rU/Wer14s3x29YGjluOTKs69daUqt6C6w+lKV3tXsyY/aTh2qiY3Pft6/TOPfdynNJbLG8a/RF8ijv+UooDt3gu3rjOV7V0o",
        "Dv21Ur+ccWUb3EdhRb2Ke1XVT794tq3n3HZueTbwK1XRma6DF3fOLHhfeOXoP8tXmXNOTe8/eFFQYtH+TbGpnYIyvq75ZLk1",
        "tEXL9r0Spn1o9Lv4yuj3TQtK54xJrThlrVhUmHhQnA977kyKODy24PZ/Pq3t09knfE72y/1qTBmz5q8Z+sn4I9r3Mr06qCfv",
        "v/pWj/ryHVdO//lmyfXQjLruSYsi1WdcuUHDDzX91LVq7ErdrDsna1o/X1dyK2vhqvGF5sp5R3Isoen1Sln43Th9t0Ge0fto",
        "f8zKsg9Tluc2mzl3SXDyrm9c2mvBtnsninvPjZvUqk1Q/K30AdHCwXmFxzoteEObdGpNct6uD7oOXrI9vXjb6szWedvSz9Zv",
        "3BI37e1Zba5s8UzvERvGFgfNiU25WpR17NiAnhdVtWln/1r32aHxW+sqzreoq7l9pWRtXOHkupqsmfWVdV4/dqzC8tcW2osX",
        "/W/Hv0VDmdO4/o+Uutf/F2GqEnG8tUfdg25eNcZ83P0IuJa7tKzAcep08+Y/7TfvbZMtlfefm6OJujD2qYHzH6ylnhkXXANH",
        "WUszTt/dujKtY2HNXZ/0Y/vWt1kWmaewzvuyXX5Jcukyx9qpPnuH1Kbt+iYltqpDaMqNvXWJ1sLmrZ/vPOZElxU9z/9h6L3K",
        "hx429dXWG/lzet/p1Dvz/J0PcjoVtGjZtnvCtHOXNlzoPjZ/4qZtUWPSLvf6092PV2y8qIrdLlQtzX5uTXlmzQXHP8J2R8zJ",
        "Dhy5t0P1rAUrRmx89WbquNpWHf0n7D3Rr0eAqTzt1sHzsb+L2+Hy1tzKU5/pNnDJS2lL3zmff9R4Il8/t37P3sGL/a2X/v75",
        "9ta5gVnXrmeX5DXtO2NWm97D9rc6frNd3cqHHjaXHN5rRj+YrtdXFhYWuirvun47bdzlS7ycAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAA/6L8=",
    ].joined()

    /// `d-gz.ova` — 10240 octets.
    static let d = [
        "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",
    ].joined()

    /// `e-sans-disque.ova` — 10240 octets.
    static let e = [
        "7dLBboMgAAZgzz4F4V6BzmrTqL1sTXbttgcgii2pihFmtrcf2jVpdthOW7rk/y5E+fmBBNn3jZZdqSIz1sHv4F4Sx/PofR15",
        "7OfEapnEaRonYhVwsbzjaUB48AderZODP8pgjPsu99P8P5Vt39qGjGqw2nQ5FRGnRHWlqXR3yOnL826xptsizB66UTWmV8TH",
        "O5vTo3P9hjFbHlUrbVS1ro7McGD+FTH1mWWCFiEh2V7VavClyhbZTjeK+NDmOKg6p/Ly/BaVticRjW11ovO8rnJa+7CgrMjY",
        "VcXUeO/DT6p0/szF/DEvmSoe/TJfMpWde6aO/bTVuWz+V8peltq9+/vyeL1Kk3mP69IwY5cbF2EAAAAAAAAAAAAAAAAAAAAA",
        "AABwgz4A",
    ].joined()

    /// `f-plain.tar` — 81920 octets.
    static let f = [
        "7dgLUFTXAcbxBUwgm2CiJjg1KisYKTXykOVhLGgMCpWhPkCwINqVXXADy+IuTx+gBOMkvmqIUrWBWBsSUEGDwQeGVVLRSgiK",
        "AeRh0AZFRECLCMtruyBWMtNpZxKTGcf/b2fu2b33nLt3znfOuXdXEhkZLpdEBMumSOXqMHubGIU0TPCY2ek5icUDpd4Py6n2",
        "jv3v7R2nOomdncVO9o4CO3sHsZODQGQn+AVEq6MkKv2lqJTKqP9V7/8df0J5uXv7GelLI/1LYPJg37rBYwaD5csPKxs+aqcb",
        "9LCuQCgyFRoI8ISxFLnr573IXaYOVskjo5SqOfJwmTBGplLLlRGu9sK3fufuaj/VQezo5OwijJSoZBFR/btCBgmDVTJJlMw3",
        "PlLmaqGO0n9QzIuMkivkq2RSC6HQUjQ7LkrfRCQdPL/+pMKF/qKpdmIXkc/8Nxf6zBZZhMgjBpadgfq+K2SDVySJkohmSdQy",
        "oaW7+yyhVLrcJkauioqWhHv6+z24PJGryEJsISREAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA4DFLMRAI4qqbS78vfOlZgeBUQXjN",
        "5c8V6nN5ipq8wMX9W0VN+9HYmy2mNiJp8s27fZ477D36lr822Ten8oh3w1Ijj83pb6y+eN60pmOcq1pb8dXoVs0zpqOm+RVK",
        "5bn1Nvf8d53/YkzeirqDrX+6mJJRGngipC37HatvluV317d/OnNCocemPRNl797Wvt8XWBBwZdLB6e1j7dbUfviH5/0P1OV1",
        "nGv0cjb/bWKHo+dNT/tRE71TpvmfHvnJ5PLwCyeDKt3e8fDuSWz5oHxPzHiXhJZbH53NceszGW/z9l/+bl0WWhxYn65a1CSO",
        "KD/soZMEW5UuObTmSoXrxnlBJ1fqqmps1781e/MIXem3u1Rmv16atXxLV0l1TKPrivpkudosp/pYsO5wrn/EjFXaa6sPHVqw",
        "3Gpumk1YWmFi6sGF+QuKh1/pNh3XVrdZW1wRUbX2Zv2Gpo60Au3Yq626V3VGBj8pjlO2CYbfz+176WfPfd1g+cmD/Ct9avT5",
        "r7toW1McE5hXIntdH3z+TkV4lX401ORpjU/czmiY1mB+MlU5c6DZDJ+r80fsO+u1+zfBW3vOnPfNqvo4Pj977bPbdtut/a5s",
        "0atHm11VXWUlxqV1a03NnOYeSLYuC/lH0Gfu2qzoMUdvXd6nO3Q4JXTKkryY4m+MzpYGfdnWWX525gRL94fDYWf24n0JuXlB",
        "q14co+04ctzLL6IzsfSaz2hlbeL9+14X7LYHT/JMm6TOTjpTvCjzymeyjS29727dJVaf1oQ5tV5OvH17R822pQkmJiPc9MMh",
        "8W+lO496ZmqyKsOqM9Q56y2L5n2UG3emSxdj/kb8ta4vP1W6GT83znpOjzTT4frrd0KrHo3ZUaFf60LbM5q7t6YdX9N0bVNH",
        "XdLG7ikxf627JCvxOSbd8Hb0niMt36pP3VnpE2IbUBDR9J/RbdXb1d5UmbNMk9DblbghocHwRwZ1J7jOQKMq//Pjzt/4QZk6",
        "OP8vVffP/wszbCv1gTtV9KeuOBCgqOpfAprT9tYUqL+7OmzYT/vOnhOivRZztqWKvW8secbrw0dzySH+hs7LT1kdf7Xz+P7Y",
        "8ZquTsu4y+cOj8zwTJ+i3F72ypDgumNP/ys6sGOsW/Tdot5QpWbY8F9NCKid2B/c/J7WIYtNn1Z5N2vL9Pvm01dfv78v1bzA",
        "+PlR1iFJ9Y2f37BekrXmixPeAbG3pv2x81hmboNtYL6sY2/K6Oy61V031B/PKPTYkuKyqGisdtOOTN/cN9tigrpfGO+4sqh2",
        "9mTn8LrYe19fD3xx2Umdmfheuv0/rbz2vBa794PrWRXy2qzgbX1fFf1+l6OycXdJ/vA0l8TmlpTKdMNZyZtGTl9w/oWqtld6",
        "9w9ZbBrVZtmLNYrW7ZdSI9zi+lr2azQaXWun7rmkoFuNP+v8HxqlAbfBp07/+r/+R7ZNovsAAHgiDX3mM6Q7njrJdAHzf5AR",
        "3fHU8XL39jMayF6/NXn0m3Do2Hj5v9wg3hP8sK5AKDIV8gcCAAAAAAAAAAAAAAAAAAC/iH8D",
    ].joined()

    /// `g-pax-taille.ova` — 81920 octets.
    static let g = [
        "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",
        "AAAAAAAA/xf/AQ==",
    ].joined()

    /// `h-gnu-dates.ova` — 143360 octets.
    static let h = [
        "7dZ7WJPXHcDxeOnsorhOq31arcZotdYlIRACIhdrUbCKd8UJykLyAim5mYRbseKt9tnQOYuKzhZmLzrxrlOrWPCyWh+1WmoR",
        "BRXrFa/MekFQyN4EnMw/2udp5zrX74eHnDfnd84v7/uec9736Gw2k1Fn0QtKa0q85PHwFmk1Gk8perT01ogxtZ+PVuPvr9Gq",
        "/STeao2v1kci85b8FyQ7nDq7TCaxW63O72r3ffFHqf3U3r5aP8+FPjxWS/7HBIWmmU2yFMHuMFotwXK10lsuEyx6q8FoSQiW",
        "jx0zSBEgDw2RBg20pAgmq02Qic0tjmB5otNpC1SpHPpEwaxzKA1mZ7zSak9QibNIJTS2VanlIVKZLGiUEC/YxaSCIyRokNEk",
        "yMRGgYl2IT5Yrnsw/RQGoyNJrUwxG5LknrjRECyPFxur5aqQIFWTFO6MYWLj0YLeKZ5ziOeLp4s7xWCxm5jEnawhjzvHKPdP",
        "NSTz1Ol1Np3e6EwXr9dbE+Dnr/X8RtOk0iDVgysOkUr+jylVSlX/oVZLwlCjJeknWv9qP/9/HXvq1Wqtt1YiG/okr/8nRLJF",
        "YbGaFQbPApycLCjijIJFYTMlOxQmcVYo3FUmwaHQCxanwqp3Ck5HY51Cn6gz2xSe+6dI0NnFFDZrsl3xMGO8UZ9oFOxNlrYE",
        "P8Px/871r/H2aXhFNnn/+/qotf5P+Pv/CTEkLHJcC7FsIf5Jnm6om9YYa9ZYPvugcXOJpEPj4QuSf28rkcq8pM1YT0+a7jLP",
        "9ilMcOjtRpvTandv0KQP9oNq6WuDw4INek1AvN47TmrTiXswp7sqvpFUbxd0TmFMuk0Iljuc4hfzcJvTaDa+KRjkUml32cA0",
        "p9hFZmjMLyaVjoqS+YjbLtnoEa+OGj1QJo9TNHRs2Py5O41JFBpPS+fUyQboHIK0e1jYAKnUYIhTphjtzmSdKSJqXMNJyoJl",
        "co3cE0oQrGbBaU9X6tNNRotBjLuDPo8EEwWdwRNQax+JOMTdn7Whk9a3IaYz6GxOwe6+QHe10SA01DutVpOjyRn4qDX+mgBf",
        "8RkmlzKrAAAAAAAAAAAAAAAAAACPW0duwc/aNPF/+g/sO4PbBwDAE6kTt4D9H/s/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADwE8huJpGkvXft8Nndz/xCItlZaCo/",
        "ttHs2LfFXL4lerz701x+e2tq5XUvpcwwq/JGfcRCdXh93Et9xqwr/VvkxUktwufkBWYU7/cqr34x2FFzdM9zVUVPebXvO263",
        "wbjpnPJW1JL9m1/YklixpupPxdnLD0dvj7+5dmavQ7EF987dXtG/2+7wrKU9hNlXa/5QH1044WTPNf1ud/aecmLBb1tHra7Y",
        "Ur3v0hD/rkGZ1X4RlRHq9j0is/tG7Wr3cZ8S05c7JpaGzAyPvJ95/d2SpSldAqZev/z+5+tC6p/uonzjvb/3/irhQPS5PPvY",
        "KxpLyYZwl07f63DM+iknjwa/M3zijsmu4+Wq6a8NnPNr1+Gvl9g7vjwpP25u7RdlKZeCE8/NMjo6riv7RO/asCnKEvpmzTcZ",
        "69ePjOv1eq4yKXd3Zs6aUQUjD7Q9ec/rxZsVc2oOHLUcf6vy3NtXqnMLazqfrnJ1crVo9qOGY6dqavOzr9c/89jHfVpjuaJh",
        "/Ev1peL4Tyv2L+i4aNt6U/neReLQXyvzyZlYvtF9FFrct6Rvdf3Mi2fbe85t59ZnA75WFZ/pOWxJt4zCD4RXjv61YrU559TM",
        "QcMWByYU798cndI1MP2b2k9XWENate7UN37GR0afi6+M/8C0sGzuhJTKU9bKxUUJB8X5sOfOW+GHYwpv/+Oze/27dQ+bm/3y",
        "wFpTetaCtSM+nXRE+36GV2f11P1X3+5TX7Hjyunf3yy9HpJe1ztxcYT6jCs3cPSh5p+5Vses0mXdOVnb9vm60luZi1ZPKjJX",
        "zT+SYwlJq1fKwu7G6nsN9Yzex/ujVpV/lLwit8XseUuDknZ969JeC7LdP1HSb17sW23aBcbdShs8Sjg4v+hY14VvaBNPrU3K",
        "2/Vhz2FLC9JKtq/JaJu3Pe1s/aatsTPeyWp3Zatneo/ZGFMSODc6+Wpx5rFjg30vqu6lnv1j3eeHJm2rqzzfqq729pXSdbFF",
        "U+tqM2fXV9V5/dCxCs1fV2QvWfyfHf9WDWVO4/o/UuZe/1+GqkrF8dYedQ+6efUE83H3I+Ba7rLyQsep0y1b/rjfvL9dtkw+",
        "aF6OJvJCzFNDFjxcS77pF1xDxlnL0k/f3bYqtUtR7d3uacf2bWi3PCJPYZ3/VYf80qSy5Y5107vvHX4vdde3ydHVnUOSb+yt",
        "S7AWtWz7fLcJJ3qs9D3/mxH3q5o8bOprrDfy5/a707Vfxvk7H+Z0LWzVun3v+BnnLm280Dsmf8rm7ZETUi/3/d3dT1ZuuqiK",
        "LhCql2U/t7Yio/aC4y+hu8PnZgeM3du5JmvhyjGbXr2ZMvFemy5+k/eeGNjH31SReuvg+ehfxe5wddTcylOf6TVk6Uupy949",
        "n3/UeCJfP69+z95hS/ysl/78RUHb3IDMa9ezS/OaD5iV1a7fyP1tjt/sULeqycPmkqPj2vEPp+v1VUVFRa6qu65fzph4+RIv",
        "JwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADA9/on",
    ].joined()
}
