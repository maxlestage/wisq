// **Deux fois la même boucle, deux traductions d'adresse.**
//
// Aujourd'hui la machine replie : `i32.wrap_i64` puis `i32.and`. Une vraie
// pagination fait autre chose : un tampon de traduction consulté en ligne, et
// une marche à quatre niveaux quand il est vide. Ce fichier engendre UN module
// qui exporte les trois formes, pour que JavaScriptCore les compile de la même
// façon et qu'on ne chronomètre que la différence.
//
// **Pourquoi elle est ici et non jetée.** Elle a d'abord été écrite comme une
// sonde jetable — son en-tête le disait —, et son chiffre est parti sur le site
// pendant que le module qui l'avait produit mourait avec son conteneur. Un
// nombre publié sans sa preuve n'est plus une mesure, c'est une affirmation.
// Alors la sonde entre, et n'importe qui peut la relancer :
//
//     cargo run -p wisq-vm --release --example paging-probe -- /tmp/paging.wasm
//     bun scripts/wasm-paging-probe.js /tmp/paging.wasm
//
// Le `.wasm` est **engendré, pas commis** : un module binaire dans l'arbre est
// une chose que personne ne relit et que rien ne régénère.

fn uleb(mut n: u64, out: &mut Vec<u8>) {
    loop {
        let mut b = (n & 0x7f) as u8;
        n >>= 7;
        if n != 0 {
            b |= 0x80;
        }
        out.push(b);
        if n == 0 {
            break;
        }
    }
}
fn sleb(mut n: i64, out: &mut Vec<u8>) {
    loop {
        let b = (n & 0x7f) as u8;
        n >>= 7;
        let sign = b & 0x40 != 0;
        if (n == 0 && !sign) || (n == -1 && sign) {
            out.push(b);
            break;
        }
        out.push(b | 0x80);
    }
}

#[derive(Default, Clone)]
struct Code(Vec<u8>);
impl Code {
    fn op(&mut self, b: u8) -> &mut Self {
        self.0.push(b);
        self
    }
    fn get(&mut self, i: u32) -> &mut Self {
        self.op(0x20);
        uleb(i as u64, &mut self.0);
        self
    }
    fn set(&mut self, i: u32) -> &mut Self {
        self.op(0x21);
        uleb(i as u64, &mut self.0);
        self
    }
    fn tee(&mut self, i: u32) -> &mut Self {
        self.op(0x22);
        uleb(i as u64, &mut self.0);
        self
    }
    fn i32c(&mut self, v: i32) -> &mut Self {
        self.op(0x41);
        sleb(v as i64, &mut self.0);
        self
    }
    fn i64c(&mut self, v: i64) -> &mut Self {
        self.op(0x42);
        sleb(v, &mut self.0);
        self
    }
    // alignement annoncé nul : l'invité n'aligne rien.
    fn load64(&mut self, off: u32) -> &mut Self {
        self.op(0x29);
        uleb(0, &mut self.0);
        uleb(off as u64, &mut self.0);
        self
    }
    fn load32(&mut self, off: u32) -> &mut Self {
        self.op(0x28);
        uleb(2, &mut self.0);
        uleb(off as u64, &mut self.0);
        self
    }
    fn store64(&mut self, off: u32) -> &mut Self {
        self.op(0x37);
        uleb(3, &mut self.0);
        uleb(off as u64, &mut self.0);
        self
    }
    fn store32(&mut self, off: u32) -> &mut Self {
        self.op(0x36);
        uleb(2, &mut self.0);
        uleb(off as u64, &mut self.0);
        self
    }
    fn call(&mut self, f: u32) -> &mut Self {
        self.op(0x10);
        uleb(f as u64, &mut self.0);
        self
    }
    fn br(&mut self, d: u32) -> &mut Self {
        self.op(0x0c);
        uleb(d as u64, &mut self.0);
        self
    }
    fn br_if(&mut self, d: u32) -> &mut Self {
        self.op(0x0d);
        uleb(d as u64, &mut self.0);
        self
    }
}

/// Un corps de fonction et les groupes de variables locales qu'il déclare.
/// Nommé parce que clippy refuse la paire brute — et il a raison : `(Vec<u8>,
/// &[(u32, u8)])` ne dit rien de ce que sont ces octets.
type Function<'a> = (Vec<u8>, &'a [(u32, u8)]);

const PAGES: u32 = 4096; // 256 Mio de mémoire linéaire
const FOLD_MASK: i32 = 0x07ff_ffff; // le repli d'aujourd'hui : 128 Mio
const PML4: i32 = 0x0900_0000;
const TLB: i32 = 0x0a00_0000;
const TLB_SLOTS: i32 = 64;

// `run(count, stride, wsMask) -> i64`
const L_ACC: u32 = 3; // i64
const L_VA: u32 = 4; // i64
const L_VPN: u32 = 5; // i64
const L_I: u32 = 6; // i32
const L_SLOT: u32 = 7; // i32
const RUN_LOCALS: &[(u32, u8)] = &[(3, 0x7e), (2, 0x7f)];
// `marche(vpn) -> i32`
const WALK_LOCALS: &[(u32, u8)] = &[(2, 0x7f)];
const W_P: u32 = 1;
const W_SLOT: u32 = 2;

/// L'adresse invitée du tour, rangée dans `vaddr`. **Identique dans les trois
/// formes** : ce n'est pas ce qu'on mesure.
fn address(c: &mut Code) {
    c.get(L_I)
        .get(1)
        .op(0x6c)
        .get(2)
        .op(0x71)
        .op(0xad)
        .set(L_VA);
}

