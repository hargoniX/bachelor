#import "@preview/polylux:0.3.1": *
#import "@preview/codelst:1.0.0": sourcecode

#import "theme.typ" : *

#show: genua-theme.with()

#set text(font: "Fira Sans", weight: "light", size: 20pt)
#set strong(delta: 100)
#set par(justify: true)

#title-slide(
  author: [Henrik Böving],
  title: "VeRix: A Verified Rust ix(4) driver",
  date: "DD.MM.2024",
  extra: "Thesis Defense",
  logo_company: "figures/genua.svg",
  logo_institution: "figures/hm.svg",
  logo_size: 45%,
)

#slide(title: "Table of contents")[
  #genua-outline
]


#new-section-slide("Goals")
#slide(title: "Goals")[
  Verify interactions of drivers with hardware by:
  1. enabling driver development in Rust on L4.Fiasco
  2. developing a driver framework for real-world hardware and formal verification
  3. developing an Intel 82599 driver on top of it
  4. verifying that this driver:
     - doesn't panic (safety)
     - doesn't put the hardware into an undefined state (safety)
     - receives all packets that are received by the hardware (correctness)
     - correctly instructs the hardware to send packets (correctness)
]

#new-section-slide("Formal Verification in Rust")
#slide(title: "Tools")[
#figure(
  table(
    columns: (auto, auto, auto, auto),
    [*Feature*], [*Kani*],         [*Creusot*],      [*Prusti*],
    [Core],      [#sym.checkmark], [#sym.checkmark], [#sym.checkmark],
    [Generics],  [#sym.checkmark], [#sym.checkmark], [#sym.checkmark],
    [Traits],    [#sym.checkmark], [#sym.checkmark], [#sym.checkmark],
    [`unsafe`],  [#sym.checkmark], [-],              [-],
    [`RefCell`], [#sym.checkmark], [#sym.checkmark], [#sym.checkmark],
  ),
  caption: [Capabilities of formal verification tools for Rust],
) <requirements>
]

#slide(title: "Kani guarantees")[
Guarantees provided by Kani:
- memory safety, that is:
  - pointer type safety
  - the absence of invalid pointer indexing
  - the absence of out-of-bounds accesses
- the absence of mathematical errors like arithmetic overflow
- the absence of runtime panics
- the absence of violations of user-added assertions
]

#slide(title: "Kani Basics")[
```rust
fn get_wrapped(a: &[u32], i: usize) -> u32 {
    return a[i % a.len()];
}

#[kani::proof]
fn check_get_wrapped() {
    let size: usize = kani::any();
    kani::assume(size < 128);
    let index: usize = kani::any();
    let array: Vec<u32> = vec![0; size];
    get_wrapped(&array, index);
}
```
]

#slide(title: "Kani counter examples")[
```rust
#[test]
fn kani_concrete_playback_check_get_wrapped_10606138830414890630() {
    let concrete_vals: Vec<Vec<u8>> = vec![
        // 0ul
        vec![0, 0, 0, 0, 0, 0, 0, 0],
        // 18446744073709551615ul
        vec![255, 255, 255, 255, 255, 255, 255, 255],
    ];
    kani::concrete_playback_run(concrete_vals, check_get_wrapped);
}
```
]

#slide(title: "Kani cover")[
```rust
fn complicated() -> usize {
    kani::any()
}

#[kani::proof]
fn check_get_wrapped() {
    let size: usize = kani::any();
    kani::assume(size < 128);
    let array: Vec<u32> = vec![0; size];
    let index = complicated();
    kani::cover(index >= array.len(), "Out of bounds indexing possible");
    get_wrapped(&array, index);
}
```
]

#slide(title: "Kani loops")[
```rust
fn zeroize(buffer: &mut [u8]) {
    for i in 0..buffer.len() { buffer[i] = 0; }
}

#[kani::unwind(32)] // <== HERE!
#[kani::proof]
fn check_zeroize() {
    let size: usize = kani::any_where(|&size| size > 0 && size < 32);
    let mut buffer: Vec<u8> = vec![10; size];
    zeroize(&mut buffer);
    let index: usize = kani::any_where(|&index| index < buffer.len());
    assert!(buffer[index] == 0);
}
```
]

#slide(title: "Kani stubs")[
```rust
fn interaction() {
    thread::sleep(Duration::from_secs(1));
    rate_limited_functionality();
}

#[kani::stub(thread::sleep, mock_sleep)] // <== HERE!
#[kani::proof]
fn check_interaction() {
    interaction();
}
```
]

#new-section-slide("verix")

#slide(title: "Architecture")[
#figure(
  image("figures/drawio/verix-arch.drawio.pdf.svg", width: 80%),
  caption: [Architecture]
) <arch>
]

#slide(title: [`pc-hal`])[
`embedded-hal` style library, providing traits for:
- DMA mappings
- PCI bus
- PCI config space
- raw pointer-based MMIO interfaces (`svd2rust` style)
]

