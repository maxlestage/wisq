import Foundation

// Images qcow2 écrites par `qemu-img` 8.2.2 (Ubuntu 24.04), compressées en
// deflate brut puis codées en base64 pour tenir dans un fichier de test.
// Ne pas éditer à la main : un octet changé ici est un test qui ne teste plus
// ce qu'il dit. Pour les refaire :
//
//     # disque.raw : 1 Mio de zéros, et les trois motifs de
//     # Qcow2ImageTests.original (0, 70 000, et les 1 500 derniers octets)
//     qemu-img convert -f raw -O qcow2 -o cluster_size=4096 disque.raw a-v3-4k.qcow2
//     qemu-img convert -c -f raw -O qcow2 -o cluster_size=4096 disque.raw b-v3-4k-comp.qcow2
//     qemu-img convert -f raw -O qcow2 -o compat=0.10 disque.raw c-v2-64k.qcow2
//     qemu-img convert -c -f raw -O qcow2 disque.raw d-v3-64k-comp.qcow2
//     cp a-v3-4k.qcow2 e-zero.qcow2 && qemu-io -f qcow2 -c "write -z 0 4096" e-zero.qcow2
//     qemu-img create -f qcow2 f-2g.qcow2 2G
//     qemu-io -f qcow2 -c "write -P 0xab 1G 8192" f-2g.qcow2
//
// puis chaque fichier en deflate brut (zlib, wbits −15, niveau 9) et base64.
enum Qcow2Fixtures {
    /// `a-v3-4k.qcow2` — 32768 octets.
    static let a = [
        "7dx3VE1xAMDx+yqRHp4klfWMQsszSggJL5G8l0SLzIyQsldZ2WTv7JBRFCqyKVtWyt7ZeyTzlOPIP/7q6Nz3/dxzf/fc+9f9",
        "/u45957fP1etdMkRBEFbyE+aO8p+n0vyDopfp7I/rv2Tzs89SAAAAAAAAP+ZnCkAAAAAAEDMJH9tAAAAAABAdMJyR0cmAgAA",
        "AAAA0a//VYXkPvx5IAAAFPj3lt/yAACgiSTFShlVrG5Zt6Gjs1tH3x79Bo8IDZ+1YPnazbF79h87fTHzTtbLD1919A1M5DVs",
        "bB1atFF37tp7wJDRE6ZFLI7csDUu6VDquSs37j99ky0ULVm2QjWLOvbNlO08fLr3DRo+bvLM+cvWbIrZnXz01IWM249evP+i",
        "Xby0cWVz6/qNnVxUnbr0CgwZNX7qnEUr12/ZmXgw5ezl6/eevP70XbeEYfmqtRQNmrZy7eDdrc+gYWMnzZi3dPXG7bv2HTmZ",
        "dvXWw+fvcrT0ZOUqmVnVa9S8dXtPv579g0eGTZm9cMW66B0JB46fuXTt7uNXH78VkZYxrVKztl2Tlm3dvfwDBg4dM3H63CWr",
        "orbF7z184nz6zQfP3n6mn35N7ucNCAAAAAAFg4Ur/fTTTz/99NNPP/30F/5+Vi4AAAAANAGLX/rpp59+8fX/AA==",
    ].joined()

