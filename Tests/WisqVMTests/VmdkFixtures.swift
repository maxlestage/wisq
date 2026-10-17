import Foundation

// Images VMDK écrites par `qemu-img` 8.2.2 (Ubuntu 24.04) — sauf `f`, voir
// plus bas —, compressées en deflate brut puis codées en base64 pour tenir
// dans un fichier de test. Ne pas éditer à la main : un octet changé ici est
// un test qui ne teste plus ce qu'il dit. Pour les refaire :
//
//     # disque.raw : le même que celui de Qcow2Fixtures
//     qemu-img convert -f raw -O vmdk -o subformat=monolithicSparse disque.raw a-sparse.vmdk
//     qemu-img convert -f raw -O vmdk -o subformat=streamOptimized disque.raw b-stream.vmdk
//     qemu-img convert -f raw -O vmdk -o subformat=monolithicSparse,zeroed_grain=on \
//         disque.raw c-zg.vmdk
//     qemu-io -f vmdk -c "write -z 0 65536" c-zg.vmdk
//     qemu-img create -f vmdk d-2g.vmdk 2G
//     qemu-io -f vmdk -c "write -P 0xab 1G 8192" d-2g.vmdk
//     qemu-img convert -f raw -O vmdk -o subformat=twoGbMaxExtentSparse disque.raw e-split.vmdk
//     # e : le morceau, e-split-s001.vmdk, sans son descripteur
//     # odd.raw : disque.raw, 4 Kio de plus, et 0…99 dans les 100 derniers octets
//     qemu-img convert -f raw -O vmdk -o subformat=streamOptimized odd.raw g-odd.vmdk
//
// **`f` n'est pas de `qemu-img`**, qui écrit son répertoire en tête même en
// streamOptimized. `ovftool` et VirtualBox le mettent à la fin, derrière un
// pied ; aucun des deux ne tourne ici, alors `f` est écrit selon la
// spécification (« Virtual Disk Format 5.0 », VMware) par un script de
// trente lignes — puis **relu par `qemu-img convert -O raw`**, qui rend
// disque.raw octet pour octet, et `qemu-img check` ne trouve rien à redire.
// Le test ne compare donc pas ce code à lui-même.
//
// puis chaque fichier en deflate brut (zlib, wbits −15, niveau 9) et base64.
enum VmdkFixtures {
    /// `a-sparse.vmdk` — 262144 octets.
    static let a = [
        "7dd5lI31HwfwO5ZwIy1IJNdMorKOsVWTbWxJYUQpcs1cDGNmmrkGUfYsUYqKVKRoD22ULYrs7SpFUdkVUrbQWP74/frzd379",
        "zunX63XO83yf8/18v8/zfX/Pee55bquk1h1iAoFA/rwjUDhw2pAzTSDmbFvibBvIFwiUPHtZJvDvYwPBULFggL+buFBSWk7v",
        "UFIkJyU7LSuamd0sLT0SzI1k56RlZiTWDDZpmZTYvXuN+t271YsPZoWzIxnRM11nBFOyI+FopP2ArEhibJ/MjMz0tGjPtJTk",
        "vJE5kdhgMC7UtH80b04o9ewD8u4abNcxFF8joV4ouU2jdslNQ7Hhqjmnx1fL7ZPa+/Sk9j0jZ9cVjoZDjcM5kWBcUlLjYDA1",
        "tVu13LTsaN9weouOHc6sMpQYik2IPV3qEcnsE4lmD6iWMiA9LSM1r36qGP+nYs9IOPV0oWadP1VyIil5W3C6VqfWmVo4NZwV",
        "jWSfSniqOy01cqY/mpmZnvMvK4ivmVA3oV6tOgl1Y70HAAAAAAAAAAAA/NVK2YJ/tCGnTjH/4dwY+wcAf0dlbYHvP99/AAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAMD/UEzh4qXKXX51fP2GzW+65Y6UXnf1H3zf",
        "+ElTZ7wwZ97i5Ws/3bhlx8+/HS9w7oWXhCpVq31dkxva3npn9z7RgcPGTHjsqZkvv/7O0pUfbtj0w+4DRwKFzit5adxVNes1",
        "aNa6/e3d0rL63Tty3MTHn35+9luL3l/zyVffbf/p19/zBy8oXf6KqgnXNm7ZpmOXSHrO3UNHP/jok8++9Nrb736w/vNvvt+1",
        "//DJc4qVKBt7ZY261ze9MblTuGdm7j0j7n94yvTnXn1z4XurP/7y2217Dx7LV+T8iy+rWKXWNY1a3Nyhc2rv7AFDRj3wyBPP",
        "vDh3/pIV6z77euvOfYdOFCx6UZkKlavXSUxq1e62rj0y+g4aPvahydNmvfLGgmWrPvpi8497fjkqv/z/5Px+AQEAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAOCvk6/I+RdfVrFKrWsa",
        "tbi5Q+fU3tkDhox64JEnnnlx7vwlK9Z99vXWnfsOnShY9KIyFSpXr5OY1KrdbV17ZPQdNHzsQ5OnzXrljQXLVn30xeYf9/xy",
        "NKZw8VLlLr86vn7D5jfdckdKr7v6D75v/KSpM16YM2/x8rWfbtyy4+ffjhc498JLQpWq1b6uyQ1tb72ze5/owGFjJjz21MyX",
        "X39n6coPN2z6YfeBI4FC55W8NO6qmvUaNGvd/vZuaVn97h05buLjTz8/+61F76/55Kvvtv/06+/5gxeULn9F1YRrG7ds07FL",
        "JD3n7qGjH3z0yWdfeu3tdz9Y//k33+/af/jkOcVKlI29skbd65vemNwp3DMz954R9z88Zfpzr7658L3VH3/57ba9B4/JL7/8",
        "8ssvv/zyyy//3yG/fy4AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/z35gxeULn9F1YRr",
        "G7ds07FLJD3n7qGjH3z0yWdfeu3tdz9Y//k33+/af/jkOcVKlI29skbd65vemNwp3DMz954R9z88Zfpzr7658L3VH3/57ba9",
        "B4/lK3L+xZdVrFLrmkYtbu7QObV39oAhox545IlnXpw7f8mKdZ99vXXnvkMnCha9qEyFytXrJCa1andb1x4ZfQcNH/vQ5Gmz",
        "XnljwbJVH32x+cc9vxyNKVy8VLnLr46v37D5TbfckdLrrv6D7xs/aeqMF+bMW7x87acbt+z4+bfjBc698JJQpWq1r2tyQ9tb",
        "7+zeJzpw2JgJjz018+XX31m68sMNm37YfeBIoNB5JS+Nu6pmvQbNWre/vVtaVr97R46b+PjTz89+a9H7az756rvtP/36u/zy",
        "yy///2P+PwA=",
    ].joined()

