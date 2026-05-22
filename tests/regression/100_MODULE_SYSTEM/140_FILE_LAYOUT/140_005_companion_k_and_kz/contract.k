// Phase 2.1: the contract lives in a .k file — public event signature only,
// no host body. The implementation companion is contract.kz alongside.
//
// Today's resolver loses this file: probe order is .kgpu, .kjs, .kz, .kc, .k,
// so when contract.kz exists as a sibling it wins and contract.k is never
// opened. The event below never makes it into the registry, and the proc in
// contract.kz has nothing to attach to. This test fails until the loader
// learns to load every companion file sharing a stem.

~pub event compute { x: u32 }
| done u32