    /// `b-v3-4k-comp.qcow2` — 21504 octets.
    static let b = [
        "7ddnUBRnGMBxiICCNKUrSBKjFOEo0kHOJIqCdASkREDKUaSXoxM1EqkXRUDqJSFSpQsIJzCEgFINPYBAqCedA44TjruVgQwT",
        "P+VT4ox5fjv77Lzvp53/zs7OGmlpUxkYGA4wvI99d3Lvrxn3LrJ/Lbn/tvePmHZOLwYAAAAAAAAAAAB8YJ9CAgAAAAAAAAAA",
        "4GPGuH8cgBgAAAAAAAAAAMDH6dvdeR5CAAAAAAAAAAAAH7G9P3/DD34fF3anEQqeCAAAAPBvf/eNMVACAAAA+P+xn/pTIMG0",
        "S6nMz4tyOE67U/JJrud8hnxIVyvHMEXknO9mf6PAcj3NcZz/wVXDgbMV3htssfcM2qTzPObSZcNGuxXTsCIa3vShEbFiNM3B",
        "lsiTaNQv/7QEu8YRpd8qJV7stpii4TYeTR7eOKEaNjtzh7hcR7ebOfrwB/MexdKAVfZDuCsdEkWuC2/wStiWOT11LmE0ltw5",
        "aS4asY2Z5Ltv1q0gW+VLZo3XaX8pU+A+m6ng27Dqb0UR1vQnNdMwnvXbThO83MkmfXKVPusrXDF6Laj8m87LaWoYUn6c+oao",
        "esj0RlayaB1iP30kybj3d+VyfxJntO7lV2cKXZZSVezpZRVWAaJqQeNbtTmemsgNYTKSi1wqQYS0GsQFmbNseWNvG8my7S5O",
        "suzUshVkXmfSTf9kwidfrdks/gTdrlRi8GIix2KYCVHqeoX3C7o9pvh1+PpqIyXiicavxtHHtpwqUaNf3medDXqs2PEND6bd",
        "pjKgbelrMRnresp6B9EmVnj7RpnkkFYS51L4T3ItFnf5yO61Jk4yltV21LosDGos+O0Erape6vVXD9jmgrOVOq/fOkJyqT7V",
        "p5fBk/3KqsZpreiOWKcNgTpFzsGzL4T+LN9qGcm/4VH3WZd2CvO0f+G5BIy0dWn48OjJHJmR0JXtkQF0u/Xto6uuNaf79TMZ",
        "x73zVJtM40RoPTMoi1oX4q1JYtFo0PbcJA65+fzzbp1UlpmAIs0GoyihTccK6ZEEJ9S1Oo/5zMYc1OgzZGExeSyLLrobjYae",
        "Q4wQ3FZEL7K7ZbiCnKcc30n3I/NeuPdqZjHwyfqy6rwsmE29ph7E8t2LxzO85ooB6wZpBAdydsbBeDwhmEgqwKHp5aToy2dc",
        "jj0art5iunTKaSq5r9LPILXadrOmMIQTXxM4SS+vsgk/6812ry1vTtBKNfjt903ZDgKmSk8pehnlgX3NIlRcRq0PtauNawwp",
        "XT10RcL1TdpgTeDBi6d/ISb2K2D10uUiBoekCVwZz71ooz3K+Ag5n5WYlnzn4xZqz6h3m7/A8Jn1VpH1U2qdpyMXqfGZ1aHz",
        "4zGUMXqZ12Ftydz5lCGVEGat33Kmk64q++s/0vScTe0gcGaqRCwuJQzgw+VL1qJaxd2ELP8gbEZeEHPkfzhQsaGbWeHVtOUe",
        "gkuv81trWMPaILH74bzW0f/d+/8O",
    ].joined()

    /// `c-v2-64k.qcow2` — 524288 octets.
    static let c = [
        "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",
        "+UG/fv36/4r9fwM=",
    ].joined()

    /// `d-v3-64k-comp.qcow2` — 329216 octets.
    static let d = [
        "7dR5cBflGQDghEBpR6EWKo4VIRQUkRaKB3Io0FYIFEGxKpZwNIQfEMmBSSDEKEFQnBZSitylJsWzhhsqKGAiWNFBBKOGQAIE",
        "5QpiSJUjJCH5NWGmFf5RWmc6nfF5dvbd3Zn9dvd73+/dQX36VYWEhISFXOyKC2Kd0PMx7KKr0JBLU792H/+vi7FhZwfXDp0S",
        "EjIqJjE5NXxkTPKlPSU0OiExccL45EsdUS8wKTmQGB8VGz4qKjkqfHRMbOAr7w+LTogbnxhISopJiA9PTh0f+LpZ1T0/flRg",
        "VPhdN4UH4pMTYwJJX/X5IbFRj6SGJwZGRydMiE9O+trPD6mdZ1zU+KRLTHK90MSolPCL5hwCAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADwH6snBQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAN96of/ewiQDAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADg22tKXagvDwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAN92vepCg9pj3UmD0Iz/2XvPvy+sgwoAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD8fyjdeXDLFd8JCXkjJ7Zo95q4pHfW",
        "xRWti3ywLsYVnV6fUnKiUYfwUU+UfF7Td16niJqR17W/b2XB3wYcHR4WMTOrW1retkZF5dfekVSx682rynIbNGra9YEto2LW",
        "HupwavCiba/8aN3Y4uVlf8yb8+LOyA2jT66Y1nbHiI1Vh06/1KvVlogZi9sEpn9W8fuayJwh+65f3v108589unfuby4bvKx4",
        "Xfk7x/rf1vL29PJb+5b07dS0zYA5XQdvbvJC+/zY9zcNK+gxLWLAufQTT+cvntiiy+QTnz7z9soeNd9t0eGhP/+93Qdj3o08",
        "lJV4//Fb4vNXRwSjotvuHLrq0X277njq7mGbHg7uKer4+C97z/xBcOdHixKb3TA8e2RG5XuFE4/dMfbQEzFJzVYWvhodXL12",
        "cHzPRyo+Tlu1atDItr/K7DAuc0v6guX3bhz0buN9VY2uPVk8s+LdXfF7His59OTx8syciuYHyoLXBMNCv1Eh3ug4uV5pQXRB",
        "bTGm5N22sdn811bFFm2dX1uH0sKbFgwrWlN31jOva37X8pppRw82veL8oPU/7PJRx7xPrh+4qFVazrOBG3f9tXhZ3IL90/oM",
        "XNhtTN62VyIntuyW+nHl6y8l9Gh42TVdR099Puamozc++GzsvMKMIRNL9ieULMwds722OG+eeSxi59Cc0/94q6pXq9Z3Zsy5",
        "oXdlbOqMuSvueX34h52fSWvUvNPkbZ892b6meNPxA787WXCiR2p1u7EL+3b6JJjZ7dc76r0VXDZ0adSMM/sqG19dXXAqff6y",
        "4blxZbM/XBDfY1JNh/A7z46IbnvX+VS+sG3w0qLnJ7yUGTZ91uLbx23+Iti59Pbx5/bmd5814rHLm3QbeWpSv3sD22fn7m45",
        "76HOY/evGJe1+bnrBy7eOCl/w/K0xlkbJh2sWbt+xNSnZjQ5vv78WrtvzdD8bhmREz7LS9+9u9/NRztWpRz8Q/XbO4a/Vl1y",
        "uGF15enjBStH5E6urkyfXlNW3ei/rVDP7JWlOz8srOuW93t2LKgtSOdddVWJWzYkbk9dw5RmLinKSdp/oH79b9aT5zaEL/lx",
        "n1kLbhlwZGiD/nO/XHk3px4J9n8goTD1wNnXlqa0yK0823rS7ndWN3mxb9ZPE2Z/cGV2wbjCF5NWPt56691VKZu/mBBZ3rzH",
        "hM+3Vo9JyK3f+OpWQ/a2efnmwz+551zZBa1ZU5HweXZG9zMtu6cdPvPcgpY5DS9r2m701EPH1hxpNzT70Vc2DBiS8mnX3559",
        "9eW1RztGbgyUL5lz1YritMojSX/puSUiY06X+7c2r5gx7+X71v785MRhVZe3uPXhrXt7t78ttjjl1PbDkd8fsSnY7JZTWZ0+",
        "adt/8XUpS54+nL0rZm929KyaN7cOXHRrwrE/vbexcWaX9NITcwqy6v3iiRlNug/advmek1dWL72gNY8lNVvx4Jfr6cTS3Nzc",
        "YNnZ4Pf8wL+hfwI=",
    ].joined()

