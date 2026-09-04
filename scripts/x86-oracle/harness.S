// L'oracle matériel : charger un état, exécuter des octets, relire l'état.
//
// La référence d'un cœur x86-64, c'est le processeur lui-même. Ce harnais
// charge les seize registres généraux et RFLAGS depuis la mémoire, saute dans
// une page exécutable qui contient les octets à l'essai, et relit tout au
// retour. Ce que la machine répond est le verdict ; aucun document n'est
// consulté.
//
// Deux détails rendent la chose possible. D'abord tous les chargements et
// rangements sont relatifs à RIP : ils ne demandent aucun registre de
// travail, et `mov` ne touche pas aux drapeaux, donc rien de ce que
// l'instruction à l'essai a laissé n'est écrasé. Ensuite le retour se fait par
// un saut indirect ajouté après les octets à l'essai, et non par un `ret` :
// une pile serait la pile de l'invité, pas la nôtre.

    .text
    .globl  wisq_x86_run
    .type   wisq_x86_run, @function

// void wisq_x86_run(uint64_t *state, void *code)
//   state[0..15]  les registres, dans l'ordre de l'encodage
//                 (rax rcx rdx rbx rsp rbp rsi rdi r8..r15)
//   state[16]     RFLAGS
//   state[17..48] les seize registres XMM, deux mots chacun, le bas d'abord
//   code          la page exécutable, terminée par le saut de retour
// Lu puis réécrit sur place.
//
// **Les XMM voyagent par `movdqu` et non `movdqa`.** L'alignement du tampon
// de l'appelant n'est pas le nôtre à décider ; exiger seize octets ferait
// dépendre le harnais d'une chose que le pilote pourrait changer sans le
// savoir, et la faute serait un plantage et non un mauvais chiffre. `movdqu`
// ne touche pas non plus aux drapeaux, ce qui est la même raison qui fait
// voyager les registres généraux par `mov`.
wisq_x86_run:
    push    %rbx
    push    %rbp
    push    %r12
    push    %r13
    push    %r14
    push    %r15

    mov     %rdi, wisq_state(%rip)
    mov     %rsi, wisq_code(%rip)
    mov     %rsp, wisq_host_rsp(%rip)
    mov     %rbp, wisq_host_rbp(%rip)
    leaq    wisq_return(%rip), %rax
    mov     %rax, wisq_return_slot(%rip)

    // Les drapeaux d'abord : popfq se sert de la pile, qui est encore la
    // nôtre. Ensuite plus rien ne touchera aux drapeaux.
    mov     16*8(%rdi), %rax
    push    %rax
    popfq

    // Les seize registres, relatifs à RIP, sans registre de travail. RDI est
    // chargé en dernier parce qu'il portait le pointeur.
    mov     wisq_state(%rip), %rdi

    // Les XMM d'abord, tant que RDI porte encore le pointeur d'état.
    // **La pile x87, chargée par FRSTOR.** L'image de 108 octets vit dans les
    // cases qui suivent les XMM ; c'est le pilote qui la fabrique, parce
    // qu'assembler un mot d'étiquettes en assembleur ne rendrait service à
    // personne.
    //
    // `FRSTOR` ne touche ni aux drapeaux, ni aux registres généraux, ni aux
    // XMM : c'est ce qui permet de l'ajouter sans rien changer aux sept corpus
    // déjà figés. `FNSAVE` au retour a la même propriété, et il n'attend pas
    // les exceptions — ce que ferait `FSAVE`, qui pourrait piéger.
    frstor  49*8(%rdi)

    movdqu  17*8(%rdi), %xmm0
    movdqu  19*8(%rdi), %xmm1
    movdqu  21*8(%rdi), %xmm2
    movdqu  23*8(%rdi), %xmm3
    movdqu  25*8(%rdi), %xmm4
    movdqu  27*8(%rdi), %xmm5
    movdqu  29*8(%rdi), %xmm6
    movdqu  31*8(%rdi), %xmm7
    movdqu  33*8(%rdi), %xmm8
    movdqu  35*8(%rdi), %xmm9
    movdqu  37*8(%rdi), %xmm10
    movdqu  39*8(%rdi), %xmm11
    movdqu  41*8(%rdi), %xmm12
    movdqu  43*8(%rdi), %xmm13
    movdqu  45*8(%rdi), %xmm14
    movdqu  47*8(%rdi), %xmm15

    mov     0*8(%rdi), %rax
    mov     1*8(%rdi), %rcx
    mov     2*8(%rdi), %rdx
    mov     3*8(%rdi), %rbx
    mov     5*8(%rdi), %rbp
    mov     6*8(%rdi), %rsi
    mov     8*8(%rdi), %r8
    mov     9*8(%rdi), %r9
    mov     10*8(%rdi), %r10
    mov     11*8(%rdi), %r11
    mov     12*8(%rdi), %r12
    mov     13*8(%rdi), %r13
    mov     14*8(%rdi), %r14
    mov     15*8(%rdi), %r15
    mov     4*8(%rdi), %rsp
    mov     7*8(%rdi), %rdi

    jmp     *wisq_code(%rip)

    .globl  wisq_return