    /// `b-stream.vmdk` — 132096 octets.
    static let b = [
        "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",
    ].joined()

    /// `c-zg.vmdk` — 262144 octets.
    static let c = [
        "7dd5lM11H8Dxi0RXVPYI14yIbLNYiiGMfUnWosWYucNkzEwz1y5LimihHZUKZSmiskULZd9aaKFCGxWl7CqesZznPE//Pec8",
        "T+f09Hqdc+/vnt/n+7v39/6dc+/53baJ7bvlDQQCBXIfgYKBs0ad2wTynN8WP78N5C4scf5lmcC/rw0EQ4WDAf5qokOJaTn9",
        "QonhnOTstKxIZnaLtPRwcGA4OyctMyMhJtisdWJCXExqap24uHAwKyk7nBE5syv1vGBydjgpEu4yJCucENU/MyMzPS3SNy25",
        "c+7KnHBUMBgdaj44kntMKOX8B+S+a7BT91Bs7fj6oc4dm3Tq3DwUlVxjaJ+aA/un9Dt7QJe+4fPnlBRJCjVNygkHoxMTmwaD",
        "KSm9aw5My44MSEpv1b3buTMMJYSi4qPOjvqEM/uHI9lDaiYPSU/LSMmdnxnG/mHYN5yUcnYQU/cPk5xwcm7+2VnduHOzpJSk",
        "rEg4+0zdmd1pKeFz+yOZmek5/3IGsTHx9eLrx9WNrxflOwAAAAAAAAAAAMCfoaRL8LeW559P/7lReVw/APgrKusSuP9z/wcA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/InyFLykZLlKV8dec13LDl1vTr79jsEj",
        "xz7w6JPT5yxY8ubqTR/u2LPvp6O/X1Co6OWhKjXrNGzW5oYbb0vtHxl21/hJT0x7/qVXX1+5butHn3/9wy8nAgWKlLgiulpM",
        "/cYt2nfp2Tsta9CIe+5/ZOpzs19e/Ma7Gz/4dPfeH4/8li94WekKlWvEN2jaumP3W8PpOUNH3zvx8adnvvjKsrfXbtn+2Vff",
        "/3z89IWFi5eNqlq7XqPm7Tr3SOqbOfDOu+97eMqzs+YvWvHOhvc/2fXtgcO/5r3o0lLlr6wed22TVtd3uyWlX/aQUeMefOyp",
        "GXMXLn1rzeZtO7/87uCxU/kvLlam4lW16iYktu10U68+GQOGj5nw0ORnXpj32vJV69/7+Itv9h86qV//37nfLyAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD87+S96NJS5a+sHndt",
        "k1bXd7slpV/2kFHjHnzsqRlzFy59a83mbTu//O7gsVP5Ly5WpuJVteomJLbtdFOvPhkDho+Z8NDkZ16Y99ryVevf+/iLb/Yf",
        "Opmn4CUly1W6Ovaa61p26Hpz8u13DB459oFHn5w+Z8GSN1dv+nDHnn0/Hf39gkJFLw9VqVmnYbM2N9x4W2r/yLC7xk96Ytrz",
        "L736+sp1Wz/6/OsffjkRKFCkxBXR1WLqN27RvkvP3mlZg0bcc/8jU5+b/fLiN97d+MGnu/f+eOS3fMHLSleoXCO+QdPWHbvf",
        "Gk7PGTr63omPPz3zxVeWvb12y/bPvvr+5+OnLyxcvGxU1dr1GjVv17lHUt/MgXfefd/DU56dNX/Rinc2vP/Jrm8PHP5Vv379",
        "+vXr169fv/6/Qr9/LgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD/PfmCl5WuULlGfIOm",
        "rTt2vzWcnjN09L0TH3965ouvLHt77Zbtn331/c/HT19YuHjZqKq16zVq3q5zj6S+mQPvvPu+h6c8O2v+ohXvbHj/k13fHjj8",
        "a96LLi1V/srqcdc2aXV9t1tS+mUPGTXuwceemjF34dK31mzetvPL7w4eO5X/4mJlKl5Vq25CYttON/XqkzFg+JgJD01+5oV5",
        "ry1ftf69j7/4Zv+hk3kKXlKyXKWrY6+5rmWHrjcn337H4JFjH3j0yelzFix5c/WmD3fs2ffT0d8vKFT08lCVmnUaNmtzw423",
        "pfaPDLtr/KQnpj3/0quvr1y39aPPv/7hlxOBAkVKXBFdLaZ+4xbtu/TsnZY1aMQ99z8y9bnZLy9+492NH3y6e++PR37Tr1+/",
        "/v/H/n8A",
    ].joined()