    /// `e-zero.qcow2` — 32768 octets.
    static let e = [
        "7dx3VE1xAMDxeytZL55VQjyblmeLkPDI6j0jWiQjM6GsoqzsWfbKng0aMrIpW6gUsrekrMg81XHwT391dN77fu65v3vu/et+",
        "f/ece8/vn6tS2GQLgqAt/E2SM0p/n4u5B3neqfSPa/nS+bV7CAAAAAAA4D+TMQUAAAAAAKgz8Z8NAAAAAACoHb+c0YqJAAAA",
        "AABA7df/SrFw3IcLDwQAgAL/3vJbHgAANJFYrLS+US2TRhZWnXr0cRo0YuwkX/9Fgeu27A47eOzspRspD56nf/ymU7Ksoayu",
        "eVPL9l1U/QYMHe3pPWPe0lUbt+8LP3wy7mri3cevMj8LRUtVqFLTuGGLtoruvR1dh3tMnDZ7YcDazbtCo2LOXLyefP/Zmw9f",
        "tUuUqVitjlmTVtY2yr79h4waP2X63CUrN2zbe+DQidgrCXcevczI+qGrV75yjfry5m06duvlMHDYmAlTZy1YviZoZ0jk0dMX",
        "4m/de5r2PluruNSgam3Txi3bdba1cx48ctxkvzmLV6zfumd/9PFzl2/efvji7afvRSTlKlWv16BZ6w5de9q7uLl7+cycv2z1",
        "ph3BEUdOnb+WlPrk9bsv9NOvyf28AQEAAACgYLBwpZ9++umnn3766aef/sLfz8oFAAAAgCZg8Us//fTTr379PwE=",
    ].joined()

    /// `f-2g.qcow2` — 393216 octets.
    static let f = [
        "7dpBSsNAFAbgpK17jzBn8BCC4MaV69hMMdCmYTKiddX7eEHBjY1YbDdtBTfS7wv8MDDvMe+tc3d981EUxbjYdznE+uc8+crt",
        "rXInjxtqu+3hcfx+vyndtK6blFfhocmndSmny5SeunxqxSi+5Jjaah7qKldh1szjwfvj6XLRpdj3zbINedXFY1MN/ds61uH2",
        "KsQ2pyb2h55fzKvXVUhxNl0+tbk/+vxiM+ei6voTlzwqU/Uc9mYuAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAfm1kBQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGev3PkAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAADg23qIiT0AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAACcm/UQF/YAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAABw7t4AAAAAAAAAgH/PHxAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAA/IVP",
    ].joined()

}