#slide(title: [`ixy` Register Access])[
```rust
pub const IXGBE_CTRL: u32 = 0x00000;
pub const IXGBE_CTRL_LNK_RST: u32 = 0x00000008;
pub const IXGBE_CTRL_RST: u32 = 0x04000000;
pub const IXGBE_CTRL_RST_MASK: u32 = IXGBE_CTRL_LNK_RST | IXGBE_CTRL_RST;
fn set_reg32(&self, reg: u32, value: u32) {
    unsafe {
        ptr::write_volatile(
            (self.addr as usize + reg as usize) as *mut u32,
            value
        );
    }
}
self.set_reg32(IXGBE_CTRL, IXGBE_CTRL_RST_MASK);
```
]

#slide(title: [`pc-hal` Register Access])[
```rust
mm2types! {
    Intel82599 Bit32 {
        Bar0 {
            ctrl @ 0x000000 RW {
                // Other fields
                lrst @ 3,
                rst @ 26,
            }
        }
    }
}

bar0.ctrl().modify(|_, w| w.lrst(1).rst(1));
```
]

#slide(title: "verix")[
  Driver performs three steps:
  1. Initialization through PCI config space
  2. Initialization through MMIO config space
  3. Packet processing through DMA queues
]

#slide(title: "RX queue state")[
#figure(
  image("figures/drawio/rx-queue.drawio.pdf.svg", width: 70%),
  caption: [Example RX queue]
) <rx-queue-1>
]

#slide(title: "Driver state")[
The driver maintains three additional things for itself:
1. A DMA allocator that manages the buffers in the DMA mapped packet buffer array.
2. A map from queue slots to DMA buffer identifiers
3. The `rx_index`, it contains the location that the driver will read the next packet from.
]

#slide(title: "Driver invariants")[
In addition to this, the driver maintains two important invariants:
1. `rx_index` is always $"RDT" + 1$.
2. Strengthening of the hardware assumption that all descriptors in the interval $["RDH", "RDT")$ contain
   read descriptors to the interval $["RDH", "RDT"]$.
]

#slide(title: "Receiving a packet")[

These two assumptions allow for the receive operation for one packet to be implemented as follows:
1. Poll until DD at `rx_index` is set to 1.
2. Keep the buffer that was used at `rx_index` to return it to the caller later.
3. Replace the buffer remembered for `rx_index` with a fresh one and write a read descriptor with it to `rx_index`.
4. As the descriptor at RDT is already initialized as a read, advance RDT and the `rx_index`.
]

#slide(title: "Verifying packet receiving")[
1. prove that the RX queue state after configuration is valid (Kani checked)
2. prove that if the queue state is valid and `rx()` is called the state remains valid (Kani checked)
3. This constitutes an induction proof that shows we always remain in a valid state (meta)
4. For all valid queue states (and thus for all reachable states):
   - prove that if the queue has a packet and we call `rx()` we get it (Kani checked)
   - prove that if the queue is empty and we call `rx()` we get nothing (Kani checked)
]

#new-section-slide("Evaluation")

#slide(title: "Verification")[
  - entire verification effort consumed approximately 150 man-hours
  - two limitations:
    1. `Drop` functionality DMA allocator could not be verified
    2. queue size is limited to 16 elements
]

#slide(title: "SAT Limitation")[
#figure(
  table(
    columns: (auto, auto, auto, auto),
    [*Solver*], [*Queue Size*], [*Time (hh:mm:ss)*], [*RAM (GB)*],
    [Minisat], [16], [Timeout], [-],
    [CaDiCal], [16], [$05:04:39$], [46],
    [CaDiCal], [32], [-], [OOM],
    [Kissat], [16], [$03:53:56$], [18],
    [Kissat], [32], [-], [OOM],
    [Glucose], [16], [$05:42:35$], [19],
    [Glucose], [32], [-], [OOM],
  ),
  caption: [Resource Consumption of different SAT solvers],
) <satres>
]

#slide(title: "SMT Limitation")[
#figure(
  table(
    columns: (auto, auto, auto),
    [*Solver*], [*Queue Size*], [*Result*],
    [Z3], [16], [Crashed CBMC],
    [CVC4], [16], [Crashed CVC4],
    [CVC5], [16], [Crashed CBMC],
  ),
  caption: [Resource Consumption of different SMT solvers],
) <smtres>
]

#slide(title: "Performance")[
#figure(
  table(
    columns: (auto, auto, auto, auto, auto),
    [*Implementation*], [*CPU Freq (GHz)*], [*Absolute (Mpps)*], [*Max (Mpps)*], [*Max\%*],
    [ixy C], [3.3], [27.4], [29.76], [92.07],
    [ixy.rs], [3.3], [27.4], [29.76], [92.07],
    [verix], [2.4], [11.9], [14.88], [79.97],
    [ixy C], [1.7], [17.2], [29.76], [57.80],
    [ixy.rs], [1.7], [17.2], [29.76], [57.80],
  ),
  caption: [Performance of ixy vs verix at a batch size of 64]
) <perf-packets>
]

#new-section-slide("Conclusion")
#slide(title: "Conclusion")[
  We thus conclude that we:
  - ported ixy to L4 at a, most likely, comparable performance
  - successfully applied our model-based proof strategy to a real world problem
  - verified the desired properties at a small but not irrelevant scale
  #pause
  Three extensions of our work seem interesting:
  - extend `pc-hal` to an `embedded-hal` style library
  - integrate verix with the rest of L4
  - improve the maximum verified queue size
]

#focus-slide[
  Questions?
]