    /// `d-2g.vmdk` — 393216 octets.
    static let d = [
        "7dp/iORzHMfx784VNUL5cYpimi2KLLs79vxo/bjbOz8uP7q97oqiuZ3v3o3d29lmxnIUG0VRFEVRFEW5oijqFEVRFEVRFEVR",
        "FEVRFF47O3/o/nZ/XD0e9Zzv9HnPd+Y7n2/z32yfuX7XSFEUG4o1Vw4eV4t1I8PjKcNjUSmKU4dPNw6Hq5XhQrV2fLXgaDNa",
        "m2n3FmozZW+u217ud7rb2otldaXs9tqdpenx6pZrZ6bnpybm5y9qTlaXm91yqT9YGqrOdctmv9x5YLmcru/vLHUW2/197bnZ",
        "vLJX1qvV0drWu/o5p9YafkDetbpjd60xfklj8sJGbfamq3bMbq3VW+dP7B1b2d9aGJyzc185vKxmv1nb3OyV1dGZmc3Vaqu1",
        "Z2yl3e3f0Vy8Zveu9YusTdfqjfpgtLfs7C/73QNjcwcW20utzAfD8anxw+b7ymZrMBufOmzSK+eyCYPZ1OT6rNlqLvfL7tp3",
        "XFtut8r19X6ns9j7z0VMjDc2NS6enGpsqvslAAAAAAAAAAAAcGRtTKenM1M9nZ3OTWNpIk2lS9PlaXPalq5LN6QdaVe6Od2a",
        "9qT5dHtaSt20ku5O96b704Pp4fRoejw9mZ5Oz6bn04vp5fRKei29kQ6lt9O76f30Yfo4fZo+T1+mr9O36fv0Y/o5/Zp+T3+m",
        "v1NlpCiOSdV0QjppxP0HAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAACANasVewAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AEBRnDZSFGeks9JoOiedly5Ik2lTuixdkbakq9P2dGOaTbvTLem2NJf2poXUSb10Z7on3ZceSA+lR9Jj6Yn0VHomPZdeSC+l",
        "g+nV9Hp6M72V3knvpQ/SR+mT9Fn6In2VvknfpR/ST+mX9Fv6I/2V/kkbKkVxbDounZhOrrj/AAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAsGa1Yg8AAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAOPIOAgAAAAAAAABHPf+AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAOD/8C8=",
    ].joined()

