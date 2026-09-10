//! **Les segments d'un noyau ELF, et pourquoi ils comptent tous.**
//!
//! `--example kernel-entry` ne posait dans la RAM invitée que le segment qui
//! porte le point d'entrée — le texte. Le vmlinux d'Alpine en a **quatre** :
//! le texte, `.data`, le percpu, et un dernier qui traîne cinq mébioctets de
//! BSS. `secondary_startup_64` charge son pointeur de pile depuis
//! `initial_stack`, qui vit dans `.data` ; sans ce segment la lecture rend
//! zéro, RSP vaut zéro, et les empilements descendent en négatif. C'est
//! exactement le `rsp = 0xffffffffffffffe8` relevé à
//! `secondary_startup_64_no_verify + 339`.
//!
//! Lire ces segments était fait à la main dans l'exemple, donc tenu par rien.
//! Ici, sur un ELF construit pour la circonstance : un outil de diagnostic qui
//! se trompe de segment ne rend pas une erreur, il rend un résultat.
use wisq_vm::kernel_image::loads;

/// Un ELF64 minimal : l'en-tête, puis `count` en-têtes de programme.
fn elf(entry: u64, headers: &[(u32, u64, u64, u64, u64, u64)]) -> Vec<u8> {
    let mut bytes = vec![0u8; 64];
    bytes[..4].copy_from_slice(b"\x7fELF");
    bytes[4] = 2; // 64 bits
    bytes[5] = 1; // petit-boutiste
    bytes[16..18].copy_from_slice(&2u16.to_le_bytes()); // ET_EXEC
    bytes[18..20].copy_from_slice(&62u16.to_le_bytes()); // x86-64
    bytes[24..32].copy_from_slice(&entry.to_le_bytes());
    bytes[32..40].copy_from_slice(&64u64.to_le_bytes()); // e_phoff
    bytes[52..54].copy_from_slice(&64u16.to_le_bytes()); // e_ehsize
    bytes[54..56].copy_from_slice(&56u16.to_le_bytes()); // e_phentsize
    bytes[56..58].copy_from_slice(&(headers.len() as u16).to_le_bytes());
    for (kind, offset, virtual_address, physical_address, file, memory) in headers {
        let mut header = vec![0u8; 56];
        header[0..4].copy_from_slice(&kind.to_le_bytes());
        header[8..16].copy_from_slice(&offset.to_le_bytes());
        header[16..24].copy_from_slice(&virtual_address.to_le_bytes());
        header[24..32].copy_from_slice(&physical_address.to_le_bytes());
        header[32..40].copy_from_slice(&file.to_le_bytes());
        header[40..48].copy_from_slice(&memory.to_le_bytes());
        bytes.extend_from_slice(&header);
    }
    bytes
}

#[test]
fn every_loadable_segment_is_reported_and_nothing_else_is() {
    // Trois entrées, dont une PT_NOTE (4) qui n'est pas chargeable et qu'un
    // lecteur naïf compterait quand même.
    let mut image = elf(
        0x0100_0090,
        &[
            (1, 0x1000, 0xffff_ffff_8100_0000, 0x0100_0000, 1000, 1000),
            (4, 0x2000, 0, 0, 32, 32), // PT_NOTE
            (1, 0x3000, 0xffff_ffff_8240_0000, 0x0240_0000, 500, 900),
        ],
    );
    // Le fichier doit porter ce que ses en-têtes annoncent, sinon le lecteur
    // refuse — c'est ce que vérifie le test d'après.
    image.resize(0x3000 + 500, 0);
    let (entry, segments) = loads(&image).expect("l'ELF se lit");
    assert_eq!(entry, 0x0100_0090);
    assert_eq!(segments.len(), 2, "la note n'est pas un segment à charger");
    assert_eq!(segments[0].physical_address, 0x0100_0000);
    assert_eq!(segments[0].file_size, 1000);

    // **Le second porte du BSS**, et c'est la distinction qui compte : quatre
    // cents octets qui existent en mémoire et pas dans le fichier. Confondre
    // les deux tailles fait soit lire hors du fichier, soit laisser un trou
    // là où le noyau attend des zéros.
    assert_eq!(segments[1].file_size, 500);
    assert_eq!(segments[1].memory_size, 900);
    assert_eq!(segments[1].physical_address, 0x0240_0000);
    assert_eq!(segments[1].virtual_address, 0xffff_ffff_8240_0000);
}

#[test]
fn a_segment_that_reaches_past_the_file_is_refused() {
    // Un `p_filesz` qui déborde du fichier : le lire ferait paniquer une
    // tranche, ou pire, servir les octets d'à côté.
    let image = elf(
        0x1000,
        &[(1, 0x20_0000, 0x1000, 0x1000, 1_000_000, 1_000_000)],
    );
    assert!(
        loads(&image).is_none(),
        "un segment qui sort du fichier n'est pas lisible"
    );
}

#[test]
fn something_that_is_not_an_elf_is_refused() {
    assert!(loads(b"MZ\x90\x00 ce n'est pas un ELF").is_none());
    assert!(loads(&[]).is_none());
    // Un ELF 32 bits : le lecteur ne sait pas le lire, et le dire vaut mieux
    // que décoder ses en-têtes comme s'ils faisaient soixante-quatre bits.
    let mut small = elf(0x1000, &[(1, 0, 0x1000, 0x1000, 16, 16)]);
    small[4] = 1; // ELFCLASS32
    assert!(loads(&small).is_none());
}
