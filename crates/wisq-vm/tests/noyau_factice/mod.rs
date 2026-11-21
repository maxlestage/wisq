//! **Le noyau factice**, partagé par les tests qui démarrent la machine PC
//! native : `pc_demarrage`, `pc_poste` et le programme d'ABI (`abi.rs`). Il
//! est aussi gravé dans `Tests/Fixtures/pc-noyau-factice.bin`, que les tests
//! Swift démarrent sur les deux cœurs ; `pc_poste` vérifie que le fichier est
//! bien celui-ci.
//!
//! Il lit la page zéro que RSI désigne, écrit sa bannière et sa ligne de
//! commande sur le port série, pose une IDT, initialise le 8259, arme le 8253,
//! dort sur `hlt`, se fait réveiller cinq fois par l'horloge, et s'éteint.

#![allow(dead_code)]

/// Le noyau factice, assemblé par `as --64` puis `objcopy -O binary` ; la
/// source est ci-dessous, pour qu'il se refabrique.
///
/// ```text
/// entree:  mov  %rsi, %r15              # la page zéro
///          lea  banniere(%rip), %rsi
///          call dire
///          mov  0x228(%r15), %esi       # cmd_line_ptr
///          call dire
///          mov  $10, %al
///          call ecrire
///          lea  gestionnaire(%rip), %rax
///          lea  idt(%rip), %rdi
///          mov  %rdi, table+2(%rip)     # la base de l'IDT
///          add  $0x200, %rdi            # la porte du vecteur 0x20
///          mov  %ax, (%rdi)
///          movw $0x10, 2(%rdi)
///          movw $0x8e00, 4(%rdi)        # présente, porte d'interruption
///          shr  $16, %rax
///          mov  %ax, 6(%rdi)
///          shr  $16, %rax
///          mov  %eax, 8(%rdi)
///          lidt table(%rip)
///          mov  $0x11, %al ; out %al, $0x20    # ICW1
///          mov  $0x20, %al ; out %al, $0x21    # ICW2 : les vecteurs à 0x20
///          mov  $0x04, %al ; out %al, $0x21    # ICW3
///          mov  $0x01, %al ; out %al, $0x21    # ICW4
///          mov  $0xfe, %al ; out %al, $0x21    # seule l'horloge démasquée
///          mov  $0x34, %al ; out %al, $0x43    # canal zéro, mode 2
///          mov  $0xa9, %al ; out %al, $0x40    # 1193 : une milliseconde
///          mov  $0x04, %al ; out %al, $0x40
///          xor  %ebx, %ebx
///          sti
/// attendre: hlt
///          cmp  $5, %ebx
///          jb   attendre
///          cli
///          lea  fin(%rip), %rsi
///          call dire
///          hlt                          # éteinte : hlt, interruptions coupées
/// gestionnaire:
///          push %rax
///          inc  %ebx
///          mov  $'.', %al
///          call ecrire
///          mov  $0x20, %al ; out %al, $0x20    # fin d'interruption
///          pop  %rax
///          iretq
/// ecrire:  push %rdx
///          mov  $0x3f8, %edx
///          out  %al, (%dx)
///          pop  %rdx
///          ret
/// dire:    lodsb
///          test %al, %al
///          jz   1f
///          call ecrire
///          jmp  dire
/// 1:       ret
/// banniere: .asciz "wisq-noyau-factice\n"
/// fin:     .asciz "\nFIN\n"
/// table:   .word 0x21*16-1 ; .quad 0
/// idt:     .fill 0x21*16, 1, 0
/// ```
pub const NOYAU_FACTICE: [u8; 229] = [
    0x49, 0x89, 0xf7, 0x48, 0x8d, 0x35, 0xb7, 0x00, 0x00, 0x00, 0xe8, 0xa5, 0x00, 0x00, 0x00, 0x41,
    0x8b, 0xb7, 0x28, 0x02, 0x00, 0x00, 0xe8, 0x99, 0x00, 0x00, 0x00, 0xb0, 0x0a, 0xe8, 0x89, 0x00,
    0x00, 0x00, 0x48, 0x8d, 0x05, 0x71, 0x00, 0x00, 0x00, 0x48, 0x8d, 0x3d, 0xb5, 0x00, 0x00, 0x00,
    0x48, 0x89, 0x3d, 0xa6, 0x00, 0x00, 0x00, 0x48, 0x81, 0xc7, 0x00, 0x02, 0x00, 0x00, 0x66, 0x89,
    0x07, 0x66, 0xc7, 0x47, 0x02, 0x10, 0x00, 0x66, 0xc7, 0x47, 0x04, 0x00, 0x8e, 0x48, 0xc1, 0xe8,
    0x10, 0x66, 0x89, 0x47, 0x06, 0x48, 0xc1, 0xe8, 0x10, 0x89, 0x47, 0x08, 0x0f, 0x01, 0x1d, 0x78,
    0x00, 0x00, 0x00, 0xb0, 0x11, 0xe6, 0x20, 0xb0, 0x20, 0xe6, 0x21, 0xb0, 0x04, 0xe6, 0x21, 0xb0,
    0x01, 0xe6, 0x21, 0xb0, 0xfe, 0xe6, 0x21, 0xb0, 0x34, 0xe6, 0x43, 0xb0, 0xa9, 0xe6, 0x40, 0xb0,
    0x04, 0xe6, 0x40, 0x31, 0xdb, 0xfb, 0xf4, 0x83, 0xfb, 0x05, 0x72, 0xfa, 0xfa, 0x48, 0x8d, 0x35,
    0x41, 0x00, 0x00, 0x00, 0xe8, 0x1b, 0x00, 0x00, 0x00, 0xf4, 0x50, 0xff, 0xc3, 0xb0, 0x2e, 0xe8,
    0x07, 0x00, 0x00, 0x00, 0xb0, 0x20, 0xe6, 0x20, 0x58, 0x48, 0xcf, 0x52, 0xba, 0xf8, 0x03, 0x00,
    0x00, 0xee, 0x5a, 0xc3, 0xac, 0x84, 0xc0, 0x74, 0x07, 0xe8, 0xed, 0xff, 0xff, 0xff, 0xeb, 0xf4,
    0xc3, 0x77, 0x69, 0x73, 0x71, 0x2d, 0x6e, 0x6f, 0x79, 0x61, 0x75, 0x2d, 0x66, 0x61, 0x63, 0x74,
    0x69, 0x63, 0x65, 0x0a, 0x00, 0x0a, 0x46, 0x49, 0x4e, 0x0a, 0x00, 0x0f, 0x02, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00,
];