    /// `e-split-s001.vmdk` — 262144 octets.
    static let e = [
        "7ddV9BdlHsDh358GAaWlu1PpRrqlWynp7u6Q7m7p7galQwnp7u7u3OJmb/ese47r85wz852LmYvPe/Ged0oULFUpKBAIBP/7",
        "FQgT+Kee/xqBoE8z6qcZCBYIRPv0GCvw7+8GwiWIEC4AAAAAAAAAAAAAwB8tuiX4S+v5j1vQf/htkPUDgD+j2JbA+c/5DwAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD4HwoK83n0uElSf509X5HSFWvUbdyqY4/+",
        "Q8dMnrlg+bpfdu0/eubyrYcv3of4LHLMBMnTZc5VoHjZKjXrN2vbpffAEeOnzVm8auO2vb+fOH/t7pPXgdARo8VJnOqrbHkL",
        "l6pQvU6jlh269xsyetJP85et/XnnviOnL9188Pxd8HCRvoyfLG2mnPmLlan8fb2mbTr3GjB83NTZi1Zu2Lrn4PFzV+88fvUx",
        "VISosROlzJA1T6GS5avVbtiifbe+g0dNnDFv6ZrNO347fOrijfvP3gYL+0WMeEnTZMzxTdFvK333Q5PWnXr+OGzslFkLV6zf",
        "svvAsbNXbj96+SFk+CixEqZInyV3wRLlqtZq0Lxd1z6DRk6YPnfJ6k3bfz108sL1e0/f6Nf/V+63AwIAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAMAfJ1jYL2LES5omY45vin5b6bsf",
        "mrTu1PPHYWOnzFq4Yv2W3QeOnb1y+9HLDyHDR4mVMEX6LLkLlihXtVaD5u269hk0csL0uUtWb9r+66GTF67fe/omKMzn0eMm",
        "Sf119nxFSlesUbdxq449+g8dM3nmguXrftm1/+iZy7cevngf4rPIMRMkT5c5V4HiZavUrN+sbZfeA0eMnzZn8aqN2/b+fuL8",
        "tbtPXgdCR4wWJ3Gqr7LlLVyqQvU6jVp26N5vyOhJP81ftvbnnfuOnL5088Hzd8HDRfoyfrK0mXLmL1am8vf1mrbp3GvA8HFT",
        "Zy9auWHrnoPHz1298/jVx1ARosZOlDJD1jyFSpavVrthi/bd+g4eNXHGvKVrNu/47fCpizfuP3urX79+/fr169evX/+fod+f",
        "CwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAMB/T/Bwkb6Mnyxtppz5i5Wp/H29pm069xow",
        "fNzU2YtWbti65+Dxc1fvPH71MVSEqLETpcyQNU+hkuWr1W7Yon23voNHTZwxb+mazTt+O3zq4o37z94GC/tFjHhJ02TM8U3R",
        "byt990OT1p16/jhs7JRZC1es37L7wLGzV24/evkhZPgosRKmSJ8ld8ES5arWatC8Xdc+g0ZOmD53yepN2389dPLC9XtP3wSF",
        "+Tx63CSpv86er0jpijXqNm7VsUf/oWMmz1ywfN0vu/YfPXP51sMX70N8FjlmguTpMucqULxslZr1m7Xt0nvgiPHT5ixetXHb",
        "3t9PnL9298nrQOiI0eIkTvVVtryFS1WoXqdRyw7d+w0ZPemn+cvW/rxz35HTl24+eP5Ov379+v8f+/8G",
    ].joined()