wisq_return:
    // Ranger avant tout : `mov` ne touche pas aux drapeaux, donc ce que
    // l'instruction à l'essai a posé survit jusqu'à ce qu'on le lise.
    mov     %rax, wisq_out+0*8(%rip)
    mov     %rcx, wisq_out+1*8(%rip)
    mov     %rdx, wisq_out+2*8(%rip)
    mov     %rbx, wisq_out+3*8(%rip)
    mov     %rsp, wisq_out+4*8(%rip)
    mov     %rbp, wisq_out+5*8(%rip)
    mov     %rsi, wisq_out+6*8(%rip)
    mov     %rdi, wisq_out+7*8(%rip)
    mov     %r8,  wisq_out+8*8(%rip)
    mov     %r9,  wisq_out+9*8(%rip)
    mov     %r10, wisq_out+10*8(%rip)
    mov     %r11, wisq_out+11*8(%rip)
    mov     %r12, wisq_out+12*8(%rip)
    mov     %r13, wisq_out+13*8(%rip)
    mov     %r14, wisq_out+14*8(%rip)
    mov     %r15, wisq_out+15*8(%rip)
    fnsave  wisq_out+49*8(%rip)
    movdqu  %xmm0, wisq_out+17*8(%rip)
    movdqu  %xmm1, wisq_out+19*8(%rip)
    movdqu  %xmm2, wisq_out+21*8(%rip)
    movdqu  %xmm3, wisq_out+23*8(%rip)
    movdqu  %xmm4, wisq_out+25*8(%rip)
    movdqu  %xmm5, wisq_out+27*8(%rip)
    movdqu  %xmm6, wisq_out+29*8(%rip)
    movdqu  %xmm7, wisq_out+31*8(%rip)
    movdqu  %xmm8, wisq_out+33*8(%rip)
    movdqu  %xmm9, wisq_out+35*8(%rip)
    movdqu  %xmm10, wisq_out+37*8(%rip)
    movdqu  %xmm11, wisq_out+39*8(%rip)
    movdqu  %xmm12, wisq_out+41*8(%rip)
    movdqu  %xmm13, wisq_out+43*8(%rip)
    movdqu  %xmm14, wisq_out+45*8(%rip)
    movdqu  %xmm15, wisq_out+47*8(%rip)

    // La pile redevient la nôtre avant qu'on ose un pushfq.
    mov     wisq_host_rsp(%rip), %rsp
    pushfq
    pop     %rax
    mov     %rax, wisq_out+16*8(%rip)
    // **Et le drapeau de direction est effacé, une fois relu.** L'ABI exige
    // qu'il le soit à l'entrée comme à la sortie de toute fonction ; le C qui
    // nous appelle s'en sert sans le savoir, dans son `memcpy` et son
    // `printf`. Tant que rien n'essayait une instruction de chaîne en arrière,
    // il ne pouvait pas être posé et l'oubli ne se voyait pas — le premier cas
    // qui l'a posé a fait planter le harnais, pas l'instruction à l'essai.
    cld
    mov     wisq_host_rbp(%rip), %rbp

    // Recopier dans le tampon de l'appelant.
    mov     wisq_state(%rip), %rdi
    leaq    wisq_out(%rip), %rsi
    mov     $63, %rcx
1:  mov     (%rsi), %rax
    mov     %rax, (%rdi)
    add     $8, %rsi
    add     $8, %rdi
    dec     %rcx
    jnz     1b

    pop     %r15
    pop     %r14
    pop     %r13
    pop     %r12
    pop     %rbp
    pop     %rbx
    ret

    .globl  wisq_return_slot
    .data
    .align  8
wisq_state:        .quad 0
wisq_code:         .quad 0
wisq_host_rsp:     .quad 0
wisq_host_rbp:     .quad 0
wisq_return_slot:  .quad 0
// Quarante-neuf cases pour les registres, plus quatorze pour l'image x87 que
// `FNSAVE` y dépose — 108 octets arrondis à la case. Le premier jet avait
// gardé les quarante-neuf : `FNSAVE` écrivait alors au-delà de la fin de la
// section, et le harnais mourait d'un défaut de segmentation. Les sept corpus
// se régénéraient quand même, parce que ce qui suivait n'était plus lu ; c'est
// le premier cas qui a demandé la pile x87 qui l'a fait tomber.
wisq_out:          .fill 63, 8, 0
    .section .note.GNU-stack,"",@progbits