/// Le `bzImage` du noyau factice : un secteur d'amorce, un secteur de setup,
/// puis le noyau en mode protégé — dont l'entrée 64 bits est à 0x200.
pub fn image() -> Vec<u8> {
    let mut code = NOYAU_FACTICE.to_vec();
    code.extend([0u8; 0x21 * 16]); // l'IDT
    image_de(&code)
}

/// **Un `bzImage` autour de `code`**, posé à l'entrée 64 bits (0x200 octets
/// après le début du noyau en mode protégé) : de quoi démarrer quelques
/// instructions écrites à la main — une boucle, une faute, une remise à zéro.
pub fn image_de(code: &[u8]) -> Vec<u8> {
    let mut protege = vec![0u8; 0x200];
    protege.extend_from_slice(code);
    protege.resize(protege.len().next_multiple_of(16), 0);
    let mut image = vec![0u8; 1024];
    image[0x1F1] = 1; // un secteur de setup derrière le secteur d'amorce
    image[0x1F4..0x1F8].copy_from_slice(&((protege.len() / 16) as u32).to_le_bytes());
    image[0x1FE..0x200].copy_from_slice(&0xAA55u16.to_le_bytes());
    image[0x202..0x206].copy_from_slice(b"HdrS");
    image[0x206..0x208].copy_from_slice(&0x020Fu16.to_le_bytes());
    image[0x211] = 0x01;
    image[0x234] = 1;
    image[0x236..0x238].copy_from_slice(&0x0001u16.to_le_bytes()); // l'entrée 64 bits
    image[0x238..0x23C].copy_from_slice(&255u32.to_le_bytes());
    image[0x258..0x260].copy_from_slice(&0x0100_0000u64.to_le_bytes());
    image[0x260..0x264].copy_from_slice(&0x1_0000u32.to_le_bytes());
    image.extend(protege);
    image
}

/// **Une boucle sans fin**, `jmp .`, interruptions coupées : une course qui
/// ne finit que si on l'arrête.
pub const BOUCLE: [u8; 3] = [0xFA, 0xEB, 0xFE];

/// **`ud2`** en anneau zéro, sans IDT : une faute que rien ne livre.
pub const FAUTE: [u8; 2] = [0x0F, 0x0B];

/// **L'impulsion de remise à zéro** : `mov $0xfe, %al ; out %al, $0x64`, puis
/// `jmp .` — ce que Linux fait pour redémarrer.
pub const REMISE: [u8; 6] = [0xB0, 0xFE, 0xE6, 0x64, 0xEB, 0xFE];
