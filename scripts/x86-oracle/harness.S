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
//   code          la page exécutable, terminée par le saut de retour
// Lu puis réécrit sur place.
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

    // La pile redevient la nôtre avant qu'on ose un pushfq.
    mov     wisq_host_rsp(%rip), %rsp
    pushfq
    pop     %rax
    mov     %rax, wisq_out+16*8(%rip)
    mov     wisq_host_rbp(%rip), %rbp

    // Recopier dans le tampon de l'appelant.
    mov     wisq_state(%rip), %rdi
    leaq    wisq_out(%rip), %rsi
    mov     $17, %rcx
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
wisq_out:          .fill 17, 8, 0
    .section .note.GNU-stack,"",@progbits