    /// `f-fin.vmdk` — 72192 octets.
    static let f = [
        "7dhrUJNXHsfxALbQtNiqLc5alQhWlrWCVFSsC1obhTXDegHBBdFFEjCFJJpAAC9EKdbZ9baWKqtuoa5bWlBBi8ULlihd0ZVS",
        "FAsIwaJbFBEBXUQIt2zQtLIz+6qXF47fT2aeM8mc8+SZ8/uf8zyJROwfZCMQCGzML4Gd4KH1jxqBlaV92dIKrAU/MFl831cg",
        "FNkLrQR4wjiLxHJNtEgs00So5StjVeo58hiZUCtTa+QqpbeH8O3fib093pjkOXnKVC/hynC1TBnb/1GkhTBCLQuPlQUmrpR5",
        "O2lizW8U81bGyhXy1TKpk1DoLJqdEGseIpJazm8+qXBhsOiNiZ5eooD5by0MmC1yipQr3bQKafTD/oErZJYrCo8NF80K18iE",
        "zmLxLKFUutxNK1fHxoXH+AUHPbo8kbfIydNJSIgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAzyzVSiBIqGku+67opWcFgtOFMYYr",
        "nyk05/MVhvzQxf1HhaH9WPytFns3kTTl1r0+v50evn3LXxsfmFt11L9hqY3vlow311y6YG/oGOWtMVZ+ObxV/4z9sGlBRVJ5",
        "Xr3b/eDdFz4fkb+i7lDrXy6lZpaFnoxsy3nX5etlBd317Z/MHFPku3nvWNl7d4x/7gstDLk67tD09pET19Z+8Ifngw/W5Xec",
        "b5RMdfytrmOy3y0/j2Fj/VOnBZ8Z+vH4ipiLp8KqfN719e/RtbxfsVc72iup5faH53J9+uxGu73zt3+6lkeVhNZnqBc1eSor",
        "jviawiNcypYcXnu10nvTvLBTq0zVBvcNb8/eMsRU9s1utcOvl2Yv39pVWqNt9F5RnyLXOOTWHI8wHckLVs5Ybby+5vDhBctd",
        "5qa7RacX6dIOLSxYUDL4arf9qLa6LcaSSmX1ulv1G5s60guNI6+1ml412Vj9pDhOuydZfze376VfPPf1lvbjR/lXBRjM+a+/",
        "5G4o0Ybml8peNwdfsEsRU22uBkO+0fbkncyGaQ2Op9JUMx8OmxFwbf6Q/ecke34Tsa3n7IXA7OqPEgty1j27fc/Edd+WL3r1",
        "WLO3uqu81Lasbp29w5S5B1NcyyP/Ffap2JgdN+LY7Sv7TYePpEZNWJKvLfna5lxZ2BdtnRXnZo5xFn9fDrtyFu9PyssPW/3i",
        "CGPH0ROSIGWnrux6wHBVre7BA8nFiTsixvmlj9PkJJ8tWZR19VPZppbe97bt9tSc0UdPab2iu3Nnp2H70iQ7uyE+5nLQ/aNs",
        "1zG/LH12VXRNpiZ3g3PxvA/zEs52mbSObyZe7/riE5WP7XOjXOf0SLMm3Xj9blT145odFvWVKao9s7l7W/qJtU3XN3fUJW/q",
        "nqD9e91lWWnAcenGd+L2Hm35RnP67qqASPeQQmXTD9Xt0tvV3lSVu0yf1Nul25jUYP0jg7obUWelV1f89efO3/ZRm2ZZ/5dr",
        "+tf/xRnuVebAp1T2p644GKKo7t8CmtP3GQo1314bNOinfWfPSdE+pznb0zz9by55RvLB47U0KfGmSRKkqkm81nniQPxofVen",
        "c8KV80eGZvplTFDtKH9lQHDd8Wf+ExfaMdIn7l5xb5RKP2jwr8aE1I7tD25+T+uAzabPqLqXvXX6A8fpa2482J/mWGj7/DDX",
        "yOT6xs9uui7JXvv5Sf+Q+NvT/th5PCuvwT20QNaxL3V4Tt2arpuaj2YU+W5N9VpUPNK4eWdWYN5bbdqw7hdGT15VXDt7/NSY",
        "uvj7X90IfXHZKZOD5/0Mj3+7SPa+Fr/v/RvZlfLa7IjtfV8W/373ZFXjntKCweleuuaW1KoM61kpm4dOX3Dhheq2V3oPDNhs",
        "GjUOOYv1itYdl9OUPgl9LQf0er2ptdP0XHLY7cZfdP0PjNKK2+BTp3//3/AjxyYzfQAAPJEGPvNZMx1PnRSmgPVvYcN0PHUk",
        "Yv8gm4fZm492j38TDqyNl//PDeJPgv/tKxCK7IX8gQA8Uf4L",
    ].joined()

