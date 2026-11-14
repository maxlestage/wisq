// Ce que le vrai processeur fait d'un accès à cheval sur une page absente.
//
// Deux pages voisines ; la seconde est rendue inaccessible par `mprotect`.
// Chaque cas place un accès à `n` octets de la frontière, dans un enfant, et
// relève trois choses : la faute a-t-elle eu lieu, quelle adresse elle nomme
// (CR2, rendu par le noyau dans `si_addr`), et combien d'octets de la page
// présente ont changé avant elle.
//
// C'est la mesure derrière `Body::peek`, `Body::poke` et la sonde de `fxsave`
// dans `crates/wisq-vm/src/x86_wasm.rs` : un accès qui franchit la frontière
// faute avec CR2 sur le **premier octet de la page absente** et n'a rien
// écrit ; `fxsave` et `fxrstor` exigent leurs 512 octets et nomment le
// **dernier**.
//
// Ce qu'elle ne mesure pas : `sgdt`, `sidt` — en anneau 3 Linux les émule
// (UMIP), et c'est son `copy_to_user` qu'on verrait — ni `lgdt`, `lidt`,
// `lretq`, `iretq`, qui ne s'exécutent pas d'ici.
//
// Usage : cc -O1 -o /tmp/straddle scripts/x86-page-straddle-probe.c && /tmp/straddle
//
// Relevé le 14 novembre 2026 (Intel Xeon, Linux 6.18) :
//
//   mov %rax,(%rdi)   8 en page : passe, 8 octets écrits
//                     7, 4, 1   : faute, CR2 = frontière+0, 0 octet écrit
//   mov (%rsi),%rax   7, 4, 1   : faute, CR2 = frontière+0
//   push %rax         7, 4, 1, 0 : faute, CR2 = frontière+0, 0 octet écrit
//   pop %rax          7, 4, 1   : faute, CR2 = frontière+0
//   rep movsq ×2      12 en page : faute, CR2 = frontière+0, 8 octets écrits
//                                  (le premier élément, rien du second)
//   fxsave64          512 : passe, 416 octets écrits
//                     496 … 16 : faute, CR2 = aire+511, 0 octet écrit
//                     0 (aire entière dans la page absente) : CR2 = aire+511
//   fxrstor64         496 … 0 : faute, CR2 = aire+511
#define _GNU_SOURCE
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

static unsigned char *page;

static int changed(void) {
  int count = 0;
  for (int at = 0; at < 4096; at++) count += page[at] != 0xcc;
  return count;
}

static void fault(int signal, siginfo_t *info, void *context) {
  (void)signal;
  (void)context;
  char line[96];
  long from = (long)((unsigned char *)info->si_addr - (page + 4096));
  int length = snprintf(line, sizeof line, "faute, CR2 = frontière%+ld, %d octet(s) écrit(s)\n",
                        from, changed());
  if (write(1, line, length)) {
  }
  _exit(1);
}

static void attempt(const char *what, int inside) {
  printf("%-10s %4d en page : ", what, inside);
  fflush(stdout);
  pid_t child = fork();
  if (child != 0) {
    waitpid(child, NULL, 0);
    return;
  }
  // La pile de l'enfant peut être la page elle-même (`push`, `pop`) : le
  // gestionnaire a donc la sienne.
  static char alternate[65536];
  stack_t stack = {alternate, 0, sizeof alternate};
  sigaltstack(&stack, NULL);
  struct sigaction action;
  memset(&action, 0, sizeof action);
  action.sa_sigaction = fault;
  action.sa_flags = SA_SIGINFO | SA_ONSTACK;
  sigaction(SIGSEGV, &action, NULL);
  sigaction(SIGBUS, &action, NULL);

  unsigned char *at = page + 4096 - inside;
  unsigned long value = 0x8877665544332211ul;
  if (!strcmp(what, "mov-ecrit")) {
    __asm__ volatile("movq %%rax,(%%rdi)" : : "D"(at), "a"(value) : "memory");
  } else if (!strcmp(what, "mov-lit")) {
    __asm__ volatile("movq (%%rsi),%%rax" : "=a"(value) : "S"(at) : "memory");
  } else if (!strcmp(what, "push")) {
    __asm__ volatile("mov %%rsp,%%rbx; lea 8(%%rdi),%%rsp; push %%rax; mov %%rbx,%%rsp"
                     :
                     : "D"(at), "a"(value)
                     : "memory", "rbx");
  } else if (!strcmp(what, "pop")) {
    __asm__ volatile("mov %%rsp,%%rbx; mov %%rdi,%%rsp; pop %%rax; mov %%rbx,%%rsp"
                     : "=a"(value)
                     : "D"(at)
                     : "memory", "rbx");
  } else if (!strcmp(what, "rep-movsq")) {
    static unsigned long source[2] = {1, 2};
    void *from = source, *to = at;
    long count = 2;
    __asm__ volatile("rep movsq" : "+S"(from), "+D"(to), "+c"(count) : : "memory");
  } else if (!strcmp(what, "fxsave")) {
    __asm__ volatile("fxsave64 (%%rdi)" : : "D"(at) : "memory");
  } else if (!strcmp(what, "fxrstor")) {
    __asm__ volatile("fxrstor64 (%%rdi)" : : "D"(at) : "memory");
  }
  printf("passe, %d octet(s) écrit(s)\n", changed());
  exit(0);
}

int main(void) {
  page = mmap(NULL, 8192, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (page == MAP_FAILED) return 1;
  memset(page, 0xcc, 4096);
  mprotect(page + 4096, 4096, PROT_NONE);

  static const int narrow[] = {8, 7, 4, 1};
  for (unsigned i = 0; i < 4; i++) attempt("mov-ecrit", narrow[i]);
  for (unsigned i = 1; i < 4; i++) attempt("mov-lit", narrow[i]);
  for (unsigned i = 0; i < 4; i++) attempt("push", narrow[i]);
  attempt("push", 0);
  for (unsigned i = 1; i < 4; i++) attempt("pop", narrow[i]);
  attempt("rep-movsq", 16);
  attempt("rep-movsq", 12);
  attempt("rep-movsq", 4);
  static const int area[] = {512, 496, 448, 416, 256, 16, 0};
  for (unsigned i = 0; i < 7; i++) attempt("fxsave", area[i]);
  // `fxrstor` sur 512 octets de `0xcc` lèverait #GP (MXCSR réservé) : ce
  // n'est pas la question posée ici.
  for (unsigned i = 1; i < 7; i++) attempt("fxrstor", area[i]);
  return 0;
}