fn loop_body(translate: &dyn Fn(&mut Code)) -> Vec<u8> {
    let mut c = Code::default();
    c.i64c(0).set(L_ACC);
    c.i32c(0).set(L_I);
    c.op(0x02).op(0x40); // block
    c.op(0x03).op(0x40); //   loop
    c.get(L_I).get(0).op(0x4f).br_if(1); //     i >= count ? sortir du block
    address(&mut c);
    translate(&mut c); //     laisse une adresse physique i32
    c.load64(0);
    c.get(L_ACC).op(0x7c).set(L_ACC);
    c.get(L_I).i32c(1).op(0x6a).set(L_I);
    c.br(0);
    c.op(0x0b).op(0x0b); //   end loop, end block
    c.get(L_ACC);
    c.op(0x0b); // end func
    c.0
}

fn declare(groups: &[(u32, u8)]) -> Vec<u8> {
    let mut out = Vec::new();
    uleb(groups.len() as u64, &mut out);
    for (count, ty) in groups {
        uleb(*count as u64, &mut out);
        out.push(*ty);
    }
    out
}

fn main() {
    let fold = |c: &mut Code| {
        c.get(L_VA).op(0xa7).i32c(FOLD_MASK).op(0x71);
    };

    let tlb = |c: &mut Code| {
        c.get(L_VA).i64c(12).op(0x88).set(L_VPN);
        c.get(L_VPN)
            .op(0xa7)
            .i32c(TLB_SLOTS - 1)
            .op(0x71)
            .i32c(4)
            .op(0x74)
            .i32c(TLB)
            .op(0x6a)
            .tee(L_SLOT);
        c.load64(0).get(L_VPN).op(0x51); // étiquette == vpn ?
        c.op(0x04).op(0x7f); // if (result i32)
        c.get(L_SLOT).load32(8);
        c.op(0x05); // else
        c.get(L_VPN).call(1);
        c.op(0x0b);
        c.get(L_VA).op(0xa7).i32c(4095).op(0x71).op(0x72);
    };

    let walk = |c: &mut Code| {
        c.get(L_VA).i64c(12).op(0x88).set(L_VPN);
        c.get(L_VPN).call(1);
        c.get(L_VA).op(0xa7).i32c(4095).op(0x71).op(0x72);
    };

    // La marche : quatre lectures de huit octets, chacune dépendante de la
    // précédente, puis l'installation. C'est la forme x86, pas une image.
    let mut w = Code::default();
    w.i32c(PML4);
    for (rank, shift) in [27i64, 18, 9, 0].iter().copied().enumerate() {
        if rank > 0 {
            w.get(W_P);
        }
        w.get(0)
            .i64c(shift)
            .op(0x88)
            .op(0xa7)
            .i32c(511)
            .op(0x71)
            .i32c(3)
            .op(0x74)
            .op(0x6a);
        w.load64(0).op(0xa7).set(W_P);
    }
    w.get(0)
        .op(0xa7)
        .i32c(TLB_SLOTS - 1)
        .op(0x71)
        .i32c(4)
        .op(0x74)
        .i32c(TLB)
        .op(0x6a)
        .set(W_SLOT);
    w.get(W_SLOT).get(0).store64(0);
    w.get(W_SLOT).get(W_P).store32(8);
    w.get(W_P);
    w.op(0x0b);

    let mut m = vec![0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00];
    fn section(id: u8, body: Vec<u8>, m: &mut Vec<u8>) {
        m.push(id);
        let mut len = Vec::new();
        uleb(body.len() as u64, &mut len);
        m.extend(len);
        m.extend(body);
    }

    let mut t = Vec::new();
    uleb(2, &mut t);
    t.extend([0x60, 0x03, 0x7f, 0x7f, 0x7f, 0x01, 0x7e]);
    t.extend([0x60, 0x01, 0x7e, 0x01, 0x7f]);
    section(1, t, &mut m);

    let mut f = Vec::new();
    uleb(4, &mut f);
    f.extend([0u8, 1, 0, 0]);
    section(3, f, &mut m);

    let mut mem = Vec::new();
    uleb(1, &mut mem);
    mem.push(0x01);
    uleb(PAGES as u64, &mut mem);
    uleb(PAGES as u64, &mut mem);
    section(5, mem, &mut m);

    let mut e = Vec::new();
    uleb(4, &mut e);
    for (nom, kind, idx) in [
        ("repli", 0u8, 0u32),
        ("tampon", 0, 2),
        ("marche", 0, 3),
        ("mem", 2, 0),
    ] {
        uleb(nom.len() as u64, &mut e);
        e.extend(nom.as_bytes());
        e.push(kind);
        uleb(idx as u64, &mut e);
    }
    section(7, e, &mut m);

    let bodies: Vec<Function> = vec![
        (loop_body(&fold), RUN_LOCALS),
        (w.0.clone(), WALK_LOCALS),
        (loop_body(&tlb), RUN_LOCALS),
        (loop_body(&walk), RUN_LOCALS),
    ];
    let mut code = Vec::new();
    uleb(bodies.len() as u64, &mut code);
    for (body, locals) in bodies {
        let mut f = declare(locals);
        f.extend(body);
        uleb(f.len() as u64, &mut code);
        code.extend(f);
    }
    section(10, code, &mut m);

    std::fs::write(std::env::args().nth(1).unwrap(), &m).unwrap();
    eprintln!("module de {} octets", m.len());
}