    /// `g-odd.vmdk` — 132608 octets.
    static let g = [
        "7dZ7VFNHHsDxKFrdKNTFiquiRLBaawvlIQgIWouCtfiuuICykUSIJIQmkUdRUbR6WqTWoqLFwlofrCDgY9UqShRX6qLVogIK",
        "KFZBQF61oghI0vDoqds/2+329Oz3k3MzN/PL3Myd38zkzvDwXmAkEAiMDK++fQWdVncVgh7d5UvdpaCnQDCo+3So4D+/KxCK",
        "jIU/NsAfhpXIQ6YOEXlI1YEqWZhGqZomk0uF4VKVWqYMdbMVvjXdwy3QTuJsv1RiJwwTq6Shmo6qpd2EgSqpWCOdHxUmdbNU",
        "awwfFLPCNDKF7H2pxFIotBJNjdQYmogk3dc3XFQ410dk98Z4R9G82W/OnTdVZBn0ulIisQ5XSEI6W8wPlnb3SawRi6aI1VKh",
        "lYfHFKFQIlliHS5TaZaL5V4+C7p6KHITWTpYdoaCpEqFVKOKsg6MkstCJYZ4R9DuZ8FgqVjSGbB1/FlELQ003H5nzNG+KyaW",
        "iMM0UlXH3XVUyyTSrnqNUilXP9cDO1sHJ4cJ9o4OTpZCphQAAAAAAAAAAAAAAAAA4H/AjCH4v7bacKz5hW1jDcdahhAAgD+c",
        "YQwBz388/wEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAgN9BQg+BIHJn/ZV7uQNeEAjO5MhLbxxWqC8cU5Qe81vY8a4ofXw8orrB2FokWVf9UOe11dZTt+TlcfOziv/p",
        "XbXYyHNjikt0Qb5xafNwN3VL0bnBjdrexgOdF+RKZEcqrJt8duQfHXosuDyj8ZOChH1X/E4ufZS5dszlgOy2isepk0fmesYl",
        "jZKur2v5SOeX43trdIbrY/M3VpRt+Ws/nwPlx5ov1MxwspgY0zzeq9rLduAo7wRnn7Ome8cVyr85tajYfa2n97OYhk8Lk8JH",
        "TFjV8ODzr7LcdX1HWC/b+a+xV4Mu+lWkqN6tdQgtPOSpFweOueJ/cMWtIrcNsxadek9/s9RmzVtTN/5Zf+X6DpXZK4vTlsS3",
        "fl0SXuMWXLFOpjbLKvkyUH/oiE/opPdbvo0+eHDOkjFvJ1uHJOfGJGbMzZ5z0eRWm/HwR+UbWy4Whd5cWV3xQW1zck6L+Z1G",
        "/TC9UY9flY4zNqt63ntbN+A3z/vq7jK1K//FgcWG/K8ucMo223bioLw0b5sh9fUldomLSg93nE0qcC50btatrbo3sLNvZ46/",
        "NOG6TcHd0TN3jIzO+UL6atE/yg8oEm+vnTZzu0tQQf5Rv3ALl6hvW0+nKt379BvmvDR2j8yu6tWFX8i3lsT7hlffVlZv1wZd",
        "MsyHc09Wel7xz3n83fm2ySOtPOITXpnaKo+K25I5+/Tia46fRxub267Kr/tgnK78VO2dDx8VN7hHtY8N3u5le1ef7DLvcs/z",
        "+gP+6eK4J7daTYa0FzfFbDuwWKto3HwtMdQ9Umct8ngaEDjmnc7s7c33SS/dszw12Wj9pqSJIWe/1zvWTwx7VlbouilgZX9T",
        "lyVNkdPnSi9t1t6w2LrMMfh2ZkjK2d2jZyZlRxaezIg2STkZeU935HhA7IY409rjndN7/mH/Qpd4v+V1BTE3bky3r7Jpi7j3",
        "cftXlxefaK+u7NPe+ri2OCtAu6q9NWa9rrHd+JfmalJallZVuP2/m/8+XWVi9/q/VtKx/r+ZZFNsyLdjUUfSFQd8FTc7toD6",
        "5F2lOerbd3r1+nW/+eykaJfltE2JDt73/XvP2PLTWrKPuq+fsUBZEnXn6Yn0iBHa1qdWkTcuHDLd55XyunLz1UFpxSEl+9RZ",
        "a6zyZrVFnP1+uV+zufvyh3ntQUptL5MhI33LRu23r3xt9rPG5zYbXYvyYVq86xML1+jKJ7sTLXL69Bs4dmlsRc3h+2P901Yc",
        "PentG/HA+W9Pv9x/pMrGL1vavCthcGZ5dOt99d8n5XrGJ0x4N8+8JW7r/vlH3nwUvqit/4jx7+WVTR3nJC+PaLpU6fdiwCm9",
        "mUNTiu3dMTOSXo7Y9WllWpGsLC1wk+5c3swd45U1n32dbZI8Iaa+IaE4peeUdXGmrnPy+998NKg9/bnNpkZtlrnwp+nakK7V",
        "avWNT/V/il30oOa33QD6dhXrBJ35P1vYI1Yg6D25rqer7UG/utDzDYJhIfrh5udSIjx/3Iy+8zHd/07m7LTrQzM+3tP0wu5/",
        "yw+V1JmkxoVHn3LPs+i7Pndz8GvJXvuuDnFMujj4o72qvb7pTp9lhKeW1r64vix44o7L9+Mql52+2fBkg5XNzsuJtfW6ASlZ",
        "zVVtRkl/GejDPzEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/D5+AA==",
    ].joined()
}
